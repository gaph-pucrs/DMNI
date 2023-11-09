package DMNIPkg;

    parameter DMNI_MMR_SIZE = 29;

    typedef enum logic [($clog2(DMNI_MMR_SIZE) - 1):0] {
        DMNI_STATUS,
        DMNI_IRQ_STATUS,
        DMNI_PENDING_SVC,
        DMNI_RELEASE_PERIPHERAL,
        DMNI_ADDRESS,
        DMNI_MANYCORE_SIZE,
        DMNI_TASKS_PER_PE,
        DMNI_IMEM_PAGE_SZ,
        DMNI_DMEM_PAGE_SZ,
        DMNI_HERMES_START,
        DMNI_HERMES_OPERATION,
        DMNI_HERMES_SIZE,
        DMNI_HERMES_SIZE_2,
        DMNI_HERMES_ADDRESS,
        DMNI_HERMES_ADDRESS_2,
        DMNI_HERMES_FLITS_AVAILABLE,
        DMNI_BR_START,
        DMNI_BR_SERVICE,
        DMNI_BR_KSVC,
        DMNI_BR_TARGET,
        DMNI_BR_PRODUCER,
        DMNI_BR_PAYLOAD,
        DMNI_BR_SVC_POP,
        DMNI_BR_SVC_KSVC,
        DMNI_BR_SVC_PRODUCER,
        DMNI_BR_SVC_PAYLOAD,
        DMNI_BR_MON_CLEAR,
        DMNI_BR_MON_PTR_QOS,
        DMNI_BR_MON_PTR_PWR /* Number of MON_PTR addresses should match BRLITE_MON_NSVC */
    } dmni_mmr_t;

    typedef enum {
        HERMES_OPERATION_SEND,
        HERMES_OPERATION_RECEIVE
    } hermes_op_t;

    typedef enum {
        MONITOR_QOS,
        MONITOR_PWR,
        BRLITE_MON_NSVC
    } monitor_type_t;

    typedef struct packed {
		logic [31:0] 	                        payload;
		logic [15:0] 	                        seq_source;
		logic [15:0] 	                        producer;
        logic [($clog2(BRLITE_MON_NSVC) - 1):0] msvc;
    } brlite_mon_t;

    typedef struct packed {
		logic [31:0] payload;
		logic [15:0] seq_source;
		logic [15:0] producer;
        logic [7:0]  ksvc;
    } brlite_svc_t;

    typedef struct packed {
		logic [31:0] payload;
		logic [15:0] seq_target;
		logic [15:0] producer;
        logic [7:0]  ksvc;
        logic [1:0]  service;
    } brlite_out_t;

endpackage
