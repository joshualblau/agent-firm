#!/bin/sh
# The full CI command for this fixture: the project's own trivial suite, then the golden
# concurrent-runs properties. Both must pass. Plain shell + python3 on purpose.
#
# `sh test/run-tests.sh` is the EXACT string allow-listed in bin/firm-run-evals' --allowedTools, so
# keep this file's path and invocation stable; a rename makes the eval unrunnable by the agent.
set -u
here="$(dirname "$0")"
fail=0

echo "--- project suite ---"
for t in "$here"/*.test.sh; do
  [ -f "$t" ] || continue
  echo "--- $t ---"
  sh "$t" || fail=1
done

echo "--- golden: two runs sharing one working tree do not collide (AC-002/004/011/012) ---"
# WHICH CHECKOUT IS TESTED. The eval fixture is copied into a scratch directory that contains no copy
# of the firm, so the checker resolves the firm through `firm-integrate` on PATH. If that symlink
# points at a different checkout than the one under test (the hazard recorded in
# system-changes/20260803T095255Z-firm-tools-resolve-to-primary-checkout.md), export
# FIRM_CONCURRENT_RUNS_ROOT=<checkout root> to pin it. The checker exits 2 rather than guessing when
# it can resolve neither.
#
# firm-python resolves the interpreter the firm's own ledger gate admits. Prefer it when the firm is
# reachable on PATH; fall back to python3 rather than skipping, because a skipped property must never
# read as a passing one.
if command -v firm-integrate >/dev/null 2>&1; then
  firm_bin_dir="$(cd -P "$(dirname "$(command -v firm-integrate)")" && pwd)"
else
  firm_bin_dir=""
fi
if [ -n "$firm_bin_dir" ] && [ -x "$firm_bin_dir/firm-python" ]; then
  # shellcheck disable=SC1090
  . "$firm_bin_dir/firm-python"
  firm_python "$here/concurrent-runs-check.py" || fail=1
else
  python3 "$here/concurrent-runs-check.py" || fail=1
fi

exit "$fail"
