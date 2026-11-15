# slog2 stop cleanup validation

Date: 2026-11-15. Target: QNX 8.0 x86_64 on QEMU.

## Lifecycle regression

`bash tests/test_slog2_stop.sh` passed. It compiles the production plugin source
into a standalone test using the real plugin's QNX compiler settings. Assertions
are enabled even though the production build uses `NDEBUG`.

The test uses real QNX threads, mutexes and pipes. Only the parser's blocking
behavior and the timed-join outcome are controlled. Each of these cases runs 32
times in one process:

- A normal successful join.
- The join times out, but the worker finishes before shutdown checks its flag.
- The worker stays blocked until after shutdown has returned.
- Initialization fails before a worker is started.

All 128 cases passed. The test checks exactly-once freeing of the queue and control
block, immediate queue release even with a blocked worker, thread detachment in
both timeout paths, closed notification pipes, safe late callbacks, and repeat stop.

A temporary negative-control copy restored the old missing-detach branch. The
test failed on its detach assertion as expected. That copy was not shipped.

## Scope

The rebuilt program also passed `bash tests/test_slog2.sh` with the real parser:

```text
slog2_lines_arrive_with_severity ok
slog2_from_now_skips_history ok
slog2_match_filters_buffer_sets ok
slog2_shutdown_is_clean ok
```

The integration script returned zero. The compiled plugin source matched the
working source (SHA-256
`ea3e3d2d82f311c4f4570c7f8b4a8d15a9d00b8960e5b65fab14af8a041f62d8`).
The tests stop only emitter processes they started, using their recorded IDs.

This verifies the plugin's ownership and cleanup, not the internals of QNX's parser.
A parser that never returns can still retain its thread and library-owned state.
Its large packet queue is now released when the input stops. See the
[remaining limits](porting-notes.md#slog2-buffering-and-shutdown-limits).

The earlier [full-suite log](test-log.txt) remains the dated baseline described in
[how it was built](how-it-was-built.md). It is not a fresh full-suite run of this fix.
