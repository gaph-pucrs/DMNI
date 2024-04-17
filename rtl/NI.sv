`include "DMNIPkg.sv"

module NI
    import DMNIPkg::*;
#(
    parameter              HERMES_FLIT_SIZE = 32,
    parameter              N_PE_X           = 2,
    parameter              N_PE_Y           = 2,
    parameter              TASKS_PER_PE     = 1,
    parameter              IMEM_PAGE_SZ     = 32768,
    parameter              DMEM_PAGE_SZ     = 32768,
    parameter logic [15:0] ADDRESS          = 16'b0
)
(
    input  logic                                         clk_i,
    input  logic                                         rst_ni,

    /* CPU Interface */
    output logic                                         irq_o,
    input  logic                                         cfg_en_i,
    input  logic                                         cfg_we_i,
    input  logic         [($clog2(DMNI_MMR_SIZE) - 1):0] cfg_addr_i,
    input  logic                                  [31:0] cfg_data_i,
    output logic                                  [31:0] cfg_data_o,

    output logic                                         release_peripheral_o,

    /* Hermes MMRs */
    input  logic                                         hermes_send_active_i,
    input  logic                                         hermes_receive_active_i,
    input  logic                                         hermes_receive_available_i,
    input  logic              [(HERMES_FLIT_SIZE - 1):0] hermes_receive_flits_available_i,
    output logic                                         hermes_start_o,
    output hermes_op_t                                   hermes_operation_o,
    output logic                                  [31:0] hermes_size_o,
    output logic                                  [31:0] hermes_size_2_o,
    output logic                                  [31:0] hermes_address_o,
    output logic                                  [31:0] hermes_address_2_o,

    /* BrLite Monitor */
    output logic                                         br_mon_clear_o,
    input  logic                                         br_mon_clear_ack_i,
    output logic [31:0]                                  br_mon_task_clear_o,
    output logic [($clog2(BRLITE_MON_NSVC) - 1):0][31:0] br_mon_ptrs_o,

    /* BrLite Service */
    input  logic                                         br_svc_rx_i,
    output logic                                         br_svc_ack_o,
    input  brlite_svc_t                                  br_svc_data_i,

    /* BrLite Output  */
    input  logic                                         br_local_busy_i,
    output logic                                         br_req_o,
    input  logic                                         br_ack_i,
    output brlite_out_t                                  br_data_o
);

////////////////////////////////////////////////////////////////////////////////
//  IRQ Control
////////////////////////////////////////////////////////////////////////////////

    logic pending_svc;

    assign irq_o = (pending_svc || br_svc_rx_i || hermes_receive_available_i);

////////////////////////////////////////////////////////////////////////////////
//  MMR Read
////////////////////////////////////////////////////////////////////////////////

    logic [31:0] cfg_data;

    always_comb begin
        case (cfg_addr_i)
            /* IRQ */
            DMNI_STATUS:                 cfg_data = {{27{1'b0}}, release_peripheral_o, br_mon_clear_o, br_local_busy_i, hermes_receive_active_i, hermes_send_active_i};
            DMNI_IRQ_STATUS:             cfg_data = {{29{1'b0}}, pending_svc, br_svc_rx_i, hermes_receive_available_i};

            /* Software config */
            DMNI_ADDRESS:                cfg_data = {16'b0, ADDRESS};
            DMNI_MANYCORE_SIZE:          cfg_data = {7'b0, N_PE_X[8:0], 7'b0, N_PE_Y[8:0]};
            DMNI_TASKS_PER_PE:           cfg_data = 32'(TASKS_PER_PE);
            DMNI_IMEM_PAGE_SZ:           cfg_data = 32'(IMEM_PAGE_SZ);
            DMNI_DMEM_PAGE_SZ:           cfg_data = 32'(DMEM_PAGE_SZ);

            /* Hermes */
            DMNI_HERMES_FLITS_AVAILABLE: cfg_data = {{(32 - HERMES_FLIT_SIZE){1'b0}}, hermes_receive_flits_available_i};

            /* BrLite Service */
            DMNI_BR_SVC_KSVC:            cfg_data = {{24{1'b0}}, br_svc_data_i.ksvc};
            DMNI_BR_SVC_PRODUCER:        cfg_data = {br_svc_data_i.seq_source, br_svc_data_i.producer};
            DMNI_BR_SVC_PAYLOAD:         cfg_data = br_svc_data_i.payload;

            default:                     cfg_data = '0;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            cfg_data_o <= '0;
        else if (cfg_en_i && !cfg_we_i)
            cfg_data_o <= cfg_data;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            pending_svc <= 1'b0;
        else if (cfg_en_i && cfg_we_i && cfg_addr_i == DMNI_PENDING_SVC)
            pending_svc <= cfg_data_i[0];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            release_peripheral_o <= 1'b0;
        else if (cfg_en_i && cfg_we_i && cfg_addr_i == DMNI_RELEASE_PERIPHERAL)
            release_peripheral_o <= cfg_data_i[0];
    end

////////////////////////////////////////////////////////////////////////////////
//  Hermes
////////////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hermes_start_o     <= '0;
            hermes_operation_o <= HERMES_OPERATION_SEND;
            hermes_address_o   <= '0;
            hermes_address_2_o <= '0;
            hermes_size_o      <= '0;
            hermes_size_2_o    <= '0;
        end
        else begin
            if (cfg_en_i && cfg_we_i) begin
                case (cfg_addr_i)
                    DMNI_HERMES_START:     hermes_start_o     <= cfg_data_i[0];
                    DMNI_HERMES_OPERATION: hermes_operation_o <= hermes_op_t'(cfg_data_i[0]);
                    DMNI_HERMES_SIZE:      hermes_size_o      <= cfg_data_i;
                    DMNI_HERMES_SIZE_2:    hermes_size_2_o    <= cfg_data_i;
                    DMNI_HERMES_ADDRESS:   hermes_address_o   <= cfg_data_i;
                    DMNI_HERMES_ADDRESS_2: hermes_address_2_o <= cfg_data_i;
                    default: ;
                endcase
            end

            if (hermes_start_o)
                hermes_start_o <= '0;
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
            else if (cfg_en_i && cfg_we_i && cfg_addr_i == DMNI_BR_START)
                br_req_o <= cfg_data_i[0];
        end
    end

    /* BrLite send payload */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            br_data_o <= '0;
        end
        else begin
            if (cfg_en_i && cfg_we_i) begin
                case (cfg_addr_i)
                    DMNI_BR_SERVICE:  br_data_o.service    <= cfg_data_i[1:0];
                    DMNI_BR_KSVC:     br_data_o.ksvc       <= cfg_data_i[7:0];
                    DMNI_BR_TARGET:   br_data_o.seq_target <= cfg_data_i[15:0];
                    DMNI_BR_PRODUCER: br_data_o.producer   <= cfg_data_i[15:0];
                    DMNI_BR_PAYLOAD:  br_data_o.payload    <= cfg_data_i[31:0];
                    default: ;
                endcase
            end
        end
    end

////////////////////////////////////////////////////////////////////////////////
//  BrLite Service Receive
////////////////////////////////////////////////////////////////////////////////

    /* BrLite receive control */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            br_svc_ack_o <= 1'b0;
        end
        else begin
            if (br_svc_ack_o)
                br_svc_ack_o <= 1'b0;
            else if (cfg_en_i && cfg_we_i && cfg_addr_i == DMNI_BR_SVC_POP)
                br_svc_ack_o <= cfg_data_i[0];
        end
    end

////////////////////////////////////////////////////////////////////////////////
//  BrLite Monitor pointer control
////////////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            br_mon_ptrs_o <= '0;
        end
        else begin
            if (cfg_en_i && cfg_we_i) begin
                case (cfg_addr_i)
                    DMNI_BR_MON_PTR_QOS: br_mon_ptrs_o[MONITOR_QOS] <= cfg_data_i;
                    DMNI_BR_MON_PTR_PWR: br_mon_ptrs_o[MONITOR_PWR] <= cfg_data_i;
                    default: ;
                endcase
            end
        end
    end

    /* Clear control */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            br_mon_clear_o       <= '0;
            br_mon_task_clear_o <= '0;
        end
        else begin
            if (br_mon_clear_ack_i) begin
                br_mon_clear_o <= 1'b0;
            end
            else if (cfg_en_i && cfg_we_i && cfg_addr_i == DMNI_BR_MON_CLEAR) begin
                br_mon_clear_o       <= 1'b1;
                br_mon_task_clear_o <= cfg_data_i;
            end
        end
    end

endmodule
