#include <dirent.h>
#include <devctl.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/neutrino.h>
#include <sys/procfs.h>

#include <fluent-bit/flb_input_plugin.h>
#include <fluent-bit/flb_log_event_encoder.h>
#include <fluent-bit/flb_time.h>

#include "in_qnx_proc.h"

static int is_digits(const char *s)
{
    if (*s == '\0') {
        return 0;
    }
    for (; *s; s++) {
        if (*s < '0' || *s > '9') {
            return 0;
        }
    }
    return 1;
}

static const char *base_name(const char *path)
{
    const char *slash;

    slash = strrchr(path, '/');
    if (slash != NULL && slash[1] != '\0') {
        return slash + 1;
    }
    return path;
}

static void copy_base_name(char *dst, size_t dst_len, const char *src)
{
    const char *base;
    size_t n;

    if (dst_len == 0) {
        return;
    }
    base = base_name(src);
    n = strlen(base);
    if (n >= dst_len) {
        n = dst_len - 1;
    }
    if (base != dst) {
        memmove(dst, base, n);
    }
    dst[n] = '\0';
}

static int ignored_errno(int err)
{
    return err == ENOENT || err == ESRCH || err == EPERM || err == EACCES;
}

static void warn_once(struct flb_in_qnx_proc *ctx, pid_t pid, int err)
{
    int i;

    for (i = 0; i < ctx->warned_n; i++) {
        if (ctx->warned[i] == pid) {
            return;
        }
    }
    if (ctx->warned_n < FLB_QNX_PROC_WARNED_MAX) {
        ctx->warned[ctx->warned_n++] = pid;
    }
    flb_plg_warn(ctx->ins, "pid %ld: %s", (long) pid, strerror(err));
}

static int devctl_err(int ret)
{
    if (ret == -1) {
        return errno;
    }
    return ret;
}

static int read_exefile(pid_t pid, char *dst, size_t dst_len)
{
    char path[64];
    int fd;
    ssize_t n;

    snprintf(path, sizeof(path), "/proc/%ld/exefile", (long) pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    n = read(fd, dst, dst_len - 1);
    close(fd);
    if (n <= 0) {
        return -1;
    }
    dst[n] = '\0';
    if (dst[n - 1] == '\n') {
        dst[n - 1] = '\0';
    }
    return 0;
}

static int process_name(int fd, pid_t pid, char *dst, size_t dst_len)
{
    char raw[sizeof(procfs_debuginfo) + 512];
    procfs_debuginfo *info;
    int ret;

    memset(raw, 0, sizeof(raw));
    info = (procfs_debuginfo *) raw;
    ret = devctl(fd, DCMD_PROC_MAPDEBUG_BASE, info, sizeof(raw), NULL);
    if (ret == EOK && info->path[0] != '\0') {
        raw[sizeof(raw) - 1] = '\0';
        copy_base_name(dst, dst_len, info->path);
        return 0;
    }
    if (read_exefile(pid, dst, dst_len) == 0 && dst[0] != '\0') {
        copy_base_name(dst, dst_len, dst);
        return 0;
    }
    return -1;
}

static int emit_one(struct flb_in_qnx_proc *ctx, pid_t pid)
{
    char ctl[64];
    char name[256];
    int fd;
    int ret;
    int err;
    procfs_info info;
    uint64_t cpu;
    struct flb_time tm;

    if (!ctx->include_self && pid == getpid()) {
        return 0;
    }

    snprintf(ctl, sizeof(ctl), "/proc/%ld/ctl", (long) pid);
    fd = open(ctl, O_RDONLY);
    if (fd < 0 && errno == ENOENT) {
        snprintf(ctl, sizeof(ctl), "/proc/%ld/as", (long) pid);
        fd = open(ctl, O_RDONLY);
    }
    if (fd < 0) {
        err = errno;
        if (!ignored_errno(err)) {
            warn_once(ctx, pid, err);
        }
        return 0;
    }

    memset(&info, 0, sizeof(info));
    ret = devctl(fd, DCMD_PROC_INFO, &info, sizeof(info), NULL);
    if (ret != EOK) {
        err = devctl_err(ret);
        close(fd);
        if (!ignored_errno(err)) {
            warn_once(ctx, pid, err);
        }
        return 0;
    }

    if (process_name(fd, pid, name, sizeof(name)) != 0) {
        snprintf(name, sizeof(name), "%ld", (long) pid);
    }
    close(fd);

    if (ctx->have_re && regexec(&ctx->re, name, 0, NULL, 0) != 0) {
        return 0;
    }

    cpu = info.utime + info.stime;
    flb_time_get(&tm);
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
        FLB_LOG_EVENT_CSTRING_VALUE("pid"),
        FLB_LOG_EVENT_INT64_VALUE((int64_t) info.pid),
        FLB_LOG_EVENT_CSTRING_VALUE("name"),
        FLB_LOG_EVENT_CSTRING_VALUE(name),
        FLB_LOG_EVENT_CSTRING_VALUE("threads"),
        FLB_LOG_EVENT_INT64_VALUE((int64_t) info.num_threads),
        FLB_LOG_EVENT_CSTRING_VALUE("cpu_ns"),
        FLB_LOG_EVENT_UINT64_VALUE(cpu),
        FLB_LOG_EVENT_CSTRING_VALUE("cpu_user_ns"),
        FLB_LOG_EVENT_UINT64_VALUE(info.utime),
        FLB_LOG_EVENT_CSTRING_VALUE("cpu_system_ns"),
        FLB_LOG_EVENT_UINT64_VALUE(info.stime),
        FLB_LOG_EVENT_CSTRING_VALUE("mem_private_bytes"),
        FLB_LOG_EVENT_UINT64_VALUE(info.private_mem),
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

static int in_qnx_proc_collect(struct flb_input_instance *ins,
                               struct flb_config *config,
                               void *data)
{
    struct flb_in_qnx_proc *ctx = data;
    DIR *dir;
    struct dirent *ent;
    pid_t pid;
    int ret;

    (void) config;
    dir = opendir("/proc");
    if (!dir) {
        flb_plg_error(ctx->ins, "cannot open /proc: %s", strerror(errno));
        return -1;
    }
    while ((ent = readdir(dir)) != NULL) {
        if (!is_digits(ent->d_name)) {
            continue;
        }
        pid = (pid_t) atol(ent->d_name);
        ret = emit_one(ctx, pid);
        if (ret != 0) {
            flb_log_event_encoder_reset(ctx->encoder);
            flb_plg_error(ctx->ins, "could not record pid %ld", (long) pid);
            closedir(dir);
            return 0;
        }
    }
    closedir(dir);

    if (ctx->encoder->output_length > 0) {
        flb_input_log_append(ins, NULL, 0,
                             ctx->encoder->output_buffer,
                             ctx->encoder->output_length);
        flb_log_event_encoder_reset(ctx->encoder);
    }
    return 0;
}

/* Init already published ctx. Clear it before freeing so a later exit
 * callback does not free the same block or regfree the same expression. */
static int init_fail(struct flb_in_qnx_proc *ctx)
{
    struct flb_input_instance *ins;

    ins = ctx->ins;
    flb_input_set_context(ins, NULL);
    if (ctx->encoder != NULL) {
        flb_log_event_encoder_destroy(ctx->encoder);
        ctx->encoder = NULL;
    }
    if (ctx->have_re) {
        regfree(&ctx->re);
        ctx->have_re = 0;
    }
    flb_free(ctx);
    return -1;
}

static int in_qnx_proc_init(struct flb_input_instance *ins,
                            struct flb_config *config,
                            void *data)
{
    struct flb_in_qnx_proc *ctx;
    int ret;

    (void) data;
    ctx = flb_calloc(1, sizeof(struct flb_in_qnx_proc));
    if (!ctx) {
        flb_errno();
        return -1;
    }
    ctx->ins = ins;
    flb_input_set_context(ins, ctx);

    ret = flb_input_config_map_set(ins, ctx);
    if (ret < 0) {
        return init_fail(ctx);
    }
    if (ctx->interval_sec == 0 && ctx->interval_nsec == 0) {
        ctx->interval_sec = 1;
    }
    if (ctx->match != NULL && ctx->match[0] != '\0') {
        if (regcomp(&ctx->re, ctx->match, REG_EXTENDED | REG_NOSUB) != 0) {
            flb_plg_error(ins, "match is not a valid regular expression");
            return init_fail(ctx);
        }
        ctx->have_re = 1;
    }

    ctx->encoder = flb_log_event_encoder_create(FLB_LOG_EVENT_FORMAT_DEFAULT);
    if (!ctx->encoder) {
        flb_plg_error(ins, "cannot create event encoder");
        return init_fail(ctx);
    }
    ret = flb_input_set_collector_time(ins, in_qnx_proc_collect,
                                       ctx->interval_sec, ctx->interval_nsec,
                                       config);
    if (ret < 0) {
        flb_plg_error(ins, "cannot set collector");
        return init_fail(ctx);
    }
    ctx->coll_fd = ret;
    return 0;
}

static void in_qnx_proc_pause(void *data, struct flb_config *config)
{
    struct flb_in_qnx_proc *ctx = data;

    (void) config;
    flb_input_collector_pause(ctx->coll_fd, ctx->ins);
}

static void in_qnx_proc_resume(void *data, struct flb_config *config)
{
    struct flb_in_qnx_proc *ctx = data;

    (void) config;
    flb_input_collector_resume(ctx->coll_fd, ctx->ins);
}

static int in_qnx_proc_exit(void *data, struct flb_config *config)
{
    struct flb_in_qnx_proc *ctx = data;

    (void) config;
    if (ctx == NULL) {
        return 0;
    }
    if (ctx->have_re) {
        regfree(&ctx->re);
    }
    if (ctx->encoder) {
        flb_log_event_encoder_destroy(ctx->encoder);
    }
    flb_free(ctx);
    return 0;
}

static struct flb_config_map config_map[] = {
    {
        FLB_CONFIG_MAP_INT, "interval_sec", "5",
        0, FLB_TRUE, offsetof(struct flb_in_qnx_proc, interval_sec),
        "Seconds between process scans"
    },
    {
        FLB_CONFIG_MAP_INT, "interval_nsec", "0",
        0, FLB_TRUE, offsetof(struct flb_in_qnx_proc, interval_nsec),
        "Extra nanoseconds between process scans"
    },
    {
        FLB_CONFIG_MAP_STR, "match", NULL,
        0, FLB_TRUE, offsetof(struct flb_in_qnx_proc, match),
        "POSIX extended regular expression applied to the process name"
    },
    {
        FLB_CONFIG_MAP_BOOL, "include_self", "false",
        0, FLB_TRUE, offsetof(struct flb_in_qnx_proc, include_self),
        "Also report this process"
    },
    {0}
};

struct flb_input_plugin in_qnx_proc_plugin = {
    .name         = "qnx_proc",
    .description  = "QNX per-process CPU time and private memory",
    .cb_init      = in_qnx_proc_init,
    .cb_pre_run   = NULL,
    .cb_collect   = in_qnx_proc_collect,
    .cb_flush_buf = NULL,
    .config_map   = config_map,
    .cb_pause     = in_qnx_proc_pause,
    .cb_resume    = in_qnx_proc_resume,
    .cb_exit      = in_qnx_proc_exit
};
