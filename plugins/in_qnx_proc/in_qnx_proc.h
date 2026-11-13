#ifndef FLB_IN_QNX_PROC_H
#define FLB_IN_QNX_PROC_H

#include <fluent-bit/flb_info.h>
#include <fluent-bit/flb_input.h>
#include <fluent-bit/flb_log_event_encoder.h>
#include <fluent-bit/flb_sds.h>

#include <regex.h>
#include <sys/types.h>

#define FLB_QNX_PROC_WARNED_MAX 128

struct flb_in_qnx_proc {
    int interval_sec;
    int interval_nsec;
    flb_sds_t match;
    int include_self;
    struct flb_log_event_encoder *encoder;
    int coll_fd;
    struct flb_input_instance *ins;
    regex_t re;
    int have_re;
    pid_t warned[FLB_QNX_PROC_WARNED_MAX];
    int warned_n;
};

#endif
