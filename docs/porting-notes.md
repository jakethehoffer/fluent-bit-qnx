# Porting notes: Fluent Bit 5.2.0 on QNX 8.0

Target: QNX SDP 8.0, x86_64, cross-built from WSL/Linux with `qcc`. aarch64 is not built or
tested yet. Everything here was checked against the SDP 8.0 headers and on the QEMU target.

Upstream is pinned in `UPSTREAM` (version, URL, SHA-256, tag commit). `tools/build.sh` downloads
it, checks the hash, extracts it under `$FBQ_BUILD/src` and applies `patches/*.patch` in order.
`tools/check-patches.sh` refuses a series with a NUL byte, CRLF line endings, a missing
`Signed-off-by`, or a patch that does not apply in order to a pristine extract.

Every QNX change is behind `__QNXNTO__` (compiler macro) or `FLB_SYSTEM_QNX` (defined by the
CMake patch), so other platforms compile the same code as before.

## Patch series

"Upstream-ready" says whether the patch could be offered to Fluent Bit as it stands (one
component per commit, guarded, no hack). It is a judgement, not a promise: Fluent Bit asks that
bundled libraries under `lib/` are only edited with maintainer agreement.

| # | File(s) | QNX fact | Fix | Upstream-ready |
|---|---------|----------|-----|----------------|
| 0001 | `CMakeLists.txt` | `accept4()` and the BSD socket calls are in `libsocket.so.4`, inotify is in `libfsnotify.so.1`; neither is part of libc. Configure probes (`FLB_HAVE_ACCEPT4`, `FLB_HAVE_INOTIFY`, `FLB_HAVE_UNIX_SOCKET`) fail to link without them and wrongly report the features missing. | Define `FLB_SYSTEM_QNX` when `CMAKE_SYSTEM_NAME` is `QNX`, add both libraries to `CMAKE_REQUIRED_LIBRARIES` before the probes, and `link_libraries()` them. | No: the global `link_libraries()` should become target-scoped linking first. |
| 0002 | `include/fluent-bit/flb_coro.h`, `include/fluent-bit/flb_output.h` | `<sys/platform.h>` (line 172 in SDP 8.0) is `#error This version of XOPEN_SOURCE is not supported` for any value except 500, 600 and 700, and the headers define `_XOPEN_SOURCE` with no value. | Do not define it when `__QNXNTO__`. | Yes |
| 0003 | `src/tls/openssl.c` | `struct in6_addr` and `inet_pton()` are not pulled in by the QNX OpenSSL or libc headers. | Include `<netinet/in.h>` and `<arpa/inet.h>` on QNX. | Yes |
| 0004 | `lib/chunkio/deps/crc32/crc32.c` | The SDP has no `<endian.h>` or `<sys/endian.h>`; byte order helpers are `ENDIAN_LE16`, `ENDIAN_BE16` in `<gulliver.h>`. | QNX branch defining `htole16`, `le16toh`, `htobe16`, `be16toh`, `__BYTE_ORDER` from gulliver.h. | Yes (touches `lib/`, needs maintainer agreement) |
| 0005 | `lib/snappy-fef67ac/compat.h` | Same missing `<endian.h>`; snappy needs `htole16` and `le32toh`. | QNX branch defining them from `ENDIAN_LE16` and `ENDIAN_LE32`. | No: third-party code, belongs in the snappy source Fluent Bit vendors. |
| 0006 | `lib/chunkio/src/cio_scan.c` | `struct dirent` has no `d_type` (a type exists only in the optional `dirent_extra`). Without a fix the filesystem storage scan finds no chunks after a restart. | On QNX test the entry with `stat(2)` through two small macros; other systems keep the `d_type` test. | Yes (touches `lib/`) |
| 0007 | `lib/chunkio/src/cio_utils.c` | No `<fts.h>` in the SDP, but `<ftw.h>` has `nftw()`. | Use the `nftw()` implementation the Emscripten build already has. | Yes (touches `lib/`) |
| 0008 | `lib/monkey/mk_server/mk_scheduler.c` | No `<sys/syscall.h>` and no `gettid` syscall. | Skip the include on QNX and use `pthread_self()` for `worker->pid`, which only labels the worker in logs. | Yes (touches `lib/`) |
| 0009 | `src/flb_network.c` | No `SO_PEERCRED` and no `struct ucred` in `<sys/socket.h>`. | Compile the unix-socket peer pid code out on QNX like macOS and FreeBSD; no peer pid is reported. | Yes |
| 0010 | `plugins/in_tail/tail_file.c` | No `/proc/<pid>/fd/<n>` symlink to turn an open fd into a path. | `iofdinfo(fd, _FDINFO_FLAG_LOCALPATH, ...)` from `<sys/iomgr.h>`, failing on error or a truncated path. The terminator is written as `'\0'` (the spike's version had a literal NUL byte there; `tools/check-patches.sh` now rejects that). | Yes |
| 0011 | `plugins/in_tail/tail_fs_inotify.c` | The QNX fsevmgr answers `EINVAL` when `IN_IGNORED` or `IN_Q_OVERFLOW` (event-only bits) are in the request mask, so no watch is added. | Request `IN_ATTRIB \| IN_MODIFY` only on QNX; the other bits are still delivered in events. | Yes |

The set came from the feasibility spike (11 edit sets across 12 files). The series was checked
to produce, file for file, the same source tree as the spike's patched tree, except for the
NUL byte fix in 0010.

## CMake options (`qnx/cmake-options.txt`)

Toolchain file `qnx/qnx-x86_64.cmake`: `CMAKE_SYSTEM_NAME QNX`, `qcc`/`q++` with
`gcc_ntox86_64`, `CMAKE_SYSROOT` and the find-root path from `$QNX_TARGET`, programs searched
on the host only. Needs `source ~/qnx800/qnxsdp-env.sh` (`tools/env.sh` does it).

Generic
- `CMAKE_BUILD_TYPE=Release`, `FLB_RELEASE=On`, `FLB_DEBUG=Off`: release build, no debug code.

Plugins (smallest set that covers a monitoring story)
- `FLB_MINIMAL=On`: switches the default plugin set off so only the listed ones are built.
- `FLB_IN_DUMMY=On`: synthetic input for the smoke test and demos.
- `FLB_IN_TAIL=On`: file input; exercises the inotify and `iofdinfo` patches.
- `FLB_OUT_STDOUT=On`: the smoke test output.
- `FLB_OUT_HTTP=On`, `FLB_OUT_FORWARD=On`, `FLB_OUT_LOKI=On`: the three network outputs the demo uses.

Event loop
- `FLB_EVENT_LOOP_POLL=On`: the SDP has no `sys/epoll.h`, `sys/event.h` (kqueue), `sys/timerfd.h`,
  `sys/eventfd.h` or `sys/signalfd.h`; it has `poll.h`. Without a flag upstream falls back to
  auto discovery, which was not tried on QNX, so the backend is chosen explicitly.

Features off
- `FLB_LUAJIT=Off`, `FLB_WASM=Off`: no Lua or Wasm filter is needed; avoids porting a bundled JIT and a Wasm runtime.
- `FLB_JEMALLOC=Off`: jemalloc is not available on QNX, the system allocator is used.
- `FLB_BACKTRACE=Off`: not needed for the port.
- `FLB_KAFKA=Off`: librdkafka is not wanted.
- `FLB_AWS=Off`, `FLB_SIGNV4=Off`, `FLB_CUSTOM_CALYPTIA=Off`: cloud-vendor features outside the scope.
- `FLB_ZIG=Off`, `FLB_PROXY_GO=Off`: no Zig or Go plugin proxy.
- `FLB_STREAM_PROCESSOR=Off`, `FLB_PROFILES=Off`, `FLB_RIPSER=Off`: trimmed scope; Ripser is a C++ component.
- `FLB_EXAMPLES=Off`, `FLB_SHARED_LIB=Off`: only the `fluent-bit` executable is built.
- `FLB_TESTS_RUNTIME=Off`, `FLB_TESTS_INTERNAL=Off`: the upstream test suites are not built; this repo has its own tests.
- `FLB_CONFIG_YAML=Off`: libyaml is not in the SDP, so only classic `.conf` files work. The qnx-ports libyaml port could enable YAML later.
- `FLB_USE_SIMDUTF=No`: avoids the C++ simdutf dependency; the banner reports SSE2 for the remaining SIMD paths.

Features on
- `FLB_TLS=On`: uses the SDP's OpenSSL 3 (`libssl.so.3`, `libcrypto.so.3`); "TLS backend selected: openssl".
- `FLB_INOTIFY=On`: tail's inotify mode, provided on QNX by `libfsnotify`.
- `FLB_SQLDB=On`: the bundled sqlite that tail's `db=` offset file uses.
- `FLB_HTTP_SERVER=On`: the built-in HTTP server (metrics, health); the test configs use `http_server on`.
- `FLB_IN_STORAGE_BACKLOG=On`: filesystem storage creates this input to read chunks back after they have been put down. `FLB_MINIMAL` switches it off, and the engine then refuses to start (`cannot init storage backlog input plugin`).

`tools/build.sh` also verifies after configure that `FLB_HAVE_ACCEPT4`, `FLB_HAVE_INOTIFY` and
`FLB_HAVE_UNIX_SOCKET` are 1 in `CMakeCache.txt`. If a probe is negative the build stops, because
tail would silently lose inotify (or the server accept4) otherwise. `HAVE_GETENTROPY` is empty on
QNX (no `getentropy()`); Fluent Bit has a fallback.

## Target

- Install directory on the target: `/data/fluent-bit-qnx` (`FBQ_TARGET_DIR`), binary at
  `/data/fluent-bit-qnx/bin/fluent-bit`. `/data` is a writable disk partition on the image.
- Runtime libraries: `fluent-bit` needs `libsocket.so.4`, `libfsnotify.so.1`, `libm.so.3`,
  `libcrypto.so.3`, `libc.so.6`, `libgcc_s.so.1` (all in `/proc/boot`) and `libssl.so.3`
  (`/system/lib`). The image has all of them, so `qnx/target-libs.txt` is empty. Libraries a
  later plugin needs and the image lacks are listed there and copied from `$QNX_TARGET` by
  `tools/deploy.sh`, never into this repo.

## Known gaps

- x86_64 only; aarch64 is untested.
- Not exercised yet: TLS to a real endpoint, tail `db=`, rotation, filesystem storage restart.
- Unix-socket peer pid is unavailable (0009).
- Compiler warnings (46 in the spike build) have not been triaged.

## Running on a real-time system

`qnx/fluent-bit.conf` is the agent the demo starts. `tools/start-agent.sh` copies it to the target and `tools/stop-agent.sh` stops that process. The inputs are `slog2` (every buffer set, from now) and `qnx_proc`. Each has `mem_buf_limit 5M` and `storage.type filesystem`. The service sets `storage.max_chunks_up 128` and `storage.path` to `$FBQ_TARGET_DIR/storage`, which is `/data/fluent-bit-qnx/storage` unless that variable was overridden. The reference file contains `__TARGET_DIR__/storage`. start-agent writes the real directory into the copy on the machine. Fluent Bit does not expand shell variables, so leaving `$FBQ_TARGET_DIR` in the file would be a literal path.

The Loki output uses host `10.0.2.2`, port `3100`, and `labels job=fluent-bit-qnx` (the same label as `tests/configs/tail-loki.conf`). When `FBQ_LOKI_HOST` or `FBQ_LOKI_PORT` is set, start-agent writes that value instead. `retry_limit false` keeps a chunk that could not be sent and tries it again, so records stay on disk while the receiver is down and are delivered once it is back. `tests/test_service.sh` covers that path. Reloading chunks after a process restart is still the filesystem-storage gap noted above.

QNX runs the higher priority number first. start-agent launches Fluent Bit with `on -p 8`, so the usual priority 10 work is scheduled ahead of log shipping. `FBQ_PRIORITY` overrides 8. Threads inherit that priority; the service test reads every thread of the fluent-bit pid with `pidin`. The process log is `$FBQ_TARGET_DIR/agent.log`. stop-agent sends SIGTERM and waits until the process has exited 0 and `pidin` no longer lists `fluent-bit`. Test helpers that start Fluent Bit themselves still use priority 10.
