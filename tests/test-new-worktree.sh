#!/usr/bin/env bash
# tests/test-new-worktree.sh — firm-new-worktree: scaffold, sanitization, deterministic port/db
# allocation, the shared-exclude idempotence, and (the case PR 1's tests could only simulate) a real
# cross-script run against the real firm-integrate.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NEW_WT="$BIN/firm-new-worktree"
NEW_RUN="$BIN/firm-new-run"
INTEGRATE="$BIN/firm-integrate"

# expected_port <run_id> <role> <wo> — recomputes the SAME cksum/awk formula the script uses, so
# determinism is checked independently rather than by calling the script twice (a second call for the
# same role/wo would collide on the branch it just created).
expected_port() {
  h="$(printf '%s' "${1}-${2}-${3}" | cksum | awk '{print $1}')"
  echo $(( 20000 + (h % 20000) ))
}
expected_db() {
  printf 'firm_%s' "$(printf '%s' "${1}_${2}_${3}" | tr -cd 'a-zA-Z0-9_')"
}

# ---------------------------------------------------------------------------
t_case "no active run fails cleanly"
repo="$(mk_repo)"
assert_rc "exit 1 without a run" 1 sh -c "cd '$repo' && '$NEW_WT' implementer wo1"
assert_output "names firm-new-run as the fix" "new-run" sh -c "cd '$repo' && '$NEW_WT' implementer wo1"

t_case "usage error with missing args"
assert_rc "no args" 2 sh -c "cd '$repo' && '$NEW_WT'"
assert_rc "one arg" 2 sh -c "cd '$repo' && '$NEW_WT' implementer"

# ---------------------------------------------------------------------------
t_case "basic scaffold: dir, branch, worktree env file"
repo2="$(mk_repo)"
run_out="$( (cd "$repo2" && "$NEW_RUN" wt-basic fast_path) )"
run_id2="$(basename "$run_out")"
wt_out="$( (cd "$repo2" && "$NEW_WT" implementer wo1) )"

wt_dir="$repo2/.agent-firm/worktrees/${run_id2}-implementer-wo1"
wt_dir_rel=".agent-firm/worktrees/${run_id2}-implementer-wo1"   # the script prints a CWD-relative path
branch="wt/${run_id2}-implementer-wo1"
assert_ok "worktree dir exists"       sh -c "[ -d '$wt_dir' ]"
assert_ok "branch was created"        sh -c "cd '$repo2' && git show-ref --verify --quiet 'refs/heads/$branch'"
assert_output "printed the right worktree path" "$wt_dir_rel" printf '%s' "$wt_out"
assert_output "printed the right branch"        "$branch"     printf '%s' "$wt_out"
assert_file "per-worktree env file written"     "$wt_dir/.agent-firm-worktree.env"
assert_output "env file has the role"        "WORKTREE_ROLE=implementer" cat "$wt_dir/.agent-firm-worktree.env"
assert_output "env file has the work order"  "WORKTREE_WORKORDER=wo1"    cat "$wt_dir/.agent-firm-worktree.env"
assert_output "env file has the branch"      "WORKTREE_BRANCH=$branch"   cat "$wt_dir/.agent-firm-worktree.env"

# ---------------------------------------------------------------------------
t_case "role/work-order sanitization is consistent across the branch name and the env file"
repo3="$(mk_repo)"
run_out3="$( (cd "$repo3" && "$NEW_RUN" wt-sanitize fast_path) )"
run_id3="$(basename "$run_out3")"
( cd "$repo3" && "$NEW_WT" 'Impl@Menter!' 'wo#1' ) >/dev/null
san_branch="wt/${run_id3}-ImplMenter-wo1"
san_dir="$repo3/.agent-firm/worktrees/${run_id3}-ImplMenter-wo1"
assert_ok "branch uses the sanitized names" sh -c "cd '$repo3' && git show-ref --verify --quiet 'refs/heads/$san_branch'"
assert_output "env file's role is sanitized too" "WORKTREE_ROLE=ImplMenter" cat "$san_dir/.agent-firm-worktree.env"
assert_output "env file's work order is sanitized too" "WORKTREE_WORKORDER=wo1" cat "$san_dir/.agent-firm-worktree.env"

# ---------------------------------------------------------------------------
t_case "port/db allocation is deterministic (recomputed independently, not by calling twice)"
repo4="$(mk_repo)"
run_out4="$( (cd "$repo4" && "$NEW_RUN" wt-determinism fast_path) )"
run_id4="$(basename "$run_out4")"
wt_out4="$( (cd "$repo4" && "$NEW_WT" implementer wo7) )"
want_port="$(expected_port "$run_id4" implementer wo7)"
want_db="$(expected_db "$run_id4" implementer wo7)"
assert_output "printed port matches the independently recomputed formula" "port:     $want_port" printf '%s' "$wt_out4"
assert_output "printed db matches the independently recomputed formula"   "db:       $want_db"   printf '%s' "$wt_out4"
assert_output "env file's port matches too" "WORKTREE_PORT=$want_port" cat "$repo4/.agent-firm/worktrees/${run_id4}-implementer-wo7/.agent-firm-worktree.env"
assert_output "env file's db matches too"   "WORKTREE_DB=$want_db"     cat "$repo4/.agent-firm/worktrees/${run_id4}-implementer-wo7/.agent-firm-worktree.env"

# ---------------------------------------------------------------------------
t_case "shared exclude gets the two patterns exactly once, even across multiple worktrees"
repo5="$(mk_repo)"
( cd "$repo5" && "$NEW_RUN" wt-exclude fast_path >/dev/null )
( cd "$repo5" && "$NEW_WT" implementer wo1 >/dev/null )
( cd "$repo5" && "$NEW_WT" implementer wo2 >/dev/null )   # a second, different work order
excl="$repo5/.git/info/exclude"
n_env="$(grep -c '^\.agent-firm-worktree\.env$' "$excl")"
n_dir="$(grep -c '^\.agent-firm/$' "$excl")"
assert_eq "'.agent-firm-worktree.env' appears exactly once" 1 "$n_env"
assert_eq "'.agent-firm/' appears exactly once"              1 "$n_dir"

# ---------------------------------------------------------------------------
t_case ".env.example is copied when present, silently skipped when absent"
repo6="$(mk_repo)"
( cd "$repo6" && printf 'FOO=bar\n' > .env.example && git add -A && git commit -qm "add env example" )
( cd "$repo6" && "$NEW_RUN" wt-envexample fast_path >/dev/null )
run_id6="$(basename "$(cat "$repo6/.agent-firm/CURRENT_RUN")")"
( cd "$repo6" && "$NEW_WT" implementer wo1 >/dev/null )
assert_file ".env.example copied into the worktree when present" \
  "$repo6/.agent-firm/worktrees/${run_id6}-implementer-wo1/.env.example"

repo7="$(mk_repo)"   # no .env.example committed here
( cd "$repo7" && "$NEW_RUN" wt-noenvexample fast_path >/dev/null )
run_id7="$(basename "$(cat "$repo7/.agent-firm/CURRENT_RUN")")"
assert_ok "no crash when .env.example is absent" sh -c "cd '$repo7' && '$NEW_WT' implementer wo1"
assert_no_file "no .env.example silently fabricated" \
  "$repo7/.agent-firm/worktrees/${run_id7}-implementer-wo1/.env.example"

# ---------------------------------------------------------------------------
t_case "worktree_created ledger event lands with the right fields"
repo8="$(mk_repo)"
( cd "$repo8" && "$NEW_RUN" wt-ledger fast_path >/dev/null )
run_dir8="$repo8/$(cat "$repo8/.agent-firm/CURRENT_RUN")"
( cd "$repo8" && "$NEW_WT" implementer wo9 >/dev/null )
assert_output "worktree_created event present"     '"event":"worktree_created"' cat "$run_dir8/run.jsonl"
assert_output "event has the role"                 '"role":"implementer"'       cat "$run_dir8/run.jsonl"
assert_output "event has the work order"           '"work_order":"wo9"'         cat "$run_dir8/run.jsonl"

# ---------------------------------------------------------------------------
t_case "CROSS-SCRIPT: a real firm-new-worktree branch merges cleanly through real firm-integrate"
# This is deliberately NOT using mk_wt_branch (PR 1's hand-simulated fixture) — it proves the two
# scripts are actually compatible with each other, not just each independently correct against a
# simulated stand-in for the other.
repo9="$(mk_repo)"
( cd "$repo9" && "$NEW_RUN" cross-script fast_path >/dev/null )
run_id9="$(basename "$(cat "$repo9/.agent-firm/CURRENT_RUN")")"
wt_out9="$( (cd "$repo9" && "$NEW_WT" implementer wo1) )"
wt_dir9="$repo9/.agent-firm/worktrees/${run_id9}-implementer-wo1"

assert_ok "the real implementer worktree is a real, usable git checkout" \
  sh -c "cd '$wt_dir9' && printf 'real work\n' > feature.txt && git add -A && git commit -qm 'wo1 work'"

before_main="$(sha_of "$repo9" main)"
assert_ok "firm-integrate (real, from PR 1) finds and merges the real worktree branch" \
  sh -c "cd '$repo9' && '$INTEGRATE'"
assert_ok "HEAD is now the integration branch" \
  sh -c "cd '$repo9' && [ \"\$(git rev-parse --abbrev-ref HEAD)\" = 'integration/$run_id9' ]"
assert_file "the worktree's real commit landed in the integration branch" \
  "$repo9/feature.txt"
assert_eq "main is untouched by a successful integration" \
  "$before_main" "$(sha_of "$repo9" main)"

t_summary
