#!/usr/bin/env bash
# tests/test-check-assertions.sh — firm-check-assertions' assertion vocabulary, including the PR 2
# rebuild of no_default_branch_merge / final_gate_pending onto the run-baseline.json SHA comparison
# (fail-closed when that baseline can't be verified), and the PR 3 addition of qa_checkout_clean,
# which delegates to firm-qa-clean-check the same way traceability_passes delegates to
# firm-traceability-check — see tests/test-qa-clean-check.sh for that script's own direct coverage;
# the cases here exercise it specifically through the assertion-vocabulary path.
#
# Scope note: this file covers the assertion VOCABULARY (one case per verb, driving the real
# delegated scripts). The assertions.yaml PARSING layer — pyyaml vs the regex fallback, dropped
# entries, zero-assertion files — is covered separately in tests/test-check-assertions-parsing.sh.
# artifact_absent, test_passes and traceability_passes were added here because all three shipped with
# zero coverage: the traceability_passes branch could be deleted from firm-check-assertions outright
# and this file still reported 25/25 green.
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
# TITLE SCOPE: this case covers artifact_exists and verdict_is ONLY. It used to also claim
# traceability_passes, which appeared nowhere in its body — deleting the whole
# `elif k == "traceability_passes"` branch from firm-check-assertions left this file at 25/25 green.
# That verb now has its own cases further down, which do drive the real script.
t_case "artifact_exists / verdict_is (unchanged vocabulary)"
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

# ---------------------------------------------------------------------------
# artifact_absent — the negative counterpart of artifact_exists, and the verb most easily misused.
t_case "artifact_absent: absent artifact PASSes, present artifact FAILs"
repo2c="$(mk_repo)"
( cd "$repo2c" && "$NEW_RUN" artifact-absent fast_path >/dev/null )
run_dir2c="$repo2c/$(cat "$repo2c/.agent-firm/CURRENT_RUN")"
write_assertions 'assertions:
  - artifact_absent: 99-never-written.md' "$repo2c"
assert_rc "PASSes for an artifact this run never produced" 0 "$CA" "$repo2c/a.yaml" "$repo2c"

write_assertions 'assertions:
  - artifact_absent: 08-qa-verdict.json' "$repo2c"
assert_rc "FAILs for an artifact that IS in the ledger" 1 "$CA" "$repo2c/a.yaml" "$repo2c"

t_case "artifact_absent CANNOT express 'this stage never ran' for a template-seeded artifact"
# Pins why `- artifact_absent: 10-handoff.md` must NOT be used to prove "QA blocked, so no handoff was
# written": firm-new-run seeds every agent-firm/templates/* file into the ledger at run start, so
# 10-handoff.md exists from t=0 and that assertion fails on a perfectly correct run. Encoded as a test
# so the suggestion cannot be re-adopted without turning this red.
assert_file "precondition: firm-new-run really does seed 10-handoff.md at t=0" "$run_dir2c/10-handoff.md"
write_assertions 'assertions:
  - artifact_absent: 10-handoff.md' "$repo2c"
assert_rc "FAILs on a brand-new run where nothing has happened yet" 1 "$CA" "$repo2c/a.yaml" "$repo2c"

# ---------------------------------------------------------------------------
# test_passes — the escape-hatch verb the qa-blocks-broken-build eval leans on hardest.
t_case "test_passes: runs a real command, in the scratch repo, and reads its exit code"
repo2d="$(mk_repo)"
write_assertions 'assertions:
  - test_passes: test -f seed.txt' "$repo2d"
assert_rc "PASSes on a command that exits 0" 0 "$CA" "$repo2d/a.yaml" "$repo2d"
# Second axis: the SAME assertions file, pointed at a directory without seed.txt, must fail — that is
# what proves the command runs with cwd set to the scratch-repo argument rather than wherever the
# checker happens to have been invoked from.
plain2d="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; t_track "$plain2d"
assert_rc "the same command FAILs against a different dir -- cwd follows the repo argument" 1 \
  "$CA" "$repo2d/a.yaml" "$plain2d"

write_assertions 'assertions:
  - test_passes: test -f definitely-not-here.txt' "$repo2d"
assert_rc "FAILs on a command that exits non-zero" 1 "$CA" "$repo2d/a.yaml" "$repo2d"

t_case "test_passes: the shell-! negation form qa-blocks-broken-build's fixture-sanity check uses"
write_assertions 'assertions:
  - test_passes: "! test -f definitely-not-here.txt"' "$repo2d"
assert_rc "a negated command PASSes when the inner command genuinely fails" 0 "$CA" "$repo2d/a.yaml" "$repo2d"
write_assertions 'assertions:
  - test_passes: "! test -f seed.txt"' "$repo2d"
assert_rc "and FAILs when the inner command unexpectedly succeeds" 1 "$CA" "$repo2d/a.yaml" "$repo2d"

# ---------------------------------------------------------------------------
# traceability_passes — delegates to firm-traceability-check. Every case below drives that real
# script against a real ledger; none of them mocks it.
t_case "traceability_passes: every criterion covered -> PASS"
repo2e="$(mk_repo)"
( cd "$repo2e" && "$NEW_RUN" trace-verb fast_path >/dev/null )
run_dir2e="$repo2e/$(cat "$repo2e/.agent-firm/CURRENT_RUN")"
# Written out explicitly instead of relying on the seeded template, so firm-traceability-check's
# pyyaml path and its regex-fallback path both extract exactly these two ids.
printf '%s\n' 'criteria:' \
  '  - id: AC-001' '    statement: divide returns a quotient' \
  '  - id: AC-002' '    statement: divide throws on a zero divisor' > "$run_dir2e/01-acceptance-criteria.yaml"
printf '%s' '{"verdict":"APPROVE","acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"09-test-evidence/unit.log"},{"id":"AC-002","covered":"yes","evidence":"09-test-evidence/unit.log"}]}' \
  > "$run_dir2e/08-qa-verdict.json"
write_assertions 'assertions:
  - traceability_passes: true' "$repo2e"
assert_rc "PASS when the verdict covers every criterion" 0 "$CA" "$repo2e/a.yaml" "$repo2e"

t_case "traceability_passes: an UNCOVERED criterion -> FAIL (the verb is not a no-op)"
printf '%s' '{"verdict":"APPROVE","acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"09-test-evidence/unit.log"}]}' \
  > "$run_dir2e/08-qa-verdict.json"
assert_rc "FAILs while AC-002 is missing from the verdict's coverage" 1 "$CA" "$repo2e/a.yaml" "$repo2e"

t_case "traceability_passes: false INVERTS the check -- the declared value is read, not ignored"
write_assertions 'assertions:
  - traceability_passes: false' "$repo2e"
assert_rc "PASSes precisely because the traceability check itself fails" 0 "$CA" "$repo2e/a.yaml" "$repo2e"

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

# ===========================================================================================
# LEDGER-READING VERBS WHEN THERE IS NO LEDGER TO READ.
#
# Every verb that resolves a path through find_ledger() must FAIL when no ledger can be resolved:
# "I could not look" is not a result, and this script is the firm's own regression guard, so a
# fail-open here silently disarms every golden eval. Two verbs used to report PASS in that state:
#
#   artifact_absent — `not found` is trivially true when nothing was searched, so it PASSED on a
#     repo where nothing had ever run. Worse, `bool(led) and (... or glob(...))` SHORT-CIRCUITED the
#     recursive `.agent-firm/**` scan, so a real artifact planted outside any run directory was
#     also reported "absent" — a false negative on a file that demonstrably exists.
#   verdict_is — `os.path.join(led or "", "08-qa-verdict.json")` left a bare relative name, which
#     os.path.exists resolved against the CHECKER'S OWN CWD; a matching verdict lying in an
#     unrelated directory satisfied `verdict_is: APPROVE`.
#
# Both were reproduced live before the fix. Every case below asserts the CORRECT (fail-closed)
# behaviour — none of them pins the old pass, because a green test over a fail-open blesses it.
# ===========================================================================================

# Run the checker with a chosen CWD. The checker's own working directory is a real axis here (it is
# what verdict_is used to resolve against), so it has to be varied deliberately rather than
# inherited from wherever the suite happens to be started.
ca_in() { local _d="$1"; shift; ( cd "$_d" && "$CA" "$@" ); }

t_case "no ledger: artifact_absent fails closed, exactly as artifact_exists already did"
repo11="$(mk_repo)"
assert_no_file "precondition: this repo has no .agent-firm at all" "$repo11/.agent-firm"
write_assertions 'assertions:
  - artifact_absent: 08-qa-verdict.json' "$repo11"
assert_rc "FAILs -- nothing was searched, so nothing was proven absent" 1 "$CA" "$repo11/a.yaml" "$repo11"
assert_output "and names the reason" "CANNOT VERIFY (fail-closed): no run ledger" "$CA" "$repo11/a.yaml" "$repo11"
write_assertions 'assertions:
  - artifact_exists: 08-qa-verdict.json' "$repo11"
assert_rc "artifact_exists FAILs in the SAME state (regression guard on the branch already correct)" 1 \
  "$CA" "$repo11/a.yaml" "$repo11"

t_case "no ledger + the artifact IS present under .agent-firm/** : artifact_absent still FAILs"
repo12="$(mk_repo)"
mkdir -p "$repo12/.agent-firm/stray"
printf '{"verdict":"APPROVE"}\n' > "$repo12/.agent-firm/stray/08-qa-verdict.json"
assert_no_file "precondition: no CURRENT_RUN, so no ledger resolves" "$repo12/.agent-firm/CURRENT_RUN"
assert_no_file "precondition: and no runs/ directory to fall back to" "$repo12/.agent-firm/runs"
assert_file "precondition: but the artifact demonstrably EXISTS" "$repo12/.agent-firm/stray/08-qa-verdict.json"
write_assertions 'assertions:
  - artifact_absent: 08-qa-verdict.json' "$repo12"
assert_rc "FAILs -- an artifact that exists is never 'absent'" 1 "$CA" "$repo12/a.yaml" "$repo12"
assert_output "the .agent-firm/** scan runs even with no ledger, and names where it found the file" \
  "EXISTS at $repo12/.agent-firm/stray/08-qa-verdict.json" "$CA" "$repo12/a.yaml" "$repo12"

t_case "artifact_absent: the .agent-firm/** scan is still wired when a ledger DOES resolve"
repo13="$(mk_repo)"
( cd "$repo13" && "$NEW_RUN" absent-glob fast_path >/dev/null )
run_dir13="$repo13/$(cat "$repo13/.agent-firm/CURRENT_RUN")"
assert_no_file "precondition: 99-stray-only.md is NOT in the run ledger" "$run_dir13/99-stray-only.md"
mkdir -p "$repo13/.agent-firm/stray"
printf 'x\n' > "$repo13/.agent-firm/stray/99-stray-only.md"
write_assertions 'assertions:
  - artifact_absent: 99-stray-only.md' "$repo13"
assert_rc "FAILs on an artifact only the recursive scan can find" 1 "$CA" "$repo13/a.yaml" "$repo13"
# Discriminator: same ledger, same scan, a name that exists NOWHERE must still PASS. Without this,
# every case above would also be satisfied by a verb that had been broken into always failing.
write_assertions 'assertions:
  - artifact_absent: 99-nowhere-at-all.md' "$repo13"
assert_rc "and PASSes for a name in neither the ledger nor anywhere under .agent-firm/" 0 \
  "$CA" "$repo13/a.yaml" "$repo13"

t_case "no ledger: verdict_is does NOT resolve 08-qa-verdict.json against the checker's own CWD"
repo14="$(mk_repo)"
elsewhere14="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; t_track "$elsewhere14"
printf '{"verdict":"APPROVE"}\n' > "$elsewhere14/08-qa-verdict.json"
assert_no_file "precondition: the repo under test has no ledger" "$repo14/.agent-firm"
assert_file "precondition: a MATCHING verdict sits in an unrelated directory" "$elsewhere14/08-qa-verdict.json"
write_assertions 'assertions:
  - verdict_is: APPROVE' "$repo14"
assert_rc "FAILs when run FROM that unrelated directory -- a stranger's file is not this run's verdict" 1 \
  ca_in "$elsewhere14" "$repo14/a.yaml" "$repo14"
assert_output "and names the reason rather than reporting 'got APPROVE'" \
  "CANNOT VERIFY (fail-closed): no run ledger" ca_in "$elsewhere14" "$repo14/a.yaml" "$repo14"
# Same repo, different CWD: one that holds no verdict file at all. This FAILed before the fix too,
# but for the wrong reason ("got None" — it looked, in the wrong place, and found nothing). Assert
# the REASON, not just the code, so the two CWDs now agree on why.
assert_rc "still FAILs from a neutral CWD holding no verdict at all" 1 \
  ca_in "$repo14" "$repo14/a.yaml" "$repo14"
assert_output "and for the same fail-closed reason, not an incidental miss" \
  "CANNOT VERIFY (fail-closed): no run ledger" ca_in "$repo14" "$repo14/a.yaml" "$repo14"

t_case "verdict_is reads the LEDGER's verdict even when a different one sits in the CWD"
repo15="$(mk_repo)"
( cd "$repo15" && "$NEW_RUN" verdict-cwd fast_path >/dev/null )
run_dir15="$repo15/$(cat "$repo15/.agent-firm/CURRENT_RUN")"
printf '{"verdict":"BLOCK"}\n' > "$run_dir15/08-qa-verdict.json"
write_assertions 'assertions:
  - verdict_is: APPROVE' "$repo15"
assert_rc "FAILs: the ledger says BLOCK, and the APPROVE lying in the CWD does not override it" 1 \
  ca_in "$elsewhere14" "$repo15/a.yaml" "$repo15"
assert_output "the detail reports the LEDGER's value" "got BLOCK" \
  ca_in "$elsewhere14" "$repo15/a.yaml" "$repo15"
# Third axis: flip the LEDGER (not the CWD file, which is untouched and still says APPROVE) and the
# identical command PASSes -- so the failures above are the ledger being read, not the checker
# refusing everything launched from $elsewhere14.
printf '{"verdict":"APPROVE"}\n' > "$run_dir15/08-qa-verdict.json"
assert_rc "PASSes once the LEDGER says APPROVE, from that same unrelated CWD" 0 \
  ca_in "$elsewhere14" "$repo15/a.yaml" "$repo15"

t_case "traceability_passes: a failure names the criterion, not just an exit code"
# The child's stdout used to be discarded, so an eval failure printed `rc=1` and nothing else --
# neither the uncovered criterion nor the reason coverage could not be verified. repo2e's verdict
# (set further up) still omits AC-002.
write_assertions 'assertions:
  - traceability_passes: true' "$repo2e"
assert_rc "precondition: this run really does fail traceability" 1 "$CA" "$repo2e/a.yaml" "$repo2e"
assert_output "the uncovered criterion appears in the detail" "AC-002" "$CA" "$repo2e/a.yaml" "$repo2e"
tp_lines="$( "$CA" "$repo2e/a.yaml" "$repo2e" 2>&1 | wc -l | tr -d ' ' )"
assert_eq "the child's multi-line output is COLLAPSED onto the one result line, not pasted in" \
  "3" "$tp_lines"

t_summary
