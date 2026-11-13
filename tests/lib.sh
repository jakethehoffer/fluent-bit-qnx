#!/usr/bin/env bash
# Helpers for tests/test_*.sh. Source this file. Do not run it.
# shellcheck disable=SC1091

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$_here/.." && pwd)"

HTTP_PORT=9880
FORWARD_PORT=24224
LOKI_PORT=13100

fbq_prepare() {
  # shellcheck disable=SC1091
  source "$root/tools/env.sh"
  python3 "$root/tests/receiver.py" --self-check >/dev/null
  "$root/tools/qemu-up.sh" >/dev/null
  mkdir -p "$FBQ_BUILD"
  local err="$FBQ_BUILD/deploy.err"
  if ! FBQ_TARGET_BIN="$("$root/tools/deploy.sh" 2>"$err")"; then
    cat "$err" >&2
    return 1
  fi
  export FBQ_TARGET_BIN
  fbq_scp "$root/tests/target-wrap.sh" "$FBQ_TARGET_DIR/wrap.sh" >/dev/null
}

begin_case() {
  CASE_DIR="$(mktemp -d /tmp/fbq-case.XXXXXX)"
  OUT="$CASE_DIR/out.jsonl"
  export CASE_DIR OUT
  : >"$OUT"
  trap 'stop_fb >/dev/null 2>&1 || true; stop_receiver || true' EXIT
}

start_receiver() {
  local ready="$CASE_DIR/receiver.ready"
  rm -f "$ready"
  python3 "$root/tests/receiver.py" \
    --http "$HTTP_PORT" --forward "$FORWARD_PORT" --loki "$LOKI_PORT" \
    --out "$OUT" --ready "$ready" \
    >"$CASE_DIR/receiver.err" 2>&1 &
  echo $! >"$CASE_DIR/receiver.pid"
  local i=0
  while [ ! -s "$ready" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$ready" ]; then
    echo "receiver did not start" >&2
    cat "$CASE_DIR/receiver.err" >&2 || true
    return 1
  fi
}

stop_receiver() {
  if [ -z "${CASE_DIR:-}" ] || [ ! -f "$CASE_DIR/receiver.pid" ]; then
    return 0
  fi
  local pid
  pid="$(cat "$CASE_DIR/receiver.pid")"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

start_fb() {
  local src="$1"
  local cfg="$CASE_DIR/fb.conf"
  sed "s|__TARGET_DIR__|$FBQ_TARGET_DIR|g" "$src" >"$cfg"
  fbq_scp "$cfg" "$FBQ_TARGET_DIR/fb.conf" >/dev/null
  local result
  local tag
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
# on is backgrounded inside a subshell that exits at once, so this shell can
# return while the wrapper (and fluent-bit) keep running.
(on -p 10 sh "$dir/wrap.sh" "$bin" "$dir/fb.conf" "$log" "$pidf" "$exitf" >/dev/null 2>&1 </dev/null &)
i=0
while [ ! -s "$pidf" ] && [ "$i" -lt 5 ]; do
  sleep 1
  i=$((i + 1))
done
if [ ! -s "$pidf" ]; then
  echo START=fail
  exit 1
fi
pid=$(cat "$pidf")
if ! kill -0 "$pid" 2>/dev/null; then
  echo START=dead
  cat "$log" 2>/dev/null || true
  exit 1
fi
echo START=ok
echo "PID=$pid"
REMOTE
    } | fbq_ssh sh -s
  )"
  printf '%s\n' "$result" >"$CASE_DIR/start.txt"
  if ! printf '%s\n' "$result" | grep -q '^START=ok$'; then
    echo "fluent-bit did not start" >&2
    printf '%s\n' "$result" >&2
    return 1
  fi
}

stop_fb() {
  if [ -z "${CASE_DIR:-}" ]; then
    return 0
  fi
  local result
  local tag
  tag="$(basename "$CASE_DIR")"
  result="$(
    {
      echo "dir=$FBQ_TARGET_DIR"
      echo "tag=$tag"
      cat <<'REMOTE'
pidf="$dir/$tag.pid"
exitf="$dir/$tag.exit"
log="$dir/$tag.log"
pid=$(cat "$pidf" 2>/dev/null || true)
if [ -z "$pid" ]; then
  echo EXIT=missing
else
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ ! -s "$exitf" ] && [ "$i" -lt 20 ]; do
    sleep 1
    i=$((i + 1))
  done
  if [ -s "$exitf" ]; then
    echo "EXIT=$(cat "$exitf")"
  else
    kill -9 "$pid" 2>/dev/null || true
    echo EXIT=hang
  fi
fi
echo ----
cat "$log" 2>/dev/null || true
REMOTE
    } | fbq_ssh sh -s
  )"
  printf '%s\n' "$result" >"$CASE_DIR/stop.txt"
}

prepare_lines_file() {
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
: >"$dir/lines.log"
REMOTE
  } | fbq_ssh sh -s >/dev/null
}

append_lines() {
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
i=1
while [ "$i" -le 20 ]; do
  if [ "$i" -lt 10 ]; then
    echo "line-0$i" >>"$dir/lines.log"
  else
    echo "line-$i" >>"$dir/lines.log"
  fi
  i=$((i + 1))
done
REMOTE
  } | fbq_ssh sh -s >/dev/null
}

wait_lines() {
  local want="$1"
  local secs="$2"
  local i=0
  local n=0
  while [ "$i" -lt "$secs" ]; do
    n=0
    if [ -f "$OUT" ]; then
      n="$(grep -c . "$OUT" || true)"
    fi
    if [ "$n" -ge "$want" ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "timed out with $n records, wanted $want" >&2
  if [ -f "$CASE_DIR/receiver.err" ]; then
    echo "---- receiver ----" >&2
    cat "$CASE_DIR/receiver.err" >&2
  fi
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
  return 1
}

run_on_target() {
  fbq_ssh "$@"
}
