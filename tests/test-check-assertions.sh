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

# ===========================================================================================
# traceability_passes must CLASSIFY firm-traceability-check's exit code, not merely INVERT it.
#
# The verb was `check("traceability_passes", (r.returncode == 0) == (v.lower() == "true"), ...)`.
# With `traceability_passes: false` — the way an eval asserts "this run SHOULD fail traceability" —
# ANY non-zero exit satisfied it. A genuine coverage gap, a usage error, an unparseable verdict, a
# missing run dir and an outright crash were indistinguishable, so an eval passed when the checker
# merely blew up. Third instance of one defect class in this file's neighbourhood (the ASCII-locale
# inversion in firm-traceability-check, artifact_absent's vacuous pass above): A CHECK THAT CANNOT
# EVALUATE ITS INPUT MUST NEVER REPORT SUCCESS.
#
# Contract, from firm-traceability-check's header: 0 = evaluated/acceptable, 1 = evaluated/coverage
# INADEQUATE, anything else = CANNOT EVALUATE. Only 0 and 1 may satisfy this verb; anything else is
# a hard FAIL on BOTH expectations.
#
# TWO axes vary across the cases below and both matter: the DECLARED expectation (true / false) and
# the CHILD'S OUTCOME (covered / genuine gap / unevaluable). Varying only the first would leave the
# fail-open untouched; varying only the second would not show that `false` is where it bit.
#
# SEAM, stated rather than overclaimed: these cases drive the child to exit 2. The mapping from an
# unexpected CRASH to exit 2 lives in firm-traceability-check and is pinned there
# (tests/test-traceability-check.sh, "an UNEXPECTED internal error is exit 2"); it cannot be injected
# through this script, because the only injection point — PYTHONPATH — would break this script's own
# `import yaml` before the child ever runs. The branch exercised here is `rc not in (0, 1)`, which is
# the same branch any other unexpected code takes.
# ===========================================================================================

# stdout+stderr must NOT contain <needle>. (lib.sh has assert_output but no negative form.)
assert_not_output() {
  local desc="$1" needle="$2" out; shift 2
  out="$("$@" 2>&1)"
  case "$out" in
    *"$needle"*) _t_no "$desc" "unexpectedly found '$needle' in: $(_t_ctx "$out")" ;;
    *) _t_ok "$desc" ;;
  esac
}

# mk_trace_repo <slug> <criteria-content> <verdict-content> — a scratch repo with a real run ledger
# whose two traceability inputs are written EXPLICITLY over firm-new-run's seeded templates, so the
# condition under test is the only thing wrong with the ledger. Echoes the repo path.
mk_trace_repo() {
  local _slug="$1" _crit="$2" _verdict="$3" _r _run
  _r="$(mk_repo)"
  ( cd "$_r" && "$NEW_RUN" "$_slug" fast_path >/dev/null )
  _run="$_r/$(cat "$_r/.agent-firm/CURRENT_RUN")"
  printf '%s' "$_crit"    > "$_run/01-acceptance-criteria.yaml"
  printf '%s' "$_verdict" > "$_run/08-qa-verdict.json"
  printf '%s' "$_r"
}

GOOD_CRIT='criteria:
  - id: AC-001
  - id: AC-002'
GOOD_COV='{"verdict":"APPROVE","acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"e1"},{"id":"AC-002","covered":"yes","evidence":"e2"}]}'
BADBYTE="$(printf '\377')"

t_case "traceability_passes: false does NOT pass when the checker CANNOT EVALUATE"
# One repo per distinct cannot-evaluate condition firm-traceability-check defines. Every one of these
# satisfied `traceability_passes: false` before the fix.
tp_bad=""
tp_add() { tp_bad="$tp_bad$1|$2
"; }

r_nocrit="$(mk_trace_repo tp-nocrit "$GOOD_CRIT" "$GOOD_COV")"
rm -f "$r_nocrit/$(cat "$r_nocrit/.agent-firm/CURRENT_RUN")/01-acceptance-criteria.yaml"
tp_add "01-acceptance-criteria.yaml is missing" "$r_nocrit"

r_noverd="$(mk_trace_repo tp-noverd "$GOOD_CRIT" "$GOOD_COV")"
rm -f "$r_noverd/$(cat "$r_noverd/.agent-firm/CURRENT_RUN")/08-qa-verdict.json"
tp_add "08-qa-verdict.json is missing" "$r_noverd"

r_dircrit="$(mk_trace_repo tp-dircrit "$GOOD_CRIT" "$GOOD_COV")"
_dc="$r_dircrit/$(cat "$r_dircrit/.agent-firm/CURRENT_RUN")/01-acceptance-criteria.yaml"
rm -f "$_dc"; mkdir -p "$_dc"
tp_add "the criteria path exists but is a directory" "$r_dircrit"

tp_add "the verdict is not valid JSON" \
  "$(mk_trace_repo tp-badjson "$GOOD_CRIT" '{not json at all')"
tp_add "the verdict top level is not an object" \
  "$(mk_trace_repo tp-notobj "$GOOD_CRIT" '["not","an","object"]')"
tp_add "acceptance_criteria_coverage is not a list" \
  "$(mk_trace_repo tp-notlist "$GOOD_CRIT" '{"acceptance_criteria_coverage":{"AC-001":"yes"}}')"
tp_add "there are zero acceptance criteria" \
  "$(mk_trace_repo tp-nocrits 'task_slug: nothing-here
' '{"acceptance_criteria_coverage":[]}')"
tp_add "a coverage entry is malformed" \
  "$(mk_trace_repo tp-malformed "$GOOD_CRIT" \
     '{"acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"e"},"a bare string"]}')"
tp_add "a covered value is outside the schema enum" \
  "$(mk_trace_repo tp-badenum "$GOOD_CRIT" \
     '{"acceptance_criteria_coverage":[{"id":"AC-001","covered":"mostly","evidence":"e"},{"id":"AC-002","covered":"yes","evidence":"e"}]}')"
tp_add "the criteria file is not valid UTF-8" \
  "$(mk_trace_repo tp-badutf8 "criteria:
  - id: AC-001
    statement: \"a lone ${BADBYTE} byte\"" "$GOOD_COV")"

while IFS='|' read -r _lbl _r; do
  [ -n "$_lbl" ] || continue
  write_assertions 'assertions:
  - traceability_passes: false' "$_r"
  assert_rc "false must NOT be satisfied by a checker that could not evaluate: $_lbl" 1 \
    "$CA" "$_r/a.yaml" "$_r"
  assert_output "and says WHY it refused: $_lbl" \
    "CANNOT VERIFY (fail-closed): firm-traceability-check reached no coverage verdict" \
    "$CA" "$_r/a.yaml" "$_r"
  # The other expectation, same state: `true` must fail too. A fix that merely flipped the polarity
  # would show up here.
  write_assertions 'assertions:
  - traceability_passes: true' "$_r"
  assert_rc "true also fails in that same state: $_lbl" 1 "$CA" "$_r/a.yaml" "$_r"
done <<EOF
$tp_bad
EOF

t_case "traceability_passes: false STILL passes on a GENUINE coverage failure (not made unsatisfiable)"
# The load-bearing discriminator. If closing the fail-open had made `false` unsatisfiable, every eval
# that inverts this gate would silently break — so the exit-1 class is pinned here, in the verb, with
# the same fixture shape as the cannot-evaluate cases above and only the defect changed.
r_gap="$(mk_trace_repo tp-realgap "$GOOD_CRIT" \
  '{"verdict":"APPROVE","acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"e1"}]}')"
write_assertions 'assertions:
  - traceability_passes: false' "$r_gap"
assert_rc "PASSes: AC-002 is genuinely uncovered, and the checker said so" 0 "$CA" "$r_gap/a.yaml" "$r_gap"
assert_output "the child's own words still reach the detail (not regressed)" "AC-002" \
  "$CA" "$r_gap/a.yaml" "$r_gap"
assert_not_output "and it is NOT reported as unevaluable" "CANNOT VERIFY" "$CA" "$r_gap/a.yaml" "$r_gap"
write_assertions 'assertions:
  - traceability_passes: true' "$r_gap"
assert_rc "and true FAILs on that same gap" 1 "$CA" "$r_gap/a.yaml" "$r_gap"

t_case "traceability_passes: covered/unevaluable/gapped are three DIFFERENT results, not two"
# Same assertions file (`false`), three ledger states. Without this, "false fails on a bad ledger"
# could be satisfied by a verb that had simply been broken into always failing.
r_full="$(mk_trace_repo tp-full "$GOOD_CRIT" "$GOOD_COV")"
write_assertions 'assertions:
  - traceability_passes: false' "$r_full"
assert_rc "false FAILs on a fully covered run" 1 "$CA" "$r_full/a.yaml" "$r_full"
write_assertions 'assertions:
  - traceability_passes: true' "$r_full"
assert_rc "true PASSes on that same fully covered run" 0 "$CA" "$r_full/a.yaml" "$r_full"

t_case "traceability_passes: NO LEDGER is not a coverage verdict either"
# `subprocess.run([tc, led or repo])` handed the SCRATCH-REPO ROOT to the child as though it were a
# run directory when no ledger resolved. A criteria/verdict pair lying at the repo root was then read
# as this run's coverage — the same shape as verdict_is' CWD bug closed further up, and it pointed
# the dangerous way: a run that produced no ledger at all could satisfy `traceability_passes: true`.
repo16="$(mk_repo)"
printf '%s' "$GOOD_CRIT" > "$repo16/01-acceptance-criteria.yaml"
printf '%s' "$GOOD_COV"  > "$repo16/08-qa-verdict.json"
assert_no_file "precondition: no run ever started here" "$repo16/.agent-firm"
assert_file "precondition: but a fully-covered pair sits at the repo ROOT" "$repo16/08-qa-verdict.json"
write_assertions 'assertions:
  - traceability_passes: true' "$repo16"
assert_rc "true FAILs -- stray root files are not this run's coverage" 1 "$CA" "$repo16/a.yaml" "$repo16"
assert_output "and names the reason" "CANNOT VERIFY (fail-closed): no run ledger" \
  "$CA" "$repo16/a.yaml" "$repo16"
write_assertions 'assertions:
  - traceability_passes: false' "$repo16"
assert_rc "false FAILs in that same state -- fail-closed on both expectations" 1 \
  "$CA" "$repo16/a.yaml" "$repo16"

t_summary
