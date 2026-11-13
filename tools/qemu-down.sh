#!/usr/bin/env bash
# Copied from qnx-ipc (tools/qemu-down.sh; same author, Apache-2.0): https://github.com/jakethehoffer/qnx-ipc
# It reuses the same QEMU image (QNX_IMAGE_DIR, default ~/qnx-images/ipc) and a running target, so the
# strings below that mention qnx-ipc are kept as they are: changing them would rebuild the shared image.
# Stop the QEMU QNX target started by tools/qemu-up.sh.
set -euo pipefail
if [ -z "${QNX_IMAGE_DIR:-}" ]; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
fi
pidfile="$QNX_IMAGE_DIR/output/qemu.pid"
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
  ssh -i "$QNX_SSH_KEY" -p "$QNX_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 \
      root@127.0.0.1 'shutdown -b' 2>/dev/null || true
  for _ in $(seq 1 10); do kill -0 "$(cat "$pidfile")" 2>/dev/null || break; sleep 1; done
  kill "$(cat "$pidfile")" 2>/dev/null || true
  echo "QNX target stopped"
else
  echo "QNX target not running"
fi
rm -f "$pidfile"
