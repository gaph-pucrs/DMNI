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
    input  logic                                               clk_i,
    input  logic                                               rst_ni,

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

    /* Memory interface */
    output logic                                               mem_en_o,
    output logic [ 3:0]                                        mem_we_o,
    output logic [31:0]                                        mem_addr_o,
    input  logic [31:0]                                        mem_data_i,
    output logic [31:0]                                        mem_data_o,

    /* Configuration interface */
    input  logic                                               hermes_st_rcv_i,
    input  logic                                               hermes_st_snd_i,
    input  logic       [31:0]                                  hermes_size_i,
    input  logic       [31:0]                                  hermes_size_2_i,
    input  logic       [31:0]                                  hermes_address_i,
    input  logic       [31:0]                                  hermes_address_2_i,
    output logic                                               hermes_send_active_o,
    output logic                                               hermes_receive_active_o,
    output logic                                               hermes_receive_available_o
);

    typedef enum {
        ARBIT_SEND,
        ARBIT_RECEIVE
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
// Arbiter
////////////////////////////////////////////////////////////////////////////////

    localparam NSOURCES = 2;
    typedef enum logic [(NSOURCES - 1):0] {
        ARBIT_PENDING_SEND    = 2'b01,
        ARBIT_PENDING_RECEIVE = 2'b10
    } arbit_pending_t;

    arbit_pending_t arbit_pending;
    assign arbit_pending[ARBIT_SEND]    = hermes_send_active_o;
    assign arbit_pending[ARBIT_RECEIVE] = hermes_receive_active_o;

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
    
    always_comb begin
        case (current_arbit)
            ARBIT_SEND:
                mem_en_o = arbit_pending[ARBIT_SEND];
            default: /* ARBIT_RECEIVE */
                mem_en_o = (
                    arbit_pending[ARBIT_RECEIVE] 
                    && hermes_receive_addr != '0
                );
        endcase
    end

    always_comb begin
        case (current_arbit)
            ARBIT_SEND:
                mem_addr_o = (hermes_send_size != '0) ? hermes_send_addr : hermes_send_addr_2;
            default: /* ARBIT_RECEIVE */
                mem_addr_o = hermes_receive_addr;
        endcase
    end

    assign mem_data_o = noc_data_i;
    assign mem_we_o = (current_arbit == ARBIT_SEND) ? '0 : '1;

endmodule
