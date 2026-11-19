/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Jake Hoffman */

/* Exercise the production stop/callback code with real QNX threads. Only the
 * blocking parser and timed-join outcome are controlled to force each race. */
#undef NDEBUG
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <fluent-bit/flb_input_plugin.h>
#include <fluent-bit/flb_mem.h>
#include <slog2_parse.h>
#include "../plugins/in_slog2/in_slog2.h"

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int mode, released, entered, freed_queue, freed_shared, detached;
static void *queue_ptr, *shared_ptr;
static struct flb_slog2_shared *active;

static void counted_free(void *ptr)
{
    if (ptr == NULL) {
        return;
    }
    pthread_mutex_lock(&gate);
    if (ptr == queue_ptr) {
        assert(++freed_queue == 1);
    }
    if (ptr == shared_ptr) {
        assert(++freed_shared == 1);
    }
    free(ptr);
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&gate);
}

static int controlled_parse(uint32_t flags, char *dir, char *match,
                            slog2_packet_info_t *info,
                            slog2_packet_callback callback, void *param)
{
    (void) flags; (void) dir; (void) match;
    pthread_mutex_lock(&gate);
    entered = 1;
    pthread_cond_broadcast(&changed);
    while (!released) {
        pthread_cond_wait(&changed, &gate);
    }
    pthread_mutex_unlock(&gate);
    if (mode == 2) {
        /* A late callback must not touch the freed queue or notification fd. */
        assert(callback(info, NULL, param) == -1);
    }
    return 0;
}

static int controlled_join(pthread_t thread, void **value,
                           const struct timespec *deadline)
{
    int done;
    (void) deadline;
    if (mode == 0) {
        return pthread_join(thread, value);
    }
    if (mode == 1) {
        /* Reproduce completion between the timed join and stop's flag check. */
        do {
            pthread_mutex_lock(&active->lock);
            done = active->thread_done;
            pthread_mutex_unlock(&active->lock);
            if (!done) { usleep(1000); }
        } while (!done);
    }
    return ETIMEDOUT;
}

static int counted_detach(pthread_t thread)
{
    detached++;
    return pthread_detach(thread);
}

int flb_input_collector_pause(int id, struct flb_input_instance *ins)
{
    (void) id; (void) ins;
    return 0;
}

int flb_pipe_close(flb_pipefd_t fd) { return close(fd); }

/* No engine logger is running in this standalone test. */
#undef flb_plg_error
#define flb_plg_error(...) ((void) 0)
#define flb_free counted_free
#define slog2_parse_all controlled_parse
#define pthread_timedjoin controlled_join
#define pthread_detach counted_detach
#include "../plugins/in_slog2/in_slog2.c"

static void run_case(int selected)
{
    struct flb_in_slog2 ctx = {0};
    int fds[2];
    struct flb_slog2_shared *sh = calloc(1, sizeof(*sh));
    assert(sh != NULL);
    sh->q = calloc(FLB_SLOG2_QUEUE_MAX, sizeof(*sh->q));
    assert(sh->q != NULL);
    assert(pthread_mutex_init(&sh->lock, NULL) == 0);
    assert(pipe(fds) == 0);
    sh->wake_fd = fds[1];
    mode = selected;
    released = selected != 2;
    entered = freed_queue = freed_shared = detached = 0;
    active = sh;
    shared_ptr = sh;
    queue_ptr = sh->q;
    ctx.shared = sh;
    ctx.coll_fd = -1;
    ctx.pipe_r = fds[0];
    ctx.pipe_w = fds[1];
    if (selected != 3) {
        assert(pthread_create(&ctx.thread, NULL, parse_thread, sh) == 0);
        ctx.thread_started = 1;
        pthread_mutex_lock(&gate);
        while (!entered) { pthread_cond_wait(&changed, &gate); }
        pthread_mutex_unlock(&gate);
    }
    in_slog2_stop(&ctx);
    assert(ctx.shared == NULL && ctx.thread_started == 0);
    assert(freed_queue == 1);
    assert(detached == (selected == 1 || selected == 2 ? 1 : 0));
    assert(fcntl(fds[0], F_GETFD) == -1 && errno == EBADF);
    assert(fcntl(fds[1], F_GETFD) == -1 && errno == EBADF);
    pthread_mutex_lock(&gate);
    if (selected == 2) {
        assert(freed_shared == 0);
        released = 1;
        pthread_cond_broadcast(&changed);
    }
    while (!freed_shared) { pthread_cond_wait(&changed, &gate); }
    pthread_mutex_unlock(&gate);
    /* Stop must also be safe to call a second time. */
    in_slog2_stop(&ctx);
    assert(freed_queue == 1 && freed_shared == 1);
}

int main(void)
{
    int i;
    alarm(30);
    for (i = 0; i < 32; i++) {
        run_case(0);
        run_case(1);
        run_case(2);
        run_case(3); /* Initialization failed before starting a worker. */
    }
    puts("slog2_stop_reclaims_queue_and_thread ok");
    return 0;
}
