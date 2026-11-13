#!/usr/bin/env bash
# QNX slog2 input tests. Prints "<name> ok" or "<name> FAILED".
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

show_case() {
  echo "---- records ----" >&2
  cat "$OUT" >&2 || true
  echo "---- target log ----" >&2
  local tag
  tag="$(basename "$CASE_DIR")"
  {
    echo "dir=$FBQ_TARGET_DIR"
    echo "tag=$tag"
    cat <<'REMOTE'
cat "$dir/$tag.log" 2>/dev/null || true
REMOTE
  } | fbq_ssh sh -s >&2 || true
}

check_py='
import json, sys
path, kind = sys.argv[1], sys.argv[2]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
recs = [row.get("record") or {} for row in rows]

def message(rec):
    return rec.get("message")

def numbered(prefix, count):
    return ["%s-%02d" % (prefix, i) for i in range(1, count + 1)]

def fail(text):
    sys.stderr.write(text + "\n")
    sys.exit(1)

sev_cycle = ("INFO", "WARNING", "ERROR")
sev_num = {"INFO": 5, "WARNING": 3, "ERROR": 2}

if kind == "lines":
    want = numbered("line", 10)
    grouped = {}
    for rec in recs:
        if rec.get("buffer_set") != "fbq-test":
            continue
        text = message(rec)
        if text in want:
            grouped.setdefault(text, []).append(rec)
    if sorted(grouped) != sorted(want):
        fail("messages %s" % sorted(grouped))
    for i, text in enumerate(want, 1):
        got = grouped.get(text, [])
        if len(got) != 1:
            fail("%s count %s" % (text, len(got)))
        rec = got[0]
        sev = sev_cycle[(i - 1) % 3]
        if rec.get("severity") != sev:
            fail("%s severity %s want %s" % (text, rec.get("severity"), sev))
        if int(rec.get("severity_num")) != sev_num[sev]:
            fail("%s severity_num %s" % (text, rec.get("severity_num")))
        if rec.get("buffer_set") != "fbq-test" or rec.get("message") != text:
            fail("%s record %s" % (text, rec))
elif kind == "skip":
    # argv[3] is this run held prefix, argv[4] the lines written after start.
    # Older packets in the same buffer use other prefixes and are ignored.
    hist_prefix = sys.argv[3]
    live_prefix = sys.argv[4]
    held = [message(rec) for rec in recs
            if isinstance(message(rec), str) and message(rec).startswith(hist_prefix + "-")]
    if held:
        fail("history delivered: %s" % held)
    live = [rec for rec in recs
            if isinstance(message(rec), str) and message(rec).startswith(live_prefix + "-")]
    got = [message(rec) for rec in live]
    want = numbered(live_prefix, 4)
    if sorted(got) != sorted(want):
        fail("live %s" % got)
    for text in want:
        if got.count(text) != 1:
            fail("%s count %s" % (text, got.count(text)))
    for rec in live:
        if rec.get("buffer_set") != "fbq-test":
            fail("live buffer_set %s" % rec.get("buffer_set"))
elif kind == "keep":
    hist_prefix = sys.argv[3]
    want = numbered(hist_prefix, 4)
    got = [message(rec) for rec in recs
           if isinstance(message(rec), str) and message(rec).startswith(hist_prefix + "-")]
    if sorted(got) != sorted(want):
        fail("history %s" % got)
    for text in want:
        if got.count(text) != 1:
            fail("%s count %s" % (text, got.count(text)))
    for rec in recs:
        text = message(rec)
        if isinstance(text, str) and text.startswith(hist_prefix + "-") and rec.get("buffer_set") != "fbq-test":
            fail("history buffer_set %s" % rec.get("buffer_set"))
elif kind == "match":
    other = []
    for rec in recs:
        text = message(rec)
        if rec.get("buffer_set") == "fbq-other":
            other.append(rec)
        elif isinstance(text, str) and text.startswith("other-"):
            other.append(rec)
    if other:
        fail("fbq-other arrived: %s" % [(rec.get("buffer_set"), message(rec)) for rec in other[:8]])
    got = [message(rec) for rec in recs if isinstance(message(rec), str) and message(rec).startswith("keep-")]
    want = numbered("keep", 4)
    if sorted(got) != sorted(want):
        fail("fbq-test lines %s" % got)
    for rec in recs:
        text = message(rec)
        if isinstance(text, str) and text.startswith("keep-") and rec.get("buffer_set") != "fbq-test":
            fail("keep buffer_set %s" % rec.get("buffer_set"))
else:
    sys.exit(2)
'

wait_kind() {
  local kind="$1"
  local secs="$2"
  shift 2
  local i=0
  while [ "$i" -lt "$secs" ]; do
    if python3 -c "$check_py" "$OUT" "$kind" "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  python3 -c "$check_py" "$OUT" "$kind" "$@" || true
  show_case
  return 1
}

exit_is_clean() {
  local file="$1"
  local label="$2"
  if grep -q '^EXIT=hang$' "$file"; then
    echo "$label EXIT=hang" >&2
    cat "$file" >&2
    return 1
  fi
  if ! grep -q '^EXIT=0$' "$file"; then
    echo "$label did not exit 0" >&2
    cat "$file" >&2
    return 1
  fi
}

slog2_lines_arrive_with_severity() {
  begin_case
  trap 'stop_emits; stop_fb >/dev/null 2>&1 || true; stop_receiver || true' EXIT
  stop_emits
  start_receiver || return 1
  start_fb "$root/tests/configs/slog2.conf" || return 1
  start_emit fbq-test lines || return 1
  emit_cmd lines "log line 10" || return 1
  wait_kind lines 20
}

slog2_from_now_skips_history() {
  local run_id hist_prefix live_prefix
  begin_case
  trap 'stop_emits; stop_fb >/dev/null 2>&1 || true; stop_receiver || true' EXIT
  stop_emits
  start_receiver || return 1
  # Starting here makes a missing slog2 input fail before the helper matters.
  start_fb "$root/tests/configs/slog2.conf" || return 1
  stop_fb
  # fbq-test keeps packets after the helper exits. A new prefix means an
  # earlier run's history-01 lines can neither satisfy nor fail this check.
  run_id="$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
  hist_prefix="h${run_id}"
  live_prefix="v${run_id}"
  start_emit fbq-test hist || return 1
  emit_cmd hist "log ${hist_prefix} 4" || return 1
  sleep 1
  start_fb "$root/tests/configs/slog2.conf" || return 1
  emit_cmd hist "log ${live_prefix} 4" || return 1
  wait_kind skip 20 "$hist_prefix" "$live_prefix"
  stop_fb
  : >"$OUT"
  start_fb "$root/tests/configs/slog2-history.conf" || return 1
  wait_kind keep 20 "$hist_prefix"
}

slog2_match_filters_buffer_sets() {
  begin_case
  trap 'stop_emits; stop_fb >/dev/null 2>&1 || true; stop_receiver || true' EXIT
  stop_emits
  start_receiver || return 1
  start_fb "$root/tests/configs/slog2.conf" || return 1
  start_emit fbq-test keep || return 1
  start_emit fbq-other other || return 1
  emit_cmd keep "log keep 4" || return 1
  emit_cmd other "log other 4" || return 1
  wait_kind match 20
}

slog2_shutdown_is_clean() {
  begin_case
  trap 'stop_emits; stop_fb >/dev/null 2>&1 || true; stop_receiver || true' EXIT
  stop_emits
  start_receiver || return 1
  start_fb "$root/tests/configs/slog2-idle.conf" || return 1
  sleep 2
  stop_fb
  cp "$CASE_DIR/stop.txt" "$CASE_DIR/idle-stop.txt"
  exit_is_clean "$CASE_DIR/idle-stop.txt" "idle stop"
  start_emit fbq-test busy || return 1
  emit_cmd busy loop || return 1
  start_fb "$root/tests/configs/slog2.conf" || return 1
  # Stop only after a loop line has arrived, so the parse thread is busy.
  if ! python3 -c '
import json, sys, time
path, secs = sys.argv[1], int(sys.argv[2])
deadline = time.time() + secs
while time.time() < deadline:
    rows = []
    try:
        rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
    except FileNotFoundError:
        rows = []
    for row in rows:
        rec = row.get("record") or {}
        text = rec.get("message")
        if isinstance(text, str) and text.startswith("loop-") and rec.get("buffer_set") == "fbq-test":
            sys.exit(0)
    time.sleep(1)
sys.stderr.write("no slog2 lines were flowing\n")
sys.exit(1)
' "$OUT" 20; then
    show_case
    return 1
  fi
  stop_fb
  cp "$CASE_DIR/stop.txt" "$CASE_DIR/busy-stop.txt"
  exit_is_clean "$CASE_DIR/busy-stop.txt" "busy stop"
}

set -e
fbq_prepare
set +e
run slog2_lines_arrive_with_severity slog2_lines_arrive_with_severity
run slog2_from_now_skips_history slog2_from_now_skips_history
run slog2_match_filters_buffer_sets slog2_match_filters_buffer_sets
run slog2_shutdown_is_clean slog2_shutdown_is_clean
exit "$fail"
