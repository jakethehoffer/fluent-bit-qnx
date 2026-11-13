#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/slog2.h>

/* slog2 buffer set leaky_sensor.
 * One INFO reading each second. After --leak-after N seconds, every second
 * allocation step takes another 8 MiB, touches it, and logs WARNING then ERROR
 * about that buffer. The figures are this program's own buffer.
 */

#define CHUNK_BYTES (8u * 1024u * 1024u)
#define CHUNK_CAP 24u

static volatile sig_atomic_t g_stop;
static unsigned char *g_blocks[CHUNK_CAP];
static unsigned g_nblocks;

static void on_signal(int sig)
{
    (void) sig;
    g_stop = 1;
}

static int parse_u(const char *text, unsigned *out)
{
    const char *p;
    unsigned long value;

    if (text == NULL || text[0] == '\0') {
        return -1;
    }
    for (p = text; *p != '\0'; p++) {
        if (*p < '0' || *p > '9') {
            return -1;
        }
    }
    errno = 0;
    value = strtoul(text, NULL, 10);
    if (errno != 0 || value > 1000000ul) {
        return -1;
    }
    *out = (unsigned) value;
    return 0;
}

static int log_line(slog2_buffer_t buffer, uint8_t severity, const char *msg)
{
    if (slog2c(buffer, 0, severity, msg) != 0) {
        fprintf(stderr, "slog2c failed\n");
        return -1;
    }
    return 0;
}

/* 1 grew, 0 already at the cap, -1 allocation failed. */
static int grow(void)
{
    unsigned char *buf;
    size_t i;

    if (g_nblocks >= CHUNK_CAP) {
        return 0;
    }
    buf = malloc(CHUNK_BYTES);
    if (buf == NULL) {
        return -1;
    }
    for (i = 0; i < CHUNK_BYTES; i += 4096) {
        buf[i] = 1;
    }
    buf[CHUNK_BYTES - 1] = 1;
    g_blocks[g_nblocks] = buf;
    g_nblocks++;
    return 1;
}

static int register_set(slog2_buffer_t *handle)
{
    slog2_buffer_set_config_t cfg;

    memset(&cfg, 0, sizeof(cfg));
    cfg.num_buffers = 1;
    cfg.buffer_set_name = "leaky_sensor";
    cfg.verbosity_level = SLOG2_DEBUG2;
    cfg.buffer_config[0].buffer_name = "main";
    cfg.buffer_config[0].num_pages = 32;
    if (slog2_register(&cfg, handle, 0) != 0) {
        fprintf(stderr, "slog2_register failed\n");
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    unsigned leak_after = 0;
    unsigned seconds = 0;
    int have_after = 0;
    slog2_buffer_t handle = NULL;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--leak-after") == 0) {
            if (i + 1 >= argc || parse_u(argv[i + 1], &leak_after) != 0) {
                fprintf(stderr, "usage: leaky_sensor --leak-after N\n");
                return 2;
            }
            have_after = 1;
            i++;
        }
        else {
            fprintf(stderr, "usage: leaky_sensor --leak-after N\n");
            return 2;
        }
    }
    if (!have_after) {
        fprintf(stderr, "usage: leaky_sensor --leak-after N\n");
        return 2;
    }

    (void) signal(SIGTERM, on_signal);
    (void) signal(SIGINT, on_signal);

    if (register_set(&handle) != 0) {
        return 1;
    }

    while (!g_stop) {
        char msg[96];
        int wrote;
        int grew;

        wrote = snprintf(msg, sizeof(msg), "reading buffer_mib=%u", g_nblocks * 8u);
        if (wrote < 0 || (size_t) wrote >= sizeof(msg) ||
            log_line(handle, SLOG2_INFO, msg) != 0) {
            return 1;
        }
        if (seconds >= leak_after && ((seconds - leak_after) % 2u) == 0u) {
            grew = grow();
            if (grew < 0) {
                fprintf(stderr, "allocation failed\n");
                return 1;
            }
            if (grew > 0) {
                wrote = snprintf(msg, sizeof(msg), "buffer grew buffer_mib=%u",
                                 g_nblocks * 8u);
                if (wrote < 0 || (size_t) wrote >= sizeof(msg)) {
                    return 1;
                }
                if (log_line(handle, SLOG2_WARNING, msg) != 0 ||
                    log_line(handle, SLOG2_ERROR, msg) != 0) {
                    return 1;
                }
            }
        }
        if (sleep(1) != 0 && g_stop) {
            break;
        }
        if (seconds < 1000000u) {
            seconds++;
        }
    }
    return 0;
}
