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

    parameter DMNI_MMR_SIZE = 13;
    typedef enum logic [($clog2(DMNI_MMR_SIZE) - 1):0] {
        DMNI_STATUS,
        DMNI_IRQ,
        DMNI_ADDRESS,
        DMNI_MANYCORE_SZ,
        DMNI_IMEM_PAGE_SZ,
        DMNI_DMEM_PAGE_SZ,
        DMNI_HERMES_SIZE,
        DMNI_HERMES_SIZE_2,
        DMNI_HERMES_ADDRESS,
        DMNI_HERMES_ADDRESS_2,
        DMNI_BR_KSVC,
        DMNI_BR_PAYLOAD,
        DMNI_RCV_TIMESTAMP
    } dmni_mmr_t;

    typedef struct packed {
		logic [15:0] payload;
		logic [15:0] seq_source;
        logic [3:0]  ksvc;
    } br_payload_t;

endpackage

`endif
