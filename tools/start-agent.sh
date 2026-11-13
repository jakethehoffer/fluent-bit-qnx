#!/usr/bin/env bash
# Start Fluent Bit on the QNX target as one service.
#
# Priority is 8 unless FBQ_PRIORITY is set. FBQ_LOKI_HOST and FBQ_LOKI_PORT
# override the Loki output in the config copied to the target. The storage
# path written there is $FBQ_TARGET_DIR/storage, not a shell variable.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/tools/env.sh"

prio="${FBQ_PRIORITY:-8}"
if ! [[ "$prio" =~ ^[0-9]+$ ]]; then
  echo "FBQ_PRIORITY must be a whole number" >&2
  exit 1
fi
if [ -n "${FBQ_LOKI_PORT:-}" ] && ! [[ "${FBQ_LOKI_PORT}" =~ ^[0-9]+$ ]]; then
  echo "FBQ_LOKI_PORT must be a whole number" >&2
  exit 1
fi
if [ -n "${FBQ_LOKI_HOST:-}" ] && ! [[ "${FBQ_LOKI_HOST}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "FBQ_LOKI_HOST must be a host name or address" >&2
  exit 1
fi
if ! [[ "$FBQ_TARGET_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "FBQ_TARGET_DIR must be a simple absolute path" >&2
  exit 1
fi

fluent_bit_running() {
  local names
  names="$(fbq_ssh "pidin -F '%100n'")"
  printf '%s\n' "$names" | sed 's/[[:space:]]*$//' | grep -E -q '/fluent-bit$'
}

show_log() {
  fbq_ssh "cat '$FBQ_TARGET_DIR/agent.log'" 2>/dev/null | sed -E \
    -e 's/retry in [0-9]+ seconds/retry scheduled/g' \
    -e 's/in the next [0-9]+ seconds/later/g' \
    -e 's/shutdown in max [0-9]+ seconds/during the grace period/g' \
    -e 's/Shutdown Grace Period=[0-9]+, Shutdown Input Grace Period=[0-9]+/shutdown grace is configured/g' \
    -e 's/resume in [0-9]+ seconds/resume scheduled/g' \
    -e 's/grace_timer=[0-9]+/grace timer tick/g' >&2 || true
}

if fluent_bit_running; then
  echo "fluent-bit is already running" >&2
  exit 1
fi
if ! fbq_ssh "test -x '$FBQ_TARGET_DIR/bin/fluent-bit'"; then
  echo "no fluent-bit on the target: run tools/deploy.sh" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "s|__TARGET_DIR__|${FBQ_TARGET_DIR}|g" "$root/qnx/fluent-bit.conf" >"$tmp"
if [ -n "${FBQ_LOKI_HOST:-}" ]; then
  sed -E "s/^([[:space:]]*Host[[:space:]]+).*/\1${FBQ_LOKI_HOST}/" "$tmp" >"$tmp.host"
  mv "$tmp.host" "$tmp"
fi
if [ -n "${FBQ_LOKI_PORT:-}" ]; then
  sed -E "s/^([[:space:]]*Port[[:space:]]+).*/\1${FBQ_LOKI_PORT}/" "$tmp" >"$tmp.port"
  mv "$tmp.port" "$tmp"
fi
if grep -F -q '__TARGET_DIR__' "$tmp" || grep -F -q '$FBQ_TARGET_DIR' "$tmp"; then
  echo "storage path was not written into the config" >&2
  exit 1
fi
if ! grep -F -q "${FBQ_TARGET_DIR}/storage" "$tmp"; then
  echo "storage path is missing from the config" >&2
  exit 1
fi

fbq_ssh "mkdir -p '$FBQ_TARGET_DIR/bin' '$FBQ_TARGET_DIR/storage'"
fbq_scp "$tmp" "$FBQ_TARGET_DIR/agent.conf" >/dev/null
fbq_scp "$root/tests/target-wrap.sh" "$FBQ_TARGET_DIR/wrap.sh" >/dev/null

set +e
result="$(
  {
    echo "dir=$FBQ_TARGET_DIR"
    echo "prio=$prio"
    cat <<'REMOTE'
rm -f "$dir/agent.pid" "$dir/agent.exit"
mkdir -p "$dir/storage"
(on -p "$prio" sh "$dir/wrap.sh" "$dir/bin/fluent-bit" "$dir/agent.conf" "$dir/agent.log" "$dir/agent.pid" "$dir/agent.exit" >/dev/null 2>&1 </dev/null &)
i=0
while [ "$i" -lt 15 ]; do
  if [ -s "$dir/agent.pid" ]; then
    pid=$(cat "$dir/agent.pid")
    if kill -0 "$pid" 2>/dev/null; then
      if grep -F -q "memory+filesystem" "$dir/agent.log" 2>/dev/null; then
        echo START=ok
        exit 0
      fi
    else
      echo START=dead
      exit 1
    fi
  fi
  sleep 1
  i=$((i + 1))
done
echo START=fail
exit 1
REMOTE
  } | fbq_ssh sh -s
)"
set -e

if ! printf '%s\n' "$result" | grep -q '^START=ok$'; then
  echo "fluent-bit did not start" >&2
  printf '%s\n' "$result" >&2
  show_log
  exit 1
fi
