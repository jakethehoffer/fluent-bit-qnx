/*  fluent-bit-qnx: QNX inputs for Fluent Bit
 *  Copyright 2026 Jake Hoffman
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#ifndef FLB_IN_QNX_PROC_H
#define FLB_IN_QNX_PROC_H

#include <fluent-bit/flb_info.h>
#include <fluent-bit/flb_input.h>
#include <fluent-bit/flb_log_event_encoder.h>
#include <fluent-bit/flb_regex.h>
#include <fluent-bit/flb_sds.h>

#include <stdint.h>
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
    /* Compiled match, or NULL when match is unset. */
    struct flb_regex *re;
    /* Processes already warned about. A process leaves the list after a
     * scan that did not fail on it, so the list holds only current faults. */
    pid_t warned[FLB_QNX_PROC_WARNED_MAX];
    unsigned char warned_seen[FLB_QNX_PROC_WARNED_MAX];
    int warned_n;
    int warn_hidden;
    int warn_hidden_reported;
    /* Set while Fluent Bit refuses records, with the loss counted since. */
    int append_failing;
    uint64_t append_lost_records;
    uint64_t append_lost_batches;
};

#endif
