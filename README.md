# fluent-bit-qnx

Fluent Bit 5.2.0 for QNX 8.0 (x86_64): a small patch series that makes upstream Fluent Bit
build and run on QNX, plus a reproducible cross-build from WSL or Linux with the QNX SDP.
QNX-native inputs for slog2 and per-process stats follow in later commits. Upstream source
is never copied here; `UPSTREAM` pins the release tarball and its SHA-256.

Quick start (needs the QNX SDP 8.0 in `~/qnx800`, cmake, ninja, and a QNX 8.0 x86_64 QEMU target):

    tools/check-patches.sh     # patches apply to a pristine tarball, no NUL or CRLF, signed off
    tools/build.sh             # download, verify, patch, configure, ninja -j4
    tools/smoke.sh             # boot the target, deploy, run a dummy to stdout, expect smoke ok

See `docs/porting-notes.md` for every patch and CMake option. Apache-2.0, see `LICENSE` and `NOTICE`.
