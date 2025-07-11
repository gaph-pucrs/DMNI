/**
 * DMNI
 * @file DMNIPkg.sv
 *
 * @author Angelo Elias Dal Zotto (angelo.dalzotto@edu.pucrs.br)
 * GAPH - Hardware Design Support Group (https://corfu.pucrs.br)
 * PUCRS - Pontifical Catholic University of Rio Grande do Sul (http://pucrs.br/)
 *
 * @date October 2023
 *
 * @brief DMNI package
 */

`ifndef DMNI_PKG
`define DMNI_PKG

package DMNIPkg;

    parameter logic [7:0] MONITOR = 8'h44;

    typedef enum logic [7:0] {
        DMNI_STATUS             = 8'h00,
        DMNI_IRQ_ENABLE         = 8'h04,
        DMNI_IRQ_PENDING        = 8'h08,

        DMNI_ADDRESS            = 8'h10,
        DMNI_MANYCORE_SZ        = 8'h14,
        DMNI_IMEM_PAGE_SZ       = 8'h18,
        DMNI_DMEM_PAGE_SZ       = 8'h1C,

        DMNI_HEAD               = 8'h20,
        DMNI_RECD_CNT           = 8'h24,
        DMNI_RCV_TIMESTAMP      = 8'h28,

        DMNI_HERMES_SIZE        = 8'h30,
        DMNI_HERMES_SIZE_2      = 8'h34,
        DMNI_HERMES_ADDRESS     = 8'h38,
        DMNI_HERMES_ADDRESS_2   = 8'h3C,

        DMNI_BR_KSVC            = 8'h40,
        DMNI_BR_PAYLOAD         = 8'h44,

        DMNI_MON_BASE           = 8'h50,
        DMNI_MON_SEM_OC         = 8'h54,
        DMNI_MON_SEM_AV         = 8'h58,
        DMNI_MON_FLITS          = 8'h5C
    } dmni_mmr_t;

    typedef struct packed {
		logic [15:0] payload;
		logic [15:0] seq_source;
        logic [3:0]  ksvc;
    } br_payload_t;

endpackage

`endif
