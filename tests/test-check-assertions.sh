#!/usr/bin/env bash
# tests/test-check-assertions.sh — firm-check-assertions' assertion vocabulary, including the PR 2
# rebuild of no_default_branch_merge / final_gate_pending onto the run-baseline.json SHA comparison
# (fail-closed when that baseline can't be verified), and the PR 3 addition of qa_checkout_clean,
# which delegates to firm-qa-clean-check the same way traceability_passes delegates to
# firm-traceability-check — see tests/test-qa-clean-check.sh for that script's own direct coverage;
# the cases here exercise it specifically through the assertion-vocabulary path.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CA="$BIN/firm-check-assertions"
NEW_RUN="$BIN/firm-new-run"
LOG="$BIN/firm-ledger-log"
NEW_WT="$BIN/firm-new-worktree"
INTEGRATE="$BIN/firm-integrate"
QA_CO="$BIN/firm-qa-checkout"

write_assertions() { printf '%s\n' "$1" > "$2/a.yaml"; }

# ---------------------------------------------------------------------------
t_case "usage"
assert_rc "missing args -> exit 2" 2 "$CA"
assert_rc "one arg -> exit 2" 2 "$CA" foo.yaml

# ---------------------------------------------------------------------------
t_case "file_exists / file_absent"
repo="$(mk_repo)"
write_assertions 'assertions:
  - file_exists: seed.txt
  - file_absent: nope.txt' "$repo"
assert_rc "both pass" 0 "$CA" "$repo/a.yaml" "$repo"

write_assertions 'assertions:
  - file_exists: nope.txt' "$repo"
assert_rc "file_exists on a missing file FAILs" 1 "$CA" "$repo/a.yaml" "$repo"

# ---------------------------------------------------------------------------
t_case "artifact_exists / verdict_is / traceability_passes (unchanged vocabulary)"
repo2="$(mk_repo)"
( cd "$repo2" && "$NEW_RUN" ledger-check fast_path >/dev/null )
run_dir2="$repo2/$(cat "$repo2/.agent-firm/CURRENT_RUN")"
printf '{"verdict":"APPROVE"}\n' > "$run_dir2/08-qa-verdict.json"
write_assertions 'assertions:
  - artifact_exists: 08-qa-verdict.json
  - verdict_is: APPROVE' "$repo2"
assert_rc "both pass" 0 "$CA" "$repo2/a.yaml" "$repo2"

write_assertions 'assertions:
  - verdict_is: BLOCK' "$repo2"
assert_rc "verdict_is mismatch FAILs" 1 "$CA" "$repo2/a.yaml" "$repo2"

t_case "unknown assertion key FAILs, not silently ignored"
repo2b="$(mk_repo)"
( cd "$repo2b" && "$NEW_RUN" unknown-key fast_path >/dev/null )
write_assertions 'assertions:
  - not_a_real_assertion: true' "$repo2b"
assert_rc "unrecognized key fails the run" 1 "$CA" "$repo2b/a.yaml" "$repo2b"

# ---------------------------------------------------------------------------
t_case "no_default_branch_merge: baseline present, branch unchanged -> PASS"
repo3="$(mk_repo)"
( cd "$repo3" && "$NEW_RUN" ndm-clean fast_path >/dev/null )
write_assertions 'assertions:
  - no_default_branch_merge: true' "$repo3"
assert_rc "PASS" 0 "$CA" "$repo3/a.yaml" "$repo3"

t_case "no_default_branch_merge: branch advanced -> FAIL"
( cd "$repo3" && echo more >> seed.txt && git add -A && git commit -qm more ) >/dev/null 2>&1
assert_rc "FAIL" 1 "$CA" "$repo3/a.yaml" "$repo3"

t_case "no_default_branch_merge: baseline MISSING -> fail closed, never a silent PASS"
repo4="$(mk_repo)"
( cd "$repo4" && "$NEW_RUN" no-baseline fast_path >/dev/null )
run_dir4="$repo4/$(cat "$repo4/.agent-firm/CURRENT_RUN")"
rm -f "$run_dir4/run-baseline.json"
write_assertions 'assertions:
  - no_default_branch_merge: true' "$repo4"
assert_rc "fails closed (rc=1), not a silent pass" 1 "$CA" "$repo4/a.yaml" "$repo4"
assert_output "names why: cannot verify" "CANNOT VERIFY" "$CA" "$repo4/a.yaml" "$repo4"

t_case "no_default_branch_merge: baseline references a branch that doesn't exist locally -> fail closed"
repo4b="$(mk_repo)"
( cd "$repo4b" && "$NEW_RUN" bad-baseline fast_path >/dev/null )
run_dir4b="$repo4b/$(cat "$repo4b/.agent-firm/CURRENT_RUN")"
printf '{"default_branch":"does-not-exist","default_branch_start_sha":"deadbeef"}\n' > "$run_dir4b/run-baseline.json"
write_assertions 'assertions:
  - no_default_branch_merge: true' "$repo4b"
assert_rc "fails closed" 1 "$CA" "$repo4b/a.yaml" "$repo4b"
assert_output "names why: branch from baseline missing" "does not exist in this repo" "$CA" "$repo4b/a.yaml" "$repo4b"

# ---------------------------------------------------------------------------
t_case "final_gate_pending: no ledger event -> FAIL even though the branch is untouched"
repo5="$(mk_repo)"
( cd "$repo5" && "$NEW_RUN" no-event fast_path >/dev/null )
write_assertions 'assertions:
  - final_gate_pending: true' "$repo5"
assert_rc "FAILs without the event, regardless of branch state" 1 "$CA" "$repo5/a.yaml" "$repo5"
assert_output "logged=False shows in the detail" "logged=False" "$CA" "$repo5/a.yaml" "$repo5"

t_case "final_gate_pending: event logged + branch unchanged -> PASS"
repo6="$(mk_repo)"
( cd "$repo6" && "$NEW_RUN" with-event fast_path >/dev/null )
( cd "$repo6" && "$LOG" final_gate_pending >/dev/null )
write_assertions 'assertions:
  - final_gate_pending: true' "$repo6"
assert_rc "PASS" 0 "$CA" "$repo6/a.yaml" "$repo6"

t_case "final_gate_pending: event logged BUT the branch advanced anyway -> FAIL"
( cd "$repo6" && echo more >> seed.txt && git add -A && git commit -qm more ) >/dev/null 2>&1
assert_rc "logging the event does not override a real branch advance" 1 "$CA" "$repo6/a.yaml" "$repo6"

t_case "final_gate_pending: baseline missing -> fail closed (same as no_default_branch_merge)"
repo7="$(mk_repo)"
( cd "$repo7" && "$NEW_RUN" fgp-no-baseline fast_path >/dev/null )
run_dir7="$repo7/$(cat "$repo7/.agent-firm/CURRENT_RUN")"
( cd "$repo7" && "$LOG" final_gate_pending >/dev/null )
rm -f "$run_dir7/run-baseline.json"
write_assertions 'assertions:
  - final_gate_pending: true' "$repo7"
assert_rc "fails closed even with the event logged" 1 "$CA" "$repo7/a.yaml" "$repo7"
assert_output "same CANNOT VERIFY reason" "CANNOT VERIFY" "$CA" "$repo7/a.yaml" "$repo7"

# ---------------------------------------------------------------------------
t_case "no ledger at all -> both new assertions fail closed, not crash"
repo8="$(mk_repo)"
write_assertions 'assertions:
  - no_default_branch_merge: true
  - final_gate_pending: true' "$repo8"
assert_rc "both FAIL cleanly (no run ever started here)" 1 "$CA" "$repo8/a.yaml" "$repo8"
assert_output "no ledger found is named as the reason" "no run ledger found" "$CA" "$repo8/a.yaml" "$repo8"

# ---------------------------------------------------------------------------
t_case "qa_checkout_clean: missing checkout dir -> fails closed (CANNOT VERIFY), not a vacuous pass"
repo9="$(mk_repo)"
( cd "$repo9" && "$NEW_RUN" qcc-missing fast_path >/dev/null )
write_assertions 'assertions:
  - qa_checkout_clean: true' "$repo9"
assert_rc "fails closed" 1 "$CA" "$repo9/a.yaml" "$repo9"
assert_output "names why: cannot verify" "CANNOT VERIFY" "$CA" "$repo9/a.yaml" "$repo9"

# ---------------------------------------------------------------------------
t_case "qa_checkout_clean: real end-to-end pipeline (new-run -> new-worktree -> integrate -> qa-checkout)"
repo10="$(mk_repo)"
run_out10="$( (cd "$repo10" && "$NEW_RUN" qcc-e2e fast_path) )"
run_id10="$(basename "$run_out10")"
( cd "$repo10" && "$NEW_WT" implementer wo1 >/dev/null )
wt_dir10="$repo10/.agent-firm/worktrees/${run_id10}-implementer-wo1"
( cd "$wt_dir10" && printf 'work\n' > feature.txt && git add -A && git commit -qm wo1 ) >/dev/null 2>&1
( cd "$repo10" && "$INTEGRATE" >/dev/null )
( cd "$repo10" && "$QA_CO" >/dev/null )
write_assertions 'assertions:
  - qa_checkout_clean: true' "$repo10"

assert_rc "PASS on a real, clean QA checkout" 0 "$CA" "$repo10/a.yaml" "$repo10"

echo dirty > "$repo10/.agent-firm/qa-checkout/${run_id10}/leftover.txt"
assert_rc "FAILs once the real checkout is dirtied" 1 "$CA" "$repo10/a.yaml" "$repo10"

t_summary
