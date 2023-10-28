package DMNIPkg;

    parameter DMNI_MMR_SIZE = 26;

    typedef enum logic [($clog2(DMNI_MMR_SIZE) - 1):0] {
        DMNI_HERMES_START,
        DMNI_HERMES_OPERATION,
        DMNI_HERMES_SEND_ACTIVE,
        DMNI_HERMES_RECEIVE_ACTIVE,
        DMNI_HERMES_SIZE,
        DMNI_HERMES_SIZE_2,
        DMNI_HERMES_ADDRESS,
        DMNI_HERMES_ADDRESS_2,
        DMNI_BR_SVC_START,
        DMNI_BR_SVC_POP,
        DMNI_BR_SVC_SERVICE,
        DMNI_BR_SVC_LOCAL_BUSY,
        DMNI_BR_SVC_HAS_MESSAGE,
        DMNI_BR_SVC_KSVC,
        DMNI_BR_SVC_TARGET,
        DMNI_BR_SVC_PRODUCER,
        DMNI_BR_SVC_PAYLOAD,
        DMNI_BR_SVC_READ_KSVC,
        DMNI_BR_SVC_READ_PRODUCER,
        DMNI_BR_SVC_READ_PAYLOAD,
        DMNI_BR_MON_PTR_QOS,
        DMNI_BR_MON_PTR_PWR,
        DMNI_BR_MON_PTR_2,
        DMNI_BR_MON_PTR_3,
        DMNI_BR_MON_PTR_4,
        DMNI_BR_MON_CLEAR_MONITOR
    } dmni_mmr_t;

    parameter BRLITE_MON_NSVC = 4;

    typedef struct packed {
		logic 	[31:0] 	payload;
		logic 	[15:0] 	seq_source;
		logic 	[15:0] 	producer;
        logic   [($clog2(BRLITE_MON_NSVC) - 1):0]  msvc;
    } brlite_mon_t;

endpackage
