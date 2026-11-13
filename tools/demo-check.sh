#!/usr/bin/env bash
# Run the live demo and check that Loki stored it.
#
#   tools/demo-check.sh
#
# Success prints "demo check passed". The first gap prints one missing item.
# On failure the host stack, the agent, and leaky_sensor are stopped.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$root/tools/demo.sh" ]; then
  echo "missing demo: tools/demo.sh"
  exit 1
fi

# shellcheck disable=SC1091
source "$root/tools/env.sh"

cleanup() {
  set +e
  if [ -f "$root/demo/host/host-down.sh" ]; then
    bash "$root/demo/host/host-down.sh" >/dev/null 2>&1
  fi
  if [ -f "$root/tools/stop-agent.sh" ]; then
    bash "$root/tools/stop-agent.sh" >/dev/null 2>&1
  fi
  if declare -F fbq_ssh >/dev/null 2>&1; then
    fbq_ssh "slay -f -Q -s SIGKILL leaky_sensor >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

set +e
bash "$root/tools/demo.sh" --headless
demo_rc=$?
set -e
if [ "$demo_rc" -ne 0 ]; then
  echo "missing demo run"
  exit 1
fi

if [ ! -f "$root/demo/host/host-up.sh" ]; then
  echo "missing demo: demo/host/host-up.sh"
  exit 1
fi
bash "$root/demo/host/host-up.sh" >/dev/null

python3 - <<'PY'
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

base = "http://127.0.0.1:3100"
rise = 8 * 1024 * 1024
info_q = '{job="fluent-bit-qnx"} | json | buffer_set="leaky_sensor" | severity="INFO"'
error_q = '{job="fluent-bit-qnx"} | json | buffer_set="leaky_sensor" | severity="ERROR"'
mem_q = '{job="fluent-bit-qnx"} | json | name="leaky_sensor" | mem_private_bytes!=""'


def query(logql):
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
        print("missing Loki answer")
        raise SystemExit(1)
    except urllib.error.URLError as exc:
        sys.stderr.write("loki query failed: %s\n" % exc)
        print("missing Loki answer")
        raise SystemExit(1)
    if payload.get("status") != "success":
        sys.stderr.write("loki status: %s\n" % payload.get("status"))
        print("missing Loki answer")
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


def rose(points):
    for index, older in enumerate(points):
        for newer in points[index + 1:]:
            if newer[1] >= older[1] + rise:
                return True
    return False


info = query(info_q)
if line_count(info) < 1:
    print("missing slog2 INFO from leaky_sensor")
    raise SystemExit(1)

errors = query(error_q)
if line_count(errors) < 1:
    print("missing slog2 ERROR from leaky_sensor")
    raise SystemExit(1)

points = memory_points(query(mem_q))
if not points:
    points = memory_points(query('{job="fluent-bit-qnx"} |= "mem_private_bytes" |= "leaky_sensor"'))
if not points:
    print("missing qnx_proc records for leaky_sensor")
    raise SystemExit(1)
if not rose(points):
    print("missing rising mem_private_bytes for leaky_sensor")
    raise SystemExit(1)
PY

echo "demo check passed"
