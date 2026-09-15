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
t_case "existing integration branch + conflicting local changes → the caller's dirty tree is irrelevant"
# AMENDED BY WO-4 (Decision D1). The fixture and every SAFETY assertion are unchanged. What changed
# is the assertion about the MECHANISM: this case used to require firm-integrate to ABORT here,
# because it had to switch the caller's HEAD onto the integration branch and a dirty tree made that
# impossible. Merging in a per-run worktree removes the reason to abort — the caller's working tree
# is not involved at all — so the tool now succeeds where it used to fail, and the guarantee the case
# exists to protect ("must not merge here") holds MORE strongly than before rather than less: it is
# no longer that the merge was refused, it is that the merge could not have landed here.
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
assert_output "fixture precondition: switching the CALLER's HEAD there really would fail" \
  "would be overwritten" sh -c "cd '$repo' && git switch 'integration/$RUN_ID' 2>&1"
before="$(sha_of "$repo" main)"

assert_ok "integrates anyway — it never needed the caller's HEAD" integrate "$repo"
assert_eq "main SHA unchanged (the actual bug)" "$before" "$(sha_of "$repo" main)"
assert_eq "still on main, nothing merged into it" "main" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
assert_eq "the caller's uncommitted change is byte-for-byte untouched" \
  "dirty-local" "$(cat "$repo/shared.txt")"
assert_ok "and the work-order branch really was merged, into the integration branch" \
  sh -c "git -C '$repo' cat-file -e 'integration/$RUN_ID:feature.txt'"

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

head_before="$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
int_wt="$repo/.agent-firm/integration/$RUN_ID"

assert_ok "integrates cleanly" integrate "$repo"
# AMENDED BY WO-4 (Decision D1). These three assertions all observed the merge result THROUGH the
# caller's working tree, which is exactly what the tool no longer writes to. The work order
# anticipated the first; the other two are the same class and had to move with it. Each is replaced
# by the stronger pair — the result IS somewhere specific, and it is NOT in the caller's checkout.
assert_eq "the caller's HEAD is unchanged (was: it became the integration branch)" \
  "$head_before" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
assert_eq "…and that is still main, so the never-rule-#1 surface is where it was" \
  "main" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
assert_file "wo1 content present — in the integration worktree" "$int_wt/alpha.txt"
assert_file "wo2 content present — in the integration worktree" "$int_wt/beta.txt"
assert_no_file "wo1 content is NOT in the caller's checkout" "$repo/alpha.txt"
assert_no_file "wo2 content is NOT in the caller's checkout" "$repo/beta.txt"
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
# AMENDED BY WO-4: this assertion still runs and still passes, but it is no longer the one that
# proves the abort worked — after D1 the caller's tree is not where the merge happened, so a clean
# status here would hold even if `git merge --abort` had been dropped entirely. Retitled to claim
# only what it now proves, and the real check follows it.
assert_eq "the caller's own tree is untouched by a conflicting integration" \
  "" "$( (cd "$repo" && git status --porcelain --untracked-files=no) )"
assert_eq "no merge left in progress — in the worktree the merge actually ran in" \
  "" "$( git -C "$repo/.agent-firm/integration/$RUN_ID" status --porcelain --untracked-files=no )"
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

# ===========================================================================
# WO-4 · the merges happen in a per-run integration worktree; the caller's HEAD is never touched.
#
# Everything above is WO-2/WO-3-era or older. The amendments D1 required are marked in place with
# "AMENDED BY WO-4" and are four assertions in three cases -- not the one the work order predicted,
# because ":78" had two siblings ("wo1/wo2 content present") that observed the merge result through
# the caller's working tree and are the same class of claim.
#
# The property under test here is a NEGATIVE one -- "the caller's HEAD did not move" -- and a
# negative is easy to assert vacuously. Each case below therefore pairs it with a positive: the
# merge DID happen, somewhere specific, and that somewhere is not the caller's checkout.
# ===========================================================================
t_case "WO-4/AC-004 · the caller's HEAD is unchanged, whatever it was pointing at"
# Deterministic half of the F2 demonstration. The interleaving is dangerous only because the merge
# target used to be a function of the caller's HEAD; if the RESULT is independent of that HEAD --
# on a branch, on a different branch, and detached -- then there is nothing for a second invocation
# to move out from under the first. Three starting positions, one expected outcome.
for start in main sidebranch detached; do
  repo="$(mk_repo)"
  mk_run "$repo" "$RUN_ID"
  mk_wt_branch "$repo" "$RUN_ID" wo1 alpha.txt "alpha work"
  case "$start" in
    sidebranch) ( cd "$repo" && git checkout -q -b unrelated-side ) >/dev/null 2>&1 ;;
    detached)   ( cd "$repo" && git checkout -q --detach HEAD ) >/dev/null 2>&1 ;;
  esac
  head_ref_before="$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
  head_sha_before="$( (cd "$repo" && git rev-parse HEAD) )"
  main_before="$(sha_of "$repo" main)"

  assert_ok "starting on '$start': integrates" integrate "$repo"
  assert_eq "starting on '$start': the caller's HEAD ref did not move" \
    "$head_ref_before" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
  assert_eq "starting on '$start': the caller's HEAD SHA did not move either" \
    "$head_sha_before" "$( (cd "$repo" && git rev-parse HEAD) )"
  assert_eq "starting on '$start': main is untouched" "$main_before" "$(sha_of "$repo" main)"
  assert_ok "starting on '$start': the merge landed on the integration branch regardless" \
    sh -c "git -C '$repo' cat-file -e 'integration/$RUN_ID:alpha.txt'"
done

t_case "WO-4/D1 · the behavior change is ANNOUNCED on every run, including a no-op one"
# Per D1 this is the condition attached to the AC-006 carve-out: the caller's HEAD not moving is
# acceptable BECAUSE the tool says so, rather than because nobody noticed.
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 alpha.txt "alpha work"
assert_output "names where integration was performed" \
  "integration performed in .agent-firm/integration/$RUN_ID" integrate "$repo"
assert_output "…and states the caller's HEAD is unchanged, with what it is" \
  "your HEAD is unchanged (main)" integrate "$repo"
assert_output "…and points the operator at the directory the merges are in" \
  ".agent-firm/integration/$RUN_ID    # the merges are HERE" integrate "$repo"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
assert_output "the announcement is printed on a no-op run too, not only when something merged" \
  "your HEAD is unchanged" integrate "$repo"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 alpha.txt "alpha work"
( cd "$repo" && git checkout -q --detach HEAD ) >/dev/null 2>&1
assert_output "a detached caller HEAD is described as detached rather than mis-reported" \
  "your HEAD is unchanged (detached at " integrate "$repo"

t_case "WO-4/AC-004 · two runs integrating CONCURRENTLY in one working tree do not collide"
# The F2 fixture. Two firm-integrate invocations really do overlap in wall-clock time: both are
# started, both block on a gate file, and the gate is released once so they enter firm-integrate
# together. Under the old code these two shared one HEAD slot -- A switches to integration/A, B
# switches to integration/B, and A's merges land on B's branch. Under the new code they are two
# directories with two HEADs and there is no slot to contend for.
#
# A fully faithful ADVERSARIAL interleave -- one that forces the context switch to fall inside the
# merge loop rather than merely overlapping the processes -- is handed to WO-7's golden eval; see
# this work order's execution report for the exact scenario. This case is not a substitute for it
# and does not claim to be; what it demonstrates is that the caller's HEAD stays put under genuine
# concurrent use, which is this work order's own core claim.
conc="$(mktemp -d "${TMPDIR:-/tmp}/firm-int-conc.XXXXXX")"; t_track "$conc"
runner="$conc/run-one.sh"
printf '%s\n' \
  '#!/bin/sh' \
  '# $1 bin  $2 repo  $3 run-dir  $4 gate  $5 outfile' \
  'i=0' \
  'while [ ! -f "$4" ]; do i=$((i+1)); [ "$i" -gt 400 ] && exit 9; sleep 0.02; done' \
  'cd "$2" || exit 8' \
  '"$1/firm-integrate" --run "$3" > "$5" 2>&1' \
  'printf "rc=%s\n" "$?" >> "$5"' > "$runner"
chmod +x "$runner"

repo="$(mk_repo)"
two_runs "$repo"
head_before="$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
main_before="$(sha_of "$repo" main)"
gate="$conc/gate"; rm -f "$gate"
"$runner" "$BIN" "$repo" ".agent-firm/runs/$RUN_A" "$gate" "$conc/a.txt" &
pid_a=$!
"$runner" "$BIN" "$repo" ".agent-firm/runs/$RUN_B" "$gate" "$conc/b.txt" &
pid_b=$!
sleep 0.3                    # let both reach the gate before either enters firm-integrate
: > "$gate"
wait "$pid_a"; wait "$pid_b"

assert_output "invocation A completed" "rc=0" cat "$conc/a.txt"
assert_output "invocation B completed" "rc=0" cat "$conc/b.txt"
assert_output "…and they really did overlap: each announced its own integration directory" \
  "integration performed in .agent-firm/integration/$RUN_A" cat "$conc/a.txt"
assert_output "…B likewise" \
  "integration performed in .agent-firm/integration/$RUN_B" cat "$conc/b.txt"
assert_eq "the caller's HEAD is still where it was" \
  "$head_before" "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"
assert_eq "main is untouched by two concurrent integrations" "$main_before" "$(sha_of "$repo" main)"
# The collision F2 describes shows up as CROSS-CONTAMINATION: A's commits on B's branch.
assert_ok "A's branch has A's work"      sh -c "git -C '$repo' cat-file -e 'integration/$RUN_A:alpha.txt'"
assert_ok "A's branch does NOT have B's" sh -c "! git -C '$repo' cat-file -e 'integration/$RUN_A:bravo.txt' 2>/dev/null"
assert_ok "B's branch has B's work"      sh -c "git -C '$repo' cat-file -e 'integration/$RUN_B:bravo.txt'"
assert_ok "B's branch does NOT have A's" sh -c "! git -C '$repo' cat-file -e 'integration/$RUN_B:alpha.txt' 2>/dev/null"
assert_ok "each run got its own integration worktree" \
  sh -c "[ -d '$repo/.agent-firm/integration/$RUN_A' ] && [ -d '$repo/.agent-firm/integration/$RUN_B' ]"

t_case "WO-4/AC-011 · the integration worktree is removable, leaving the registration consistent"
# The residual this change introduces: reverting it means removing a worktree, not deleting a
# directory. Asserted rather than only documented, because "git worktree remove works here" is the
# whole content of the rollback note.
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 alpha.txt "alpha work"
assert_ok "integrates" integrate "$repo"
assert_ok "the worktree is registered with git, not merely a directory on disk" \
  sh -c "git -C '$repo' worktree list --porcelain | grep -q 'integration/$RUN_ID'"
assert_ok "git worktree remove takes it cleanly" \
  sh -c "git -C '$repo' worktree remove '$repo/.agent-firm/integration/$RUN_ID'"
assert_no_file "the directory is gone" "$repo/.agent-firm/integration/$RUN_ID"
assert_ok "…and git no longer lists it" \
  sh -c "! git -C '$repo' worktree list --porcelain | grep -q 'integration/$RUN_ID'"
assert_ok "the shared working tree's own registration is still consistent" \
  sh -c "git -C '$repo' worktree list >/dev/null && git -C '$repo' status --porcelain >/dev/null"
assert_ok "the integration branch itself survives removal — the merges are not lost" \
  sh -c "git -C '$repo' cat-file -e 'integration/$RUN_ID:alpha.txt'"
assert_ok "and a later run re-creates the worktree rather than failing" integrate "$repo"

t_case "WO-4 · a re-run REUSES the integration worktree instead of destroying work in it"
# firm-qa-checkout may force-remove its own directory because a QA checkout is a disposable
# materialization of a committed SHA. An integration worktree is where the Integrator resolves
# conflicts BY HAND, so force-removing it on a re-run would delete exactly that. This pins the
# difference, because copying firm-qa-checkout's remove-and-re-add would have been the obvious move.
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 alpha.txt "alpha work"
assert_ok "first integration" integrate "$repo"
int_wt="$repo/.agent-firm/integration/$RUN_ID"
printf 'hand-resolved by the Integrator\n' > "$int_wt/RECONCILED.txt"
mk_wt_branch "$repo" "$RUN_ID" wo2 beta.txt "beta work"
assert_ok "second integration" integrate "$repo"
assert_file "the Integrator's uncommitted file survived the re-run" "$int_wt/RECONCILED.txt"
assert_eq "…byte-for-byte" "hand-resolved by the Integrator" "$(cat "$int_wt/RECONCILED.txt")"
assert_file "and the second work-order branch was merged in" "$int_wt/beta.txt"

t_case "WO-4/AC-008 · the integration worktree path gets the same containment rigor as the QA one"
repo="$(mk_repo)"
mk_run "$repo" "$RUN_ID"
mk_wt_branch "$repo" "$RUN_ID" wo1 alpha.txt "alpha work"
redirect="$(mktemp -d "${TMPDIR:-/tmp}/firm-int-redirect.XXXXXX")"; t_track "$redirect"
printf 'sentinel\n' > "$redirect/PRECIOUS.txt"
before="$(sha_of "$repo" main)"
mkdir -p "$repo/.agent-firm"
ln -s "$redirect" "$repo/.agent-firm/integration"
assert_fail "a symlinked .agent-firm/integration parent is refused" integrate "$repo"
assert_output "…naming the redirect rather than failing obscurely" \
  "integration worktree parent is unsafe or redirected" integrate "$repo"
assert_no_file "the redirect target received no worktree" "$redirect/$RUN_ID"
assert_file "…and its contents are untouched" "$redirect/PRECIOUS.txt"
rm "$repo/.agent-firm/integration"
mkdir -p "$repo/.agent-firm/integration"
ln -s "$redirect" "$repo/.agent-firm/integration/$RUN_ID"
assert_fail "a symlinked per-run integration directory is refused" integrate "$repo"
assert_output "…and says it refuses to follow it" "refusing symlinked integration worktree" \
  integrate "$repo"
assert_no_file "still nothing written through the link" "$redirect/alpha.txt"
rm "$repo/.agent-firm/integration/$RUN_ID"
# A plain directory sitting where the worktree belongs is NOT force-removed: it is refused, because
# this script cannot know what it is.
mkdir -p "$repo/.agent-firm/integration/$RUN_ID"
printf 'not a worktree\n' > "$repo/.agent-firm/integration/$RUN_ID/SOMETHING.txt"
assert_fail "a non-worktree directory in the way is refused, not deleted" integrate "$repo"
assert_output "…and says what to do about it" "not a worktree of this repository" integrate "$repo"
assert_file "the directory's contents are still there" \
  "$repo/.agent-firm/integration/$RUN_ID/SOMETHING.txt"
assert_eq "main SHA unchanged through every one of those refusals" "$before" "$(sha_of "$repo" main)"
assert_eq "and the caller's HEAD never moved either" "main" \
  "$( (cd "$repo" && git rev-parse --abbrev-ref HEAD) )"

# ---------------------------------------------------------------------------
t_case "AC-010: --help states how the run is selected, on stdout, exit 0, merging nothing"
# --run arrived on this tool in this run; the statement of what it OUTRANKS did not, and `--help` fell
# into the `-*` catch-all and exited 2 with "unknown option --help". This is the tool where that gap
# costs the most: the run id it resolves picks BOTH the branches merged AND the ledger the merge is
# recorded in, and F3 is precisely the failure of getting those two from different places.
repoH="$(mk_repo)"
mk_run "$repoH" "$RUN_ID"
mk_wt_branch "$repoH" "$RUN_ID" wo1 feature.txt "wo1 work"
beforeH="$(sha_of "$repoH" main)"
helpH="$( integrate "$repoH" --help 2>/dev/null )"; rcH=$?
assert_eq "--help exits 0" 0 "$rcH"
assert_output "the synopsis is on stdout" "usage: firm-integrate" printf '%s' "$helpH"
assert_output "it names the selector in the accepted two-word spelling" "--run <run-dir>" \
  printf '%s' "$helpH"
assert_output "it says the explicit selector is authoritative" "AUTHORITATIVE" printf '%s' "$helpH"
assert_output "…and that the ambient pointer is then not read at all" "CURRENT_RUN is not" \
  printf '%s' "$helpH"
assert_output "…naming the ambient pointer it beats" ".agent-firm/CURRENT_RUN" printf '%s' "$helpH"
assert_output "…in the wording shared across every in-scope tool" "Explicit beats ambient" \
  printf '%s' "$helpH"
assert_output "…and states that the SAME run id drives the glob and the ledger (F3)" \
  "BOTH selections" printf '%s' "$helpH"
assert_eq "--help created no integration branch" "" \
  "$( (cd "$repoH" && git for-each-ref --format='%(refname:short)' 'refs/heads/integration/*') )"
assert_no_file "…and no integration worktree" "$repoH/.agent-firm/integration"
assert_eq "main SHA unchanged" "$beforeH" "$(sha_of "$repoH" main)"
assert_eq "and the caller's HEAD did not move" "main" \
  "$( (cd "$repoH" && git rev-parse --abbrev-ref HEAD) )"
helpH2="$( integrate "$repoH" -h 2>/dev/null )"; rcH2=$?
assert_eq "-h exits 0 too" 0 "$rcH2"
assert_eq "-h prints the byte-identical synopsis" "$helpH" "$helpH2"
assert_rc "an unrelated option is still refused, and rc 2 is still its status" 2 \
  integrate "$repoH" --bogus
assert_output "…and the refusal now carries the same run-selection statement" "Explicit beats ambient" \
  sh -c "cd '$repoH' && '$BIN/firm-integrate' --bogus 2>&1"
# Without this, "created no integration branch" could be passing on a fixture where a real merge
# creates nothing either -- a comparison that cannot fail.
assert_ok "fixture precondition: a REAL invocation on this fixture does create one" integrate "$repoH"
assert_ne "…so the emptiness asserted above was a live measurement" "" \
  "$( (cd "$repoH" && git for-each-ref --format='%(refname:short)' 'refs/heads/integration/*') )"

t_summary
