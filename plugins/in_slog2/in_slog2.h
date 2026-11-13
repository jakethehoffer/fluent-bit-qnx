#ifndef FLB_IN_SLOG2_H
#define FLB_IN_SLOG2_H

#include <fluent-bit/flb_info.h>
#include <fluent-bit/flb_input.h>
#include <fluent-bit/flb_log_event_encoder.h>
#include <fluent-bit/flb_pipe.h>
#include <fluent-bit/flb_sds.h>

#include <pthread.h>
#include <stdint.h>

/* One slot is a bounded copy of a slog2 packet. 1024 slots; when the queue
 * is full the oldest slot is dropped. */
#define FLB_SLOG2_QUEUE_MAX 1024
#define FLB_SLOG2_MSG_MAX   1024
#define FLB_SLOG2_NAME_MAX  128
#define FLB_SLOG2_MATCH_MAX 256

struct flb_slog2_packet {
    uint64_t timestamp;
    uint32_t flags;
    uint32_t owner_pid;
    uint16_t thread_id;
    uint16_t code;
    uint8_t severity;
    char buffer_set[FLB_SLOG2_NAME_MAX];
    char buffer[FLB_SLOG2_NAME_MAX];
    char message[FLB_SLOG2_MSG_MAX];
};

/* Owned by the parse thread once the plugin has detached it. The thread
 * frees this block on the way out in that case. */
struct flb_slog2_shared {
    pthread_mutex_t lock;
    int stop;
    int plugin_gone;
    int thread_done;
    int wake_fd;
    struct flb_input_instance *ins;
    int from_now;
    int poll_interval_ms;
    uint64_t dropped;
    uint64_t skipped;
    unsigned head;
    unsigned count;
    char match_api[FLB_SLOG2_MATCH_MAX];
    struct flb_slog2_packet q[FLB_SLOG2_QUEUE_MAX];
};

struct flb_in_slog2 {
    flb_sds_t match;
    int from_now;
    int poll_interval_ms;
    struct flb_log_event_encoder *encoder;
    struct flb_input_instance *ins;
    struct flb_slog2_shared *shared;
    uint64_t logged_dropped;
    uint64_t logged_skipped;
    pthread_t thread;
    int thread_started;
    int coll_fd;
    flb_pipefd_t pipe_r;
    flb_pipefd_t pipe_w;
};

#endif
