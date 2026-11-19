# Live dashboard demo

This runs the QNX agent against a local Loki and Grafana so slog2 lines and per-process stats show up on one dashboard. Memory and `cpu_ns` figures are about the processes the agent is watching, including the demo program `leaky_sensor`.

## What you get

- Loki on `127.0.0.1:3100`, with files under `$HOME/.local/share/fluent-bit-qnx-demo`.
- Grafana on `127.0.0.1:3000`, anonymous viewer, dashboard at `/d/qnx-fleet/qnx-fleet`.
- Panel 1: slog2 lines from the buffer sets the `name` filter selects (All shows every buffer set). Each line keeps its QNX severity, and the level color is ERROR red, WARNING yellow, INFO and NOTICE blue.
- Panel 2: `mem_private_bytes` per process name (`unwrap` on `qnx_proc` records).
- Panel 3: CPU as a percent of one core per process name: the per-second increase of the `cpu_ns` running total (`rate_counter`), divided by 10^7.
- `name` and `pid` variables to narrow those series. `name` starts at `leaky_sensor`. `pid` starts at all pids so a restart stays on the chart.

`leaky_sensor` registers the slog2 buffer set `leaky_sensor`, logs an INFO reading every second, and after `--leak-after N` seconds allocates and touches 8 MiB every other second. Each growth logs WARNING, then ERROR.

## Run

From WSL, after `source tools/env.sh`, with the shared QNX target available:

```bash
tools/demo.sh
tools/demo-check.sh
```

The demo starts `leaky_sensor` with `--leak-after 15`, so the first 15 seconds show calm INFO lines, and scans processes every second. After Loki first shows the memory rise, it lets the leak run 30 more seconds before the restart, so the memory chart climbs in steps. `tools/demo.sh --leak SECONDS` changes those 30 seconds. `leaky_sensor` stops growing at 192 MiB.

`tools/demo.sh --hold SECONDS` keeps the dashboard, agent and `leaky_sensor` running for that long after the memory drop, for watching or filming. `tools/demo.sh --headless` is the same narrated run for an unattended check. The check runs that mode and queries Loki for `leaky_sensor` INFO lines, ERROR lines, and rising `mem_private_bytes`. It prints `demo check passed` or the first missing item.

The demo starts the agent with `tools/start-agent.sh` at priority 8, Loki `10.0.2.2:3100`, and `FBQ_PROC_INTERVAL_SEC=1`, which adds `interval_sec 1` to the `qnx_proc` input in the copy on the target. It reuses the running QEMU target. It stops the agent, `leaky_sensor`, Loki, and Grafana on the way out.

## Pinned host binaries

`demo/host/versions.txt` records the Loki and Grafana linux-amd64 archives and the publisher SHA-256 of each. `demo/host/host-up.sh` caches them in `$HOME/.cache/fluent-bit-qnx-demo`, checks the publisher checksum against that pin, and checks the file you downloaded. The archives are not committed.

`demo/host/host-down.sh` stops the two processes.
