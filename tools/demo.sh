#!/usr/bin/env bash
# Narrated live demo: slog2 and qnx_proc on a local Grafana dashboard.
#
#   tools/demo.sh [--headless]
#
# Starts the pinned host stack, one agent at priority 8, and leaky_sensor.
# Stops all of them on the way out. Safe to run again.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/tools/env.sh"

data="${FBQ_DEMO_DATA_ROOT:-$HOME/.local/share/fluent-bit-qnx-demo}"
headless=0
case "${1:-}" in
  "") ;;
  --headless) headless=1 ;;
  *)
    echo "usage: tools/demo.sh [--headless]" >&2
    exit 2
    ;;
esac

if ! [[ "$FBQ_TARGET_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "FBQ_TARGET_DIR must be a simple absolute path" >&2
  exit 1
fi

cleanup() {
  set +e
  bash "$root/tools/stop-agent.sh" >/dev/null 2>&1
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
slay -f -Q -s SIGKILL leaky_sensor >/dev/null 2>&1 || true
REMOTE
  } | fbq_ssh sh -s >/dev/null 2>&1 || true
  bash "$root/demo/host/host-down.sh" >/dev/null 2>&1
}
trap cleanup EXIT

loki_query() {
  python3 - "$1" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

mode = sys.argv[1]
base = "http://127.0.0.1:3100"
rise = 8 * 1024 * 1024
info_q = '{job="fluent-bit-qnx"} | json | buffer_set="leaky_sensor" | severity="INFO"'
error_q = '{job="fluent-bit-qnx"} | json | buffer_set="leaky_sensor" | severity="ERROR"'
mem_q = '{job="fluent-bit-qnx"} | json | name="leaky_sensor" | mem_private_bytes!=""'
any_q = '{job="fluent-bit-qnx"}'
sample_q = '{job="fluent-bit-qnx"} |= "leaky_sensor"'


def fetch(logql):
    now = time.time()
    params = urllib.parse.urlencode({
        "query": logql,
        "start": str(int((now - 7200) * 1e9)),
        "end": str(int((now + 60) * 1e9)),
        "limit": "5000",
        "direction": "forward",
    })
    url = base + "/loki/api/v1/query_range?" + params
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        sys.stderr.write(exc.read().decode("utf-8", "replace")[:800] + "\n")
        raise SystemExit(1)
    except urllib.error.URLError as exc:
        sys.stderr.write("loki query failed: %s\n" % exc)
        raise SystemExit(1)
    if payload.get("status") != "success":
        sys.stderr.write("loki query status %s\n" % payload.get("status"))
        raise SystemExit(1)
    return payload.get("data", {}).get("result") or []


def line_count(result):
    return sum(len(stream.get("values") or []) for stream in result)


def memory_from_line(line):
    try:
        body = json.loads(line)
    except json.JSONDecodeError:
        return None
    found = None
    if isinstance(body, dict):
        if body.get("name") == "leaky_sensor" and "mem_private_bytes" in body:
            found = body.get("mem_private_bytes")
        inner = body.get("body")
        if found is None and isinstance(inner, dict) and inner.get("name") == "leaky_sensor":
            found = inner.get("mem_private_bytes")
    if found is None:
        return None
    try:
        return int(float(found))
    except (TypeError, ValueError):
        return None


def memory_points(result):
    points = []
    for stream in result:
        raw = (stream.get("stream") or {}).get("mem_private_bytes")
        label_mem = None
        if raw is not None:
            try:
                label_mem = int(float(raw))
            except ValueError:
                label_mem = None
        for pair in stream.get("values") or []:
            if not pair:
                continue
            mem = label_mem if label_mem is not None else memory_from_line(pair[1])
            if mem is None:
                continue
            try:
                points.append((int(pair[0]), mem))
            except ValueError:
                continue
    points.sort()
    return points


def memory_rose(points):
    for index, older in enumerate(points):
        for newer in points[index + 1:]:
            if newer[1] >= older[1] + rise:
                return True
    return False


def memory_dropped(points):
    if not memory_rose(points):
        return False
    peak = max(mem for _, mem in points)
    return points[-1][1] <= peak - rise


if mode == "empty":
    raise SystemExit(0 if line_count(fetch(any_q)) == 0 else 1)
if mode == "info":
    raise SystemExit(0 if line_count(fetch(info_q)) > 0 else 1)
if mode == "error":
    raise SystemExit(0 if line_count(fetch(error_q)) > 0 else 1)
if mode == "proc":
    pts = memory_points(fetch(mem_q))
    if not pts:
        pts = memory_points(fetch('{job="fluent-bit-qnx"} |= "mem_private_bytes" |= "leaky_sensor"'))
    raise SystemExit(0 if pts else 1)
def sensor_points():
    pts = memory_points(fetch(mem_q))
    if pts:
        return pts
    return memory_points(fetch('{job="fluent-bit-qnx"} |= "mem_private_bytes" |= "leaky_sensor"'))


if mode == "rose":
    raise SystemExit(0 if memory_rose(sensor_points()) else 1)
if mode == "dropped":
    raise SystemExit(0 if memory_dropped(sensor_points()) else 1)
if mode == "series":
    points = sensor_points()
    for _, mem in points:
        print(mem)
    raise SystemExit(0 if memory_dropped(points) else 1)
if mode == "sample":
    shown = 0
    for stream in fetch(sample_q):
        labels = stream.get("stream") or {}
        values = stream.get("values") or []
        line = values[-1][1] if values else ""
        sys.stderr.write("%s %s\n" % (labels, line[:240]))
        shown += 1
        if shown >= 8:
            break
    raise SystemExit(0)
sys.stderr.write("unknown loki query\n")
raise SystemExit(2)
PY
}

wait_for() {
  local mode="$1"
  local tries="$2"
  local n=0
  while [ "$n" -lt "$tries" ]; do
    if loki_query "$mode"; then
      return 0
    fi
    sleep 2
    n=$((n + 1))
  done
  return 1
}

compile_sensor() {
  mkdir -p "$FBQ_BUILD/bin"
  # slog2_register, so this is the slog2 helper qcc line.
  qcc -Vgcc_ntox86_64 -O2 -Wall -Wextra -Werror \
    -o "$FBQ_BUILD/bin/leaky_sensor" \
    "$root/demo/target/leaky_sensor.c" -lslog2
}

copy_sensor() {
  fbq_ssh "mkdir -p '$FBQ_TARGET_DIR/bin'"
  fbq_scp "$FBQ_BUILD/bin/leaky_sensor" "$FBQ_TARGET_DIR/bin/leaky_sensor.new" >/dev/null
  fbq_ssh "chmod 755 '$FBQ_TARGET_DIR/bin/leaky_sensor.new' && mv -f '$FBQ_TARGET_DIR/bin/leaky_sensor.new' '$FBQ_TARGET_DIR/bin/leaky_sensor'"
}

start_sensor_once() {
  local after="$1"
  local result
  result="$(
    {
      echo "dir=$FBQ_TARGET_DIR"
      echo "after=$after"
      cat <<'REMOTE'
slay -f -Q leaky_sensor >/dev/null 2>&1 || true
i=0
while [ "$i" -lt 8 ]; do
  found=$(slay -p leaky_sensor 2>/dev/null || true)
  if [ -z "$found" ]; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
slay -f -Q -s SIGKILL leaky_sensor >/dev/null 2>&1 || true
rm -f "$dir/leaky_sensor.out"
(on -p 10 "$dir/bin/leaky_sensor" --leak-after "$after" >"$dir/leaky_sensor.out" 2>&1 </dev/null &)
i=0
while [ "$i" -lt 8 ]; do
  found=$(slay -p leaky_sensor 2>/dev/null || true)
  if [ -n "$found" ]; then
    echo START=ok
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done
echo START=fail
cat "$dir/leaky_sensor.out" 2>/dev/null || true
exit 1
REMOTE
    } | fbq_ssh sh -s
  )"
  printf '%s\n' "$result" | grep -q '^START=ok$'
}

start_sensor() {
  local after="$1"
  local n=0
  while [ "$n" -lt 8 ]; do
    if start_sensor_once "$after"; then
      return 0
    fi
    n=$((n + 1))
    sleep 1
  done
  echo "leaky_sensor did not start" >&2
  fbq_ssh "cat '$FBQ_TARGET_DIR/leaky_sensor.out'" >&2 || true
  return 1
}

echo "== 1. Host stack"
bash "$root/demo/host/host-down.sh"
rm -rf "$data/loki"
bash "$root/demo/host/host-up.sh"
if ! loki_query empty; then
  echo "Loki is not empty" >&2
  exit 1
fi

echo "== 2. Agent"
bash "$root/tools/qemu-up.sh"
bash "$root/tools/stop-agent.sh"
compile_sensor
copy_sensor
FBQ_PRIORITY=8 FBQ_LOKI_HOST=10.0.2.2 FBQ_LOKI_PORT=3100 \
  bash "$root/tools/start-agent.sh"

echo "== 3. leaky_sensor"
start_sensor 2

echo "== 4. Loki records"
if ! wait_for info 40 || ! wait_for proc 40; then
  echo "leaky_sensor records did not reach Loki" >&2
  loki_query sample >&2 || true
  exit 1
fi

echo "== 5. Dashboard"
echo "http://127.0.0.1:3000/d/qnx-fleet/qnx-fleet"
if [ "$headless" -eq 0 ]; then
  echo "Open the dashboard to watch slog2, private memory, and cpu_ns."
fi

echo "== 6. Leak"
if ! wait_for rose 45 || ! wait_for error 10; then
  echo "leaky_sensor memory did not rise" >&2
  loki_query sample >&2 || true
  exit 1
fi
echo "leaky_sensor private memory rose"

echo "== 7. Restart leaky_sensor"
start_sensor 600

echo "== 8. Memory drop"
if ! wait_for dropped 40; then
  echo "leaky_sensor memory did not drop" >&2
  echo "leaky_sensor mem_private_bytes" >&2
  loki_query series >&2 || true
  loki_query sample >&2 || true
  exit 1
fi
echo "leaky_sensor mem_private_bytes"
loki_query series

echo "== 9. Stop"
echo "demo stopped"
