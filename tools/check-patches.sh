#!/usr/bin/env bash
# Check the patch series in patches/ (or $FBQ_PATCH_DIR). Exits non-zero when:
#   - there are no patches
#   - a patch contains a NUL byte
#   - a patch contains CRLF line endings
#   - a patch has no "Signed-off-by: Name <email>" line
#   - a patch is not named NNNN-<component>-<summary>.patch, or numbers repeat
#   - a patch does not apply cleanly, in order, to a pristine extract of the pinned tarball
# Each patch is applied for real in a temporary tree after its dry run, so patch N is
# checked against the result of patches 1..N-1. Fuzz is not allowed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch_dir="${FBQ_PATCH_DIR:-$root/patches}"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

shopt -s nullglob
patches=("$patch_dir"/*.patch)
if [ "${#patches[@]}" -eq 0 ]; then
  echo "FAIL: no patches in $patch_dir" >&2
  exit 1
fi

# Static checks, one patch at a time.
prev=""
for p in "${patches[@]}"; do
  name="$(basename "$p")"
  if ! [[ "$name" =~ ^([0-9]{4})-[A-Za-z0-9_]+-[A-Za-z0-9._+-]+\.patch$ ]]; then
    bad "$name: name must look like NNNN-<component>-<short-summary>.patch"
  else
    num="${BASH_REMATCH[1]}"
    if [ "$num" = "$prev" ]; then bad "$name: patch number $num is used twice"; fi
    prev="$num"
  fi
  if [ "$(tr -cd '\0' < "$p" | wc -c)" -ne 0 ]; then
    bad "$name: contains a NUL byte"
  fi
  if [ "$(tr -cd '\r' < "$p" | wc -c)" -ne 0 ]; then
    bad "$name: contains CR (CRLF line endings)"
  fi
  if ! grep -aqE '^Signed-off-by: [^<>]+ <[^<>@ ]+@[^<>@ ]+>[[:space:]]*$' "$p"; then
    bad "$name: no Signed-off-by line"
  fi
done

# Apply in order to a pristine extract.
tarball="$("$root/tools/fetch-upstream.sh")"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fbq-check-patches.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
tar xzf "$tarball" -C "$tmp" --strip-components=1
for p in "${patches[@]}"; do
  name="$(basename "$p")"
  if ! out="$(cd "$tmp" && patch -p1 -F0 --dry-run --no-backup-if-mismatch < "$p" 2>&1)"; then
    bad "$name: does not apply cleanly (dry run)"
    echo "$out" | sed 's/^/    /' >&2
    # Later patches build on this one, so stop here instead of piling up noise.
    break
  fi
  (cd "$tmp" && patch -p1 -F0 --no-backup-if-mismatch < "$p" >/dev/null)
done

if [ "$fail" -ne 0 ]; then
  echo "check-patches: FAILED" >&2
  exit 1
fi
echo "check-patches ok (${#patches[@]} patches)"
