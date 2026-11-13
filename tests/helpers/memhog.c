#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Allocate and touch N mebibytes, then sleep until stopped. */
int main(int argc, char **argv)
{
    long mib;
    size_t bytes;
    unsigned char *buf;
    size_t i;

    mib = (argc > 1) ? atol(argv[1]) : 64;
    if (mib < 1) {
        return 1;
    }
    bytes = (size_t) mib * 1024 * 1024;
    buf = malloc(bytes);
    if (!buf) {
        return 1;
    }
    for (i = 0; i < bytes; i += 4096) {
        buf[i] = 1;
    }
    buf[bytes - 1] = 1;
    for (;;) {
        sleep(60);
    }
}
