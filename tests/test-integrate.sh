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

t_summary
