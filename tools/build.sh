#!/usr/bin/env bash
# Build Fluent Bit 5.2.0 for QNX 8.0 x86_64 with the patch series in patches/.
#
#   tools/build.sh [--clean]
#
# Steps: fetch the pinned tarball (cache, SHA-256 checked against UPSTREAM), check the
# patch series, extract to $FBQ_BUILD/src, apply patches/*.patch in order, configure with
# qnx/qnx-x86_64.cmake and qnx/cmake-options.txt, then ninja -j4.
# Result: $FBQ_BUILD/bin/fluent-bit (stripped; the unstripped one is next to it as
# fluent-bit.unstripped). Without --clean, an up-to-date source and build tree are reused;
# changed patches always trigger a fresh extract, because patches only apply to a pristine tree.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/tools/env.sh"
# shellcheck disable=SC1091
source "$root/UPSTREAM"

clean=0
case "${1:-}" in
  "") ;;
  --clean) clean=1 ;;
  *) echo "usage: tools/build.sh [--clean]" >&2; exit 2 ;;
esac

src="$FBQ_BUILD/src"
bld="$FBQ_BUILD/build"
jobs=4
mkdir -p "$FBQ_BUILD"

"$root/tools/check-patches.sh"
tarball="$("$root/tools/fetch-upstream.sh")"

# The source tree is valid for this exact tarball and this exact patch series.
src_stamp="$( { echo "$FB_SHA256"; cat "$root"/patches/*.patch; } | sha256sum | cut -d' ' -f1)"
if [ "$clean" = 1 ] || [ ! -f "$src/.fbq-stamp" ] || [ "$(cat "$src/.fbq-stamp")" != "$src_stamp" ]; then
  echo "== Extracting $(basename "$tarball") to $src"
  rm -rf "$src" "$bld"
  mkdir -p "$src"
  tar xzf "$tarball" -C "$src" --strip-components=1
  for p in "$root"/patches/*.patch; do
    echo "   applying $(basename "$p")"
    (cd "$src" && patch -p1 -F0 --no-backup-if-mismatch < "$p" >/dev/null)
  done
  echo "$src_stamp" > "$src/.fbq-stamp"
fi

# Plugin sources are not in the tarball. Copy them after every extract so a
# changed .c file is rebuilt by ninja without a second configure.
if [ -d "$root/plugins" ]; then
  find "$root/plugins" -type f -print | sort | while IFS= read -r plugin_file; do
    rel="${plugin_file#"$root/plugins/"}"
    mkdir -p "$src/plugins/$(dirname "$rel")"
    cp -f "$plugin_file" "$src/plugins/$rel"
  done
fi

# Plain option lines from the file (comments and blank lines dropped).
mapfile -t options < <(grep -Ev '^[[:space:]]*(#|$)' "$root/qnx/cmake-options.txt")

cfg_stamp="$( {
  cat "$root/qnx/qnx-x86_64.cmake" "$root/qnx/cmake-options.txt"
  echo "$src_stamp"
  if [ -d "$root/plugins" ]; then
    find "$root/plugins" -name CMakeLists.txt -print | sort | while IFS= read -r cmake_file; do
      cat "$cmake_file"
    done
  fi
} | sha256sum | cut -d' ' -f1)"
if [ ! -f "$bld/build.ninja" ] || [ ! -f "$bld/.fbq-cfg-stamp" ] || [ "$(cat "$bld/.fbq-cfg-stamp")" != "$cfg_stamp" ]; then
  echo "== Configuring (several minutes: bundled libraries are probed with qcc)"
  mkdir -p "$bld"
  cmake -S "$src" -B "$bld" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$root/qnx/qnx-x86_64.cmake" \
    "${options[@]}" > "$FBQ_BUILD/configure.log" 2>&1 \
    || { tail -40 "$FBQ_BUILD/configure.log" >&2; echo "configure failed, see $FBQ_BUILD/configure.log" >&2; exit 1; }
  # The CMake patch puts libsocket and libfsnotify into the probe link line. If a probe still
  # comes out negative, tail would silently lose inotify or the server would lose accept4.
  for v in FLB_HAVE_ACCEPT4 FLB_HAVE_INOTIFY FLB_HAVE_UNIX_SOCKET; do
    if ! grep -Eq "^$v:[A-Z]+=1$" "$bld/CMakeCache.txt"; then
      echo "configure probe $v was not detected (see $FBQ_BUILD/configure.log)" >&2
      rm -f "$bld/.fbq-cfg-stamp"
      exit 1
    fi
  done
  echo "$cfg_stamp" > "$bld/.fbq-cfg-stamp"
fi

echo "== Building (ninja -j$jobs)"
ninja -C "$bld" -j"$jobs" > "$FBQ_BUILD/build.log" 2>&1 \
  || { tail -60 "$FBQ_BUILD/build.log" >&2; echo "build failed, see $FBQ_BUILD/build.log" >&2; exit 1; }
tail -1 "$FBQ_BUILD/build.log"

mkdir -p "$FBQ_BUILD/bin"
for helper in "$root"/tests/helpers/*.c; do
  [ -f "$helper" ] || continue
  helper_name="$(basename "$helper" .c)"
  echo "== helper $helper_name"
  qcc -Vgcc_ntox86_64 -O2 -Wall -Wextra -Werror \
    -o "$FBQ_BUILD/bin/$helper_name" "$helper"
done

mkdir -p "$FBQ_BUILD/bin"
cp -f "$bld/bin/fluent-bit" "$FBQ_BUILD/bin/fluent-bit.unstripped"
ntox86_64-strip -o "$FBQ_BUILD/bin/fluent-bit" "$bld/bin/fluent-bit"
ls -l "$FBQ_BUILD/bin/fluent-bit"
echo "build ok: $FBQ_BUILD/bin/fluent-bit"
