/**
 * DMNI
 * @file NI.sv
 *
 * @author Angelo Elias Dal Zotto (angelo.dalzotto@edu.pucrs.br)
 * GAPH - Hardware Design Support Group (https://corfu.pucrs.br)
 * PUCRS - Pontifical Catholic University of Rio Grande do Sul (http://pucrs.br/)
 *
 * @date October 2023
 *
 * @brief Network Interface functionality for DMNI
 */

`include "DMNIPkg.sv"

module NI
    import DMNIPkg::*;
#(
    parameter              N_PE_X           = 2,
    parameter              N_PE_Y           = 2,
    parameter              TASKS_PER_PE     = 1,
    parameter              IMEM_PAGE_SZ     = 32768,
    parameter              DMEM_PAGE_SZ     = 32768,
    parameter logic [15:0] ADDRESS          = 16'b0
)
(
    input  logic               clk_i,
    input  logic               rst_ni,

    input  logic               dmni_buffer_eop_acked_i,
    input  logic        [31:0] rcv_timestamp_i,

    /* CPU Interface */
    output logic               irq_o,
    input  logic               cfg_en_i,
    input  logic         [3:0] cfg_we_i,
    input  logic         [7:0] cfg_addr_i,
    input  logic        [31:0] cfg_data_i,
    output logic        [31:0] cfg_data_o,

    output logic               release_peripheral_o,

    /* Hermes MMRs */
    input  logic               hermes_send_active_i,
    input  logic               hermes_receive_active_i,
    input  logic               hermes_receive_available_i,
    output logic               hermes_st_rcv_o,
    output logic               hermes_st_snd_o,
    input  logic        [31:0] hermes_data_i,
    input  logic        [31:0] hermes_received_cnt_i,
    output logic        [31:0] hermes_size_o,
    output logic        [31:0] hermes_size_2_o,
    output logic        [31:0] hermes_address_o,
    output logic        [31:0] hermes_address_2_o,

    /* BrLite Service */
    input  logic               br_rx_i,
    output logic               br_ack_o,
    input  br_payload_t        br_data_i,

    /* BrLite Output  */
    input  logic               br_local_busy_i,
    output logic               br_req_o,
    input  logic               br_ack_i,
    output br_payload_t        br_data_o
);

////////////////////////////////////////////////////////////////////////////////
//  Monitoring queue
////////////////////////////////////////////////////////////////////////////////

    logic [31:0] rcv_timestamp;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            rcv_timestamp <= '0;
        else if(dmni_buffer_eop_acked_i)
            rcv_timestamp <= rcv_timestamp_i;
    end

////////////////////////////////////////////////////////////////////////////////
//  IRQ Control
////////////////////////////////////////////////////////////////////////////////

    logic pending_svc;

    assign irq_o = ((pending_svc && !hermes_send_active_i) || br_rx_i || hermes_receive_available_i);

////////////////////////////////////////////////////////////////////////////////
//  MMR Read
////////////////////////////////////////////////////////////////////////////////

    logic [31:0] cfg_data;

    always_comb begin
        case (cfg_addr_i)
            /* IRQ */
            DMNI_STATUS:           cfg_data = {24'h000000, 1'b0, br_local_busy_i, hermes_receive_active_i, hermes_send_active_i, release_peripheral_o, 1'b0, 1'b0, 1'b0};
            DMNI_IRQ:              cfg_data = {28'h0000000, pending_svc, br_rx_i, hermes_receive_available_i, 1'b0};

            /* Software config */
            DMNI_ADDRESS:          cfg_data = {16'h0000, ADDRESS};
            DMNI_MANYCORE_SZ:      cfg_data = {16'(TASKS_PER_PE), 8'(N_PE_X), 8'(N_PE_Y)};
            DMNI_IMEM_PAGE_SZ:     cfg_data = 32'(IMEM_PAGE_SZ);
            DMNI_DMEM_PAGE_SZ:     cfg_data = 32'(DMEM_PAGE_SZ);

            /* Hermes */
            DMNI_HERMES_SIZE:      cfg_data = hermes_size_o;
            DMNI_HERMES_SIZE_2:    cfg_data = hermes_size_2_o;
            DMNI_HERMES_ADDRESS:   cfg_data = hermes_size_o;
            DMNI_HERMES_ADDRESS_2: cfg_data = hermes_size_2_o;

            DMNI_HEAD:             cfg_data = hermes_data_i;
            DMNI_RECD_CNT:         cfg_data = hermes_received_cnt_i;

            /* BrLite Service */
            DMNI_BR_KSVC:          cfg_data = {24'h000000, 1'b1, 3'b000, br_data_i.ksvc};
            DMNI_BR_PAYLOAD:       cfg_data = {br_data_i.seq_source, br_data_i.payload};

            /* Monitoring */
            DMNI_RCV_TIMESTAMP:    cfg_data = rcv_timestamp;

            default:               cfg_data = '0;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            cfg_data_o <= '0;
        else if (cfg_en_i && (cfg_we_i == '0))
            cfg_data_o <= cfg_data;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            pending_svc <= 1'b0;
        else if (cfg_en_i && cfg_we_i[0] && cfg_addr_i == DMNI_IRQ)
            pending_svc <= cfg_data_i[3];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            release_peripheral_o <= 1'b0;
        else if (cfg_en_i && cfg_we_i[0] && cfg_addr_i == DMNI_STATUS)
            release_peripheral_o <= cfg_data_i[3];
    end

////////////////////////////////////////////////////////////////////////////////
//  Hermes
////////////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_st_snd_o <= 1'b0;
        end
        else begin
            if (cfg_en_i && cfg_we_i[0] && cfg_addr_i == DMNI_STATUS)
                hermes_st_snd_o <= cfg_data_i[0];

            if (hermes_st_snd_o)
                hermes_st_snd_o <= 1'b0; 
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_st_rcv_o <= 1'b0;
        end
        else begin 
            if (cfg_en_i && cfg_we_i[0] && cfg_addr_i == DMNI_STATUS)
                hermes_st_rcv_o <= cfg_data_i[1];
            
            if (hermes_st_rcv_o)
                hermes_st_rcv_o <= 1'b0; 
        end
    end

    logic [31:0] w_data;
    always_comb begin
        w_data[31:24] = cfg_we_i[3] ? cfg_data_i[31:24] : cfg_data[31:24];
        w_data[23:16] = cfg_we_i[2] ? cfg_data_i[23:16] : cfg_data[23:16];
        w_data[15: 8] = cfg_we_i[1] ? cfg_data_i[15: 8] : cfg_data[15: 8];
        w_data[ 7: 0] = cfg_we_i[0] ? cfg_data_i[ 7: 0] : cfg_data[ 7: 0];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_address_o   <= '0;
            hermes_address_2_o <= '0;
            hermes_size_o      <= '0;
            hermes_size_2_o    <= '0;
        end
        else begin
            if (cfg_en_i && (cfg_we_i != '0)) begin
                case (cfg_addr_i)
                    DMNI_HERMES_SIZE:      hermes_size_o      <= w_data;
                    DMNI_HERMES_SIZE_2:    hermes_size_2_o    <= w_data;
                    DMNI_HERMES_ADDRESS:   hermes_address_o   <= w_data;
                    DMNI_HERMES_ADDRESS_2: hermes_address_2_o <= w_data;
                    default: ;
                endcase
            end
        end
    end

////////////////////////////////////////////////////////////////////////////////
//  BrLite Service Send
////////////////////////////////////////////////////////////////////////////////

    /* BrLite send control */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            br_req_o <= 1'b0;
        end
        else begin
            if (br_ack_i)
                br_req_o <= 1'b0;
            else if (cfg_en_i && cfg_we_i[0] && cfg_addr_i == DMNI_BR_KSVC)
                br_req_o <= 1'b1;
        end
    end

    /* BrLite send payload */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            br_data_o <= '0;
        end
        else if (cfg_en_i) begin
            if (cfg_addr_i == DMNI_BR_KSVC && cfg_we_i[0])
                br_data_o.ksvc <= cfg_data_i[3:0];

            if (cfg_addr_i == DMNI_BR_PAYLOAD) begin
                if (cfg_we_i[0])
                    br_data_o.payload[7:0] <= cfg_data_i[7:0];

                if (cfg_we_i[1])
                    br_data_o.payload[15:8] <= cfg_data_i[15:8];
            end
        end
    end

////////////////////////////////////////////////////////////////////////////////
//  BrLite Service Receive
////////////////////////////////////////////////////////////////////////////////

    /* BrLite receive control */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            br_ack_o <= 1'b0;
        end
        else begin
            if (br_ack_o)
                br_ack_o <= 1'b0;
            else if (cfg_en_i && (cfg_we_i == '0) && cfg_addr_i == DMNI_BR_KSVC)
                br_ack_o <= 1'b1;
        end
    end

endmodule
