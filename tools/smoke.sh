#!/usr/bin/env bash
# Smoke test: Fluent Bit on the QNX 8.0 QEMU target.
#
#   tools/smoke.sh
#
# Boots the target if needed (tools/qemu-up.sh), builds (tools/build.sh), deploys
# (tools/deploy.sh), then runs on the target
#   fluent-bit -i dummy -p 'dummy={"msg":"smoke"}' -o stdout -f 1
# for a few seconds. Passes when the stdout output holds "msg"=>"smoke", there is no [error]
# line, and the process exits 0 after SIGTERM. Prints "smoke ok" on success.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/tools/env.sh"

"$root/tools/qemu-up.sh"
"$root/tools/build.sh"
target_bin="$("$root/tools/deploy.sh")"
dir="$FBQ_TARGET_DIR"
run_secs="${FBQ_SMOKE_SECONDS:-4}"

# The script that runs on the target is a quoted heredoc, so no quoting survives ssh twice.
result="$( { echo "dir=$dir"; echo "bin=$target_bin"; echo "secs=$run_secs"; cat <<'REMOTE'
export LD_LIBRARY_PATH="$dir/lib"
out="$dir/smoke.out"
rm -f "$out"
"$bin" -i dummy -p 'dummy={"msg":"smoke"}' -o stdout -f 1 > "$out" 2>&1 &
pid=$!
sleep "$secs"
kill -TERM "$pid" 2>/dev/null || true
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
  sleep 1
  i=$((i + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  kill -9 "$pid" 2>/dev/null || true
  echo "EXIT=hang"
else
  rc=0
  wait "$pid" || rc=$?
  echo "EXIT=$rc"
fi
echo "---- $out"
cat "$out"
REMOTE
} | fbq_ssh sh -s)"

echo "$result"

fail=0
exit_line="$(echo "$result" | grep -m1 '^EXIT=' || true)"
if [ "$exit_line" != "EXIT=0" ]; then
  echo "smoke FAILED: expected EXIT=0 after SIGTERM, got '${exit_line:-none}'" >&2
  fail=1
fi
if ! echo "$result" | grep -qF '"msg"=>"smoke"'; then
  echo 'smoke FAILED: output has no "msg"=>"smoke"' >&2
  fail=1
fi
if echo "$result" | grep -q '\[error\]'; then
  echo "smoke FAILED: an [error] line is in the output" >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "smoke ok"
