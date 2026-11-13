# How this port was built

Jake Hoffman directed an AI coding agent. That is the whole authorship story. The commits are his, as Jake Hoffman `<122403457+jakethehoffer@users.noreply.github.com>`. This file is the public record of what the spike showed and what landed after it. It does not add a result the tests, the patches, or those notes do not already support.

## The spike

On 2026-11-12 a feasibility spike tried Fluent Bit 5.2.0 on QNX SDP 8.0 x86_64. It was local research. Nothing from it was pushed, posted, or opened upstream.

The spike's conclusion was that the release cross-compiles and runs once a small patch set is applied. The patched tree delivered `dummy` and `tail` records to a host with `out_http`. An `out_forward` capture from that same effort contained two of three tail lines. `out_loki` was compiled and not run. The event loop was set to `poll` because the SDP headers that were checked have `poll.h` and do not have epoll, kqueue, timerfd, eventfd, or signalfd.

The spike's patch file had a literal NUL byte in the tail `iofdinfo` change, so it could not be reused as a real patch. Two output workers looked stuck in a Linux run of the same poll backend. That run used a single-threaded receiver. A short Linux retry with a threaded receiver finished with no pending tasks. The QNX target was down for that retry, so the spike left the on-machine two-worker case open.

The spike did not show TLS to a real endpoint, tail `db=`, rotation, filesystem storage after a process restart, a saved metrics response, or an aarch64 build. The slog2 and procfs sections were header and documentation notes, not plugins.

## What landed

The commits through the demo, oldest first. The table stops at the demo commit.

| Commit | Subject |
| --- | --- |
| `3a11c95` | Initial commit |
| `713ab6b` | Make Fluent Bit 5.2.0 build and run on QNX 8.0. |
| `95f82a7` | Prove every sent record arrives once on the QNX machine. |
| `f1afb61` | Report every running program from Fluent Bit on QNX. |
| `5b7605f` | Read QNX system-log lines from Fluent Bit. |
| `9a915ba` | Run Fluent Bit as a quiet priority-8 service on QNX. |
| `0cde2a6` | Add a live dashboard demo for the QNX agent. |

Every commit after the initial one carries `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. The build, delivery, and qnx_proc commits also carry `Co-authored-by: Cursor <cursoragent@cursor.com>`.

Those commits are what turned the spike into this tree:

- [`patches/`](../patches/) is the series, including the NUL fix in [`0010`](../patches/0010-in_tail-resolve-the-file-name-with-iofdinfo-on-QNX.patch). [`tools/check-patches.sh`](../tools/check-patches.sh) rejects a NUL byte.
- [`forward_delivers_every_tail_line`](../tests/test_outputs.sh) is the later check that every tail line arrives once. The spike's capture was missing one.
- [`two_workers_shutdown_clean`](../tests/test_outputs.sh) is the on-machine two-worker check. The receiver is [`tests/receiver.py`](../tests/receiver.py), which is multi-threaded. The spike had only done that shape of check on Linux.
- [`loki_push_received`](../tests/test_outputs.sh) and [`tools/demo-check.sh`](../tools/demo-check.sh) run the Loki output the spike did not run.
- [`plugins/in_qnx_proc`](../plugins/in_qnx_proc/in_qnx_proc.c) and [`plugins/in_slog2`](../plugins/in_slog2/in_slog2.c) are the inputs the spike only sketched from headers.
- [`qnx/fluent-bit.conf`](../qnx/fluent-bit.conf) and the start/stop scripts are the priority-8 service.
- [`docs/images/dashboard.png`](images/dashboard.png) is the demo picture.

[`docs/test-log.txt`](test-log.txt) is the latest full check: patch check, clean build, every on-machine test, and the demo check.

## Still open

A live process-name list, a colored NOTICE line, and saved chunks coming back after a restart are still open. So are aarch64, TLS to a real endpoint, tail `db=`, rotation, and unix-socket peer pid. The engineering notes are [porting-notes.md](porting-notes.md). No upstream pull request is open. [fluent/fluent-bit#8757](https://github.com/fluent/fluent-bit/issues/8757) is the stale request.
