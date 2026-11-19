/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Jake Hoffman */

/* Run the shipped slog2 collect step on the QNX target with queued packets.
 * Only the record encoder, the hand-off to Fluent Bit and the logger are
 * fakes, so one record or one hand-off can be made to fail on purpose. */
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <fluent-bit/flb_input_plugin.h>
#include <fluent-bit/flb_log_event_encoder.h>
#include <fluent-bit/flb_time.h>
#include "../plugins/in_slog2/in_slog2.h"
#include "collect_fakes.h"
#include "../plugins/in_slog2/in_slog2.c"

static struct flb_log_event_encoder enc;
static struct flb_in_slog2 ctx;
static struct flb_slog2_shared *sh;
static int fds[2];

static void setup(void)
{
    memset(&ctx, 0, sizeof(ctx));
    memset(&enc, 0, sizeof(enc));
    sh = calloc(1, sizeof(*sh));
    assert(sh != NULL);
    sh->q = calloc(FLB_SLOG2_QUEUE_MAX, sizeof(*sh->q));
    assert(sh->q != NULL);
    assert(pthread_mutex_init(&sh->lock, NULL) == 0);
    assert(pipe(fds) == 0);
    assert(fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0);
    ctx.encoder = &enc;
    ctx.shared = sh;
    ctx.pipe_r = fds[0];
    reset_counters();
}

static void teardown(void)
{
    close(fds[0]);
    close(fds[1]);
    pthread_mutex_destroy(&sh->lock);
    free(sh->q);
    free(sh);
}

static void queue_packets(int n)
{
    int i;

    for (i = 0; i < n; i++) {
        struct flb_slog2_packet *slot;

        slot = &sh->q[(sh->head + sh->count) % FLB_SLOG2_QUEUE_MAX];
        memset(slot, 0, sizeof(*slot));
        slot->timestamp = 1700000000ULL * 1000000000ULL;
        slot->severity = SLOG2_INFO;
        snprintf(slot->buffer_set, sizeof(slot->buffer_set), "fbq_test");
        snprintf(slot->message, sizeof(slot->message), "line %d", i);
        sh->count++;
    }
}

static void one_bad_record_keeps_the_rest(void)
{
    setup();
    queue_packets(5);
    fail_commit_at = 3;
    assert(in_slog2_collect(NULL, NULL, &ctx) == 0);
    assert(commits == 5);
    assert(rollbacks == 1);
    assert(append_calls == 1);
    assert(stored_records == 4);
    assert(sh->count == 0);
    assert(enc.output_length == 0);
    assert(strstr(last_msg, "could not encode 1 slog2 records") != NULL);
    teardown();
    puts("slog2_bad_record_keeps_the_rest ok");
}

static void refused_handoff_is_reported_once(void)
{
    int i;

    setup();
    append_result = -1;
    for (i = 0; i < 3; i++) {
        queue_packets(2);
        assert(in_slog2_collect(NULL, NULL, &ctx) == 0);
    }
    assert(append_calls == 3);
    assert(errors == 1);
    assert(strstr(last_msg, "did not store 2 slog2 records") != NULL);
    assert(ctx.append_lost_records == 6 && ctx.append_lost_batches == 3);
    assert(enc.output_length == 0);

    append_result = 0;
    queue_packets(2);
    assert(in_slog2_collect(NULL, NULL, &ctx) == 0);
    assert(stored_records == 2);
    assert(strstr(last_msg, "6 slog2 records in 3 batches were lost") != NULL);
    assert(ctx.append_failing == 0);

    queue_packets(1);
    assert(in_slog2_collect(NULL, NULL, &ctx) == 0);
    assert(errors == 1);
    assert(stored_records == 3);
    teardown();
    puts("slog2_refused_handoff_reported_once ok");
}

int main(void)
{
    alarm(60);
    one_bad_record_keeps_the_rest();
    refused_handoff_is_reported_once();
    return 0;
}
