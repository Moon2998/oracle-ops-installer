#!/bin/bash
# Regenerates the library manifest (SHA-256 of every lib/*.sh listed there) inside oracle-ops-installer.sh.
#   tests/update-lib-digests.sh                 rewrite the block between "# BEGIN LIB MANIFEST" and "# END LIB MANIFEST"
#   tests/update-lib-digests.sh --check         change nothing; exit 1 if the block is stale or a lib/*.sh file is not listed
#   --root DIR                                  operate on another copy of the installer tree (default: this repository)
# The libraries and their order are the ones already listed in the block; to add a library, put a line
#   0000000000000000000000000000000000000000000000000000000000000000  lib/<name>.sh
# into the block (the loader refuses that digest) and run this script. No root, no network.
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    --root) [ $# -ge 2 ] || { echo "update-lib-digests: --root needs a directory" >&2; exit 2; }; root="$(cd "$2" && pwd)" || exit 2; shift 2 ;;
    *) echo "usage: update-lib-digests.sh [--check] [--root DIR]" >&2; exit 2 ;;
  esac
done
entry="$root/oracle-ops-installer.sh"
[ -f "$entry" ] || { echo "update-lib-digests: no $entry" >&2; exit 2; }
grep -qx '# BEGIN LIB MANIFEST' "$entry" && grep -qx '# END LIB MANIFEST' "$entry" || { echo "update-lib-digests: manifest markers not found in $entry" >&2; exit 2; }

# the listed libraries, in order: the second field of every quoted manifest line
listed="$(sed -n '/^# BEGIN LIB MANIFEST$/,/^# END LIB MANIFEST$/p' "$entry" | sed -n 's/^  "[0-9a-f]\{64\}  \(lib\/[a-z0-9-]*\.sh\)"$/\1/p')"
[ -n "$listed" ] || { echo "update-lib-digests: no library is listed in the manifest of $entry" >&2; exit 2; }

block="$(mktemp "${TMPDIR:-/tmp}/lib-manifest.XXXXXX")" || exit 2
trap 'rm -f -- "$block"' EXIT
{
  echo '# BEGIN LIB MANIFEST'
  echo 'LIB_MANIFEST=('
  while IFS= read -r rel; do
    [ -f "$root/$rel" ] && [ ! -L "$root/$rel" ] || { echo "update-lib-digests: $rel is missing or not a regular file" >&2; exit 2; }
    printf '  "%s  %s"\n' "$(sha256sum -- "$root/$rel" | cut -d' ' -f1)" "$rel"
  done <<< "$listed"
  echo ')'
  echo '# END LIB MANIFEST'
} > "$block" || exit 2

current="$(sed -n '/^# BEGIN LIB MANIFEST$/,/^# END LIB MANIFEST$/p' "$entry")"
rc=0
if [ "$current" != "$(cat "$block")" ]; then rc=1; fi

unlisted=""
for f in "$root"/lib/*.sh; do
  [ -e "$f" ] || continue
  rel="lib/$(basename "$f")"
  printf '%s\n' "$listed" | grep -qxF -- "$rel" || unlisted="$unlisted $rel"
done

if [ "$check" = 1 ]; then
  [ "$rc" = 0 ] || echo "STALE: the library manifest in oracle-ops-installer.sh does not match lib/*.sh; run tests/update-lib-digests.sh"
  [ -z "$unlisted" ] || { echo "UNLISTED library file(s) (never sourced):$unlisted"; rc=1; }
  [ "$rc" != 0 ] || echo "library manifest is current"
  exit "$rc"
fi

[ -z "$unlisted" ] || echo "note: not listed, never sourced:$unlisted"
if [ "$rc" = 0 ]; then echo "library manifest already current"; exit 0; fi
tmp="$(mktemp "${TMPDIR:-/tmp}/installer-entry.XXXXXX")" || exit 2
trap 'rm -f -- "$block" "$tmp"' EXIT
awk -v blockfile="$block" '
  /^# BEGIN LIB MANIFEST$/ { while ((getline line < blockfile) > 0) print line; skip = 1; next }
  /^# END LIB MANIFEST$/   { skip = 0; next }
  !skip { print }
' "$entry" > "$tmp" || exit 2
cat "$tmp" > "$entry" || exit 2     # same inode: owner and mode of the entry script are kept
echo "library manifest updated"
