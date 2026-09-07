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
head_before9="$( (cd "$repo9" && git rev-parse --abbrev-ref HEAD) )"
assert_ok "firm-integrate (real, from PR 1) finds and merges the real worktree branch" \
  sh -c "cd '$repo9' && '$INTEGRATE'"
# AMENDED BY WO-4 (Decision D1), and flagged here because this file belongs to another work order.
# These two assertions observed the merge result THROUGH the caller's working tree, which is exactly
# what firm-integrate no longer writes to: it merges in .agent-firm/integration/<run_id> and leaves
# the caller's HEAD alone. The cross-script claim this case exists to make — that a real
# firm-new-worktree branch really does merge through the real firm-integrate — is unchanged and is
# now checked against the integration branch itself, which is where the merge actually is.
assert_eq "the caller's HEAD is unchanged (was: it became the integration branch)" \
  "$head_before9" "$( (cd "$repo9" && git rev-parse --abbrev-ref HEAD) )"
assert_ok "the integration branch exists and is where the merge went" \
  sh -c "git -C '$repo9' cat-file -e 'integration/$run_id9:feature.txt'"
assert_file "the worktree's real commit landed in the integration worktree" \
  "$repo9/.agent-firm/integration/$run_id9/feature.txt"
assert_no_file "…and NOT in the caller's checkout" "$repo9/feature.txt"
assert_eq "main is untouched by a successful integration" \
  "$before_main" "$(sha_of "$repo9" main)"

# ---------------------------------------------------------------------------
t_case "--run is authoritative: branch, worktree dir AND ledger follow it, not CURRENT_RUN (AC-003)"
# Two REAL runs, both valid, with CURRENT_RUN naming the one that must NOT be used. That is the whole
# property: not "the tool can find a run" but "the tool does not quietly prefer the ambient one".
# Run B is left fully valid on purpose — a fixture where B is broken would pass even if the tool
# consulted it, which is the assertion-that-cannot-fail this suite exists to avoid.
repo10="$(mk_repo)"
run_a="$( (cd "$repo10" && "$NEW_RUN" wt-alpha fast_path) )"
run_b="$( (cd "$repo10" && "$NEW_RUN" wt-bravo fast_path) )"   # created second, so CURRENT_RUN -> B
id_a="$(basename "$run_a")"; id_b="$(basename "$run_b")"
assert_ne "fixture precondition: the two runs are genuinely different runs" "$id_a" "$id_b"
assert_eq "fixture precondition: CURRENT_RUN really names run B" \
  ".agent-firm/runs/$id_b" "$(cat "$repo10/.agent-firm/CURRENT_RUN")"

out10="$( (cd "$repo10" && "$NEW_WT" --run ".agent-firm/runs/$id_a" implementer wo1) )"
assert_ok "branch is named for run A" \
  sh -c "cd '$repo10' && git show-ref --verify --quiet 'refs/heads/wt/${id_a}-implementer-wo1'"
assert_fail "no branch was created under run B's name" \
  sh -c "cd '$repo10' && git show-ref --verify --quiet 'refs/heads/wt/${id_b}-implementer-wo1'"
assert_file "worktree directory is named for run A" "$repo10/.agent-firm/worktrees/${id_a}-implementer-wo1"
assert_no_file "no worktree directory under run B's name" "$repo10/.agent-firm/worktrees/${id_b}-implementer-wo1"
assert_output "the printed worktree path names run A" ".agent-firm/worktrees/${id_a}-implementer-wo1" printf '%s' "$out10"
assert_output "env file's branch names run A too" "WORKTREE_BRANCH=wt/${id_a}-implementer-wo1" \
  cat "$repo10/.agent-firm/worktrees/${id_a}-implementer-wo1/.agent-firm-worktree.env"
assert_output "worktree_created landed in run A's ledger" '"event":"worktree_created"' \
  cat "$repo10/.agent-firm/runs/$id_a/run.jsonl"
# The half that was unscoped before this change: the ledger call carried no --run at all, so the
# event was attributed to whatever CURRENT_RUN said (F3's defect class, one tool over).
assert_fail "run B's ledger got NO worktree_created event" \
  grep -q worktree_created "$repo10/.agent-firm/runs/$id_b/run.jsonl"

t_case "--run also accepts an absolute run directory, and CURRENT_RUN still selects when it is absent"
out10b="$( (cd "$repo10" && "$NEW_WT" --run "$repo10/.agent-firm/runs/$id_a" implementer wo2) )"
assert_output "absolute selector produces run A's naming as well" \
  ".agent-firm/worktrees/${id_a}-implementer-wo2" printf '%s' "$out10b"
out10c="$( (cd "$repo10" && "$NEW_WT" implementer wo3) )"   # no --run: the pre-change form
assert_output "the zero-selector form still follows CURRENT_RUN (run B), unchanged" \
  ".agent-firm/worktrees/${id_b}-implementer-wo3" printf '%s' "$out10c"

t_case "F6: a <role> beginning with '-' is refused, not turned into a silently-wrong worktree"
# The hazard, stated exactly: this tool is positional-first, so an OLD copy handed `--run <dir>` takes
# "--run" as the role, keeps the hyphens through `tr -cd 'a-zA-Z0-9-'`, and creates
# wt/<AMBIENT-run>--run-<junk>. This copy must refuse instead. (Residual, and it is not closed here:
# the refusal only fires when the NEW copy is the one executing.)
assert_rc "exit 2 rather than create a worktree" 2 sh -c "cd '$repo10' && '$NEW_WT' -implementer wo9"
assert_output "the diagnostic names the leading dash" "begins with '-'" \
  sh -c "cd '$repo10' && '$NEW_WT' -implementer wo9"
assert_output "and states the two-word run selector" "--run <run-dir>" \
  sh -c "cd '$repo10' && '$NEW_WT' -implementer wo9"
assert_rc "a bare --run with no directory is refused, not consumed as the <role>" 2 \
  sh -c "cd '$repo10' && '$NEW_WT' --run"
assert_output "--run=<dir> is refused by spelling, naming the accepted form" "two words" \
  sh -c "cd '$repo10' && '$NEW_WT' --run=.agent-firm/runs/$id_a implementer wo9"
# The property behind those three: none of the refused calls created anything. Only the three
# worktrees created above exist.
assert_eq "no branch was created by any refused call" 3 \
  "$( (cd "$repo10" && git for-each-ref --format='%(refname:short)' 'refs/heads/wt/*') | wc -l | tr -d ' ')"
assert_no_file "no worktree directory was created for the refused role" \
  "$repo10/.agent-firm/worktrees/${id_b}--implementer-wo9"

t_case "an explicit --run that fails containment refuses and scaffolds nothing (AC-008, via firm-run-resolve)"
assert_rc "a run directory that does not exist is refused" 2 \
  sh -c "cd '$repo10' && '$NEW_WT' --run .agent-firm/runs/nope implementer wo4"
assert_output "the diagnostic names the specific violation, not a generic failure" "does not exist" \
  sh -c "cd '$repo10' && '$NEW_WT' --run .agent-firm/runs/nope implementer wo4"
assert_rc "a path outside <repo>/.agent-firm/runs/ is refused" 2 \
  sh -c "cd '$repo10' && '$NEW_WT' --run .agent-firm implementer wo4"
assert_no_file "nothing was scaffolded for a refused selector" \
  "$repo10/.agent-firm/worktrees/nope-implementer-wo4"
assert_fail "and the refused selector wrote no event into run B's ledger either" \
  grep -q wo4 "$repo10/.agent-firm/runs/$id_b/run.jsonl"

# ---------------------------------------------------------------------------
# The two DELIBERATE behavior changes that come with routing this tool through firm-run-resolve.
# Both are pinned here rather than left as prose, because both replace something that used to
# "succeed": a worktree named after a run that does not exist, and a worktree created under whatever
# subdirectory the caller happened to be in.
t_case "an ambient pointer that no longer resolves refuses, instead of naming a worktree after it"
repo11="$(mk_repo)"
run_out11="$( (cd "$repo11" && "$NEW_RUN" wt-dangling fast_path) )"
run_id11="$(basename "$run_out11")"
printf '%s\n' '.agent-firm/runs/does-not-exist' > "$repo11/.agent-firm/CURRENT_RUN"
assert_rc "exit 1 — this tool's historical status for 'no usable run'" 1 \
  sh -c "cd '$repo11' && '$NEW_WT' implementer wo1"
assert_output "the diagnostic says which directory is missing" "does not exist" \
  sh -c "cd '$repo11' && '$NEW_WT' implementer wo1"
assert_no_file "no branch/worktree was named after the dangling pointer" \
  "$repo11/.agent-firm/worktrees/does-not-exist-implementer-wo1"

t_case "invoked from a subdirectory: refused by name, because every path it writes is CWD-relative"
# Before this change the CWD-relative ambient read made this fail by accident ('.agent-firm/CURRENT_RUN'
# is not there). firm-run-resolve anchors the pointer at the repository root on purpose, so the
# precondition now has to be asserted instead of inherited.
printf '%s\n' ".agent-firm/runs/$run_id11" > "$repo11/.agent-firm/CURRENT_RUN"
mkdir -p "$repo11/sub"
assert_rc "exit 1 from a subdirectory" 1 sh -c "cd '$repo11/sub' && '$NEW_WT' implementer wo1"
assert_output "and it names the repository root it requires" "repository root" \
  sh -c "cd '$repo11/sub' && '$NEW_WT' implementer wo1"
assert_no_file "nothing was created under the subdirectory" "$repo11/sub/.agent-firm"
assert_ok "the same call from the repository root still works" \
  sh -c "cd '$repo11' && '$NEW_WT' implementer wo1"

t_summary
