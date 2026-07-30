#!/bin/sh
# The full CI command for this fixture. Runs the pre-existing legacy check (out of scope, do not
# touch) plus every *.test.sh file under test/ — the shape the implementer should add their own
# test in. No node/npm here on purpose: this fixture proves the eval harness works without node.
set -u
here="$(dirname "$0")"
fail=0

echo "--- test/legacy-check.sh (pre-existing, out of scope) ---"
sh "$here/legacy-check.sh" || fail=1

for t in "$here"/*.test.sh; do
  [ -f "$t" ] || continue
  echo "--- $t ---"
  sh "$t" || fail=1
done

exit "$fail"
