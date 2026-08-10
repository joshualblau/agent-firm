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
assert_output "names the missing branch and the fix" "run firm-integrate first" sh -c "cd '$repo' && '$QAC'"
# The remediation the message names has to be a command that EXISTS. It used to say `bin/integrate`,
# which has never been a file in this repo — a dead-end instruction at the exact moment the operator
# is stuck. Two assertions, because "names the right thing" and "the right thing is real" are
# different failures: a rename could satisfy the string match while still pointing at nothing.
assert_file "the remediation it names is a real script" "$BIN/firm-integrate"
assert_ok "does not point at the nonexistent bin/integrate" \
  sh -c "cd '$repo' && ! '$QAC' 2>&1 | grep -q 'bin/integrate'"

t_case "an explicit, nonexistent branch argument is refused the same way"
repo1b="$(mk_repo)"
( cd "$repo1b" && "$NEW_RUN" explicit-missing fast_path >/dev/null )
assert_rc "non-integration names are rejected before resolution" 2 sh -c "cd '$repo1b' && '$QAC' does-not-exist"
assert_rc "existing main can never be captured as the QA candidate" 2 sh -c "cd '$repo1b' && '$QAC' main"

t_case "integration candidate must descend from the immutable full accepted base"
repo1c="$(mk_repo)"
( cd "$repo1c" && "$NEW_RUN" unrelated fast_path >/dev/null )
id1c="$(basename "$(cat "$repo1c/.agent-firm/CURRENT_RUN")")"
( cd "$repo1c" && git checkout -q --orphan unrelated-root && git rm -q -rf . && printf 'other\n' > other.txt && git add other.txt && git commit -qm unrelated && git branch "integration/$id1c" && git checkout -q main )
assert_rc "unrelated integration history is rejected" 1 sh -c "cd '$repo1c' && '$QAC'"
python3 - "$repo1c/.agent-firm/runs/$id1c/run-metadata.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["accepted_base_sha"]=d["accepted_base_sha"][:7]; json.dump(d,open(p,"w"))
PY
assert_rc "abbreviated accepted base is rejected" 2 sh -c "cd '$repo1c' && '$QAC'"

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
candidate="$repo2/.agent-firm/runs/$run_id2/09-test-evidence/qa-candidate.json"
assert_file "candidate identity is persisted" "$candidate"
assert_eq "candidate SHA is full and exact" "$int_sha" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidate_sha"])' "$candidate")"
assert_eq "candidate generation starts at one" 1 "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["generation"])' "$candidate")"
assert_eq "candidate metadata mode is 600" 600 "$(stat -f '%Lp' "$candidate" 2>/dev/null || stat -c '%a' "$candidate")"
assert_eq "QA checkout is detached" "" "$(git -C "$qa_dir" branch --show-current)"

t_case "the checkout is truly a worktree of THIS repo, not a disconnected clone"
# --git-common-dir prints a path RELATIVE TO CWD, so it must be resolved from INSIDE each dir before
# comparing -- comparing the raw strings from two different CWDs compares unrelated relative paths.
abs_common_dir() { ( cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P ); }
assert_eq "qa checkout shares object storage with the origin repo (same git-common-dir)" \
  "$(abs_common_dir "$repo2")" "$(abs_common_dir "$qa_dir")"

# ---------------------------------------------------------------------------
t_case "re-running replaces the previous checkout rather than erroring or stacking"
# The QA checkout is detached by design. Create a new commit there, then advance only the source ref;
# the persisted first candidate remains immutable until a deliberate second capture.
( cd "$qa_dir" && printf 'more\n' >> result.txt && git add -A && git commit -qm "more work" && \
  git update-ref "refs/heads/integration/$run_id2" HEAD ) >/dev/null 2>&1
new_sha="$(sha_of "$repo2" "integration/$run_id2")"
assert_ne "fixture precondition: the branch actually moved" "$int_sha" "$new_sha"

assert_ok "second run succeeds (doesn't error on an existing checkout)" sh -c "cd '$repo2' && '$QAC'"
assert_eq "the checkout now reflects the NEW HEAD, not the stale one" "$new_sha" "$(sha_of "$qa_dir" HEAD)"
assert_eq "generation increments on deliberate recapture" 2 "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["generation"])' "$candidate")"

t_case "candidate capture refuses concurrent or redirected metadata state"
repo3="$(mk_repo)"
( cd "$repo3" && "$NEW_RUN" checkout-lock fast_path >/dev/null )
id3="$(basename "$(cat "$repo3/.agent-firm/CURRENT_RUN")")"
( cd "$repo3" && git branch "integration/$id3" )
run3="$repo3/.agent-firm/runs/$id3"
mkdir "$run3/.qa-checkout.lock"
assert_rc "existing capture lock blocks" 1 sh -c "cd '$repo3' && '$QAC'"
rmdir "$run3/.qa-checkout.lock"
mkdir -p "$run3/09-test-evidence"
printf '{}\n' > "$run3/09-test-evidence/qa-candidate.json"
assert_rc "malformed prior generation blocks instead of resetting" 1 sh -c "cd '$repo3' && '$QAC'"
assert_eq "malformed prior metadata remains byte-identical" "{}" "$(cat "$run3/09-test-evidence/qa-candidate.json")"

t_case "CURRENT_RUN lexical traversal is rejected before normalization"
repo4="$(mk_repo)"
( cd "$repo4" && "$NEW_RUN" checkout-traversal fast_path >/dev/null )
id4="$(basename "$(cat "$repo4/.agent-firm/CURRENT_RUN")")"
( cd "$repo4" && git branch "integration/$id4" )
printf '.agent-firm/runs/../runs/%s\n' "$id4" > "$repo4/.agent-firm/CURRENT_RUN"
assert_rc "contained-looking traversal is rejected" 2 sh -c "cd '$repo4' && '$QAC'"

t_summary
