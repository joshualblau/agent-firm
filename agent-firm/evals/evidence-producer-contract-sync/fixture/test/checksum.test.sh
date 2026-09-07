#!/bin/sh
set -eu
here="$(dirname "$0")"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf 'abc' > "$tmp"
got="$(sh "$here/../src/checksum.sh" "$tmp")"
want=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
[ "$got" = "$want" ] || { echo "checksum mismatch: $got != $want" >&2; exit 1; }
echo "ok checksum"
