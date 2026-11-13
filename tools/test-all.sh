#!/usr/bin/env bash
# Full check, then docs/test-log.txt.
#
#   tools/test-all.sh
#
# Runs tools/check-patches.sh, a clean tools/build.sh, tools/test-target.sh
# and tools/demo-check.sh. The log names each result as ok or FAILED, and
# records the Fluent Bit version, the patch count and the QNX toolchain
# version. It does not record timings.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/tools/env.sh"
# shellcheck disable=SC1091
source "$root/UPSTREAM"

log="$root/docs/test-log.txt"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/fbq-test-all.XXXXXX")"
cp_rc=1
build_rc=1
test_rc=1
demo_rc=1
log_written=0

run_step() {
  local outfile="$1"
  shift
  local rc
  "$@" 2>&1 | tee "$outfile"
  rc=${PIPESTATUS[0]}
  return "$rc"
}

fluent_bit_version() {
  local out token
  token=""
  if [ "$build_rc" -eq 0 ]; then
    # timeout(1) runs a program. fbq_ssh is a shell function, so call ssh
    # with the same options the function uses.
    # shellcheck disable=SC2086
    out="$(timeout 30 ssh $FBQ_SSH_OPTS root@127.0.0.1 "$FBQ_TARGET_DIR/bin/fluent-bit" --version 2>&1 || true)"
    token="$(printf '%s\n' "$out" | sed -n 's/^Fluent Bit v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1 || true)"
    if [ -z "$token" ] && [ -f "$FBQ_BUILD/bin/fluent-bit" ]; then
      out="$(strings "$FBQ_BUILD/bin/fluent-bit" 2>/dev/null | grep -F 'Fluent Bit v' | head -n 1 || true)"
      token="$(printf '%s\n' "$out" | sed -n 's/.*Fluent Bit v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1 || true)"
    fi
  fi
  if [ -z "$token" ]; then
    token="$FB_VERSION"
  fi
  printf '%s\n' "$token"
}

toolchain_version() {
  local line
  line="$(ntox86_64-gcc --version 2>/dev/null | head -n 1 | tr -d '\r' || true)"
  if [ -z "$line" ]; then
    line="unknown"
  fi
  printf '%s\n' "$line"
}

patch_count() {
  local n
  n="$(sed -n 's/^check-patches ok (\([0-9][0-9]*\) patches)$/\1/p' "$workdir/check-patches.out" 2>/dev/null | head -n 1 || true)"
  if [ -z "$n" ]; then
    n="$(find "$root/patches" -maxdepth 1 -type f -name '*.patch' | wc -l | tr -d '[:space:]')"
  fi
  printf '%s\n' "$n"
}

result_line() {
  local name="$1"
  local rc="$2"
  local outfile="$3"
  local marker="$4"
  if [ "$rc" -eq 0 ] && [ -f "$outfile" ] && grep -q "$marker" "$outfile"; then
    printf '%s ok\n' "$name"
  else
    printf '%s FAILED\n' "$name"
  fi
}

test_names() {
  local f
  find "$root/tests" -maxdepth 1 -type f -name 'test_*.sh' | sort | while IFS= read -r f; do
    sed -n 's/^run \([A-Za-z0-9_][A-Za-z0-9_]*\) .*/\1/p' "$f"
  done
}

write_log() {
  local fb_ver toolchain count name
  [ "$log_written" -eq 0 ] || return 0
  log_written=1
  fb_ver="$(fluent_bit_version)"
  toolchain="$(toolchain_version)"
  count="$(patch_count)"
  mkdir -p "$(dirname "$log")"
  {
    printf 'fluent-bit: %s\n' "$fb_ver"
    printf 'patches: %s\n' "$count"
    printf 'qnx-toolchain: %s\n' "$toolchain"
    printf '\n'
    result_line check-patches "$cp_rc" "$workdir/check-patches.out" '^check-patches ok'
    result_line build "$build_rc" "$workdir/build.out" '^build ok:'
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if [ -f "$workdir/test-target.out" ] && grep -qx -- "$name FAILED" "$workdir/test-target.out"; then
        printf '%s FAILED\n' "$name"
      elif [ -f "$workdir/test-target.out" ] && grep -qx -- "$name ok" "$workdir/test-target.out"; then
        printf '%s ok\n' "$name"
      else
        printf '%s FAILED\n' "$name"
      fi
    done < <(test_names)
    result_line demo-check "$demo_rc" "$workdir/demo-check.out" '^demo check passed$'
  } >"$log"
  rm -rf "$workdir"
  return 0
}

trap 'write_log || true' EXIT

echo "== check-patches"
set +e
run_step "$workdir/check-patches.out" "$root/tools/check-patches.sh"
cp_rc=$?
set -e
if [ "$cp_rc" -eq 0 ]; then
  echo "check-patches ok"
else
  echo "check-patches FAILED"
fi

echo "== build --clean"
echo "configure and ninja logs: $FBQ_BUILD/configure.log $FBQ_BUILD/build.log"
set +e
run_step "$workdir/build.out" "$root/tools/build.sh" --clean
build_rc=$?
set -e
if [ "$build_rc" -eq 0 ]; then
  echo "build ok"
else
  echo "build FAILED"
fi

echo "== test-target"
set +e
run_step "$workdir/test-target.out" "$root/tools/test-target.sh"
test_rc=$?
set -e
if [ "$test_rc" -eq 0 ]; then
  echo "test-target ok"
else
  echo "test-target FAILED"
fi

# The demo starts its own agent. A test that left fluent-bit up would make
# that start fail for a reason the demo did not cause.
echo "== stop leftover agent"
bash "$root/tools/stop-agent.sh" || echo "stop-agent FAILED"

echo "== demo-check"
set +e
run_step "$workdir/demo-check.out" "$root/tools/demo-check.sh"
demo_rc=$?
set -e
if [ "$demo_rc" -eq 0 ]; then
  echo "demo-check ok"
else
  echo "demo-check FAILED"
fi

if [ "$cp_rc" -ne 0 ] || [ "$build_rc" -ne 0 ] || [ "$test_rc" -ne 0 ] || [ "$demo_rc" -ne 0 ]; then
  echo "test-all FAILED"
  exit 1
fi
echo "test-all ok"
exit 0
