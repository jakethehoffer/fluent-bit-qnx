/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Jake Hoffman */

/* Run the shipped qnx_proc scan against the real /proc on the QNX target.
 * Only the record encoder, the hand-off to Fluent Bit and the logger are
 * fakes, so one record or one hand-off can be made to fail on purpose. */
#include <errno.h>
#include <fluent-bit/flb_input_plugin.h>
#include <fluent-bit/flb_log_event_encoder.h>
#include <fluent-bit/flb_time.h>
#include "../plugins/in_qnx_proc/in_qnx_proc.h"
#include "collect_fakes.h"

/* These tests leave match unset, so the regex search is never made. */
static int unused_regex_match(struct flb_regex *re, unsigned char *s,
                              size_t n)
{
    (void) re; (void) s; (void) n;
    assert(!"match is unset in these tests");
    return 0;
}
#define flb_regex_match unused_regex_match

#include "../plugins/in_qnx_proc/in_qnx_proc.c"

static struct flb_log_event_encoder enc;
static struct flb_in_qnx_proc ctx;

static void setup(void)
{
    memset(&ctx, 0, sizeof(ctx));
    memset(&enc, 0, sizeof(enc));
    ctx.encoder = &enc;
    ctx.include_self = 1;
    reset_counters();
}

static void one_bad_record_keeps_the_rest(void)
{
    setup();
    fail_commit_at = 2;
    assert(in_qnx_proc_collect(NULL, NULL, &ctx) == 0);
    assert(commits >= 3);
    assert(rollbacks == 1);
    assert(append_calls == 1);
    assert(stored_records == commits - 1);
    assert(enc.output_length == 0);
    assert(strstr(last_msg, "could not encode 1 process records") != NULL);
    puts("qnx_proc_bad_record_keeps_the_rest ok");
}

static void refused_handoff_is_reported_once(void)
{
    int before;

    setup();
    append_result = -1;
    assert(in_qnx_proc_collect(NULL, NULL, &ctx) == 0);
    assert(in_qnx_proc_collect(NULL, NULL, &ctx) == 0);
    assert(in_qnx_proc_collect(NULL, NULL, &ctx) == 0);
    assert(append_calls == 3);
    assert(errors == 1);
    assert(strstr(last_msg, "did not store") != NULL);
    assert(ctx.append_failing == 1);
    assert(ctx.append_lost_batches == 3);
    assert(ctx.append_lost_records == (uint64_t) commits);
    assert(stored_records == 0);
    assert(enc.output_length == 0);

    append_result = 0;
    commits = 0;
    assert(in_qnx_proc_collect(NULL, NULL, &ctx) == 0);
    assert(stored_records == commits);
    assert(strstr(last_msg, "in 3 scans were lost") != NULL);
    assert(ctx.append_failing == 0);
    assert(ctx.append_lost_records == 0 && ctx.append_lost_batches == 0);

    before = errors;
    assert(in_qnx_proc_collect(NULL, NULL, &ctx) == 0);
    assert(errors == before);
    puts("qnx_proc_refused_handoff_reported_once ok");
}

static void fail_range(pid_t from, pid_t to)
{
    pid_t p;

    for (p = from; p <= to; p++) {
        warn_once(&ctx, p, EIO);
    }
    warn_scan_end(&ctx);
}

static void warning_list_never_stays_full(void)
{
    int w;

    setup();
    /* 200 failing processes: 128 listed and warned, the rest summed once. */
    fail_range(1, 200);
    assert(warns == FLB_QNX_PROC_WARNED_MAX + 1);
    assert(strstr(last_msg, "72 more processes") != NULL);
    assert(ctx.warned_n == FLB_QNX_PROC_WARNED_MAX);

    /* The same faults next scan: nothing new is said. */
    w = warns;
    fail_range(1, 200);
    assert(warns == w);

    /* Most processes recover or exit: the list shrinks to the 10 left. */
    fail_range(1, 10);
    assert(warns == w);
    assert(ctx.warned_n == 10);
    assert(ctx.warn_hidden_reported == 0);

    /* A new fault is reported, and recovered ids leave the list. */
    fail_range(500, 500);
    assert(warns == w + 1);
    assert(ctx.warned_n == 1 && ctx.warned[0] == 500);
    puts("qnx_proc_warning_list_never_stays_full ok");
}

int main(void)
{
    alarm(60);
    one_bad_record_keeps_the_rest();
    refused_handoff_is_reported_once();
    warning_list_never_stays_full();
    return 0;
}
