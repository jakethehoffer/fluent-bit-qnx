/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Jake Hoffman */

/* Shared fakes for the collect fault tests. Include after the Fluent Bit
 * headers and before the plugin source. Only the record encoder, the hand-off
 * to Fluent Bit and the plugin logger are replaced. Everything else in the
 * plugin runs as shipped. */
#ifndef FBQ_COLLECT_FAKES_H
#define FBQ_COLLECT_FAKES_H

#undef NDEBUG
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static int commits;        /* commit attempts, including failed ones */
static int fail_commit_at; /* 1-based attempt that fails, 0 for none */
static int rollbacks;
static int append_calls;
static int append_result;
static int stored_records; /* records in batches Fluent Bit accepted */
static int warns;
static int errors;
static char last_msg[512];

static int fake_ok(struct flb_log_event_encoder *e)
{
    (void) e;
    return FLB_EVENT_ENCODER_SUCCESS;
}

static int fake_set_timestamp(struct flb_log_event_encoder *e, struct flb_time *tm)
{
    (void) e; (void) tm;
    return FLB_EVENT_ENCODER_SUCCESS;
}

static int fake_values(struct flb_log_event_encoder *e, ...)
{
    (void) e;
    return FLB_EVENT_ENCODER_SUCCESS;
}

/* output_length counts committed records, one byte each. */
static int fake_commit(struct flb_log_event_encoder *e)
{
    commits++;
    if (commits == fail_commit_at) {
        return FLB_EVENT_ENCODER_ERROR_INVALID_ARGUMENT;
    }
    e->output_length++;
    return FLB_EVENT_ENCODER_SUCCESS;
}

static int fake_rollback(struct flb_log_event_encoder *e)
{
    (void) e;
    rollbacks++;
    return FLB_EVENT_ENCODER_SUCCESS;
}

static int fake_reset(struct flb_log_event_encoder *e)
{
    e->output_length = 0;
    return FLB_EVENT_ENCODER_SUCCESS;
}

static int fake_append(struct flb_input_instance *ins, const char *tag,
                       size_t tag_len, const void *buf, size_t size)
{
    (void) ins; (void) tag; (void) tag_len; (void) buf;
    append_calls++;
    if (append_result == 0) {
        stored_records += (int) size;
    }
    return append_result;
}

__attribute__((unused)) static int fake_time_get(struct flb_time *tm)
{
    tm->tm.tv_sec = 1;
    tm->tm.tv_nsec = 0;
    return 0;
}

static void note(int *counter, const char *fmt, ...)
{
    va_list ap;

    (*counter)++;
    va_start(ap, fmt);
    vsnprintf(last_msg, sizeof(last_msg), fmt, ap);
    va_end(ap);
}

static void reset_counters(void)
{
    commits = fail_commit_at = rollbacks = 0;
    append_calls = append_result = stored_records = 0;
    warns = errors = 0;
    last_msg[0] = '\0';
}

#undef flb_plg_warn
#undef flb_plg_error
#define flb_plg_warn(ins, ...) note(&warns, __VA_ARGS__)
#define flb_plg_error(ins, ...) note(&errors, __VA_ARGS__)
#define flb_log_event_encoder_begin_record fake_ok
#define flb_log_event_encoder_set_timestamp fake_set_timestamp
#define flb_log_event_encoder_append_body_values_unsafe fake_values
#define flb_log_event_encoder_commit_record fake_commit
#define flb_log_event_encoder_rollback_record fake_rollback
#define flb_log_event_encoder_reset fake_reset
#define flb_input_log_append fake_append
#define flb_time_get fake_time_get

#endif
