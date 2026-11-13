#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/slog2.h>

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
    (void) sig;
    g_stop = 1;
}

static int write_text(const char *path, const char *text)
{
    int fd;
    size_t n;
    ssize_t wrote;

    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return -1;
    }
    n = strlen(text);
    wrote = write(fd, text, n);
    if (wrote < 0 || (size_t) wrote != n || write(fd, "\n", 1) != 1) {
        close(fd);
        return -1;
    }
    if (close(fd) != 0) {
        return -1;
    }
    return 0;
}

static const uint8_t sev_cycle[3] = {
    SLOG2_INFO,
    SLOG2_WARNING,
    SLOG2_ERROR
};

static int emit_numbered(slog2_buffer_t buffer, const char *prefix, int count)
{
    int i;

    if (prefix == NULL || prefix[0] == '\0' || strlen(prefix) > 32) {
        return -1;
    }
    if (count < 1 || count > 10000) {
        return -1;
    }
    for (i = 1; i <= count; i++) {
        char msg[64];
        int n;

        n = snprintf(msg, sizeof(msg), "%s-%02d", prefix, i);
        if (n < 0 || n >= (int) sizeof(msg)) {
            return -1;
        }
        if (slog2c(buffer, (uint16_t) i, sev_cycle[(i - 1) % 3], msg) != 0) {
            return -1;
        }
    }
    return 0;
}

static int take_command(const char *ctl, const char *done, char *dst, size_t dst_len)
{
    int fd;
    ssize_t n;

    if (dst_len == 0) {
        return 0;
    }
    dst[0] = '\0';
    (void) unlink(done);
    if (rename(ctl, done) != 0) {
        return 0;
    }
    fd = open(done, O_RDONLY);
    if (fd < 0) {
        (void) unlink(done);
        return 0;
    }
    n = read(fd, dst, dst_len - 1);
    close(fd);
    (void) unlink(done);
    if (n <= 0) {
        dst[0] = '\0';
        return 0;
    }
    dst[n] = '\0';
    if (dst[n - 1] == '\n') {
        dst[--n] = '\0';
    }
    if (n > 0 && dst[n - 1] == '\r') {
        dst[--n] = '\0';
    }
    return dst[0] != '\0';
}

static void run_loop(slog2_buffer_t buffer, const char *ctl, const char *done,
                     const char *ack)
{
    unsigned n;

    if (write_text(ack, "loop") != 0) {
        return;
    }
    n = 1;
    while (!g_stop) {
        char msg[64];
        char line[128];
        int wrote;

        wrote = snprintf(msg, sizeof(msg), "loop-%04u", n);
        if (wrote > 0 && wrote < (int) sizeof(msg)) {
            (void) slog2c(buffer, 0, sev_cycle[(n - 1) % 3], msg);
        }
        n++;
        if (n == 0) {
            n = 1;
        }
        if (take_command(ctl, done, line, sizeof(line)) &&
            strcmp(line, "quit") == 0) {
            g_stop = 1;
            break;
        }
        usleep(50000);
    }
}

static const char *need(int argc, char **argv, int *index)
{
    if (*index + 1 >= argc) {
        fprintf(stderr, "missing value for %s\n", argv[*index]);
        return NULL;
    }
    *index += 1;
    return argv[*index];
}

int main(int argc, char **argv)
{
    const char *set_name = NULL;
    const char *ctl = NULL;
    const char *ready = NULL;
    const char *ack = NULL;
    char done[512];
    slog2_buffer_set_config_t cfg;
    slog2_buffer_t handle;
    int i;

    for (i = 1; i < argc; i++) {
        const char *arg = argv[i];
        const char *val;

        if (strcmp(arg, "--set") == 0) {
            val = need(argc, argv, &i);
            if (val == NULL) {
                return 2;
            }
            set_name = val;
        }
        else if (strcmp(arg, "--ctl") == 0) {
            val = need(argc, argv, &i);
            if (val == NULL) {
                return 2;
            }
            ctl = val;
        }
        else if (strcmp(arg, "--ready") == 0) {
            val = need(argc, argv, &i);
            if (val == NULL) {
                return 2;
            }
            ready = val;
        }
        else if (strcmp(arg, "--ack") == 0) {
            val = need(argc, argv, &i);
            if (val == NULL) {
                return 2;
            }
            ack = val;
        }
        else {
            fprintf(stderr, "unknown argument %s\n", arg);
            return 2;
        }
    }
    if (set_name == NULL || ctl == NULL || ready == NULL || ack == NULL) {
        fprintf(stderr, "usage: slog2_emit --set NAME --ctl PATH --ready PATH --ack PATH\n");
        return 2;
    }
    if (strlen(ctl) + strlen(".done") >= sizeof(done)) {
        fprintf(stderr, "control path is too long\n");
        return 2;
    }
    snprintf(done, sizeof(done), "%s.done", ctl);

    (void) signal(SIGTERM, on_signal);
    (void) signal(SIGINT, on_signal);

    memset(&cfg, 0, sizeof(cfg));
    cfg.num_buffers = 1;
    cfg.buffer_set_name = set_name;
    cfg.verbosity_level = SLOG2_DEBUG2;
    cfg.buffer_config[0].buffer_name = "main";
    cfg.buffer_config[0].num_pages = 8;
    if (slog2_register(&cfg, &handle, 0) != 0) {
        (void) write_text(ready, "fail");
        fprintf(stderr, "slog2_register failed\n");
        return 1;
    }
    if (write_text(ready, "ok") != 0) {
        fprintf(stderr, "could not write ready file\n");
        return 1;
    }

    while (!g_stop) {
        char line[128];
        char prefix[32];
        int count;

        if (!take_command(ctl, done, line, sizeof(line))) {
            usleep(50000);
            continue;
        }
        if (strcmp(line, "quit") == 0) {
            break;
        }
        if (strcmp(line, "loop") == 0) {
            run_loop(handle, ctl, done, ack);
            break;
        }
        count = 0;
        prefix[0] = '\0';
        if (sscanf(line, "log %31s %d", prefix, &count) == 2 &&
            emit_numbered(handle, prefix, count) == 0) {
            (void) write_text(ack, line);
            continue;
        }
        fprintf(stderr, "ignored command\n");
    }
    return 0;
}
