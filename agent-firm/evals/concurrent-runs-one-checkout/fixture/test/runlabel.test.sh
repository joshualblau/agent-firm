#!/bin/sh
set -eu
here="$(dirname "$0")"
got="$(sh "$here/../src/runlabel.sh" 20260907T063536Z-close-retro-loose-ends)"
want="close-retro-loose-ends (20260907T063536Z)"
[ "$got" = "$want" ] || { echo "runlabel mismatch: '$got' != '$want'" >&2; exit 1; }

if sh "$here/../src/runlabel.sh" nodashes >/dev/null 2>&1; then
  echo "runlabel accepted a non-run-id" >&2; exit 1
fi
echo "ok runlabel"
