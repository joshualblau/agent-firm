#!/usr/bin/env bash
# tests/test-integrate.sh — regression tests for the firm-integrate default-branch escape.
#
# The bug: firm-integrate ran under `set -uo pipefail` (no -e) and discarded the exit code of
# `git switch`. When the switch failed — an existing integration branch that conflicts with local
# changes, or one already checked out in a linked worktree — the script carried on and merged every
# wt/* branch into whatever was checked out. With the Lead sitting on `main`, that is an autonomous
# merge to the default branch: never-rule #1, and invisible to the permission layer because
# Bash(firm-integrate:*) is allow-listed while Bash(git merge:*) is only `ask`.
#
# Every case below asserts the default branch SHA is unchanged. Run this file against the pre-fix
# script and cases A/B/C fail loudly — that is the point.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN_ID="20260728T120000Z-testrun"

integrate() { r="$1"; shift; ( cd "$r" && "$BIN/firm-integrate" "$@" ); }

# ---------------------------------------------------------------------------
t_case "refuses a target outside integration/* (positive allowlist)"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 feature.txt "wo1 work"
before="$(sha_of "$repo" main)"

assert_rc "explicit 'main' target is refused" 2 integrate "$repo" main
assert_eq "main SHA unchanged after refusal" "$before" "$(sha_of "$repo" main)"

assert_rc "explicit 'release/1.0' target is refused" 2 integrate "$repo" release/1.0
assert_eq "main SHA unchanged after second refusal" "$before" "$(sha_of "$repo" main)"

# ---------------------------------------------------------------------------
t_case "existing integration branch + conflicting local changes → switch fails, must not merge here"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
(
  cd "$repo"
  printf 'base\n' > shared.txt && git add -A && git commit -qm base
  git checkout -q -b "integration/$RUN_ID"
  printf 'from-integration\n' > shared.txt && git add -A && git commit -qm int
  git checkout -q main
) >/dev/null 2>&1
mk_wt_branch "$repo" "$RUN_ID" wo1 feature.txt "wo1 work"
# Dirty the tree LAST: mk_wt_branch runs `git add -A`, so anything uncommitted before it gets
# swallowed into the work-order branch and the tree is clean again by the time integrate runs.
( cd "$repo" && printf 'dirty-local\n' > shared.txt )
assert_output "fixture precondition: switch to the integration branch really does fail" \
  "would be overwritten" sh -c "cd '$repo' && git switch 'integration/$RUN_ID' 2>&1"
before="$(sha_of "$repo" main)"

assert_fail "aborts when it cannot reach the integration branch" integrate "$repo"
assert_eq "main SHA unchanged (the actual bug)" "$before" "$(sha_of "$repo" main)"
assert_eq "still on main, nothing merged into it" "main" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"

# ---------------------------------------------------------------------------
t_case "integration branch checked out in a linked worktree → switch fails, must not merge here"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 feature.txt "wo1 work"
linked="$(mk_linked_worktree "$repo" "integration/$RUN_ID")"
assert_file "fixture precondition: the linked worktree really exists" "$linked"
before="$(sha_of "$repo" main)"

assert_fail "aborts when the branch is held by another worktree" integrate "$repo"
assert_eq "main SHA unchanged" "$before" "$(sha_of "$repo" main)"
assert_eq "still on main" "main" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"

# ---------------------------------------------------------------------------
t_case "happy path: creates integration/<run_id> and merges the work-order branches"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 alpha.txt "alpha"
mk_wt_branch "$repo" "$RUN_ID" wo2 beta.txt  "beta"
before="$(sha_of "$repo" main)"

assert_ok "integrates cleanly" integrate "$repo"
assert_eq "HEAD is the integration branch" "integration/$RUN_ID" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
assert_file "wo1 content present" "$repo/alpha.txt"
assert_file "wo2 content present" "$repo/beta.txt"
assert_eq "main SHA unchanged by a successful integration" "$before" "$(sha_of "$repo" main)"
assert_output "handoff names immutable stage-summary publisher" \
  "firm-integration-summary --stage integrate/<stage-instance>" integrate "$repo"

# ---------------------------------------------------------------------------
t_case "conflict path: reports the conflict, aborts the merge, leaves the tree clean"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
(
  cd "$repo"
  printf 'base\n' > shared.txt && git add -A && git commit -qm base
) >/dev/null 2>&1
mk_wt_branch "$repo" "$RUN_ID" wo1 shared.txt "wo1 version"
mk_wt_branch "$repo" "$RUN_ID" wo2 shared.txt "wo2 version"
before="$(sha_of "$repo" main)"

assert_fail "non-zero exit when a merge conflicts" integrate "$repo"
assert_output "conflict is surfaced, not swallowed" "CONFLICT" integrate "$repo"
assert_eq "no merge left in progress" "" "$( (cd "$repo" && git status --porcelain --untracked-files=no) )"
assert_eq "main SHA unchanged" "$before" "$(sha_of "$repo" main)"

# ---------------------------------------------------------------------------
t_case "no work-order branches is a clean no-op"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
before="$(sha_of "$repo" main)"

assert_ok "exits 0 with nothing to integrate" integrate "$repo"
assert_eq "main SHA unchanged" "$before" "$(sha_of "$repo" main)"

# ===========================================================================
# WO-3 · the explicit --run selector.
#
# Everything ABOVE this line is pre-existing and deliberately unmodified — AC-006 is the claim that
# adding a selector changed nothing about the forms that already worked, and a suite edited to
# accommodate the change cannot make that claim.
#
# firm-integrate makes TWO selections from the run id, and until now both came from the ambient
# pointer: WHICH BRANCHES it merges (the `wt/<run_id>-*` glob) and WHICH RUN'S LEDGER records that
# it did (the firm-ledger-log call). Threading --run into only the first is the dangerous partial
# fix, because a run that merges the right branches and files the evidence under another run looks
# entirely correct from the outside. Both halves are asserted below, separately.
# ===========================================================================
RUN_A="20260907T110000Z-run-alpha"
RUN_B="20260907T110000Z-run-bravo"

# two_runs <repo> — runs A and B both exist, both have a work-order branch, CURRENT_RUN names B.
two_runs() {
  mk_run "$1" "$RUN_A"
  mk_run "$1" "$RUN_B"          # mk_run rewrites CURRENT_RUN, so B is the ambient answer
  mk_wt_branch "$1" "$RUN_A" wo1 alpha.txt "alpha work"
  mk_wt_branch "$1" "$RUN_B" wo1 bravo.txt "bravo work"
}

t_case "WO-3/AC-002 · --run names run A while CURRENT_RUN names run B: only A's branches are merged"
repo="$(mk_repo)"
two_runs "$repo"
assert_eq "fixture precondition: the ambient pointer really names B" \
  "$RUN_B" "$(basename "$(cat "$repo/.agent-firm/CURRENT_RUN")")"
before="$(sha_of "$repo" main)"

assert_ok "integrates with --run naming A" integrate "$repo" --run ".agent-firm/runs/$RUN_A"
# Asserted against the BRANCH'S TREE rather than the working tree on purpose: what is being claimed
# is which commits were merged, and that claim must survive WO-4 moving the merge off the caller's
# checked-out HEAD.
assert_ok "A's work-order branch is in A's integration branch" \
  sh -c "git -C '$repo' cat-file -e 'integration/$RUN_A:alpha.txt'"
assert_ok "B's work-order branch is NOT — the ambient pointer did not choose the sources" \
  sh -c "! git -C '$repo' cat-file -e 'integration/$RUN_A:bravo.txt' 2>/dev/null"
assert_ok "no integration branch was created for B at all" \
  sh -c "! git -C '$repo' show-ref --verify --quiet 'refs/heads/integration/$RUN_B'"
assert_output "exactly one branch was merged, so the glob was scoped and not merely lucky" \
  "merged: 1   conflicts: 0" integrate "$repo" --run ".agent-firm/runs/$RUN_A"
assert_eq "main SHA unchanged" "$before" "$(sha_of "$repo" main)"

t_case "WO-3/AC-002 · the integrated ledger event is written to run A, not to CURRENT_RUN's run B"
# The second half of AC-002, and the half that fails silently. It is asserted twice, because the two
# assertions fail on different hosts and each covers the other's gap:
#   · below, by OBSERVING THE CALL through a recording stub — portable, runs everywhere;
#   · further down, by observing the REAL LEDGER ROW — only on a host whose P2 row is supported,
#     since ledger writes fail closed everywhere else.
stub="$(mktemp -d "${TMPDIR:-/tmp}/firm-int-stub.XXXXXX")"; t_track "$stub"
mkdir -p "$stub/bin"
# firm-integrate resolves its siblings from its own location, so a copied bin/ is enough to
# interpose. Only the COLLABORATOR is stubbed; firm-integrate and the resolver are the real files.
cp "$BIN/firm-integrate" "$BIN/firm-run-resolve" "$BIN/firm-python" "$stub/bin/"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$FIRM_TEST_LEDGER_ARGV"' > "$stub/bin/firm-ledger-log"
chmod +x "$stub/bin/firm-ledger-log"
repo="$(mk_repo)"
two_runs "$repo"
real_repo="$( cd "$repo" && pwd -P )"
argv_log="$stub/ledger-argv.txt"; : > "$argv_log"
( cd "$repo" && FIRM_TEST_LEDGER_ARGV="$argv_log" "$stub/bin/firm-integrate" \
    --run ".agent-firm/runs/$RUN_A" ) >/dev/null 2>&1
assert_output "the ledger call happened at all" "integrated" cat "$argv_log"
assert_output "…and it names run A's directory explicitly" \
  "--run $real_repo/.agent-firm/runs/$RUN_A" cat "$argv_log"
assert_ok "…and run B appears nowhere in it" sh -c "! grep -q '$RUN_B' '$argv_log'"

repo="$(mk_repo)"
two_runs "$repo"
if t_p2_row_supported; then
  ( cd "$repo" && "$BIN/firm-integrate" --run ".agent-firm/runs/$RUN_A" ) >/dev/null 2>&1
  assert_ok "the real integrated row landed in A's ledger" \
    sh -c "grep -q '\"event\":\"integrated\"' '$repo/.agent-firm/runs/$RUN_A/run.jsonl'"
  # Not a vacuous negative: mk_run creates no run.jsonl, so a write aimed at B would CREATE this
  # file. Its absence is evidence, not silence.
  assert_no_file "B's ledger was never even created" "$repo/.agent-firm/runs/$RUN_B/run.jsonl"
else
  t_skip "the real integrated row lands in A's ledger and not B's" \
    "this host's P2 row is unsupported, so every ledger write fails closed and NO row is produced anywhere; the recording-stub assertions above cover the same claim here"
fi

t_case "WO-3/AC-007 · an unresolvable run stops firm-integrate before a single merge"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 feature.txt "wo1 work"
before="$(sha_of "$repo" main)"
assert_rc "a --run naming a nonexistent run is refused" 2 \
  integrate "$repo" --run ".agent-firm/runs/never-created"
assert_output "…names run selection, distinguishably from a switch or conflict failure" \
  "cannot resolve the run named by --run" integrate "$repo" --run ".agent-firm/runs/never-created"
assert_output "…and says nothing was merged" "NOTHING merged" \
  integrate "$repo" --run ".agent-firm/runs/never-created"
assert_eq "main SHA unchanged" "$before" "$(sha_of "$repo" main)"
assert_eq "HEAD did not move" "main" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
assert_ok "no integration branch was created for the run it refused" \
  sh -c "! git -C '$repo' show-ref --verify --quiet 'refs/heads/integration/never-created'"
assert_rc "--run with no value is a usage error, not a silent fallback" 2 integrate "$repo" --run
assert_rc "an unknown option is refused" 2 integrate "$repo" --bogus

t_case "WO-3/AC-007 · with no run resolvable at all it refuses, instead of inventing integration/none"
# The pre-change behaviour: no pointer meant run_id="none", which passed the integration/* allowlist,
# so `git switch -c integration/none` created a junk branch, merged nothing into it and exited 0 —
# a silent success that had selected no run at all. That is the shape AC-007 forbids.
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 feature.txt "wo1 work"
rm -f "$repo/.agent-firm/CURRENT_RUN"
before="$(sha_of "$repo" main)"
assert_rc "it refuses rather than exiting 0 having done nothing" 2 integrate "$repo"
assert_output "…saying which ambiguity it hit" "no run resolvable" integrate "$repo"
assert_output "…and naming the two ways out" "Pass --run <run-dir>, or run firm-new-run first" \
  integrate "$repo"
assert_ok "integration/none was NOT created" \
  sh -c "! git -C '$repo' show-ref --verify --quiet 'refs/heads/integration/none'"
assert_eq "main SHA unchanged" "$before" "$(sha_of "$repo" main)"
assert_eq "HEAD did not move" "main" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"

t_case "WO-3/AC-008 · containment is enforced on the explicit selector at this call site"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 feature.txt "wo1 work"
elsewhere="$(mktemp -d "${TMPDIR:-/tmp}/firm-int-elsewhere.XXXXXX")"; t_track "$elsewhere"
printf 'sentinel\n' > "$elsewhere/PRECIOUS.txt"
ln -s "$elsewhere" "$repo/.agent-firm/runs/linked"
before="$(sha_of "$repo" main)"
assert_rc "a symlinked run selector is refused" 2 integrate "$repo" --run ".agent-firm/runs/linked"
assert_output "…naming the containment violation" "is a symlink" \
  integrate "$repo" --run ".agent-firm/runs/linked"
assert_rc "a traversal selector is refused" 2 \
  integrate "$repo" --run ".agent-firm/runs/../runs/$RUN_ID"
assert_rc "a selector outside .agent-firm/runs/ is refused" 2 integrate "$repo" --run ".agent-firm"
other="$(mk_repo)"; mk_run "$other" "$RUN_A"
assert_rc "a well-formed run in a DIFFERENT checkout is refused" 2 \
  integrate "$repo" --run "$other/.agent-firm/runs/$RUN_A"
assert_eq "main SHA unchanged through every refusal" "$before" "$(sha_of "$repo" main)"
assert_file "the symlink target is untouched" "$elsewhere/PRECIOUS.txt"

t_case "WO-3/AC-006 · the positional [integration-branch] still works, with and without --run"
repo="$(mk_repo)"
two_runs "$repo"
before="$(sha_of "$repo" main)"
assert_rc "the integration/* allowlist still refuses 'main' WITH --run — no escape hatch was added" \
  2 integrate "$repo" --run ".agent-firm/runs/$RUN_A" main
assert_eq "main SHA unchanged after that refusal" "$before" "$(sha_of "$repo" main)"
assert_ok "an explicit integration/* target is accepted alongside --run" \
  integrate "$repo" --run ".agent-firm/runs/$RUN_A" integration/hand-picked
assert_ok "…and it merged A's branch into THAT branch" \
  sh -c "git -C '$repo' cat-file -e 'integration/hand-picked:alpha.txt'"
assert_ok "…and not B's" \
  sh -c "! git -C '$repo' cat-file -e 'integration/hand-picked:bravo.txt' 2>/dev/null"
assert_eq "main SHA unchanged" "$before" "$(sha_of "$repo" main)"

t_summary
