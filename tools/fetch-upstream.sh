#!/usr/bin/env bash
# Print the path of the pinned upstream Fluent Bit tarball, downloading it into the cache
# ($FBQ_TARBALL_CACHE, default ~/.cache/fluent-bit-qnx) only when it is missing or its
# SHA-256 differs from UPSTREAM. Progress goes to stderr; stdout is just the path.
# Needs no QNX SDP, so tools/check-patches.sh can use it on any Linux.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/UPSTREAM"
cache="${FBQ_TARBALL_CACHE:-$HOME/.cache/fluent-bit-qnx}"
tarball="$cache/fluent-bit-$FB_VERSION.tar.gz"

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

if [ -f "$tarball" ] && [ "$(sha_of "$tarball")" = "$FB_SHA256" ]; then
  echo "$tarball"
  exit 0
fi

mkdir -p "$cache"
tmp="$tarball.part.$$"
trap 'rm -f "$tmp"' EXIT
echo "Downloading $FB_URL" >&2
curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$FB_URL" >&2
got="$(sha_of "$tmp")"
if [ "$got" != "$FB_SHA256" ]; then
  echo "SHA-256 mismatch for $FB_URL" >&2
  echo "  expected $FB_SHA256" >&2
  echo "  got      $got" >&2
  echo "  (GitHub archives are not promised byte-stable; upstream commit is $FB_COMMIT)" >&2
  exit 1
fi
mv -f "$tmp" "$tarball"
trap - EXIT
echo "$tarball"
