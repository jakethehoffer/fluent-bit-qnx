#!/usr/bin/env bash
# QNX process input tests. Prints "<name> ok" or "<name> FAILED".
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

stop_helpers() {
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
slay -f -Q -s SIGKILL memhog >/dev/null 2>&1 || true
slay -f -Q -s SIGKILL spinner >/dev/null 2>&1 || true
REMOTE
  } | fbq_ssh sh -s >/dev/null || true
}

start_helper() {
  local name="$1"
  shift
  local args="$*"
  local result
  result="$(
    {
      echo "dir=$FBQ_TARGET_DIR"
      echo "name=$name"
      echo "args=$args"
      cat <<'REMOTE'
(on -p 10 "$dir/bin/$name" $args >/dev/null 2>&1 </dev/null &)
i=0
while [ "$i" -lt 5 ]; do
  found=$(slay -p "$name" 2>/dev/null || true)
  if [ -n "$found" ]; then
    echo START=ok
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done
echo START=fail
exit 1
REMOTE
    } | fbq_ssh sh -s
  )"
  if ! printf '%s\n' "$result" | grep -q '^START=ok$'; then
    echo "helper $name did not start" >&2
    printf '%s\n' "$result" >&2
    return 1
  fi
}

check_proc() {
  python3 -c '
import json, sys
kind = sys.argv[1]
rows = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8") if line.strip()]
recs = [row.get("record") or {} for row in rows]

def named(name):
    return [rec for rec in recs if rec.get("name") == name]

if kind == "mem":
    hits = [rec for rec in named("memhog") if int(rec.get("mem_private_bytes") or 0) >= 64 * 1024 * 1024]
    if not hits:
        sys.stderr.write("memhog records: %s\n" % named("memhog")[:3])
        sys.exit(1)
elif kind == "cpu":
    vals = [int(rec.get("cpu_ns") or 0) for rec in named("spinner")]
    if len(vals) < 2 or not any(vals[i] < vals[i + 1] for i in range(len(vals) - 1)):
        sys.stderr.write("spinner cpu_ns: %s\n" % vals)
        sys.exit(1)
elif kind == "match":
    if not recs or any(rec.get("name") != "memhog" for rec in recs):
        sys.stderr.write("names: %s\n" % [rec.get("name") for rec in recs[:8]])
        sys.exit(1)
else:
    sys.exit(2)
' "$1" "$OUT"
}

proc_reports_named_process() {
  begin_case
  trap 'stop_helpers; stop_fb >/dev/null 2>&1 || true; stop_receiver || true' EXIT
  start_helper memhog 64
  start_receiver
  start_fb "$root/tests/configs/qnx-proc.conf"
  sleep 4
  check_proc mem
}

proc_cpu_increases_for_spinner() {
  begin_case
  trap 'stop_helpers; stop_fb >/dev/null 2>&1 || true; stop_receiver || true' EXIT
  start_helper spinner
  start_receiver
  start_fb "$root/tests/configs/qnx-proc.conf"
  sleep 3
  stop_fb
  check_proc cpu
}

proc_match_filters_names() {
  begin_case
  trap 'stop_helpers; stop_fb >/dev/null 2>&1 || true; stop_receiver || true' EXIT
  start_helper memhog 64
  start_helper spinner
  start_receiver
  start_fb "$root/tests/configs/qnx-proc-match.conf"
  sleep 4
  check_proc match
}

proc_survives_short_lived_processes() {
  begin_case
  trap 'stop_helpers; stop_fb >/dev/null 2>&1 || true; stop_receiver || true' EXIT
  start_helper memhog 64
  start_receiver
  start_fb "$root/tests/configs/qnx-proc.conf"
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
i=0
while [ "$i" -lt 200 ]; do
  sh -c ":"
  i=$((i + 1))
done
REMOTE
  } | fbq_ssh sh -s >/dev/null
  sleep 3
  stop_fb
  check_proc mem
  if grep -E "qnx_proc:.*\[(error| warn)\]|\[(error| warn)\].*qnx_proc" "$CASE_DIR/stop.txt"; then
    return 1
  fi
}

# A match that regcomp rejects must end the process. A double free of the
# plugin context crashes or hangs instead of returning from init.
proc_bad_match_exits() {
  local cfg tag result status
  begin_case
  trap 'stop_fb >/dev/null 2>&1 || true' EXIT
  cfg="$CASE_DIR/fb.conf"
  sed "s|__TARGET_DIR__|$FBQ_TARGET_DIR|g" "$root/tests/configs/qnx-proc-bad-match.conf" >"$cfg"
  fbq_scp "$cfg" "$FBQ_TARGET_DIR/fb.conf" >/dev/null
  tag="$(basename "$CASE_DIR")"
  result="$(
    {
      echo "dir=$FBQ_TARGET_DIR"
      echo "bin=$FBQ_TARGET_BIN"
      echo "tag=$tag"
      cat <<'REMOTE'
export LD_LIBRARY_PATH="$dir/lib"
pidf="$dir/$tag.pid"
exitf="$dir/$tag.exit"
log="$dir/$tag.log"
rm -f "$pidf" "$exitf" "$log"
slay -f -Q -s SIGKILL fluent-bit >/dev/null 2>&1 || true
(on -p 10 sh "$dir/wrap.sh" "$bin" "$dir/fb.conf" "$log" "$pidf" "$exitf" >/dev/null 2>&1 </dev/null &)
i=0
while [ ! -s "$exitf" ] && [ "$i" -lt 20 ]; do
  sleep 1
  i=$((i + 1))
done
if [ -s "$exitf" ]; then
  echo "EXIT=$(cat "$exitf")"
else
  pid=$(cat "$pidf" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo EXIT=hang
    kill -TERM "$pid" 2>/dev/null || true
    kill -9 "$pid" 2>/dev/null || true
  else
    echo EXIT=missing
  fi
fi
echo ----
cat "$log" 2>/dev/null || true
REMOTE
    } | fbq_ssh sh -s
  )"
  printf '%s\n' "$result" >"$CASE_DIR/stop.txt"
  status="$(printf '%s\n' "$result" | sed -n 's/^EXIT=//p' | head -n 1)"
  case "$status" in
    1|255) ;;
    hang|missing|"")
      echo "bad match did not exit (EXIT=${status:-none})" >&2
      printf '%s\n' "$result" >&2
      return 1
      ;;
    *)
      echo "bad match crashed or exited oddly (EXIT=$status)" >&2
      printf '%s\n' "$result" >&2
      return 1
      ;;
  esac
  if ! printf '%s\n' "$result" | grep -q 'match is not a valid regular expression'; then
    echo "bad match did not report the regular expression" >&2
    printf '%s\n' "$result" >&2
    return 1
  fi
  if printf '%s\n' "$result" | grep -Eiq 'memory fault|segmentation|dumper|double free|core dumped'; then
    echo "bad match log shows a crash" >&2
    printf '%s\n' "$result" >&2
    return 1
  fi
}

set -e
fbq_prepare
set +e
if [ -n "${FBQ_ONLY:-}" ]; then
  run "$FBQ_ONLY" "$FBQ_ONLY"
  exit "$fail"
fi
run proc_reports_named_process proc_reports_named_process
run proc_cpu_increases_for_spinner proc_cpu_increases_for_spinner
run proc_match_filters_names proc_match_filters_names
run proc_survives_short_lived_processes proc_survives_short_lived_processes
run proc_bad_match_exits proc_bad_match_exits
exit "$fail"
