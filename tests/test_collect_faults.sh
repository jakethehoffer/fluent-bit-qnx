#!/usr/bin/env bash
# One bad record, a refused hand-off and a flood of unreadable processes,
# run through the shipped collect code on the QNX target. Only the record
# encoder, the hand-off to Fluent Bit and the logger are fakes.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/tools/env.sh"
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

run_on_target() {
  local name="$1" plugin="$2"
  python3 "$root/tests/build_plugin_test.py" "$FBQ_BUILD" "$plugin" "$name.c" "$FBQ_BUILD/bin/$name"
  fbq_ssh "mkdir -p $FBQ_TARGET_DIR/bin"
  fbq_scp "$FBQ_BUILD/bin/$name" "$FBQ_TARGET_DIR/bin/$name.new" >/dev/null
  fbq_ssh "mv -f $FBQ_TARGET_DIR/bin/$name.new $FBQ_TARGET_DIR/bin/$name && chmod 755 $FBQ_TARGET_DIR/bin/$name && LD_LIBRARY_PATH=$FBQ_TARGET_DIR/lib $FBQ_TARGET_DIR/bin/$name"
}

# The test binaries print one line per case they pass.
qnx_proc_collect_faults() {
  "$root/tools/qemu-up.sh" >/dev/null
  run_on_target qnx_proc_collect_faults in_qnx_proc.c
}

slog2_collect_faults() {
  "$root/tools/qemu-up.sh" >/dev/null
  run_on_target slog2_collect_faults in_slog2.c
}

run qnx_proc_collect_faults qnx_proc_collect_faults
run slog2_collect_faults slog2_collect_faults
exit "$fail"
