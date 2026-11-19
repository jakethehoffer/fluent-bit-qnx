# How this port was built

Jake Hoffman directed AI coding agents. That is the whole authorship story. The commits are his, as Jake Hoffman `<122403457+jakethehoffer@users.noreply.github.com>`. This file is the public record of what the spike showed and what landed after it. It does not add a result the tests, the patches, or those notes do not already support.

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

Authorship correction (2026-11-14): the implementation sessions ran through Cursor.
The `Co-Authored-By: Claude Opus 5.5` trailers were prescribed by the implementation
plan and copied into the commits. They are not a verified record of the model that
did that work. The build, delivery, and qnx_proc commits also carry a Cursor trailer.
The historical commits are preserved rather than rewritten. Jake directed the work.

Those commits are what turned the spike into this tree:

- [`patches/`](../patches/) is the series, including the NUL fix in [`0010`](../patches/0010-in_tail-resolve-the-file-name-with-iofdinfo-on-QNX.patch). [`tools/check-patches.sh`](../tools/check-patches.sh) rejects a NUL byte.
- [`forward_delivers_every_tail_line`](../tests/test_outputs.sh) is the later check that every tail line arrives once. The spike's capture was missing one.
- [`two_workers_shutdown_clean`](../tests/test_outputs.sh) is the on-machine two-worker check. The receiver is [`tests/receiver.py`](../tests/receiver.py), which is multi-threaded. The spike had only done that shape of check on Linux.
- [`loki_push_received`](../tests/test_outputs.sh) and [`tools/demo-check.sh`](../tools/demo-check.sh) run the Loki output the spike did not run.
- [`plugins/in_qnx_proc`](../plugins/in_qnx_proc/in_qnx_proc.c) and [`plugins/in_slog2`](../plugins/in_slog2/in_slog2.c) are the inputs the spike only sketched from headers.
- [`qnx/fluent-bit.conf`](../qnx/fluent-bit.conf) and the start/stop scripts are the priority-8 service.
- [`docs/images/dashboard.png`](images/dashboard.png) is the demo picture.

## After the demo

A review on 2026-11-14 found claims that went further than the tests and some
small faults in the two QNX inputs. Jake directed two more agents to work
through them, each checked on the QNX machine before it was pushed:

- OpenAI Codex aligned the public claims with the test evidence (`1732947`) and
  made stopping the slog2 input release its packet queue and reclaim a finished
  parser thread (`8fb7783`, see [slog2-stop-validation.md](slog2-stop-validation.md)).
- Claude (Anthropic) fixed three collect faults on 2026-11-15: one bad record no
  longer drops the whole batch, a batch Fluent Bit refuses is now reported, and
  the `qnx_proc` warning list no longer fills up. See
  [record and hand-off errors](porting-notes.md#record-and-hand-off-errors).

[`docs/test-log.txt`](test-log.txt) is the latest full check: patch check, clean build, every on-machine test, and the demo check.

The full run completed on 2026-11-15 against the source committed with this
paragraph (the commit that adds `tests/test_collect_faults.sh`). The patch check,
clean build, all 20 target tests, and the demo check passed with an overall exit
status of zero. The 20 include the slog2 stop check and the two collect fault checks.
An earlier run that day failed `proc_survives_short_lived_processes` on an `EAGAIN`
warning, which led to the `EAGAIN` change in the porting notes, and another ran out
of space on the target's small data disk after deliberate test crashes left core
files. Those core files were removed before the recorded run.
These results cover the named scenarios, not every failure path or the open gaps below.

## Still open

A live process-name list and a colored NOTICE line are still open. Saved chunks coming back after a restart now have a test (`agent_keeps_saved_records_across_restart`). So are aarch64, TLS to a real endpoint, tail `db=`, rotation, and unix-socket peer pid. The engineering notes are [porting-notes.md](porting-notes.md). No upstream pull request is open. [fluent/fluent-bit#8757](https://github.com/fluent/fluent-bit/issues/8757) is the stale request.
