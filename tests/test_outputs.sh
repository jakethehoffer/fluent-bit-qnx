#!/usr/bin/env bash
# Delivery tests. Each name is printed as "<name> ok" or "<name> FAILED".
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/tests/lib.sh"

fail=0

run() {
  local name="$1"
  shift
  set +e
  (
    set -euo pipefail
    "$@"
  )
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "$name ok"
  else
    echo "$name FAILED"
    fail=1
  fi
}

lines_py='
import json, sys
path, kind = sys.argv[1], sys.argv[2]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]

def line_of(row):
    rec = row.get("record") or {}
    if kind == "loki":
        raw = rec.get("line")
        try:
            body = json.loads(raw) if isinstance(raw, str) else {}
        except json.JSONDecodeError:
            body = {}
        return body.get("log")
    return rec.get("log")

if kind == "dummy":
    n = sum(1 for row in rows if (row.get("record") or {}).get("msg") == "http-dummy")
    if n < 5:
        sys.stderr.write("dummy records %s, want at least 5\n" % n)
        sys.exit(1)
    sys.exit(0)

if kind == "loki":
    bad = [row for row in rows if ((row.get("record") or {}).get("labels") or {}).get("job") != "fluent-bit-qnx"]
    if bad or not rows:
        sys.stderr.write("loki labels missing on %s of %s rows\n" % (len(bad), len(rows)))
        sys.exit(1)

got = [line_of(row) for row in rows]
want = ["line-%02d" % i for i in range(1, 21)]
if got != want:
    sys.stderr.write("got %s\n" % got)
    sys.exit(1)
'

check_lines() {
  if ! python3 -c "$lines_py" "$OUT" "$1"; then
    echo "---- records ----" >&2
    cat "$OUT" >&2 || true
    return 1
  fi
}

shutdown_ok() {
  python3 -c '
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
if "EXIT=0" not in text.splitlines():
    sys.stderr.write(text)
    sys.exit(1)
if "still running" in text or "pending task(s)" in text:
    sys.stderr.write(text)
    sys.exit(1)
if "0 pending tasks" not in text:
    sys.stderr.write(text)
    sys.exit(1)
' "$CASE_DIR/stop.txt"
}

http_delivers_dummy_records() {
  begin_case
  start_receiver
  start_fb "$root/tests/configs/http-dummy.conf"
  wait_lines 5 20
  stop_fb
  check_lines dummy
}

tail_delivers_appended_lines_in_order() {
  begin_case
  prepare_lines_file
  start_receiver
  start_fb "$root/tests/configs/tail-http.conf"
  sleep 2
  append_lines
  wait_lines 20 25
  sleep 2
  stop_fb
  check_lines http
}

forward_delivers_every_tail_line() {
  begin_case
  prepare_lines_file
  start_receiver
  start_fb "$root/tests/configs/tail-forward.conf"
  sleep 2
  append_lines
  wait_lines 20 30
  sleep 2
  stop_fb
  check_lines http
}

loki_push_received() {
  begin_case
  prepare_lines_file
  start_receiver
  start_fb "$root/tests/configs/tail-loki.conf"
  sleep 2
  append_lines
  wait_lines 20 30
  sleep 2
  stop_fb
  check_lines loki
}

two_workers_shutdown_clean() {
  begin_case
  start_receiver
  start_fb "$root/tests/configs/http-workers.conf"
  wait_lines 1 20
  stop_fb
  shutdown_ok
}

set -e
fbq_prepare
set +e
run http_delivers_dummy_records http_delivers_dummy_records
run tail_delivers_appended_lines_in_order tail_delivers_appended_lines_in_order
run forward_delivers_every_tail_line forward_delivers_every_tail_line
run loki_push_received loki_push_received
run two_workers_shutdown_clean two_workers_shutdown_clean
exit "$fail"
