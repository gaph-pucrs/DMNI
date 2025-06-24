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
    parameter              BR_BUFFER_SIZE     = 4,
    parameter              N_PE_X             = 2,
    parameter              N_PE_Y             = 2,
    parameter              TASKS_PER_PE       = 1,
    parameter              IMEM_PAGE_SZ       = 32768,
    parameter              DMEM_PAGE_SZ       = 32768,
    parameter logic [15:0] ADDRESS            = 16'b0
)
(
    input  logic                                        clk_i,
    input  logic                                        rst_ni,

    input  logic        [31:0]                          tick_counter_i,

    /* CPU interface (MMR) */
    output logic                                        irq_o,
    input  logic                                        cfg_en_i,
    input  logic        [3:0]                           cfg_we_i,
    input  logic        [7:0]                           cfg_addr_i,
    input  logic        [31:0]                          cfg_data_i,
    output logic        [31:0]                          cfg_data_o,

    output logic                                        release_peripheral_o,

    /* Memory interface */
    output logic                                        mem_en_o,
    output logic        [ 3:0]                          mem_we_o,
    output logic        [31:0]                          mem_addr_o,
    input  logic        [31:0]                          mem_data_i,
    output logic        [31:0]                          mem_data_o,

    /* Hermes input interface */
    input  logic                                        noc_rx_i,
    input  logic                                        noc_eop_i,
    output logic                                        noc_credit_o,
    input  logic        [(HERMES_FLIT_SIZE - 1):0]      noc_data_i,

    /* Hermes output interface */
    output logic                                        noc_tx_o,
    output logic                                        noc_eop_o,
    input  logic                                        noc_credit_i,
    output logic        [(HERMES_FLIT_SIZE - 1):0]      noc_data_o,

    /* BrLite Service interface */
    input  logic                                        br_req_i,
    output logic                                        br_ack_o,
    input  br_payload_t                                 br_data_i,

    /* BrLite Output interface */
    input  logic                                        br_local_busy_i,
    output logic                                        br_req_o,
    input  logic                                        br_ack_i,
    output br_payload_t                                 br_data_o
);

    logic                            hermes_buffer_tx;
    logic                            hermes_buffer_eop;
    logic                            hermes_buffer_ack;
    logic [(HERMES_FLIT_SIZE - 1):0] hermes_buffer_data;

    RingBuffer #(
        .DATA_SIZE   (HERMES_FLIT_SIZE+1),
        .BUFFER_SIZE (HERMES_BUFFER_SIZE)
    )
    hermes_buffer (
        .clk_i    (clk_i                                  ),
        .rst_ni   (rst_ni                                 ),
        .buf_rst_i(1'b0                                   ),
        .rx_i     (noc_rx_i                               ),
        .rx_ack_o (noc_credit_o                           ),
        .data_i   ({noc_eop_i, noc_data_i}                ),
        .tx_o     (hermes_buffer_tx                       ),
        .tx_ack_i (hermes_buffer_ack                      ),
        .data_o   ({hermes_buffer_eop, hermes_buffer_data})
    );

    logic              dmni_buffer_eop_acked;
    logic              hermes_buffer_eop_acked;
    logic              hermes_send_active;
    logic              hermes_receive_active;
    logic              hermes_receive_available;
    logic              hermes_st_rcv;
    logic              hermes_st_snd;
    logic       [31:0] rcv_timestamp;
    logic       [31:0] hermes_size;
    logic       [31:0] hermes_size_2;
    logic       [31:0] hermes_address;
    logic       [31:0] hermes_address_2;
    logic       [31:0] hermes_received_cnt;

    assign hermes_buffer_eop_acked = noc_rx_i         && noc_credit_o      && noc_eop_i;
    assign dmni_buffer_eop_acked   = hermes_buffer_tx && hermes_buffer_ack && hermes_buffer_eop;

    /* verilator lint_off UNUSEDSIGNAL */
    logic timestamp_ack;
    logic timestamp_tx;
    /* verilator lint_on UNUSEDSIGNAL */

    RingBuffer #(
        .DATA_SIZE   (32                                                  ),
        .BUFFER_SIZE (HERMES_BUFFER_SIZE/4 < 2  ? 2 : HERMES_BUFFER_SIZE/4)
    )
    timestamp_buffer (
        .clk_i    (clk_i                  ),
        .rst_ni   (rst_ni                 ),
        .buf_rst_i(1'b0                   ),
        .rx_i     (hermes_buffer_eop_acked),
        .rx_ack_o (timestamp_ack          ),
        .data_i   (tick_counter_i         ),
        .tx_o     (timestamp_tx           ),
        .tx_ack_i (dmni_buffer_eop_acked  ),
        .data_o   (rcv_timestamp          )
    );

    DMA #(
        .HERMES_FLIT_SIZE (HERMES_FLIT_SIZE)
    )
    dma (
        .clk_i                            (clk_i                         ),
        .rst_ni                           (rst_ni                        ),
        .noc_rx_i                         (hermes_buffer_tx              ),
        .noc_eop_i                        (hermes_buffer_eop             ),
        .noc_credit_o                     (hermes_buffer_ack             ),
        .noc_data_i                       (hermes_buffer_data            ),
        .noc_tx_o                         (noc_tx_o                      ),
        .noc_eop_o                        (noc_eop_o                     ),
        .noc_ack_i                        (noc_credit_i                  ),
        .noc_data_o                       (noc_data_o                    ),
        .mem_en_o                         (mem_en_o                      ),
        .mem_we_o                         (mem_we_o                      ),
        .mem_addr_o                       (mem_addr_o                    ),
        .mem_data_i                       (mem_data_i                    ),
        .mem_data_o                       (mem_data_o                    ),
        .hermes_st_rcv_i                  (hermes_st_rcv                 ),
        .hermes_st_snd_i                  (hermes_st_snd                 ),
        .hermes_size_i                    (hermes_size                   ),
        .hermes_size_2_i                  (hermes_size_2                 ),
        .hermes_address_i                 (hermes_address                ),
        .hermes_address_2_i               (hermes_address_2              ),
        .hermes_received_cnt_o            (hermes_received_cnt           ),
        .hermes_send_active_o             (hermes_send_active            ),
        .hermes_receive_active_o          (hermes_receive_active         ),
        .hermes_receive_available_o       (hermes_receive_available      )
    );

    logic        br_buffer_tx;
    logic        br_buffer_ack;
    br_payload_t br_buffer_data;

    RingBuffer #(
        .DATA_SIZE   ($bits(br_payload_t)),
        .BUFFER_SIZE (BR_BUFFER_SIZE     )
    )
    br_svc_buffer (
        .clk_i    (clk_i         ),
        .rst_ni   (rst_ni        ),
        .buf_rst_i(1'b0          ),
        .rx_i     (br_req_i      ),
        .rx_ack_o (br_ack_o      ),
        .data_i   (br_data_i     ),
        .tx_o     (br_buffer_tx  ),
        .tx_ack_i (br_buffer_ack ),
        .data_o   (br_buffer_data)
    );

    NI #(
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
        .dmni_buffer_eop_acked_i          (dmni_buffer_eop_acked         ),
        .rcv_timestamp_i                  (rcv_timestamp                 ),
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
        .hermes_st_rcv_o                  (hermes_st_rcv                 ),
        .hermes_st_snd_o                  (hermes_st_snd                 ),
        .hermes_data_i                    (hermes_buffer_data            ),
        .hermes_received_cnt_i            (hermes_received_cnt           ),
        .hermes_size_o                    (hermes_size                   ),
        .hermes_size_2_o                  (hermes_size_2                 ),
        .hermes_address_o                 (hermes_address                ),
        .hermes_address_2_o               (hermes_address_2              ),
        .br_rx_i                          (br_buffer_tx                  ),
        .br_ack_o                         (br_buffer_ack                 ),
        .br_data_i                        (br_buffer_data                ),
        .br_local_busy_i                  (br_local_busy_i               ),
        .br_req_o                         (br_req_o                      ),
        .br_ack_i                         (br_ack_i                      ),
        .br_data_o                        (br_data_o                     )
    );

endmodule
