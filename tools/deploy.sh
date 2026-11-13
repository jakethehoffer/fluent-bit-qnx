#!/usr/bin/env bash
# Copy the built fluent-bit to the QNX target and print its path on the target.
#
#   tools/deploy.sh
#
# Layout under $FBQ_TARGET_DIR on the target:
#   bin/fluent-bit   the stripped binary from $FBQ_BUILD/bin
#   lib/             runtime libraries the target image lacks (listed in qnx/target-libs.txt),
#                    copied from $QNX_TARGET/x86_64 on this host, never stored in the repo
# Run fluent-bit there with LD_LIBRARY_PATH=$FBQ_TARGET_DIR/lib. The script checks that the
# binary starts with that setting, and fails with the missing library if it does not.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/tools/env.sh"

bin="$FBQ_BUILD/bin/fluent-bit"
[ -f "$bin" ] || { echo "no $bin: run tools/build.sh first" >&2; exit 1; }
dir="$FBQ_TARGET_DIR"

fbq_ssh "mkdir -p $dir/bin $dir/lib"

# Copy under a new name and rename: QNX can keep a program file busy for a moment after
# its last process exited, so overwriting the previous binary in place may fail.
fbq_scp "$bin" "$dir/bin/fluent-bit.new" >/dev/null
fbq_ssh "chmod 755 $dir/bin/fluent-bit.new && mv -f $dir/bin/fluent-bit.new $dir/bin/fluent-bit"

for extra in memhog spinner slog2_emit; do
  host_extra="$FBQ_BUILD/bin/$extra"
  [ -f "$host_extra" ] || continue
  fbq_scp "$host_extra" "$dir/bin/$extra.new" >/dev/null
  fbq_ssh "chmod 755 $dir/bin/$extra.new && mv -f $dir/bin/$extra.new $dir/bin/$extra"
  echo "deployed helper $extra" >&2
done

while IFS= read -r lib; do
  lib="${lib%%#*}"
  lib="$(echo "$lib" | tr -d '[:space:]')"
  [ -n "$lib" ] || continue
  [ -f "$QNX_TARGET/x86_64/$lib" ] || { echo "target-libs.txt: $QNX_TARGET/x86_64/$lib not found" >&2; exit 1; }
  fbq_scp "$QNX_TARGET/x86_64/$lib" "$dir/lib/$(basename "$lib").new" >/dev/null
  fbq_ssh "mv -f $dir/lib/$(basename "$lib").new $dir/lib/$(basename "$lib")"
  echo "deployed lib $(basename "$lib")" >&2
done < "$root/qnx/target-libs.txt"

if ! out="$(fbq_ssh "LD_LIBRARY_PATH=$dir/lib $dir/bin/fluent-bit --version" 2>&1)"; then
  echo "fluent-bit does not start on the target:" >&2
  echo "$out" >&2
  echo "A missing library belongs in qnx/target-libs.txt (path relative to \$QNX_TARGET/x86_64)." >&2
  exit 1
fi
echo "$out" | head -1 >&2
echo "$dir/bin/fluent-bit"
