#!/usr/bin/env bash
# Stop the Fluent Bit agent started by tools/start-agent.sh.
# SIGTERM, then wait until it has exited 0 and pidin shows no fluent-bit.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/tools/env.sh"

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

set +e
result="$(
  {
    echo "dir=$FBQ_TARGET_DIR"
    cat <<'REMOTE'
pid=$(cat "$dir/agent.pid" 2>/dev/null || true)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo STOP=absent
  exit 0
fi
rm -f "$dir/agent.exit"
kill -TERM "$pid" 2>/dev/null || true
i=0
while [ "$i" -lt 20 ]; do
  if [ -s "$dir/agent.exit" ] && ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  echo STOP=hang
  exit 1
fi
code=$(cat "$dir/agent.exit" 2>/dev/null || echo missing)
if [ "$code" != "0" ]; then
  echo STOP=bad
  echo "EXIT=$code"
  exit 1
fi
echo STOP=ok
REMOTE
  } | fbq_ssh sh -s
)"
set -e

if printf '%s\n' "$result" | grep -q '^STOP=hang$'; then
  echo "fluent-bit did not exit" >&2
  show_log
  exit 1
fi
if printf '%s\n' "$result" | grep -q '^STOP=bad$'; then
  echo "fluent-bit exit was not 0" >&2
  printf '%s\n' "$result" >&2
  show_log
  exit 1
fi
if ! printf '%s\n' "$result" | grep -Eq '^STOP=(ok|absent)$'; then
  echo "fluent-bit did not stop" >&2
  printf '%s\n' "$result" >&2
  show_log
  exit 1
fi
if fluent_bit_running; then
  echo "fluent-bit is still running" >&2
  exit 1
fi
