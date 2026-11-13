#!/usr/bin/env bash
# Stop the Loki and Grafana processes started by demo/host/host-up.sh.
set -euo pipefail

data="${FBQ_DEMO_DATA_ROOT:-$HOME/.local/share/fluent-bit-qnx-demo}"
run="$data/run"

stop_one() {
  local file="$1"
  local pid cmd i

  [ -f "$file" ] || return 0
  pid="$(cat "$file" 2>/dev/null || true)"
  rm -f "$file"
  if [ -z "${pid:-}" ] || ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$cmd" in
    *loki-linux-amd64*|*grafana-server*|*bin/grafana*) ;;
    *) return 0 ;;
  esac
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

if curl -fsS --connect-timeout 2 --max-time 5 -X POST \
  "http://127.0.0.1:3100/flush" >/dev/null 2>&1; then
  :
fi

stop_one "$run/grafana.pid"
stop_one "$run/loki.pid"
