/**
 * DMNI
 * @file DMNI.sv
 *
 * @author Angelo Elias Dal Zotto (angelo.dalzotto@edu.pucrs.br)
 * GAPH - Hardware Design Support Group (https://corfu.pucrs.br)
 * PUCRS - Pontifical Catholic University of Rio Grande do Sul (http://pucrs.br/)
 *
 * @date October 2023
 *
 * @brief DMNI top
 */

`include "DMNIPkg.sv"

module DMNI
    import DMNIPkg::*;
#(
    parameter              HERMES_FLIT_SIZE   = 32,
    parameter              HERMES_BUFFER_SIZE = 16,
    parameter              BR_MON_BUFFER_SIZE = 8,
    parameter              BR_SVC_BUFFER_SIZE = 4,
    parameter              N_PE_X             = 2,
    parameter              N_PE_Y             = 2,
    parameter              TASKS_PER_PE       = 1,
    parameter              IMEM_PAGE_SZ       = 32768,
    parameter              DMEM_PAGE_SZ       = 32768,
    parameter logic [15:0] ADDRESS            = 16'b0
)
(
    input logic                                         clk_i,
    input logic                                         rst_ni,

    /* CPU interface (MMR) */
    output logic                                        irq_o,
    input  logic                                        cfg_en_i,
    input  logic                                        cfg_we_i,
    input  logic        [($clog2(DMNI_MMR_SIZE) - 1):0] cfg_addr_i,
    input  logic        [31:0]                          cfg_data_i,
    output logic        [31:0]                          cfg_data_o,

    output logic                                        release_peripheral_o,

    /* Memory interface */
    output logic        [ 3:0]                          mem_we_o,
    output logic        [31:0]                          mem_addr_o,
    input  logic        [31:0]                          mem_data_i,
    output logic        [31:0]                          mem_data_o,

    /* Hermes input interface */
    input  logic                                        noc_rx_i,
    output logic                                        noc_credit_o,
    input  logic        [(HERMES_FLIT_SIZE - 1):0]      noc_data_i,

    /* Hermes output interface */
    output logic                                        noc_tx_o,
    input  logic                                        noc_credit_i,
    output logic        [(HERMES_FLIT_SIZE - 1):0]      noc_data_o,

    /* BrLite Monitor interface */
    input  logic                                        br_req_mon_i,
    output logic                                        br_ack_mon_o,
    input  brlite_mon_t                                 br_mon_data_i,

    /* BrLite Service interface */
    input  logic                                        br_req_svc_i,
    output logic                                        br_ack_svc_o,
    input  brlite_svc_t                                 br_svc_data_i,

    /* BrLite Output interface */
    input  logic                                        br_local_busy_i,
    output logic                                        br_req_o,
    input  logic                                        br_ack_i,
    output brlite_out_t                                 br_data_o
);

    logic                            hermes_buffer_tx;
    logic                            hermes_buffer_ack;
    logic [(HERMES_FLIT_SIZE - 1):0] hermes_buffer_data;

    RingBuffer #(
        .DATA_SIZE   (HERMES_FLIT_SIZE  ),
        .BUFFER_SIZE (HERMES_BUFFER_SIZE)
    )
    hermes_buffer (
        .clk_i    (clk_i             ),
        .rst_ni   (rst_ni            ),
        .rx_i     (noc_rx_i          ),
        .rx_ack_o (noc_credit_o      ),
        .data_i   (noc_data_i        ),
        .tx_o     (hermes_buffer_tx  ),
        .tx_ack_i (hermes_buffer_ack ),
        .data_o   (hermes_buffer_data)
    );

    logic        br_mon_buffer_tx;
    logic        br_mon_buffer_ack;
    brlite_mon_t br_mon_buffer_data;

    RingBuffer #(
        .DATA_SIZE   ($bits(brlite_mon_t)),
        .BUFFER_SIZE (BR_MON_BUFFER_SIZE )
    )
    br_mon_buffer (
        .clk_i    (clk_i             ),
        .rst_ni   (rst_ni            ),
        .rx_i     (br_req_mon_i      ),
        .rx_ack_o (br_ack_mon_o      ),
        .data_i   (br_mon_data_i     ),
        .tx_o     (br_mon_buffer_tx  ),
        .tx_ack_i (br_mon_buffer_ack ),
        .data_o   (br_mon_buffer_data)
    );

    logic                                               hermes_start;
    logic                                               hermes_send_active;
    logic                                               hermes_receive_active;
    logic                                               hermes_receive_available;
    logic                                               br_mon_clear;
    logic                                               br_mon_clear_ack;
    hermes_op_t                                         hermes_operation;
    logic       [31:0]                                  hermes_size;
    logic       [31:0]                                  hermes_size_2;
    logic       [31:0]                                  hermes_address;
    logic       [31:0]                                  hermes_address_2;
    logic       [31:0]                                  br_mon_task_clear;
    logic       [(HERMES_FLIT_SIZE - 1):0]              hermes_receive_flits_available;
    logic       [($clog2(BRLITE_MON_NSVC) - 1):0][31:0] br_mon_ptrs;

    DMA #(
        .HERMES_FLIT_SIZE (HERMES_FLIT_SIZE),
        .N_PE_X           (N_PE_X          ),
        .N_PE_Y           (N_PE_Y          ),
        .TASKS_PER_PE     (TASKS_PER_PE    )
    )
    dma (
        .clk_i                            (clk_i                         ),
        .rst_ni                           (rst_ni                        ),
        .noc_rx_i                         (hermes_buffer_tx              ),
        .noc_credit_o                     (hermes_buffer_ack             ),
        .noc_data_i                       (hermes_buffer_data            ),
        .noc_tx_o                         (noc_tx_o                      ),
        .noc_ack_i                        (noc_credit_i                  ),
        .noc_data_o                       (noc_data_o                    ),
        .brlite_req_i                     (br_mon_buffer_tx              ),
        .brlite_ack_o                     (br_mon_buffer_ack             ),
        .brlite_data_i                    (br_mon_buffer_data            ),
        .mem_we_o                         (mem_we_o                      ),
        .mem_addr_o                       (mem_addr_o                    ),
        .mem_data_i                       (mem_data_i                    ),
        .mem_data_o                       (mem_data_o                    ),
        .hermes_start_i                   (hermes_start                  ),
        .brlite_clear_i                   (br_mon_clear                  ),
        .hermes_operation_i               (hermes_operation              ),
        .hermes_size_i                    (hermes_size                   ),
        .hermes_size_2_i                  (hermes_size_2                 ),
        .hermes_address_i                 (hermes_address                ),
        .hermes_address_2_i               (hermes_address_2              ),
        .brlite_task_clear_i              (br_mon_task_clear             ),
        .brlite_mon_ptrs_i                (br_mon_ptrs                   ),
        .hermes_send_active_o             (hermes_send_active            ),
        .hermes_receive_active_o          (hermes_receive_active         ),
        .hermes_receive_available_o       (hermes_receive_available      ),
        .brlite_clear_ack_o               (br_mon_clear_ack              ),
        .hermes_receive_flits_available_o (hermes_receive_flits_available)
    );

    logic        br_svc_buffer_tx;
    logic        br_svc_buffer_ack;
    brlite_svc_t br_svc_buffer_data;

    RingBuffer #(
        .DATA_SIZE   ($bits(brlite_svc_t)),
        .BUFFER_SIZE (BR_SVC_BUFFER_SIZE )
    )
    br_svc_buffer (
        .clk_i    (clk_i             ),
        .rst_ni   (rst_ni            ),
        .rx_i     (br_req_svc_i      ),
        .rx_ack_o (br_ack_svc_o      ),
        .data_i   (br_svc_data_i     ),
        .tx_o     (br_svc_buffer_tx  ),
        .tx_ack_i (br_svc_buffer_ack ),
        .data_o   (br_svc_buffer_data)
    );

    NI #(
        .HERMES_FLIT_SIZE (HERMES_FLIT_SIZE),
        .N_PE_X           (N_PE_X          ),
        .N_PE_Y           (N_PE_Y          ),
        .TASKS_PER_PE     (TASKS_PER_PE    ),
        .IMEM_PAGE_SZ     (IMEM_PAGE_SZ    ),
        .DMEM_PAGE_SZ     (DMEM_PAGE_SZ    ),
        .ADDRESS          (ADDRESS         )
    )
    ni (
        .clk_i                            (clk_i                         ),
        .rst_ni                           (rst_ni                        ),
        .irq_o                            (irq_o                         ),
        .cfg_en_i                         (cfg_en_i                      ),
        .cfg_we_i                         (cfg_we_i                      ),
        .cfg_addr_i                       (cfg_addr_i                    ),
        .cfg_data_i                       (cfg_data_i                    ),
        .cfg_data_o                       (cfg_data_o                    ),
        .release_peripheral_o             (release_peripheral_o          ),
        .hermes_send_active_i             (hermes_send_active            ),
        .hermes_receive_active_i          (hermes_receive_active         ),
        .hermes_receive_available_i       (hermes_receive_available      ),
        .hermes_receive_flits_available_i (hermes_receive_flits_available),
        .hermes_start_o                   (hermes_start                  ),          
        .hermes_operation_o               (hermes_operation              ),
        .hermes_size_o                    (hermes_size                   ),
        .hermes_size_2_o                  (hermes_size_2                 ),
        .hermes_address_o                 (hermes_address                ),
        .hermes_address_2_o               (hermes_address_2              ),
        .br_mon_clear_o                   (br_mon_clear                  ),
        .br_mon_clear_ack_i               (br_mon_clear_ack              ),
        .br_mon_task_clear_o              (br_mon_task_clear             ),
        .br_mon_ptrs_o                    (br_mon_ptrs                   ),
        .br_svc_rx_i                      (br_svc_buffer_tx              ),
        .br_svc_ack_o                     (br_svc_buffer_ack             ),
        .br_svc_data_i                    (br_svc_buffer_data            ),
        .br_local_busy_i                  (br_local_busy_i               ),
        .br_req_o                         (br_req_o                      ),
        .br_ack_i                         (br_ack_i                      ),
        .br_data_o                        (br_data_o                     )
    );

endmodule
