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

    /* Header flit bit that marks an intermediate source-routing header */
    parameter int SR_FLAG = 27;

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
        DMNI_MON_FLITS          = 8'h5C,

        DMNI_OSZ_WINDOW         = 8'h60,
        DMNI_OSZ_BLOCK          = 8'h64
    } dmni_mmr_t;

    /**
     * DMNI_OSZ_BLOCK: port closing of this PE's OSZ zone, written by the kernel
     *   [3:0]   blocked external ports {S, N, W, E}
     *   [4]     the E port is the zone's access point (entrance)
     *   [5]     [31:16] holds a valid source
     *   [31:16] source accepted by the access point (mapper PE address)
     */
    parameter int OSZ_BLOCK_ACCESS_BIT    = 4;
    parameter int OSZ_BLOCK_SRC_VALID_BIT = 5;

    typedef struct packed {
		logic [15:0] payload;
		logic [15:0] seq_source;
        logic [3:0]  ksvc;
    } br_payload_t;

endpackage

`endif
