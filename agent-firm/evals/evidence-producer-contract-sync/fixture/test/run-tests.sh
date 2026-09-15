#!/bin/sh
# The full CI command for this fixture: the project's own trivial suite, then the golden
# producer-contract properties. Both must pass. Plain shell + python3 on purpose -- no node here.
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

echo "--- golden: evidence_produced producer contract stays in sync with the writer ---"
# WHICH CHECKOUT IS TESTED. The eval fixture is copied into a scratch directory that contains no
# copy of the firm, so the checker resolves the firm through `firm-ledger-log` on PATH. If that
# symlink points at a different checkout than the one under test (the hazard recorded in
# system-changes/20260803T095255Z-firm-tools-resolve-to-primary-checkout.md), export
# FIRM_CONTRACT_SYNC_ROOT=<checkout root> to pin it. The checker refuses to run at all rather than
# guessing when it can resolve neither.
# firm-python resolves the interpreter the firm's own ledger gate admits. Prefer it when the firm is
# reachable on PATH; fall back to python3 rather than skipping, because a skipped property must
# never read as a passing one.
if command -v firm-ledger-log >/dev/null 2>&1; then
  firm_bin_dir="$(cd -P "$(dirname "$(command -v firm-ledger-log)")" && pwd)"
else
  firm_bin_dir=""
fi
if [ -n "$firm_bin_dir" ] && [ -x "$firm_bin_dir/firm-python" ]; then
  # shellcheck disable=SC1090
  . "$firm_bin_dir/firm-python"
  firm_python "$here/producer-contract-sync.py" || fail=1
else
  python3 "$here/producer-contract-sync.py" || fail=1
fi

exit "$fail"
