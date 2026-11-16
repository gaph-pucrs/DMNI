/**
 * DMNI
 * @file DMA.sv
 *
 * @author Angelo Elias Dal Zotto (angelo.dalzotto@edu.pucrs.br)
 * GAPH - Hardware Design Support Group (https://corfu.pucrs.br)
 * PUCRS - Pontifical Catholic University of Rio Grande do Sul (http://pucrs.br/)
 *
 * @date October 2023
 *
 * @brief DMA functionality for DMNI
 */

`include "DMNIPkg.sv"

module DMA
    import DMNIPkg::*;
#(
    parameter HERMES_FLIT_SIZE = 32,
    parameter MEM_OUTSTANDING  = 4      /* Power of 2: memory transactions in flight, and send flits buffered */
)
(
    input  logic                            clk_i,
    input  logic                            rst_ni,

    /* Hermes input interface (RECEIVE) */
    input  logic                            noc_rx_i,
    input  logic                            noc_eop_i,
    output logic                            noc_credit_o,
    input  logic [(HERMES_FLIT_SIZE - 1):0] noc_data_i,

    /* Hermes output interface (SEND) */
    output logic                            noc_tx_o,
    output logic                            noc_eop_o,
    input  logic                            noc_ack_i,
    output logic [(HERMES_FLIT_SIZE - 1):0] noc_data_o,

    /* OBI memory interface */
    output logic                            mem_req_o,
    input  logic                            mem_gnt_i,
    output logic                     [31:0] mem_addr_o,
    output logic                            mem_we_o,
    output logic                     [ 3:0] mem_be_o,
    output logic                     [31:0] mem_wdata_o,
    input  logic                            mem_rvalid_i,
    input  logic                     [31:0] mem_rdata_i,

    /* Configuration interface */
    input  logic                            hermes_st_rcv_i,
    input  logic                            hermes_st_snd_i,
    input  logic                     [31:0] hermes_size_i,
    input  logic                     [31:0] hermes_size_2_i,
    input  logic                     [31:0] hermes_address_i,
    input  logic                     [31:0] hermes_address_2_i,
    output logic                     [31:0] hermes_received_cnt_o,
    output logic                            hermes_send_active_o,
    output logic                            hermes_receive_active_o,
    output logic                            hermes_receive_available_o,

    /* Monitoring interface */
    input  logic                            hermes_monitor_reset_i,
    input  logic                            hermes_monitor_sem_av_post_i,
    input  logic                            hermes_monitor_sem_oc_wait_i,
    input  logic                     [ 7:0] hermes_monitor_length_i,
    input  logic                     [ 7:0] hermes_monitor_flits_i,
    input  logic                     [31:0] hermes_monitor_addr_i,
    output logic                     [ 7:0] hermes_monitor_sem_oc_o,
    output logic                            hermes_monitor_active_o
);

    typedef enum {
        ARBIT_NONE,
        ARBIT_SEND,
        ARBIT_RECEIVE,
        ARBIT_MONITOR
    } arbit_t;

    arbit_t current_arbit;

    typedef enum logic [2:0] {
        HERMES_SEND_IDLE  = 3'b001,
        HERMES_SEND_DATA  = 3'b010,
        HERMES_SEND_DRAIN = 3'b100
    } hermes_send_t;

    hermes_send_t hermes_send_state;

    /**
     * OBI: a request holds until gnt. Every source below keeps its request
     * and address stable while waiting, and the arbiter does not switch.
     */
    logic mem_accept;
    assign mem_accept = mem_req_o && mem_gnt_i;

    /* Room to track one more response */
    logic rsp_room;

////////////////////////////////////////////////////////////////////////////////
// NoC Receive FSM
////////////////////////////////////////////////////////////////////////////////

    typedef enum logic [5:0] {
        HERMES_RECEIVE_HEADER          = 6'b000001,
        HERMES_RECEIVE_WAIT            = 6'b000010,
        HERMES_RECEIVE_DATA            = 6'b000100,
        HERMES_RECEIVE_EOP             = 6'b001000,
        HERMES_RECEIVE_LOOPBACK_HEADER = 6'b010000,
        HERMES_RECEIVE_LOOPBACK_DATA   = 6'b100000
    } hermes_receive_t;

    hermes_receive_t hermes_receive_state;

    /**
     * SR header: never a normal or monitoring packet. It always targets this PE,
     * because the router only delivers to the local port when the header's
     * address is its own (and force-IO is clear), so the DMNI drops it and
     * loops the rest of the packet back without checking the address.
     */
    logic sr_header;
    assign sr_header = noc_data_i[SR_FLAG];

    logic loopback_active;      /* either loopback state */
    assign loopback_active = (hermes_receive_state inside {HERMES_RECEIVE_LOOPBACK_HEADER, HERMES_RECEIVE_LOOPBACK_DATA});

    logic loopback_data;        /* the input buffer drives the output link */
    assign loopback_data = (hermes_receive_state == HERMES_RECEIVE_LOOPBACK_DATA);

    logic loopback_xfer;        /* one flit moves from the input buffer to the router */
    assign loopback_xfer = loopback_data && noc_rx_i && noc_ack_i;

    logic loopback_drop_header; /* the SR header is popped without being forwarded */
    assign loopback_drop_header = (hermes_receive_state == HERMES_RECEIVE_LOOPBACK_HEADER) && noc_rx_i;

    logic loopback_eop_ack;     /* the last flit of a looped packet left the input buffer */
    assign loopback_eop_ack = noc_eop_i && (loopback_xfer || loopback_drop_header);

    logic [31:0] hermes_receive_addr;
    logic [31:0] hermes_receive_size;

    /* Without an address the flits are dropped, with no memory write */
    logic receive_req;
    assign receive_req = (
        noc_rx_i
        && hermes_receive_active_o
        && current_arbit == ARBIT_RECEIVE
        && hermes_receive_addr != '0
        && rsp_room
    );

    /* A flit consumed by the Receive FSM */
    logic can_receive;
    assign can_receive = (
        noc_rx_i
        && hermes_receive_active_o
        && current_arbit == ARBIT_RECEIVE
        && (hermes_receive_addr == '0 || mem_accept)
    );
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_receive_addr     <= '0;
            hermes_receive_size     <= '0;
        end
        else begin
            if (hermes_receive_state == HERMES_RECEIVE_WAIT) begin
                hermes_receive_addr     <= hermes_address_i;
                hermes_receive_size     <= hermes_size_i;
            end
            else if (can_receive && hermes_receive_addr != '0) begin
                hermes_receive_addr <= hermes_receive_addr + 32'h4;
                hermes_receive_size <= hermes_receive_size - 32'b1;
            end
        end
    end

    hermes_receive_t hermes_receive_next_state;
    always_comb begin
        case (hermes_receive_state)
            HERMES_RECEIVE_HEADER: begin
                if (!noc_rx_i) begin
                    hermes_receive_next_state = HERMES_RECEIVE_HEADER;
                end
                else if (sr_header) begin
                    /* The loopback shares the output link with the Send FSM */
                    if (hermes_send_state != HERMES_SEND_IDLE)
                        hermes_receive_next_state = HERMES_RECEIVE_HEADER;
                    else
                        hermes_receive_next_state = HERMES_RECEIVE_LOOPBACK_HEADER; /* drop this header, forward the rest */
                end
                else begin
                    hermes_receive_next_state = (noc_data_i[23:16] != MONITOR)
                        ? HERMES_RECEIVE_WAIT
                        : HERMES_RECEIVE_EOP;
                end
            end
            HERMES_RECEIVE_WAIT:
                hermes_receive_next_state = hermes_st_rcv_i
                    ? HERMES_RECEIVE_DATA
                    : HERMES_RECEIVE_WAIT;
            HERMES_RECEIVE_DATA: begin
                if (can_receive) begin
                    if (noc_eop_i)
                        hermes_receive_next_state = HERMES_RECEIVE_HEADER;
                    else if (hermes_receive_size == 32'b1)
                        hermes_receive_next_state = HERMES_RECEIVE_WAIT;
                    else
                        hermes_receive_next_state = HERMES_RECEIVE_DATA;
                end
                else begin
                    hermes_receive_next_state = HERMES_RECEIVE_DATA;
                end
            end
            HERMES_RECEIVE_EOP:
                /* The monitor FSM may be stalled with the EOP flit still in the buffer */
                hermes_receive_next_state = (noc_rx_i && noc_eop_i && noc_credit_o)
                    ? HERMES_RECEIVE_HEADER
                    : HERMES_RECEIVE_EOP;
            HERMES_RECEIVE_LOOPBACK_HEADER: begin
                if (!noc_rx_i)
                    hermes_receive_next_state = HERMES_RECEIVE_LOOPBACK_HEADER;
                else
                    /* A single-flit SR packet has nothing to forward: drop it */
                    hermes_receive_next_state = noc_eop_i
                        ? HERMES_RECEIVE_HEADER
                        : HERMES_RECEIVE_LOOPBACK_DATA;
            end
            HERMES_RECEIVE_LOOPBACK_DATA:
                hermes_receive_next_state = (loopback_xfer && noc_eop_i)
                    ? HERMES_RECEIVE_HEADER
                    : HERMES_RECEIVE_LOOPBACK_DATA;
            default:
                hermes_receive_next_state = HERMES_RECEIVE_HEADER;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            hermes_receive_state <= HERMES_RECEIVE_HEADER;
        else 
            hermes_receive_state <= hermes_receive_next_state;
    end

    assign hermes_receive_active_o = (hermes_receive_state == HERMES_RECEIVE_DATA);
    assign hermes_receive_available_o = (hermes_receive_state == HERMES_RECEIVE_WAIT);

////////////////////////////////////////////////////////////////////////////////
// NoC Monitor FSM
////////////////////////////////////////////////////////////////////////////////
    
    typedef enum logic [6:0] {  
        HERMES_MONITOR_HEADER    = 7'b0000001,
        HERMES_MONITOR_AVAILABLE = 7'b0000010,
        HERMES_MONITOR_RECEIVE   = 7'b0000100,
        HERMES_MONITOR_OCCUPIED  = 7'b0001000,
        HERMES_MONITOR_EOP       = 7'b0010000,
        HERMES_MONITOR_DROP      = 7'b0100000,
        HERMES_MONITOR_DROP_OCC  = 7'b1000000
    } hermes_monitor_t;
    
    hermes_monitor_t hermes_monitor_state;

    logic mon_sem_av_wait;
    assign mon_sem_av_wait = (hermes_monitor_state == HERMES_MONITOR_AVAILABLE);

    logic [7:0] monitor_sem_av;

    logic monitor_available;
    assign monitor_available = (monitor_sem_av != '0) || hermes_monitor_sem_av_post_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            monitor_sem_av <= '0;
        end
        else begin
            if (hermes_monitor_reset_i)
                monitor_sem_av <= hermes_monitor_length_i;
            else if (hermes_monitor_sem_av_post_i && !mon_sem_av_wait)
                monitor_sem_av <= monitor_sem_av + 1'b1;
            else if (mon_sem_av_wait && monitor_available && !hermes_monitor_sem_av_post_i)
                monitor_sem_av <= monitor_sem_av - 1'b1;
        end
    end
    
    logic [7:0] monitor_cnt;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            monitor_cnt <= '0;
        end
        else begin
            if (hermes_monitor_state == HERMES_MONITOR_AVAILABLE)
                monitor_cnt <= '0;
            else if (can_monitor)
                monitor_cnt <= monitor_cnt + 1'b1;
        end
    end

    hermes_monitor_t hermes_monitor_next_state;
    always_comb begin
        case (hermes_monitor_state)
            HERMES_MONITOR_HEADER: begin
                if (noc_rx_i) begin
                    hermes_monitor_next_state = (!sr_header && noc_data_i[23:16] == MONITOR)
                        ? HERMES_MONITOR_AVAILABLE
                        : HERMES_MONITOR_EOP;
                end
                else begin
                    hermes_monitor_next_state = HERMES_MONITOR_HEADER;
                end
            end
            HERMES_MONITOR_AVAILABLE:
                hermes_monitor_next_state = monitor_available
                    ? HERMES_MONITOR_RECEIVE
                    : HERMES_MONITOR_DROP;
            HERMES_MONITOR_RECEIVE: begin
                if (can_monitor && noc_eop_i)
                    hermes_monitor_next_state = HERMES_MONITOR_OCCUPIED;
                else if (can_monitor && (monitor_cnt == (hermes_monitor_flits_i - 1'b1)))
                    hermes_monitor_next_state = HERMES_MONITOR_DROP_OCC;
                else
                    hermes_monitor_next_state = HERMES_MONITOR_RECEIVE;
            end
            HERMES_MONITOR_EOP:
                hermes_monitor_next_state = ((can_receive && noc_eop_i) || loopback_eop_ack)
                    ? HERMES_MONITOR_HEADER
                    : HERMES_MONITOR_EOP;
            HERMES_MONITOR_DROP:
                hermes_monitor_next_state = (noc_rx_i && noc_eop_i)
                    ? HERMES_MONITOR_HEADER
                    : HERMES_MONITOR_DROP;
            HERMES_MONITOR_DROP_OCC:
                hermes_monitor_next_state = (noc_rx_i && noc_eop_i)
                    ? HERMES_MONITOR_OCCUPIED
                    : HERMES_MONITOR_DROP_OCC;
            default:    /* HERMES_MONITOR_OCCUPIED */
                hermes_monitor_next_state = HERMES_MONITOR_HEADER;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            hermes_monitor_state <= HERMES_MONITOR_HEADER;
        else 
            hermes_monitor_state <= hermes_monitor_next_state;
    end

    logic [ 7:0] hermes_monitor_index;
    logic [15:0] hermes_monitor_offset;
    logic [31:0] hermes_monitor_addr;

    logic monitor_req;
    assign monitor_req = (
        noc_rx_i
        && hermes_monitor_active_o
        && current_arbit == ARBIT_MONITOR
        && hermes_monitor_addr != '0
        && rsp_room
    );

    /* A flit consumed by the Monitor FSM */
    logic can_monitor;
    assign can_monitor = (
        noc_rx_i
        && hermes_monitor_active_o
        && current_arbit == ARBIT_MONITOR
        && (hermes_monitor_addr == '0 || mem_accept)
    );
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_monitor_addr   <= '0;
            hermes_monitor_index  <= '0;
            hermes_monitor_offset <= '0;
        end
        else begin
            if (hermes_monitor_state == HERMES_MONITOR_HEADER) begin
                if ((hermes_monitor_index == hermes_monitor_length_i) || hermes_monitor_reset_i) begin
                    hermes_monitor_index  <= '0;
                    hermes_monitor_offset <= '0;
                end
            end
            else if (hermes_monitor_state == HERMES_MONITOR_AVAILABLE) begin
                hermes_monitor_addr <= hermes_monitor_addr_i + 32'(hermes_monitor_offset);
            end
            else if (can_monitor && hermes_monitor_addr != '0) begin
                hermes_monitor_addr   <= hermes_monitor_addr   + 32'h00000004;
                hermes_monitor_offset <= hermes_monitor_offset + 16'h0004;
                if (noc_eop_i)
                    hermes_monitor_index <= hermes_monitor_index + 1'b1;
            end
        end
    end

    logic mon_sem_oc_post;
    assign mon_sem_oc_post = (hermes_monitor_state == HERMES_MONITOR_OCCUPIED);

    logic mon_sem_oc_available;
    assign mon_sem_oc_available = (hermes_monitor_sem_oc_o != '0) || mon_sem_oc_post;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_monitor_sem_oc_o <= '0;
        end
        else begin
            if (hermes_monitor_reset_i)
                hermes_monitor_sem_oc_o <= '0;
            else if (mon_sem_oc_post && !hermes_monitor_sem_oc_wait_i)
                hermes_monitor_sem_oc_o <= hermes_monitor_sem_oc_o + 1'b1;
            else if (hermes_monitor_sem_oc_wait_i && mon_sem_oc_available && !mon_sem_oc_post)
                hermes_monitor_sem_oc_o <= hermes_monitor_sem_oc_o - 1'b1;
        end
    end

    assign hermes_monitor_active_o = (hermes_monitor_state == HERMES_MONITOR_RECEIVE);

////////////////////////////////////////////////////////////////////////////////
// NoC Send FSM
////////////////////////////////////////////////////////////////////////////////

    logic [31:0] hermes_send_addr;
    logic [31:0] hermes_send_addr_2;
    logic [31:0] hermes_send_size;
    logic [31:0] hermes_send_size_2;

    logic                            send_tx;
    logic                            send_eop;
    logic [(HERMES_FLIT_SIZE - 1):0] send_data;

    /* Flits read or being read and not sent yet: they all fit the send buffer */
    localparam int SEND_CNT_W = $clog2(MEM_OUTSTANDING + 1);
    logic [SEND_CNT_W - 1:0] send_count;

    logic send_room;
    assign send_room = (send_count != SEND_CNT_W'(MEM_OUTSTANDING));

    logic send_req;
    assign send_req = (
        hermes_send_state == HERMES_SEND_DATA
        && current_arbit == ARBIT_SEND
        && send_room
        && rsp_room
    );

    logic send_read;
    assign send_read = current_arbit == ARBIT_SEND && mem_accept;

    logic send_read_last;
    assign send_read_last = send_read && (
        (hermes_send_size == 32'b1 && hermes_send_size_2 == '0) ||
        (hermes_send_size == '0    && hermes_send_size_2 == 32'b1)
    );

    logic send_pop;
    assign send_pop = send_tx && noc_ack_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            send_count <= '0;
        else
            send_count <= send_count + SEND_CNT_W'(send_read) - SEND_CNT_W'(send_pop);
    end

    /* Responses come in order: remember which ones carry a flit to send */
    logic rsp_send;
    logic rsp_last;

    /* verilator lint_off UNUSEDSIGNAL */
    logic rsp_tx;
    logic rsp_almost_full;
    logic rsp_almost_empty;
    logic [$clog2(MEM_OUTSTANDING + 1) - 1:0] rsp_count;
    /* verilator lint_on UNUSEDSIGNAL */

    RingBuffer #(
        .DATA_SIZE              (2              ),
        .BUFFER_SIZE            (MEM_OUTSTANDING),
        .FIRST_WORD_FALL_THROUGH(0              ),
        .ALMOST_FULL_THRESHOLD  (0              ),
        .ALMOST_EMPTY_THRESHOLD (0              )
    )
    rsp_buffer (
        .clk_i         (clk_i                    ),
        .rst_ni        (rst_ni                   ),
        .buf_rst_i     (1'b0                     ),
        .rx_i          (mem_accept               ),
        .rx_ack_o      (rsp_room                 ),
        .data_i        ({send_read, send_read_last}),
        .tx_o          (rsp_tx                   ),
        .tx_ack_i      (mem_rvalid_i             ),
        .data_o        ({rsp_send, rsp_last}     ),
        .count_o       (rsp_count                ),
        .almost_full_o (rsp_almost_full          ),
        .almost_empty_o(rsp_almost_empty         )
    );

    logic send_rsp;
    assign send_rsp = mem_rvalid_i && rsp_send;

    /* Send buffer: read flits wait here for the link */
    /* verilator lint_off UNUSEDSIGNAL */
    logic send_rx_ack;
    logic send_almost_full;
    logic send_almost_empty;
    logic [SEND_CNT_W - 1:0] send_buffer_count;
    /* verilator lint_on UNUSEDSIGNAL */

    RingBuffer #(
        .DATA_SIZE              (HERMES_FLIT_SIZE + 1),
        .BUFFER_SIZE            (MEM_OUTSTANDING     ),
        .FIRST_WORD_FALL_THROUGH(1                   ),
        .ALMOST_FULL_THRESHOLD  (0                   ),
        .ALMOST_EMPTY_THRESHOLD (0                   )
    )
    send_buffer (
        .clk_i         (clk_i                                             ),
        .rst_ni        (rst_ni                                            ),
        .buf_rst_i     (1'b0                                              ),
        .rx_i          (send_rsp                                          ),
        .rx_ack_o      (send_rx_ack                                       ),
        .data_i        ({rsp_last, mem_rdata_i[(HERMES_FLIT_SIZE - 1):0]}),
        .tx_o          (send_tx                                           ),
        .tx_ack_i      (noc_ack_i                                         ),
        .data_o        ({send_eop, send_data}                             ),
        .count_o       (send_buffer_count                                 ),
        .almost_full_o (send_almost_full                                  ),
        .almost_empty_o(send_almost_empty                                 )
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_send_addr   <= '0;
            hermes_send_addr_2 <= '0;
            hermes_send_size   <= '0;
            hermes_send_size_2 <= '0;
        end
        else begin
            if (hermes_send_state == HERMES_SEND_IDLE) begin
                hermes_send_addr   <= hermes_address_i;
                hermes_send_addr_2 <= hermes_address_2_i;
                hermes_send_size   <= hermes_size_i;
                hermes_send_size_2 <= hermes_size_2_i;
            end
            else if (send_read) begin
                if (hermes_send_size != '0) begin
                    hermes_send_addr <= hermes_send_addr + 32'h4;
                    hermes_send_size <= hermes_send_size - 32'b1;
                end
                else begin
                    hermes_send_addr_2 <= hermes_send_addr_2 + 32'h4;
                    hermes_send_size_2 <= hermes_send_size_2 - 32'b1;
                end
            end
        end
    end

    hermes_send_t hermes_send_next_state;
    always_comb begin
        case (hermes_send_state)
            HERMES_SEND_IDLE:
                hermes_send_next_state = hermes_st_snd_i
                    ? HERMES_SEND_DATA
                    : HERMES_SEND_IDLE;
            HERMES_SEND_DATA:
                hermes_send_next_state = send_read_last
                    ? HERMES_SEND_DRAIN
                    : HERMES_SEND_DATA;
            HERMES_SEND_DRAIN:
                /* Wait for the last flit to leave the send buffer */
                hermes_send_next_state = (send_pop && send_eop)
                    ? HERMES_SEND_IDLE
                    : HERMES_SEND_DRAIN;
            default:
                hermes_send_next_state = HERMES_SEND_IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            hermes_send_state <= HERMES_SEND_IDLE;
        else
            hermes_send_state <= hermes_send_next_state;
    end

    /* During a loopback the input buffer drives the output link directly */
    assign noc_tx_o   = loopback_data ? noc_rx_i   : send_tx;
    assign noc_eop_o  = loopback_data ? noc_eop_i  : send_eop;
    assign noc_data_o = loopback_data ? noc_data_i : send_data;
    assign hermes_send_active_o = (hermes_send_state != HERMES_SEND_IDLE);

////////////////////////////////////////////////////////////////////////////////
// Arbiter
////////////////////////////////////////////////////////////////////////////////

    localparam NSOURCES = 4;
    typedef enum logic [(NSOURCES-1):0] {
        ARBIT_PENDING_NONE    = 4'b0001,
        ARBIT_PENDING_SEND    = 4'b0010,
        ARBIT_PENDING_RECEIVE = 4'b0100,
        ARBIT_PENDING_MONITOR = 4'b1000
    } arbit_pending_t;

    arbit_pending_t arbit_pending;
    assign arbit_pending[ARBIT_NONE]    = 1'b0;
    assign arbit_pending[ARBIT_SEND]    = (hermes_send_state == HERMES_SEND_DATA) && !loopback_active;
    assign arbit_pending[ARBIT_RECEIVE] = hermes_receive_active_o;
    assign arbit_pending[ARBIT_MONITOR] = hermes_monitor_active_o || (mon_sem_av_wait && monitor_available);

    arbit_t arbit_rr;
    always_comb begin
        arbit_rr = current_arbit;
        for (int i = 1; i < NSOURCES; i++) begin
            if (i <= current_arbit)
                continue;

            if (arbit_pending[i]) begin
                arbit_rr = arbit_t'(i);
                break;
            end
        end

        if (arbit_rr == current_arbit) begin
            for (int i = 1; i < NSOURCES; i++) begin
                if (arbit_pending[i]) begin
                    arbit_rr = arbit_t'(i);
                    break;
                end
            end
        end
    end

    /* A request waiting for gnt: OBI forbids changing it */
    logic mem_wait;
    assign mem_wait = mem_req_o && !mem_gnt_i;

    logic [2:0] timer;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            timer <= '0;
        end
        else begin
            /* A stalled cycle does not count against the time slice */
            if (!mem_wait)
                timer <= timer - 1'b1;
            if (arbit_pending[current_arbit] == 1'b0)
                timer <= '1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            current_arbit <= ARBIT_NONE;
        end
        else begin
            if (mem_wait)
                ;
            else if (arbit_pending == '0)
                current_arbit <= ARBIT_NONE;
            else if ((timer == '0 && current_arbit != ARBIT_MONITOR) || arbit_pending[current_arbit] == 1'b0)
                current_arbit <= arbit_rr;
        end
    end

////////////////////////////////////////////////////////////////////////////////
// Memory interface
////////////////////////////////////////////////////////////////////////////////
    
    always_comb begin
        case (current_arbit)
            ARBIT_SEND:    mem_req_o = send_req;
            ARBIT_RECEIVE: mem_req_o = receive_req;
            ARBIT_MONITOR: mem_req_o = monitor_req;
            default:       mem_req_o = 1'b0;
        endcase
    end

    always_comb begin
        case (current_arbit)
            ARBIT_SEND:    mem_addr_o = (hermes_send_size != '0) ? hermes_send_addr : hermes_send_addr_2;
            ARBIT_RECEIVE: mem_addr_o = hermes_receive_addr;
            ARBIT_MONITOR: mem_addr_o = hermes_monitor_addr;
            default:       mem_addr_o = '0;
        endcase
    end

    /* Receive and Monitor write whole flits, Send reads them */
    assign mem_we_o    = (current_arbit inside {ARBIT_RECEIVE, ARBIT_MONITOR});
    assign mem_be_o    = 4'hF;
    assign mem_wdata_o = noc_data_i;

    assign noc_credit_o = (
           can_receive
        || (hermes_monitor_state inside {HERMES_MONITOR_AVAILABLE, HERMES_MONITOR_DROP, HERMES_MONITOR_DROP_OCC})
        || can_monitor
        || loopback_drop_header
        || loopback_xfer
    );

////////////////////////////////////////////////////////////////////////////////
// Reporting
////////////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_received_cnt_o <= '0;
        end
        else begin
            if (hermes_st_rcv_i)
                hermes_received_cnt_o <= '0;
            else if (can_receive)
                hermes_received_cnt_o <= hermes_received_cnt_o + HERMES_FLIT_SIZE/8;
        end
    end

////////////////////////////////////////////////////////////////////////////////
// Debug
////////////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            ;
        else if (mon_sem_av_wait && !monitor_available)
            $display("[%7.3f] [DMNI] Monitoring FIFO is full. Dropping packet.", $time()/1_000_000.0);
    end

endmodule
