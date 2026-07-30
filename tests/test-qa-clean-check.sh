#!/usr/bin/env bash
# tests/test-qa-clean-check.sh — firm-qa-clean-check: what it actually proves (no visible changes),
# what it doesn't (read-only), and its fail-closed behavior on a checkout that can't be inspected.
#
# The name matters: this is NOT read-only enforcement. It is one honest, cheap signal. Every case
# below exercises the real script against a real git checkout, never a mock.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QCC="$BIN/firm-qa-clean-check"

# ---------------------------------------------------------------------------
t_case "missing directory -> CANNOT VERIFY, fails closed (rc=2), not a vacuous pass"
repo="$(mk_repo)"
assert_rc "exit 2 on a directory that doesn't exist" 2 "$QCC" "$repo/does-not-exist"
assert_output "names the reason" "CANNOT VERIFY" "$QCC" "$repo/does-not-exist"
assert_output "names the fix" "firm-qa-checkout" "$QCC" "$repo/does-not-exist"

# ---------------------------------------------------------------------------
t_case "a directory that exists but is not a git checkout -> CANNOT VERIFY (rc=2), not a false pass"
plain="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $plain"
assert_rc "exit 2, not a silent pass" 2 "$QCC" "$plain"
assert_output "names the git-status failure" "git status" "$QCC" "$plain"

# ---------------------------------------------------------------------------
t_case "a real, clean checkout -> PASS (rc=0)"
repo2="$(mk_repo)"
( cd "$repo2" && git worktree add -q -b integration/probe qa-wt ) >/dev/null 2>&1
assert_rc "exit 0" 0 "$QCC" "$repo2/qa-wt"
assert_output "says clean" "clean" "$QCC" "$repo2/qa-wt"

# ---------------------------------------------------------------------------
t_case "a modified TRACKED file -> DIRTY (rc=1)"
( cd "$repo2" && echo more >> qa-wt/seed.txt )
assert_rc "exit 1" 1 "$QCC" "$repo2/qa-wt"
assert_output "shows the modified file" "seed.txt" "$QCC" "$repo2/qa-wt"
( cd "$repo2" && git -C qa-wt checkout -- seed.txt ) >/dev/null 2>&1

# ---------------------------------------------------------------------------
t_case "an UNTRACKED file -> DIRTY (rc=1) -- proves this is NOT just a tracked-file diff"
echo new > "$repo2/qa-wt/leftover.txt"
assert_rc "exit 1 on an untracked file too" 1 "$QCC" "$repo2/qa-wt"
assert_output "shows the untracked file" "leftover.txt" "$QCC" "$repo2/qa-wt"
rm -f "$repo2/qa-wt/leftover.txt"

# ---------------------------------------------------------------------------
t_case "clean again after cleanup -> PASS (rc=0) -- confirms the fixture, not a stuck FAIL"
assert_rc "exit 0" 0 "$QCC" "$repo2/qa-wt"

# ---------------------------------------------------------------------------
t_case "no-arg form resolves the exact path firm-qa-checkout creates"
repo3="$(mk_repo)"
mk_run "$repo3" "runid-clean-check"
( cd "$repo3" && git worktree add -q -b "integration/runid-clean-check" \
    ".agent-firm/qa-checkout/runid-clean-check" ) >/dev/null 2>&1
assert_rc "resolves via CURRENT_RUN and passes" 0 sh -c "cd '$repo3' && '$QCC'"

echo dirty > "$repo3/.agent-firm/qa-checkout/runid-clean-check/x.txt"
assert_rc "resolves via CURRENT_RUN and correctly fails" 1 sh -c "cd '$repo3' && '$QCC'"

# ---------------------------------------------------------------------------
t_case "a firm-ledger-log event is recorded for every outcome"
repo4="$(mk_repo)"
mk_run "$repo4" "runid-ledger"
( cd "$repo4" && git worktree add -q -b "integration/runid-ledger" \
    ".agent-firm/qa-checkout/runid-ledger" ) >/dev/null 2>&1
( cd "$repo4" && "$QCC" ) >/dev/null
assert_output "clean status logged" '"event":"qa_clean_check","status":"clean"' \
  cat "$repo4/.agent-firm/runs/runid-ledger/run.jsonl"

t_summary
