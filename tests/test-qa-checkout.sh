#!/usr/bin/env bash
# tests/test-qa-checkout.sh — firm-qa-checkout materializes a clean worktree at the integration
# branch HEAD; refuses when that branch doesn't exist; re-running replaces the previous checkout.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QAC="$BIN/firm-qa-checkout"
NEW_RUN="$BIN/firm-new-run"

# ---------------------------------------------------------------------------
t_case "refuses clearly when the target branch doesn't exist"
repo="$(mk_repo)"
( cd "$repo" && "$NEW_RUN" no-integration fast_path >/dev/null )
assert_rc "exit 1 when integration/<run_id> was never created" 1 sh -c "cd '$repo' && '$QAC'"
assert_output "names the missing branch and the fix" "run bin/integrate first" sh -c "cd '$repo' && '$QAC'"

t_case "an explicit, nonexistent branch argument is refused the same way"
repo1b="$(mk_repo)"
assert_rc "exit 1" 1 sh -c "cd '$repo1b' && '$QAC' does-not-exist"

# ---------------------------------------------------------------------------
t_case "materializes a clean checkout at the integration branch HEAD"
repo2="$(mk_repo)"
( cd "$repo2" && "$NEW_RUN" checkout-basic fast_path >/dev/null )
run_id2="$(basename "$(cat "$repo2/.agent-firm/CURRENT_RUN")")"
( cd "$repo2" && git checkout -q -b "integration/$run_id2" && printf 'integrated\n' > result.txt && git add -A && git commit -qm integrated && git checkout -q main ) >/dev/null 2>&1
int_sha="$(sha_of "$repo2" "integration/$run_id2")"

out2="$( (cd "$repo2" && "$QAC") )"
qa_dir="$repo2/.agent-firm/qa-checkout/${run_id2}"
assert_ok "qa checkout dir exists"        sh -c "[ -d '$qa_dir' ]"
assert_file "the integrated file is there" "$qa_dir/result.txt"
assert_eq  "checkout HEAD matches the integration branch" "$int_sha" "$(sha_of "$qa_dir" HEAD)"
assert_output "reports it's a clean checkout, tells QA not to edit" "Do NOT edit source" \
  printf '%s' "$out2"
assert_ok "qa_checkout ledger event was logged" \
  sh -c "grep -q '\"event\":\"qa_checkout\"' '$repo2/.agent-firm/runs/$run_id2/run.jsonl'"

t_case "the checkout is truly a worktree of THIS repo, not a disconnected clone"
# --git-common-dir prints a path RELATIVE TO CWD, so it must be resolved from INSIDE each dir before
# comparing -- comparing the raw strings from two different CWDs compares unrelated relative paths.
abs_common_dir() { ( cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P ); }
assert_eq "qa checkout shares object storage with the origin repo (same git-common-dir)" \
  "$(abs_common_dir "$repo2")" "$(abs_common_dir "$qa_dir")"

# ---------------------------------------------------------------------------
t_case "re-running replaces the previous checkout rather than erroring or stacking"
# Can't `git checkout integration/<id>` again in the MAIN repo here: firm-qa-checkout already holds
# that branch checked out in the qa_dir linked worktree, and git refuses to check the same branch out
# twice. Commit the change INSIDE the existing qa_dir worktree instead -- that's a real advance of the
# integration branch, without needing to detach/reattach anything.
( cd "$qa_dir" && printf 'more\n' >> result.txt && git add -A && git commit -qm "more work" ) >/dev/null 2>&1
new_sha="$(sha_of "$repo2" "integration/$run_id2")"
assert_ne "fixture precondition: the branch actually moved" "$int_sha" "$new_sha"

assert_ok "second run succeeds (doesn't error on an existing checkout)" sh -c "cd '$repo2' && '$QAC'"
assert_eq "the checkout now reflects the NEW HEAD, not the stale one" "$new_sha" "$(sha_of "$qa_dir" HEAD)"

t_summary
