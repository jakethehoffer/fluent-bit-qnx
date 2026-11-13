#!/usr/bin/env bash
# Run every tests/test_*.sh on the QNX target. Prints "<name> ok" or "<name> FAILED".
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/tools/env.sh"

shopt -s nullglob
tests=("$root"/tests/test_*.sh)
if [ "${#tests[@]}" -eq 0 ]; then
  echo "no tests FAILED"
  exit 1
fi

fail=0
for t in "${tests[@]}"; do
  if ! bash "$t"; then
    fail=1
  fi
done
exit "$fail"
