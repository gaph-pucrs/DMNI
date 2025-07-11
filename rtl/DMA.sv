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
    parameter HERMES_FLIT_SIZE = 32
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

    /* Memory interface */
    output logic                            mem_en_o,
    output logic                     [ 3:0] mem_we_o,
    output logic                     [31:0] mem_addr_o,
    input  logic                     [31:0] mem_data_i,
    output logic                     [31:0] mem_data_o,

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

////////////////////////////////////////////////////////////////////////////////
// NoC Receive FSM
////////////////////////////////////////////////////////////////////////////////

    typedef enum logic [3:0] {  
        HERMES_RECEIVE_HEADER = 4'b0001,
        HERMES_RECEIVE_WAIT   = 4'b0010,
        HERMES_RECEIVE_DATA   = 4'b0100,
        HERMES_RECEIVE_EOP    = 4'b1000
    } hermes_receive_t;

    hermes_receive_t hermes_receive_state;

    logic can_receive;
    always_comb begin
        can_receive = (
            noc_rx_i 
            && current_arbit == ARBIT_RECEIVE
        );
    end

    logic [31:0] hermes_receive_addr;
    logic [31:0] hermes_receive_size;
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
            else if (can_receive && hermes_receive_active_o && hermes_receive_addr != '0) begin
                hermes_receive_addr <= hermes_receive_addr + 32'h4;
                hermes_receive_size <= hermes_receive_size - 32'b1;
            end
        end
    end

    hermes_receive_t hermes_receive_next_state;
    always_comb begin
        case (hermes_receive_state)
            HERMES_RECEIVE_HEADER: begin
                if (noc_rx_i) begin
                    hermes_receive_next_state = (noc_data_i[23:16] != MONITOR) 
                        ? HERMES_RECEIVE_WAIT 
                        : HERMES_RECEIVE_EOP;
                end
                else begin
                    hermes_receive_next_state = HERMES_RECEIVE_HEADER;
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
                hermes_receive_next_state = (noc_rx_i && noc_eop_i)
                    ? HERMES_RECEIVE_HEADER
                    : HERMES_RECEIVE_EOP;
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

    logic monitor_available;
    assign monitor_available = (monitor_sem_av != '0);

    logic [7:0] monitor_sem_av;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            monitor_sem_av <= '0;
        end
        else begin
            if (hermes_monitor_reset_i)
                monitor_sem_av <= hermes_monitor_length_i;

            if (hermes_monitor_sem_av_post_i && !(mon_sem_av_wait && monitor_available))
                monitor_sem_av <= monitor_sem_av + 1'b1;
            
            if (!hermes_monitor_sem_av_post_i && (mon_sem_av_wait && monitor_available))
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
            else if (hermes_monitor_state == HERMES_MONITOR_RECEIVE && noc_rx_i)
                monitor_cnt <= monitor_cnt + 1'b1;
        end
    end

    hermes_monitor_t hermes_monitor_next_state;
    always_comb begin
        case (hermes_monitor_state)
            HERMES_MONITOR_HEADER: begin
                if (noc_rx_i) begin
                    hermes_monitor_next_state = (noc_data_i[23:16] == MONITOR) 
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
                if (noc_rx_i && noc_eop_i) begin
                    hermes_monitor_next_state = HERMES_MONITOR_OCCUPIED;
                end
                else if (noc_rx_i && (monitor_cnt == (hermes_monitor_flits_i - 1'b1))) begin
                    hermes_monitor_next_state = HERMES_MONITOR_DROP_OCC;
                end
                else begin
                    hermes_monitor_next_state = HERMES_MONITOR_RECEIVE;
                end
            end
            HERMES_MONITOR_EOP:
                hermes_monitor_next_state = (can_receive && noc_eop_i)
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
            else if (noc_rx_i && hermes_monitor_active_o && hermes_monitor_addr != '0) begin
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
    assign mon_sem_oc_available = (hermes_monitor_sem_oc_o != '0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_monitor_sem_oc_o <= '0;
        end
        else begin
            if (hermes_monitor_reset_i)
                hermes_monitor_sem_oc_o <= '0;
            
            if (mon_sem_oc_post && !(hermes_monitor_sem_oc_wait_i && mon_sem_oc_available))
                hermes_monitor_sem_oc_o <= hermes_monitor_sem_oc_o + 1'b1;

            if (!mon_sem_oc_post && (hermes_monitor_sem_oc_wait_i && mon_sem_oc_available))
                hermes_monitor_sem_oc_o <= hermes_monitor_sem_oc_o - 1'b1;
        end
    end

    assign hermes_monitor_active_o = (hermes_monitor_state == HERMES_MONITOR_RECEIVE);

////////////////////////////////////////////////////////////////////////////////
// NoC Send FSM
////////////////////////////////////////////////////////////////////////////////
    
    typedef enum logic [3:0] {
        HERMES_SEND_IDLE    = 4'b0001,
        HERMES_SEND_PRELOAD = 4'b0010,
        HERMES_SEND_DATA    = 4'b0100,
        HERMES_SEND_STOP    = 4'b1000
    } hermes_send_t;

    hermes_send_t hermes_send_state;

    logic can_send;
    logic can_send_r;
    always_comb begin
        can_send = (
            noc_ack_i 
            && current_arbit == ARBIT_SEND
        );
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (rst_ni == 1'b0)
            can_send_r <= 1'b1;
        else
            can_send_r <= can_send;
    end

    logic [31:0] hermes_send_addr;
    logic [31:0] hermes_send_addr_2;
    logic [31:0] hermes_send_size;
    logic [31:0] hermes_send_size_2;

    logic [31:0] hermes_send_addr_r;
    logic [31:0] hermes_send_addr_2_r;
    logic [31:0] hermes_send_size_r;
    logic [31:0] hermes_send_size_2_r;

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
            else if (can_send) begin
                if (hermes_send_size != '0) begin
                    hermes_send_addr <= hermes_send_addr + 32'h4;
                    hermes_send_size <= hermes_send_size - 32'b1;
                end
                else begin
                    hermes_send_addr_2 <= hermes_send_addr_2 + 32'h4;
                    hermes_send_size_2 <= hermes_send_size_2 - 32'b1;
                end
            end
            else if (can_send_r) begin
                /* Credit drop, roll back address and size */
                hermes_send_addr   <= hermes_send_addr_r;
                hermes_send_addr_2 <= hermes_send_addr_2_r;
                hermes_send_size   <= hermes_send_size_r;
                hermes_send_size_2 <= hermes_send_size_2_r;
            end
        end
    end

    /* This is needed as the credit will drop after the memory address has changed */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_send_addr_r   <= '0;
            hermes_send_addr_2_r <= '0;
            hermes_send_size_r   <= '0;
            hermes_send_size_2_r <= '0;
        end
        else if (noc_ack_i) begin
            hermes_send_addr_r   <= hermes_send_addr;
            hermes_send_addr_2_r <= hermes_send_addr_2;
            hermes_send_size_r   <= hermes_send_size;
            hermes_send_size_2_r <= hermes_send_size_2;
        end
    end

    hermes_send_t hermes_send_next_state;
    always_comb begin
        case (hermes_send_state) 
            HERMES_SEND_IDLE:
                hermes_send_next_state = hermes_st_snd_i
                    ? HERMES_SEND_PRELOAD 
                    : HERMES_SEND_IDLE;
            HERMES_SEND_PRELOAD:
                hermes_send_next_state = (can_send)
                    ? HERMES_SEND_DATA
                    : HERMES_SEND_PRELOAD;
            HERMES_SEND_DATA: begin
                if (!can_send) begin
                    hermes_send_next_state = HERMES_SEND_PRELOAD;
                end 
                else begin
                    if (
                        (hermes_send_size == 32'b1 && hermes_send_size_2 == '0) ||
                        (hermes_send_size == '0 && hermes_send_size_2 == 32'b1)
                    )
                        hermes_send_next_state = HERMES_SEND_STOP;
                    else
                        hermes_send_next_state = HERMES_SEND_DATA;
                end
            end
            HERMES_SEND_STOP:
                hermes_send_next_state = (noc_ack_i && current_arbit == ARBIT_SEND)
                    ? HERMES_SEND_IDLE
                    : HERMES_SEND_STOP;
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

    assign noc_tx_o   = (hermes_send_state inside {HERMES_SEND_DATA, HERMES_SEND_STOP}) && current_arbit == ARBIT_SEND;
    assign noc_eop_o  = (hermes_send_state == HERMES_SEND_STOP);
    assign noc_data_o = mem_data_i;
    assign hermes_send_active_o = (hermes_send_state != HERMES_SEND_IDLE);

////////////////////////////////////////////////////////////////////////////////
// Arbiter
////////////////////////////////////////////////////////////////////////////////

    localparam NSOURCES = 3;
    typedef enum logic [(NSOURCES):0] {
        ARBIT_PENDING_NONE    = 4'b0001,
        ARBIT_PENDING_SEND    = 4'b0010,
        ARBIT_PENDING_RECEIVE = 4'b0100,
        ARBIT_PENDING_MONITOR = 4'b1000
    } arbit_pending_t;

    arbit_pending_t arbit_pending;
    assign arbit_pending[ARBIT_NONE]    = 1'b0;
    assign arbit_pending[ARBIT_SEND]    = hermes_send_active_o;
    assign arbit_pending[ARBIT_RECEIVE] = hermes_receive_active_o;
    assign arbit_pending[ARBIT_MONITOR] = hermes_monitor_active_o || (hermes_monitor_state == HERMES_MONITOR_AVAILABLE && monitor_available);

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

    logic [3:0] timer;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            timer <= '0;
        end
        else begin
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
            if (arbit_pending == '0) begin
                current_arbit <= ARBIT_NONE;
            end
            else begin
                if (arbit_pending[ARBIT_MONITOR])
                    current_arbit <= ARBIT_MONITOR;
                else if (timer == '0 || arbit_pending[current_arbit] == 1'b0)
                    current_arbit <= arbit_rr;
            end
        end
    end

////////////////////////////////////////////////////////////////////////////////
// Memory interface
////////////////////////////////////////////////////////////////////////////////
    
    always_comb begin
        case (current_arbit)
            ARBIT_SEND:
                mem_en_o = hermes_send_active_o;
            ARBIT_RECEIVE:
                mem_en_o = (
                    hermes_receive_active_o 
                    && hermes_receive_addr != '0
                );
            ARBIT_MONITOR:
                mem_en_o = (
                    hermes_monitor_active_o
                    && hermes_monitor_addr != '0
                );
            default:
                mem_en_o = 1'b0;
        endcase
    end

    always_comb begin
        case (current_arbit)
            ARBIT_SEND:
                mem_addr_o = (hermes_send_size != '0) ? hermes_send_addr : hermes_send_addr_2;
            ARBIT_RECEIVE:
                mem_addr_o = hermes_receive_addr;
            ARBIT_MONITOR:
                mem_addr_o = hermes_monitor_addr;
            default: /* ARBIT_RECEIVE */
                mem_addr_o = '0;
        endcase
    end

    always_comb begin
        case (current_arbit)
            ARBIT_RECEIVE:
                mem_we_o = {4{hermes_receive_active_o}};
            ARBIT_MONITOR:
                mem_we_o = {4{hermes_monitor_active_o}};
            default:    /* ARBIT_MONITOR */
                mem_we_o = '0;
        endcase
    end

    assign mem_data_o   = noc_data_i;
    assign noc_credit_o = (
           (hermes_receive_active_o && current_arbit == ARBIT_RECEIVE) 
        || (hermes_monitor_state inside {HERMES_MONITOR_AVAILABLE, HERMES_MONITOR_RECEIVE, HERMES_MONITOR_DROP, HERMES_MONITOR_DROP_OCC})
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
            else if (hermes_receive_active_o && can_receive)
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
