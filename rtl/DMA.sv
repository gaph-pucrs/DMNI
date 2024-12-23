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
    parameter N_PE_X           = 2,
    parameter N_PE_Y           = 2,
    parameter TASKS_PER_PE     = 1
)
(
    input  logic                                               clk_i,
    input  logic                                               rst_ni,

    input  logic [31:0]                                        tick_counter_i,

    input  logic                                               buf_eop_acked_i,
    output logic [31:0]                                        rcv_timestamp_o,

    /* Hermes input interface (RECEIVE) */
    input  logic                                               noc_rx_i,
    input  logic                                               noc_eop_i,
    output logic                                               noc_credit_o,
    input  logic [(HERMES_FLIT_SIZE - 1):0]                    noc_data_i,

    /* Hermes output interface (SEND) */
    output logic                                               noc_tx_o,
    output logic                                               noc_eop_o,
    input  logic                                               noc_ack_i,
    output logic [(HERMES_FLIT_SIZE - 1):0]                    noc_data_o,

    /* BrLite Monitor receive interface */
    input  logic                                               brlite_req_i,
    output logic                                               brlite_ack_o,
    input  brlite_mon_t                                        brlite_data_i,

    /* Memory interface */
    output logic                                               mem_en_o,
    output logic [ 3:0]                                        mem_we_o,
    output logic [31:0]                                        mem_addr_o,
    input  logic [31:0]                                        mem_data_i,
    output logic [31:0]                                        mem_data_o,

    /* Configuration interface */
    input  logic                                               hermes_start_i,
    input  logic                                               brlite_clear_i,
    input  hermes_op_t                                         hermes_operation_i,
    input  logic       [31:0]                                  hermes_size_i,
    input  logic       [31:0]                                  hermes_size_2_i,
    input  logic       [31:0]                                  hermes_address_i,
    input  logic       [31:0]                                  hermes_address_2_i,
    input  logic       [31:0]                                  brlite_task_clear_i,
    input  logic       [($clog2(BRLITE_MON_NSVC) - 1):0][31:0] brlite_mon_ptrs_i,
    output logic                                               hermes_send_active_o,
    output logic                                               hermes_receive_active_o,
    output logic                                               hermes_receive_available_o,
    output logic                                               brlite_clear_ack_o
);

    localparam N_PE = N_PE_X * N_PE_Y;

    typedef enum {
        ARBIT_SEND,
        ARBIT_RECEIVE,
        ARBIT_BR_LITE
    } arbit_t;

    arbit_t current_arbit;

////////////////////////////////////////////////////////////////////////////////
// NoC Receive FSM
////////////////////////////////////////////////////////////////////////////////

    typedef enum logic [2:0] {  
        HERMES_RECEIVE_HEADER = 3'b001,
        HERMES_RECEIVE_WAIT   = 3'b010,
        HERMES_RECEIVE_DATA   = 3'b100
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
            else if (can_receive && hermes_receive_state == HERMES_RECEIVE_DATA) begin
                hermes_receive_addr <= hermes_receive_addr + 32'h4;
                hermes_receive_size <= hermes_receive_size - 32'b1;
            end
        end
    end

    hermes_receive_t hermes_receive_next_state;
    always_comb begin
        case (hermes_receive_state)
            HERMES_RECEIVE_HEADER:
                hermes_receive_next_state = noc_rx_i 
                    ? HERMES_RECEIVE_WAIT 
                    : HERMES_RECEIVE_HEADER;
            HERMES_RECEIVE_WAIT:
                hermes_receive_next_state = (
                    hermes_start_i 
                    && hermes_operation_i == HERMES_OPERATION_RECEIVE
                )
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

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            rcv_timestamp_o <= '0;
        else if (buf_eop_acked_i)
            rcv_timestamp_o <= tick_counter_i;
    end

    assign noc_credit_o = (hermes_receive_state == HERMES_RECEIVE_DATA) 
        ? can_receive
        : (hermes_receive_state != HERMES_RECEIVE_WAIT);

    assign hermes_receive_active_o = (hermes_receive_state == HERMES_RECEIVE_DATA);
    assign hermes_receive_available_o = (hermes_receive_state == HERMES_RECEIVE_WAIT);

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
                hermes_send_next_state = (
                    hermes_start_i 
                    && hermes_operation_i == HERMES_OPERATION_SEND
                )
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
                        (hermes_send_size == 32'b1 && hermes_send_size_2 == '0)
                        || (hermes_send_size == '0 && hermes_send_size_2 == 32'b1)
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
// BrLite Monitor Receive FSM
////////////////////////////////////////////////////////////////////////////////

    typedef enum logic [5:0] {
        BRLITE_RECEIVE_IDLE           = 6'b000001,
        BRLITE_RECEIVE_SEARCH         = 6'b000010,
        BRLITE_RECEIVE_POPULATE_TABLE = 6'b000100,
        BRLITE_RECEIVE_WRITE_TASK     = 6'b001000,
        BRLITE_RECEIVE_WRITE_PAYLOAD  = 6'b010000,
        BRLITE_RECEIVE_ACK            = 6'b100000
    } brlite_receive_t;

    brlite_receive_t brlite_receive_state;

    typedef logic [((N_PE == 1) ? 0 : ($clog2(N_PE) - 1)):0] pe_idx_t;
    typedef logic [((TASKS_PER_PE == 1) ? 0 : ($clog2(TASKS_PER_PE) - 1)):0] task_idx_t;

    logic [15:0] mon_table [(N_PE - 1):0][(TASKS_PER_PE - 1):0];

    task_idx_t task_idx;

    logic task_found;
    assign task_found = (mon_table[pe_idx_t'(brlite_data_i.seq_source)][task_idx] == brlite_data_i.producer);

    logic has_free;

    brlite_receive_t brlite_receive_next_state;
    always_comb begin
        case (brlite_receive_state)
            BRLITE_RECEIVE_IDLE: begin
                if (brlite_req_i)
                    brlite_receive_next_state = (brlite_mon_ptrs_i[brlite_data_i.msvc] != '0)
                        ? BRLITE_RECEIVE_SEARCH
                        : BRLITE_RECEIVE_ACK;
                else
                    brlite_receive_next_state = BRLITE_RECEIVE_IDLE;
            end
            BRLITE_RECEIVE_SEARCH: begin
                if (task_idx == task_idx_t'(TASKS_PER_PE - 1) && !task_found)
                    brlite_receive_next_state = has_free
                        ? BRLITE_RECEIVE_POPULATE_TABLE
                        : BRLITE_RECEIVE_ACK;
                else
                    brlite_receive_next_state = task_found
                        ? BRLITE_RECEIVE_WRITE_TASK
                        : BRLITE_RECEIVE_SEARCH;
            end
            BRLITE_RECEIVE_POPULATE_TABLE:
                brlite_receive_next_state = BRLITE_RECEIVE_WRITE_TASK;
            BRLITE_RECEIVE_WRITE_TASK:
                brlite_receive_next_state = (current_arbit == ARBIT_SEND)
                    ? BRLITE_RECEIVE_WRITE_PAYLOAD
                    : BRLITE_RECEIVE_WRITE_TASK;
            BRLITE_RECEIVE_WRITE_PAYLOAD:
                brlite_receive_next_state = (current_arbit == ARBIT_SEND)
                    ? BRLITE_RECEIVE_ACK
                    : BRLITE_RECEIVE_WRITE_PAYLOAD;
            BRLITE_RECEIVE_ACK: 
                brlite_receive_next_state = BRLITE_RECEIVE_IDLE;
            default:
                brlite_receive_next_state = BRLITE_RECEIVE_IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            brlite_receive_state <= BRLITE_RECEIVE_IDLE;
        else
            brlite_receive_state <= brlite_receive_next_state;
    end

    logic [31:0] mon_ptr;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            mon_ptr <= '0;
        end
        else begin
            if (brlite_receive_state == BRLITE_RECEIVE_IDLE)
                mon_ptr <= brlite_mon_ptrs_i[brlite_data_i.msvc];
        end
    end

    task_idx_t free_idx;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            task_idx <= '0;
            free_idx <= '0;
            has_free <= 1'b0;
        end
        else begin
            if (brlite_receive_state == BRLITE_RECEIVE_IDLE) begin
                task_idx <= '0;
                free_idx <= '0;
                has_free <= 1'b0;
            end
            else if (brlite_receive_state == BRLITE_RECEIVE_SEARCH) begin
                if (!task_found) begin
                    task_idx <= task_idx + 1'b1;
                    if (!has_free && mon_table[pe_idx_t'(brlite_data_i.seq_source)][task_idx] == '1) begin
                        has_free <= 1'b1;
                        free_idx <= task_idx;
                    end
                end
            end
            else if (brlite_receive_state == BRLITE_RECEIVE_POPULATE_TABLE) begin
                task_idx <= free_idx;
            end
        end
    end

    assign brlite_ack_o = (brlite_receive_state == BRLITE_RECEIVE_ACK);

    logic [31:0] brlite_data;
    assign brlite_data = (brlite_receive_state == BRLITE_RECEIVE_WRITE_PAYLOAD)
        ? brlite_data_i.payload
        : 32'(brlite_data_i.producer);

    logic [(((TASKS_PER_PE == 1) ? 0 : ($clog2(TASKS_PER_PE) - 1)) + 16):0] brlite_offset; /* Add 16 bits from address */
    assign brlite_offset = {brlite_data_i.seq_source, task_idx};

    /* Fix it later, reducing the number of bits to the minimum really necessary */
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] brlite_addr_base;
    /* verilator lint_on UNUSEDSIGNAL */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            brlite_addr_base <= '0;
        else if (brlite_receive_state == BRLITE_RECEIVE_SEARCH)
            brlite_addr_base <= mon_ptr + 32'({brlite_offset, 3'b0});
    end

    logic [31:0] brlite_addr;
    /* Computed address + word selection from FSM + align to 4 bytes */
    assign brlite_addr = {brlite_addr_base[31:3], (brlite_receive_state == BRLITE_RECEIVE_WRITE_PAYLOAD), 2'b0};

////////////////////////////////////////////////////////////////////////////////
// Monitor table control
////////////////////////////////////////////////////////////////////////////////

    typedef enum logic [3:0] {
        MONITOR_IDLE   = 4'b0001,
        MONITOR_SEARCH = 4'b0010,
        MONITOR_CLEAR  = 4'b0100,
        MONITOR_IGNORE = 4'b1000
    } monitor_t;

    monitor_t monitor_state;

    task_idx_t clear_idx;

    logic clear_found;
    assign clear_found = (mon_table[pe_idx_t'(brlite_task_clear_i[31:16])][clear_idx] == brlite_task_clear_i[15:0]);

    monitor_t monitor_next_state;
    always_comb begin
        case (monitor_state)
            MONITOR_IDLE: 
                monitor_next_state = brlite_clear_i 
                    ? MONITOR_SEARCH 
                    : MONITOR_IDLE;
            MONITOR_SEARCH: begin
                if (clear_idx == task_idx_t'(TASKS_PER_PE - 1) && !clear_found)
                    monitor_next_state = MONITOR_IGNORE;
                else
                    monitor_next_state = clear_found ? MONITOR_CLEAR : MONITOR_SEARCH;
            end
            MONITOR_CLEAR:
                monitor_next_state = MONITOR_IDLE;
            MONITOR_IGNORE:
                monitor_next_state = MONITOR_IDLE;
            default:
                monitor_next_state = MONITOR_IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            monitor_state <= MONITOR_IDLE;
        else
            monitor_state <= monitor_next_state;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            clear_idx   <= '0;
        end
        else begin
            if (monitor_state == MONITOR_IDLE)
                clear_idx   <= '0;
            else if (monitor_state == MONITOR_SEARCH && !clear_found)
                clear_idx <= clear_idx + 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int p = 0; p < N_PE; p++)
                for (int t = 0; t < TASKS_PER_PE; t++)
                    mon_table[p][t] <= '1;
        end
        else begin
            if (brlite_receive_state == BRLITE_RECEIVE_POPULATE_TABLE)
                mon_table[pe_idx_t'(brlite_data_i.seq_source)][free_idx] <= brlite_data_i.producer;

            if (monitor_state == MONITOR_CLEAR)
                mon_table[pe_idx_t'(brlite_task_clear_i[31:16])][clear_idx] <= '1;
        end
    end

    assign brlite_clear_ack_o = (monitor_state == MONITOR_CLEAR || monitor_state == MONITOR_IGNORE);

////////////////////////////////////////////////////////////////////////////////
// Arbiter
////////////////////////////////////////////////////////////////////////////////

    localparam NSOURCES = 3;
    typedef enum logic [(NSOURCES - 1):0] {
        ARBIT_PENDING_SEND    = 3'b001,
        ARBIT_PENDING_RECEIVE = 3'b010,
        ARBIT_PENDING_BR_LITE = 3'b100
    } arbit_pending_t;

    arbit_pending_t arbit_pending;
    assign arbit_pending[ARBIT_SEND]    = hermes_send_active_o;
    assign arbit_pending[ARBIT_RECEIVE] = hermes_receive_active_o;
    assign arbit_pending[ARBIT_BR_LITE] = (
        brlite_receive_state == BRLITE_RECEIVE_WRITE_TASK
        || brlite_receive_state == BRLITE_RECEIVE_WRITE_PAYLOAD
    );

    arbit_t next_arbit;

    always_comb begin
        next_arbit = current_arbit;
        for (int i = 0; i < NSOURCES; i++) begin
            if (i <= current_arbit)
                continue;

            if (arbit_pending[i]) begin
                next_arbit = arbit_t'(i);
                break;
            end
        end

        if (next_arbit == current_arbit) begin
            for (int i = 0; i < NSOURCES; i++) begin
                if (arbit_pending[i]) begin
                    next_arbit = arbit_t'(i);
                    break;
                end
            end
        end
    end

    logic [3:0] timer;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            current_arbit <= ARBIT_SEND;
            timer         <= '0;
        end
        else begin
            if (timer != '0)
                timer <= timer - 1'b1;

            if (arbit_pending != '0 && (timer == '0 || arbit_pending[current_arbit] == 1'b0)) begin
                timer <= '1;
                current_arbit <= next_arbit;
            end
        end
    end

////////////////////////////////////////////////////////////////////////////////
// Memory interface
////////////////////////////////////////////////////////////////////////////////

    assign mem_data_o = (current_arbit == ARBIT_RECEIVE) ? noc_data_i : brlite_data;
    
    always_comb begin
        case (current_arbit)
            ARBIT_SEND:
                mem_addr_o = (hermes_send_size != '0) ? hermes_send_addr : hermes_send_addr_2;
            ARBIT_RECEIVE:
                mem_addr_o = hermes_receive_addr;
            ARBIT_BR_LITE:
                mem_addr_o = brlite_addr;
            default:
                mem_addr_o = '0;
        endcase
    end


    assign mem_we_o = (current_arbit == ARBIT_SEND) ? '0 : '1;

    always_comb begin
        if (arbit_pending == '0) begin
            mem_en_o = 1'b0;
        end
        else begin
            case (current_arbit)
                ARBIT_SEND:
                    mem_en_o = arbit_pending[ARBIT_SEND];
                ARBIT_RECEIVE:
                    mem_en_o = (
                        arbit_pending[ARBIT_RECEIVE] 
                        && hermes_receive_addr != '0
                    );
                ARBIT_BR_LITE:
                    mem_en_o = arbit_pending[ARBIT_BR_LITE];
                default:
                    mem_en_o = 1'b0;
            endcase
        end
    end

endmodule
