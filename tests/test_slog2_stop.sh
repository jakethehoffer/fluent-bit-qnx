#!/usr/bin/env bash
# Deterministic stop races on real QNX threads, without stopping other programs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/tools/env.sh"
slog2_stop_reclaims_queue_and_thread() {
python3 "$root/tests/build_slog2_stop_test.py" "$FBQ_BUILD"
"$root/tools/qemu-up.sh" >/dev/null
fbq_ssh "mkdir -p $FBQ_TARGET_DIR/bin"
fbq_scp "$FBQ_BUILD/bin/slog2_stop_lifecycle" "$FBQ_TARGET_DIR/bin/slog2_stop_lifecycle.new" >/dev/null
fbq_ssh "mv -f $FBQ_TARGET_DIR/bin/slog2_stop_lifecycle.new $FBQ_TARGET_DIR/bin/slog2_stop_lifecycle && chmod 755 $FBQ_TARGET_DIR/bin/slog2_stop_lifecycle && LD_LIBRARY_PATH=$FBQ_TARGET_DIR/lib $FBQ_TARGET_DIR/bin/slog2_stop_lifecycle"
}
run() { shift; "$@"; }
run slog2_stop_reclaims_queue_and_thread slog2_stop_reclaims_queue_and_thread
