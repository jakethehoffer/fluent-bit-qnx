#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include <slog2_parse.h>
#include <sys/slog2.h>

#include <fluent-bit/flb_input_plugin.h>
#include <fluent-bit/flb_log_event_encoder.h>
#include <fluent-bit/flb_pipe.h>
#include <fluent-bit/flb_time.h>

#include "in_slog2.h"

/* slog2 keeps letters, digits, '_' and '.' in a buffer-set name and stores
 * every other byte as '_'. Checked on the target: "fbq-test" is stored as
 * "fbq_test", while "zz.bb" and "ZzBb" stay as written. slog2_parse_all
 * matches the stored name, so the match list is rewritten the same way.
 * The record uses the caller's original token when that token stores as
 * the packet's name, which keeps buffer_set "fbq-test" for match fbq-test.
 */

static int name_byte_kept(char c)
{
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '_' || c == '.') {
        return 1;
    }
    return 0;
}

static void copy_bounded(char *dst, size_t dst_len, const char *src, size_t src_cap)
{
    size_t n;

    if (dst_len == 0) {
        return;
    }
    n = 0;
    if (src != NULL) {
        while (n < src_cap && n + 1 < dst_len && src[n] != '\0') {
            dst[n] = src[n];
            n++;
        }
    }
    dst[n] = '\0';
}

static int all_digits(const char *s)
{
    if (s == NULL || *s == '\0') {
        return 0;
    }
    for (; *s != '\0'; s++) {
        if (*s < '0' || *s > '9') {
            return 0;
        }
    }
    return 1;
}

/* Live files are "<set>.<pid>" or "<set>.<pid>..<index>". */
static void strip_file_suffix(char *name)
{
    char *dot;

    dot = strrchr(name, '.');
    if (dot == NULL || dot == name || !all_digits(dot + 1)) {
        return;
    }
    if (dot > name && dot[-1] == '.') {
        dot[-1] = '\0';
        dot = strrchr(name, '.');
        if (dot != NULL && dot != name && all_digits(dot + 1)) {
            *dot = '\0';
        }
        return;
    }
    *dot = '\0';
}

static void buffer_set_from_file(char *dst, size_t dst_len,
                                 const char *file_name, size_t file_cap)
{
    char tmp[FLB_SLOG2_NAME_MAX];
    size_t i;
    size_t start;
    size_t len;

    start = 0;
    len = 0;
    if (file_name != NULL) {
        for (i = 0; i < file_cap && file_name[i] != '\0'; i++) {
            if (file_name[i] == '/') {
                start = i + 1;
            }
            len = i + 1;
        }
    }
    if (start > len) {
        start = 0;
    }
    copy_bounded(tmp, sizeof(tmp),
                 file_name != NULL ? file_name + start : "",
                 len - start);
    strip_file_suffix(tmp);
    copy_bounded(dst, dst_len, tmp, sizeof(tmp) - 1);
}

static void sanitize_token(char *dst, size_t dst_len, const char *src, size_t n)
{
    size_t o;

    while (n > 0 && (*src == ' ' || *src == '\t')) {
        src++;
        n--;
    }
    while (n > 0 && (src[n - 1] == ' ' || src[n - 1] == '\t')) {
        n--;
    }
    o = 0;
    while (n > 0 && o + 1 < dst_len) {
        char c = *src;
        if (!name_byte_kept(c)) {
            c = '_';
        }
        dst[o++] = c;
        src++;
        n--;
    }
    if (dst_len > 0) {
        dst[o] = '\0';
    }
}

static void sanitize_match_list(char *dst, size_t dst_len, const char *src)
{
    size_t o;

    if (dst_len == 0) {
        return;
    }
    dst[0] = '\0';
    o = 0;
    if (src == NULL || src[0] == '\0') {
        return;
    }
    while (*src != '\0') {
        const char *comma;
        char token[FLB_SLOG2_NAME_MAX];
        size_t tn;
        size_t n;

        comma = strchr(src, ',');
        n = comma != NULL ? (size_t) (comma - src) : strlen(src);
        sanitize_token(token, sizeof(token), src, n);
        tn = strlen(token);
        if (tn > 0) {
            if (o > 0 && o + 1 < dst_len) {
                dst[o++] = ',';
            }
            if (o + tn >= dst_len) {
                tn = dst_len - o - 1;
            }
            memcpy(dst + o, token, tn);
            o += tn;
            dst[o] = '\0';
        }
        if (comma == NULL) {
            break;
        }
        src = comma + 1;
    }
}

static void buffer_set_for_record(char *dst, size_t dst_len,
                                  const char *stored, const char *match_raw)
{
    const char *p;

    if (match_raw != NULL && match_raw[0] != '\0' && stored != NULL) {
        p = match_raw;
        while (*p != '\0') {
            const char *comma;
            const char *tok;
            char original[FLB_SLOG2_NAME_MAX];
            char sanitized[FLB_SLOG2_NAME_MAX];
            size_t n;
            size_t o;
            size_t i;

            comma = strchr(p, ',');
            n = comma != NULL ? (size_t) (comma - p) : strlen(p);
            tok = p;
            while (n > 0 && (*tok == ' ' || *tok == '\t')) {
                tok++;
                n--;
            }
            while (n > 0 && (tok[n - 1] == ' ' || tok[n - 1] == '\t')) {
                n--;
            }
            o = 0;
            for (i = 0; i < n && o + 1 < sizeof(original); i++) {
                original[o++] = tok[i];
            }
            original[o] = '\0';
            sanitize_token(sanitized, sizeof(sanitized), original, o);
            if (sanitized[0] != '\0' && strcmp(sanitized, stored) == 0) {
                copy_bounded(dst, dst_len, original, sizeof(original));
                return;
            }
            if (comma == NULL) {
                break;
            }
            p = comma + 1;
        }
    }
    copy_bounded(dst, dst_len, stored != NULL ? stored : "", FLB_SLOG2_NAME_MAX);
}

static void copy_message(char *dst, size_t dst_len, uint16_t data_size,
                         const void *payload)
{
    const char *src = payload;
    size_t n;

    if (dst_len == 0) {
        return;
    }
    dst[0] = '\0';
    if (src == NULL) {
        return;
    }
    if (data_size == 0) {
        n = 0;
        while (n + 1 < dst_len && src[n] != '\0') {
            n++;
        }
    }
    else {
        n = data_size;
        if (n >= dst_len) {
            n = dst_len - 1;
        }
    }
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static const char *severity_name(uint8_t severity)
{
    switch (severity) {
    case SLOG2_SHUTDOWN:
        return "SHUTDOWN";
    case SLOG2_CRITICAL:
        return "CRITICAL";
    case SLOG2_ERROR:
        return "ERROR";
    case SLOG2_WARNING:
        return "WARNING";
    case SLOG2_NOTICE:
        return "NOTICE";
    case SLOG2_INFO:
        return "INFO";
    case SLOG2_DEBUG1:
        return "DEBUG1";
    case SLOG2_DEBUG2:
        return "DEBUG2";
    default:
        return "UNKNOWN";
    }
}

static void packet_wall_time(uint64_t timestamp, uint32_t flags, struct flb_time *tm)
{
    uint64_t wall;

    wall = timestamp;
    if ((flags & SLOG2_PACKET_FLAGS_MONOTONIC) != 0) {
        struct timespec mono;
        struct timespec real;

        if (clock_gettime(CLOCK_MONOTONIC, &mono) == 0 &&
            clock_gettime(CLOCK_REALTIME, &real) == 0) {
            uint64_t mono_ns;
            uint64_t real_ns;

            mono_ns = timespec2nsec(&mono);
            real_ns = timespec2nsec(&real);
            if (timestamp <= mono_ns) {
                uint64_t age = mono_ns - timestamp;
                wall = real_ns >= age ? real_ns - age : 0;
            }
            else {
                wall = real_ns + (timestamp - mono_ns);
            }
        }
    }
    tm->tm.tv_sec = (time_t) (wall / 1000000000ULL);
    tm->tm.tv_nsec = (long) (wall % 1000000000ULL);
}

static int on_packet(slog2_packet_info_t *info, void *payload, void *param)
{
    struct flb_slog2_shared *sh = param;
    struct flb_slog2_packet *slot;
    unsigned index;
    char byte;

    pthread_mutex_lock(&sh->lock);
    if (sh->stop || sh->plugin_gone) {
        pthread_mutex_unlock(&sh->lock);
        return -1;
    }
    if (info == NULL || payload == NULL ||
        info->data_type != SLOG2_TYPE_ASCII_STRING) {
        sh->skipped++;
        pthread_mutex_unlock(&sh->lock);
        return 0;
    }
    if (sh->count == FLB_SLOG2_QUEUE_MAX) {
        sh->head = (sh->head + 1) % FLB_SLOG2_QUEUE_MAX;
        sh->count--;
        sh->dropped++;
    }
    index = (sh->head + sh->count) % FLB_SLOG2_QUEUE_MAX;
    slot = &sh->q[index];
    memset(slot, 0, sizeof(*slot));
    slot->timestamp = info->timestamp;
    slot->flags = info->flags;
    slot->owner_pid = info->owner_pid;
    slot->thread_id = info->thread_id;
    slot->code = info->code;
    slot->severity = info->severity;
    buffer_set_from_file(slot->buffer_set, sizeof(slot->buffer_set),
                         info->file_name, sizeof(info->file_name));
    copy_bounded(slot->buffer, sizeof(slot->buffer),
                 info->buffer_name, sizeof(info->buffer_name));
    copy_message(slot->message, sizeof(slot->message), info->data_size, payload);
    sh->count++;
    if (sh->wake_fd >= 0) {
        byte = 1;
        (void) flb_pipe_w(sh->wake_fd, &byte, 1);
    }
    pthread_mutex_unlock(&sh->lock);
    return 0;
}

static void *parse_thread(void *arg)
{
    struct flb_slog2_shared *sh = arg;
    slog2_packet_info_t info;
    uint32_t flags;
    char *match;
    int gone;

    memset(&info, 0, sizeof(info));
    info.size = sizeof(info);
    if (sh->poll_interval_ms > 0) {
        (void) slog2_parse_settings(SLOG2_PARSE_SETTINGS_NOTIFY_POLL_INTERVAL,
                                    (uint32_t) sh->poll_interval_ms);
    }
    flags = SLOG2_PARSE_FLAGS_DYNAMIC;
    if (sh->from_now) {
        flags |= SLOG2_PARSE_FLAGS_CURRENT;
    }
    match = sh->match_api[0] != '\0' ? sh->match_api : NULL;
    (void) slog2_parse_all(flags, NULL, match, &info, on_packet, sh);

    pthread_mutex_lock(&sh->lock);
    sh->thread_done = 1;
    gone = sh->plugin_gone;
    pthread_mutex_unlock(&sh->lock);
    if (gone) {
        pthread_mutex_destroy(&sh->lock);
        flb_free(sh);
    }
    return NULL;
}

static int encode_packet(struct flb_in_slog2 *ctx, const struct flb_slog2_packet *pkt)
{
    struct flb_time tm;
    char set_name[FLB_SLOG2_NAME_MAX];
    const char *severity;
    int ret;

    packet_wall_time(pkt->timestamp, pkt->flags, &tm);
    buffer_set_for_record(set_name, sizeof(set_name), pkt->buffer_set, ctx->match);
    severity = severity_name(pkt->severity);
    ret = flb_log_event_encoder_begin_record(ctx->encoder);
    if (ret != FLB_EVENT_ENCODER_SUCCESS) {
        return -1;
    }
    ret = flb_log_event_encoder_set_timestamp(ctx->encoder, &tm);
    if (ret != FLB_EVENT_ENCODER_SUCCESS) {
        return -1;
    }
    ret = flb_log_event_encoder_append_body_values(
        ctx->encoder,
        FLB_LOG_EVENT_CSTRING_VALUE("buffer_set"),
        FLB_LOG_EVENT_CSTRING_VALUE(set_name),
        FLB_LOG_EVENT_CSTRING_VALUE("buffer"),
        FLB_LOG_EVENT_CSTRING_VALUE(pkt->buffer),
        FLB_LOG_EVENT_CSTRING_VALUE("severity"),
        FLB_LOG_EVENT_CSTRING_VALUE(severity),
        FLB_LOG_EVENT_CSTRING_VALUE("severity_num"),
        FLB_LOG_EVENT_INT64_VALUE((int64_t) pkt->severity),
        FLB_LOG_EVENT_CSTRING_VALUE("pid"),
        FLB_LOG_EVENT_INT64_VALUE((int64_t) pkt->owner_pid),
        FLB_LOG_EVENT_CSTRING_VALUE("thread_id"),
        FLB_LOG_EVENT_INT64_VALUE((int64_t) pkt->thread_id),
        FLB_LOG_EVENT_CSTRING_VALUE("code"),
        FLB_LOG_EVENT_INT64_VALUE((int64_t) pkt->code),
        FLB_LOG_EVENT_CSTRING_VALUE("message"),
        FLB_LOG_EVENT_CSTRING_VALUE(pkt->message),
        FLB_LOG_EVENT_VALUE_LIST_TERMINATOR());
    if (ret != FLB_EVENT_ENCODER_SUCCESS) {
        return -1;
    }
    ret = flb_log_event_encoder_commit_record(ctx->encoder);
    if (ret != FLB_EVENT_ENCODER_SUCCESS) {
        return -1;
    }
    return 0;
}

static int in_slog2_collect(struct flb_input_instance *ins,
                            struct flb_config *config,
                            void *data)
{
    struct flb_in_slog2 *ctx = data;
    struct flb_slog2_shared *sh = ctx->shared;
    char junk[128];

    (void) config;
    if (sh == NULL) {
        return 0;
    }
    while (flb_pipe_r(ctx->pipe_r, junk, sizeof(junk)) > 0) {
    }

    for (;;) {
        struct flb_slog2_packet pkt;
        int have;

        pthread_mutex_lock(&sh->lock);
        have = 0;
        if (sh->count > 0) {
            pkt = sh->q[sh->head];
            sh->head = (sh->head + 1) % FLB_SLOG2_QUEUE_MAX;
            sh->count--;
            have = 1;
        }
        pthread_mutex_unlock(&sh->lock);
        if (!have) {
            break;
        }
        if (encode_packet(ctx, &pkt) != 0) {
            flb_log_event_encoder_reset(ctx->encoder);
            flb_plg_error(ctx->ins, "could not record slog2 packet");
            break;
        }
    }
    if (ctx->encoder->output_length > 0) {
        flb_input_log_append(ins, NULL, 0,
                             ctx->encoder->output_buffer,
                             ctx->encoder->output_length);
        flb_log_event_encoder_reset(ctx->encoder);
    }
    return 0;
}

static void shared_free(struct flb_slog2_shared *sh)
{
    if (sh == NULL) {
        return;
    }
    pthread_mutex_destroy(&sh->lock);
    flb_free(sh);
}

static void in_slog2_stop(struct flb_in_slog2 *ctx)
{
    struct flb_slog2_shared *sh = ctx->shared;
    int joined;

    if (ctx->coll_fd >= 0) {
        flb_input_collector_pause(ctx->coll_fd, ctx->ins);
        ctx->coll_fd = -1;
    }

    joined = 0;
    if (ctx->thread_started && sh != NULL) {
        struct timespec deadline;
        int jr;

        pthread_mutex_lock(&sh->lock);
        sh->stop = 1;
        pthread_mutex_unlock(&sh->lock);

        /*
         * Do not pthread_cancel the parse thread. slog2_parse_all is not a
         * cancellation point. Set the stop flag (the callback returns
         * non-zero once it runs), then join for 2 seconds. If the thread is
         * still blocked, detach only after the callback's shared state lives
         * in a block the thread itself frees on the way out. The plugin does
         * not free that block, and the callback does not use the pipe after
         * plugin_gone is set.
         */
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += 2;
        jr = pthread_timedjoin(ctx->thread, NULL, &deadline);
        if (jr == 0 || jr == ESRCH) {
            joined = 1;
        }
        else {
            int fd;
            int done;

            pthread_mutex_lock(&sh->lock);
            sh->stop = 1;
            sh->plugin_gone = 1;
            fd = sh->wake_fd;
            sh->wake_fd = -1;
            done = sh->thread_done;
            pthread_mutex_unlock(&sh->lock);
            if (fd >= 0) {
                flb_pipe_close(fd);
                if (ctx->pipe_w == fd) {
                    ctx->pipe_w = -1;
                }
            }
            if (done) {
                shared_free(sh);
            }
            else {
                pthread_detach(ctx->thread);
            }
            ctx->shared = NULL;
            ctx->thread_started = 0;
            sh = NULL;
        }
    }
    if (joined && sh != NULL) {
        shared_free(sh);
        ctx->shared = NULL;
        ctx->thread_started = 0;
    }
    else if (!ctx->thread_started && ctx->shared != NULL) {
        shared_free(ctx->shared);
        ctx->shared = NULL;
    }
    if (ctx->pipe_w >= 0) {
        flb_pipe_close(ctx->pipe_w);
        ctx->pipe_w = -1;
    }
    if (ctx->pipe_r >= 0) {
        flb_pipe_close(ctx->pipe_r);
        ctx->pipe_r = -1;
    }
}

static int init_fail(struct flb_in_slog2 *ctx)
{
    struct flb_input_instance *ins = ctx->ins;

    in_slog2_stop(ctx);
    if (ctx->encoder != NULL) {
        flb_log_event_encoder_destroy(ctx->encoder);
    }
    /* Init already published ctx. Drop it here so a later exit callback
     * does not free the same block. */
    flb_input_set_context(ins, NULL);
    flb_free(ctx);
    return -1;
}

static int in_slog2_init(struct flb_input_instance *ins,
                         struct flb_config *config,
                         void *data)
{
    struct flb_in_slog2 *ctx;
    struct flb_slog2_shared *sh;
    flb_pipefd_t fds[2];
    int ret;

    (void) data;
    ctx = flb_calloc(1, sizeof(*ctx));
    if (ctx == NULL) {
        flb_errno();
        return -1;
    }
    ctx->ins = ins;
    ctx->pipe_r = -1;
    ctx->pipe_w = -1;
    ctx->coll_fd = -1;
    flb_input_set_context(ins, ctx);

    ret = flb_input_config_map_set(ins, ctx);
    if (ret < 0) {
        return init_fail(ctx);
    }
    if (ctx->poll_interval_ms <= 0) {
        flb_plg_error(ins, "poll_interval_ms must be positive");
        return init_fail(ctx);
    }
    if (ctx->match != NULL && strlen(ctx->match) >= FLB_SLOG2_MATCH_MAX) {
        flb_plg_error(ins, "match is too long");
        return init_fail(ctx);
    }

    ctx->encoder = flb_log_event_encoder_create(FLB_LOG_EVENT_FORMAT_DEFAULT);
    if (ctx->encoder == NULL) {
        flb_plg_error(ins, "cannot create event encoder");
        return init_fail(ctx);
    }
    if (flb_pipe_create(fds) != 0) {
        flb_plg_error(ins, "cannot create notification pipe");
        return init_fail(ctx);
    }
    ctx->pipe_r = fds[0];
    ctx->pipe_w = fds[1];
    if (flb_pipe_set_nonblocking(ctx->pipe_r) != 0 ||
        flb_pipe_set_nonblocking(ctx->pipe_w) != 0) {
        flb_plg_error(ins, "cannot set notification pipe nonblocking");
        return init_fail(ctx);
    }

    sh = flb_calloc(1, sizeof(*sh));
    if (sh == NULL) {
        flb_errno();
        return init_fail(ctx);
    }
    if (pthread_mutex_init(&sh->lock, NULL) != 0) {
        flb_free(sh);
        flb_plg_error(ins, "cannot create slog2 lock");
        return init_fail(ctx);
    }
    sh->wake_fd = ctx->pipe_w;
    sh->from_now = ctx->from_now ? 1 : 0;
    sh->poll_interval_ms = ctx->poll_interval_ms;
    sanitize_match_list(sh->match_api, sizeof(sh->match_api), ctx->match);
    ctx->shared = sh;

    ret = pthread_create(&ctx->thread, NULL, parse_thread, sh);
    if (ret != 0) {
        flb_plg_error(ins, "cannot start slog2 parse thread");
        return init_fail(ctx);
    }
    ctx->thread_started = 1;

    ret = flb_input_set_collector_event(ins, in_slog2_collect, ctx->pipe_r, config);
    if (ret < 0) {
        flb_plg_error(ins, "cannot set collector");
        return init_fail(ctx);
    }
    ctx->coll_fd = ret;
    return 0;
}

static void in_slog2_pause(void *data, struct flb_config *config)
{
    struct flb_in_slog2 *ctx = data;

    (void) config;
    flb_input_collector_pause(ctx->coll_fd, ctx->ins);
}

static void in_slog2_resume(void *data, struct flb_config *config)
{
    struct flb_in_slog2 *ctx = data;

    (void) config;
    flb_input_collector_resume(ctx->coll_fd, ctx->ins);
}

static int in_slog2_exit(void *data, struct flb_config *config)
{
    struct flb_in_slog2 *ctx = data;

    (void) config;
    if (ctx == NULL) {
        return 0;
    }
    in_slog2_stop(ctx);
    if (ctx->encoder != NULL) {
        flb_log_event_encoder_destroy(ctx->encoder);
    }
    flb_free(ctx);
    return 0;
}

static struct flb_config_map config_map[] = {
    {
        FLB_CONFIG_MAP_STR, "match", NULL,
        0, FLB_TRUE, offsetof(struct flb_in_slog2, match),
        "Comma-separated slog2 buffer-set names to read. Empty reads all of them."
    },
    {
        FLB_CONFIG_MAP_BOOL, "from_now", "true",
        0, FLB_TRUE, offsetof(struct flb_in_slog2, from_now),
        "Read packets logged after this input starts"
    },
    {
        FLB_CONFIG_MAP_INT, "poll_interval_ms", "100",
        0, FLB_TRUE, offsetof(struct flb_in_slog2, poll_interval_ms),
        "Milliseconds between slog2 live-parse polls"
    },
    {0}
};

struct flb_input_plugin in_slog2_plugin = {
    .name         = "slog2",
    .description  = "QNX system log (slog2)",
    .cb_init      = in_slog2_init,
    .cb_pre_run   = NULL,
    .cb_collect   = in_slog2_collect,
    .cb_flush_buf = NULL,
    .config_map   = config_map,
    .cb_pause     = in_slog2_pause,
    .cb_resume    = in_slog2_resume,
    .cb_exit      = in_slog2_exit
};
