#!/usr/bin/env bash
# QNX service tests. Prints "<name> ok" or "<name> FAILED".
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

need_tool() {
  local rel="$1"
  if [ ! -f "$root/$rel" ]; then
    echo "missing $rel" >&2
    return 1
  fi
}

stop_quiet() {
  if [ -f "$root/tools/stop-agent.sh" ]; then
    "$root/tools/stop-agent.sh" >/dev/null 2>&1 || true
  fi
}

start_default() {
  (
    unset FBQ_PRIORITY
    unset FBQ_LOKI_HOST
    unset FBQ_LOKI_PORT
    exec "$root/tools/start-agent.sh"
  )
}

start_loki_receiver() {
  (
    unset FBQ_PRIORITY
    unset FBQ_LOKI_HOST
    export FBQ_LOKI_PORT="$LOKI_PORT"
    exec "$root/tools/start-agent.sh"
  )
}

stop_emits() {
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
slay -f -Q -s SIGKILL slog2_emit >/dev/null 2>&1 || true
REMOTE
  } | fbq_ssh sh -s >/dev/null || true
}

start_emit() {
  local setname="$1"
  local id="$2"
  local result
  result="$(
    {
      echo "dir=$FBQ_TARGET_DIR"
      echo "setname=$setname"
      echo "id=$id"
      cat <<'REMOTE'
rm -f "$dir/slog2-$id.cmd" "$dir/slog2-$id.cmd.new" "$dir/slog2-$id.cmd.done" \
  "$dir/slog2-$id.ready" "$dir/slog2-$id.ack"
(on -p 10 "$dir/bin/slog2_emit" --set "$setname" --ctl "$dir/slog2-$id.cmd" --ready "$dir/slog2-$id.ready" --ack "$dir/slog2-$id.ack" >/dev/null 2>&1 </dev/null &)
i=0
while [ "$i" -lt 5 ]; do
  if [ -s "$dir/slog2-$id.ready" ]; then
    if grep -q '^ok$' "$dir/slog2-$id.ready"; then
      echo START=ok
      exit 0
    fi
    echo START=fail
    cat "$dir/slog2-$id.ready" 2>/dev/null || true
    exit 1
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
    echo "helper slog2_emit did not start" >&2
    printf '%s\n' "$result" >&2
    return 1
  fi
}

emit_cmd() {
  local id="$1"
  local cmd="$2"
  local result
  result="$(
    {
      echo "dir=$FBQ_TARGET_DIR"
      echo "id=$id"
      printf "cmd='%s'\n" "$cmd"
      printf "want='%s'\n" "$cmd"
      cat <<'REMOTE'
rm -f "$dir/slog2-$id.ack"
printf '%s\n' "$cmd" > "$dir/slog2-$id.cmd.new"
mv -f "$dir/slog2-$id.cmd.new" "$dir/slog2-$id.cmd"
i=0
while [ "$i" -lt 10 ]; do
  if [ -f "$dir/slog2-$id.ack" ] && grep -F -x -q "$want" "$dir/slog2-$id.ack"; then
    echo ACK=ok
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done
echo ACK=fail
cat "$dir/slog2-$id.ack" 2>/dev/null || true
exit 1
REMOTE
    } | fbq_ssh sh -s
  )"
  if ! printf '%s\n' "$result" | grep -q '^ACK=ok$'; then
    echo "slog2_emit did not accept: $cmd" >&2
    printf '%s\n' "$result" >&2
    return 1
  fi
}

show_agent_log() {
  echo "---- agent log ----" >&2
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
cat "$dir/agent.log" 2>/dev/null || true
REMOTE
  } | fbq_ssh sh -s | sed -E \
    -e 's/retry in [0-9]+ seconds/retry scheduled/g' \
    -e 's/in the next [0-9]+ seconds/later/g' \
    -e 's/shutdown in max [0-9]+ seconds/during the grace period/g' \
    -e 's/Shutdown Grace Period=[0-9]+, Shutdown Input Grace Period=[0-9]+/shutdown grace is configured/g' \
    -e 's/resume in [0-9]+ seconds/resume scheduled/g' \
    -e 's/grace_timer=[0-9]+/grace timer tick/g' >&2 || true
}

prio_py='
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()

def section(begin, end):
    body = []
    on = False
    for line in lines:
        if line.strip() == begin:
            on = True
            continue
        if line.strip() == end:
            break
        if on:
            body.append(line.strip())
    return body

if any(line.strip() == "NO_PID" for line in lines):
    sys.stderr.write("fluent-bit pid was not running\n")
    sys.exit(1)
names = [line for line in section("BEGIN_NAME", "END_NAME") if line]
# pidin prints a header, then one path per thread.
paths = [line for line in names[1:] if line]
if not paths or any(not line.endswith("/fluent-bit") for line in paths):
    sys.stderr.write("pid is not fluent-bit: %s\n" % paths)
    sys.exit(1)
prios = []
for line in section("BEGIN_PRIO", "END_PRIO"):
    match = re.fullmatch(r"(\d+)[A-Za-z]*", line)
    if match:
        prios.append(int(match.group(1)))
if not prios:
    sys.stderr.write("no thread priorities from pidin\n")
    sys.exit(1)
if any(prio != 8 for prio in prios):
    sys.stderr.write("thread priorities %s\n" % prios)
    sys.exit(1)
'

check_priorities() {
  local out
  out="$(mktemp)"
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
pid=$(cat "$dir/agent.pid" 2>/dev/null || true)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo NO_PID
  exit 0
fi
echo BEGIN_NAME
pidin -F "%100n" -p "$pid"
echo END_NAME
echo BEGIN_PRIO
pidin -F "%p" -p "$pid"
echo END_PRIO
REMOTE
  } | fbq_ssh sh -s >"$out"
  if ! python3 -c "$prio_py" "$out"; then
    echo "---- pidin ----" >&2
    cat "$out" >&2
    show_agent_log
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
}

records_py='
import json, sys
path = sys.argv[1]
want = ["svc-%02d" % i for i in range(1, 21)]
counts = {key: 0 for key in want}
bad_label = 0
rows = 0
for raw_line in open(path, encoding="utf-8"):
    raw_line = raw_line.strip()
    if not raw_line:
        continue
    rows += 1
    try:
        row = json.loads(raw_line)
    except json.JSONDecodeError:
        continue
    rec = row.get("record") or {}
    labels = rec.get("labels") or {}
    body_raw = rec.get("line")
    try:
        body = json.loads(body_raw) if isinstance(body_raw, str) else {}
    except json.JSONDecodeError:
        body = {}
    message = body.get("message")
    if message not in counts:
        continue
    counts[message] += 1
    if labels.get("job") != "fluent-bit-qnx":
        bad_label += 1
dupes = [key for key, count in counts.items() if count > 1]
missing = [key for key, count in counts.items() if count == 0]
if dupes or bad_label:
    sys.stderr.write("counts %s bad_label %s rows %s\n" % (counts, bad_label, rows))
    sys.exit(2)
if missing:
    sys.exit(1)
'

wait_records() {
  local i=0
  local rc
  while [ "$i" -lt 40 ]; do
    set +e
    python3 -c "$records_py" "$OUT" >/dev/null 2>"$CASE_DIR/records.err"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      cat "$CASE_DIR/records.err" >&2 || true
      return 1
    fi
    sleep 1
    i=$((i + 1))
  done
  python3 -c "$records_py" "$OUT" >&2 || true
  echo "---- records ----" >&2
  cat "$OUT" >&2 || true
  if [ -f "$CASE_DIR/receiver.err" ]; then
    echo "---- receiver ----" >&2
    cat "$CASE_DIR/receiver.err" >&2 || true
  fi
  show_agent_log
  return 1
}

wait_slog_flush_failed() {
  local i=0
  local result
  while [ "$i" -lt 25 ]; do
    result="$(
      {
        echo "dir=$FBQ_TARGET_DIR"
        cat <<'REMOTE'
if grep -F "failed to flush" "$dir/agent.log" 2>/dev/null | grep -F -q "slog2"; then
  echo FOUND=yes
else
  echo FOUND=no
fi
REMOTE
      } | fbq_ssh sh -s
    )"
    if printf '%s\n' "$result" | grep -q '^FOUND=yes$'; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "slog2 output was not retried while the receiver was down" >&2
  show_agent_log
  return 1
}

clear_storage() {
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
rm -rf "$dir/storage"
mkdir -p "$dir/storage"
REMOTE
  } | fbq_ssh sh -s >/dev/null
}

agent_state() {
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
echo BEGIN_NAMES
pidin -F "%100n"
echo END_NAMES
if [ -f "$dir/agent.exit" ]; then
  echo "EXIT=$(cat "$dir/agent.exit")"
else
  echo EXIT=missing
fi
REMOTE
  } | fbq_ssh sh -s
}

agent_runs_at_configured_priority() {
  need_tool tools/start-agent.sh
  trap 'stop_quiet' EXIT
  stop_quiet
  start_default
  sleep 2
  check_priorities
}

agent_buffers_while_receiver_down_then_delivers() {
  need_tool tools/start-agent.sh
  begin_case
  trap 'stop_emits; stop_quiet; stop_receiver || true' EXIT
  stop_emits
  stop_quiet
  clear_storage
  start_loki_receiver
  start_emit fbq-service svc
  emit_cmd svc "log svc 20"
  wait_slog_flush_failed
  start_receiver
  wait_records
}

agent_stops_cleanly() {
  local state
  need_tool tools/stop-agent.sh
  need_tool tools/start-agent.sh
  trap 'stop_quiet' EXIT
  stop_quiet
  start_default
  "$root/tools/stop-agent.sh"
  state="$(agent_state)"
  if printf '%s\n' "$state" | sed -n '/^BEGIN_NAMES$/,/^END_NAMES$/p' | sed 's/[[:space:]]*$//' | grep -E -q '/fluent-bit$'; then
    echo "fluent-bit still running" >&2
    printf '%s\n' "$state" >&2
    return 1
  fi
  printf '%s\n' "$state" | grep -q '^EXIT=0$' || {
    echo "agent exit was not 0" >&2
    printf '%s\n' "$state" >&2
    show_agent_log
    return 1
  }
}

set -e
# Missing start/stop scripts are the failure this test is written to catch.
# Building the target first would hide that behind a long, unrelated run.
if [ -f "$root/tools/start-agent.sh" ] && [ -f "$root/tools/stop-agent.sh" ]; then
  fbq_prepare
fi
set +e
run agent_runs_at_configured_priority agent_runs_at_configured_priority
run agent_buffers_while_receiver_down_then_delivers agent_buffers_while_receiver_down_then_delivers
run agent_stops_cleanly agent_stops_cleanly
exit "$fail"
