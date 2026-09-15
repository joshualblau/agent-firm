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
assert_eq "candidate metadata mode is 600" 600 "$(t_file_mode "$candidate")"
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

t_case "QA and evidence parent redirects are rejected without touching either target"
repo5="$(mk_repo)"
( cd "$repo5" && "$NEW_RUN" checkout-parent-redirect fast_path >/dev/null )
id5="$(basename "$(cat "$repo5/.agent-firm/CURRENT_RUN")")"
( cd "$repo5" && git branch "integration/$id5" )
redirect5="$(mktemp -d "${TMPDIR:-/tmp}/firm-qa-parent.XXXXXX")"; t_track "$redirect5"
printf 'qa target sentinel\n' > "$redirect5/qa-sentinel"
qa_before="$(shasum -a 256 "$redirect5/qa-sentinel" | awk '{print $1}')"
ln -s "$redirect5" "$repo5/.agent-firm/qa-checkout"
assert_rc "symlinked QA parent is rejected" 2 sh -c "cd '$repo5' && '$QAC'"
assert_eq "QA redirect sentinel stays byte-identical" "$qa_before" "$(shasum -a 256 "$redirect5/qa-sentinel" | awk '{print $1}')"
assert_no_file "QA redirect receives no checkout" "$redirect5/$id5"
rm "$repo5/.agent-firm/qa-checkout"

run5="$repo5/.agent-firm/runs/$id5"
mv "$run5/09-test-evidence" "$redirect5/evidence-target"
printf 'evidence target sentinel\n' > "$redirect5/evidence-target/sentinel"
evidence_before="$(shasum -a 256 "$redirect5/evidence-target/sentinel" | awk '{print $1}')"
ln -s "$redirect5/evidence-target" "$run5/09-test-evidence"
assert_rc "symlinked evidence parent is rejected" 2 sh -c "cd '$repo5' && '$QAC'"
assert_eq "evidence redirect sentinel stays byte-identical" "$evidence_before" "$(shasum -a 256 "$redirect5/evidence-target/sentinel" | awk '{print $1}')"
assert_no_file "evidence redirect receives no candidate metadata" "$redirect5/evidence-target/qa-candidate.json"
rm "$run5/09-test-evidence"
mv "$redirect5/evidence-target" "$run5/09-test-evidence"

# ---------------------------------------------------------------------------
# WO-2 · the explicit --run selector.
#
# Everything ABOVE this line is pre-existing and is deliberately unmodified: AC-006 is the claim
# that adding a selector changed nothing about the forms that already worked, and a suite edited to
# accommodate the change cannot make that claim.
#
# Everything BELOW is new. The defect being closed is not "wrong answer" but "no answer available":
# this tool had no run selector at all, so when two runs shared one working tree the second one's
# Lead had to hand-substitute the tool entirely. The assertions therefore care about BINDING —
# which run's checkout, which run's candidate metadata, which run's ledger — rather than about exit
# status, because every wrong-run failure mode here exits 0.
# ---------------------------------------------------------------------------
t_case "WO-2/AC-001 · --run alone captures a candidate with NO CURRENT_RUN present at all"
repo6="$(mk_repo)"
( cd "$repo6" && "$NEW_RUN" no-pointer fast_path >/dev/null )
id6="$(basename "$(cat "$repo6/.agent-firm/CURRENT_RUN")")"
( cd "$repo6" && git checkout -q -b "integration/$id6" && printf 'integrated\n' > r.txt && \
  git add -A && git commit -qm int && git checkout -q main ) >/dev/null 2>&1
sha6="$(sha_of "$repo6" "integration/$id6")"
rm -f "$repo6/.agent-firm/CURRENT_RUN"
assert_no_file "fixture precondition: there is no ambient pointer to fall back to" \
  "$repo6/.agent-firm/CURRENT_RUN"
assert_ok "the explicit selector alone is sufficient" \
  sh -c "cd '$repo6' && '$QAC' --run .agent-firm/runs/$id6"
assert_eq "the checkout is at that run's candidate SHA" \
  "$sha6" "$(sha_of "$repo6/.agent-firm/qa-checkout/$id6" HEAD)"
assert_file "the candidate metadata is in that run's evidence directory" \
  "$repo6/.agent-firm/runs/$id6/09-test-evidence/qa-candidate.json"
assert_ok "the qa_checkout event is in that run's ledger" \
  sh -c "grep -q '\"event\":\"qa_checkout\"' '$repo6/.agent-firm/runs/$id6/run.jsonl'"
assert_no_file "CURRENT_RUN was neither required nor created" "$repo6/.agent-firm/CURRENT_RUN"

t_case "WO-2/AC-002 · --run names run A while CURRENT_RUN names run B: everything binds to A"
repo7="$(mk_repo)"
( cd "$repo7" && "$NEW_RUN" alpha fast_path >/dev/null )
id_a="$(basename "$(cat "$repo7/.agent-firm/CURRENT_RUN")")"
( cd "$repo7" && "$NEW_RUN" bravo fast_path >/dev/null )
id_b="$(basename "$(cat "$repo7/.agent-firm/CURRENT_RUN")")"
assert_ne "fixture precondition: the two runs really are distinct" "$id_a" "$id_b"
assert_eq "fixture precondition: CURRENT_RUN names B, the run NOT being asked for" \
  "$id_b" "$(basename "$(cat "$repo7/.agent-firm/CURRENT_RUN")")"
# Distinct content per branch, so a checkout bound to the wrong run shows up as the wrong FILE and
# not merely as a path that happens to differ.
( cd "$repo7" && git checkout -q -b "integration/$id_a" && printf 'alpha\n' > alpha.txt && \
  git add -A && git commit -qm a && git checkout -q main ) >/dev/null 2>&1
( cd "$repo7" && git checkout -q -b "integration/$id_b" && printf 'bravo\n' > bravo.txt && \
  git add -A && git commit -qm b && git checkout -q main ) >/dev/null 2>&1
sha_a="$(sha_of "$repo7" "integration/$id_a")"
assert_ok "captures with --run naming A" sh -c "cd '$repo7' && '$QAC' --run .agent-firm/runs/$id_a"
assert_eq "the checkout is at A's candidate SHA, not B's" \
  "$sha_a" "$(sha_of "$repo7/.agent-firm/qa-checkout/$id_a" HEAD)"
assert_file "…and holds A's file"        "$repo7/.agent-firm/qa-checkout/$id_a/alpha.txt"
assert_no_file "…and not B's"            "$repo7/.agent-firm/qa-checkout/$id_a/bravo.txt"
assert_no_file "B got no QA checkout at all" "$repo7/.agent-firm/qa-checkout/$id_b"
assert_file "A's candidate metadata was written" \
  "$repo7/.agent-firm/runs/$id_a/09-test-evidence/qa-candidate.json"
assert_no_file "B's run directory received no candidate metadata" \
  "$repo7/.agent-firm/runs/$id_b/09-test-evidence/qa-candidate.json"
assert_eq "the persisted candidate records A as its run" "$id_a" \
  "$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' \
     "$repo7/.agent-firm/runs/$id_a/09-test-evidence/qa-candidate.json")"
assert_ok "the qa_checkout event landed in A's ledger" \
  sh -c "grep -q '\"event\":\"qa_checkout\"' '$repo7/.agent-firm/runs/$id_a/run.jsonl'"
assert_ok "…and NOT in B's — a wrong-target ledger write is the silent half of this bug" \
  sh -c "! grep -q '\"event\":\"qa_checkout\"' '$repo7/.agent-firm/runs/$id_b/run.jsonl'"
assert_eq "CURRENT_RUN still names B: it was not consulted and not rewritten" \
  "$id_b" "$(basename "$(cat "$repo7/.agent-firm/CURRENT_RUN")")"

t_case "WO-2/AC-001 · --run does not merely OUTRANK the ambient pointer, it does not read it"
# Outranking and not-reading are different claims and only the second one satisfies AC-001 ("does
# not read, create, or require CURRENT_RUN"). An unreadable pointer is the cheapest way to tell them
# apart: a tool that still reads it fails here, and a tool that does not cannot notice.
if [ "$(id -u)" = "0" ]; then
  t_skip "an unreadable CURRENT_RUN is not consulted" \
    "running as uid 0, which can read a mode-000 file, so the distinction is not constructible here"
else
  chmod 000 "$repo7/.agent-firm/CURRENT_RUN"
  assert_ok "a second capture succeeds with CURRENT_RUN unreadable" \
    sh -c "cd '$repo7' && '$QAC' --run .agent-firm/runs/$id_a"
  assert_eq "…and it was a real second capture (generation incremented)" 2 \
    "$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["generation"])' \
       "$repo7/.agent-firm/runs/$id_a/09-test-evidence/qa-candidate.json")"
  chmod 644 "$repo7/.agent-firm/CURRENT_RUN"
fi

t_case "WO-2/AC-006 · the positional [branch] argument still works, with and without --run"
repo8="$(mk_repo)"
( cd "$repo8" && "$NEW_RUN" positional fast_path >/dev/null )
id8="$(basename "$(cat "$repo8/.agent-firm/CURRENT_RUN")")"
( cd "$repo8" && git checkout -q -b integration/other-name && printf 'other\n' > other.txt && \
  git add -A && git commit -qm o && git checkout -q main ) >/dev/null 2>&1
sha8="$(sha_of "$repo8" integration/other-name)"
cand8="$repo8/.agent-firm/runs/$id8/09-test-evidence/qa-candidate.json"
assert_ok "positional branch, no --run (the pre-existing form)" \
  sh -c "cd '$repo8' && '$QAC' integration/other-name"
assert_eq "…captured that branch" "$sha8" "$(sha_of "$repo8/.agent-firm/qa-checkout/$id8" HEAD)"
assert_eq "…at generation 1" 1 \
  "$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["generation"])' "$cand8")"
assert_ok "the same positional branch AFTER --run" \
  sh -c "cd '$repo8' && '$QAC' --run .agent-firm/runs/$id8 integration/other-name"
assert_eq "…captured the same branch, bound to the run --run named" \
  "$sha8" "$(sha_of "$repo8/.agent-firm/qa-checkout/$id8" HEAD)"
assert_eq "…and really ran, rather than short-circuiting (generation 2)" 2 \
  "$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["generation"])' "$cand8")"
assert_eq "the default branch is still computed from the RESOLVED run id" \
  "refs/heads/integration/other-name" \
  "$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_ref"])' "$cand8")"

t_case "WO-2/AC-007 · an unresolvable --run stops the tool with its own distinguishable message"
repo9="$(mk_repo)"
( cd "$repo9" && "$NEW_RUN" fail-closed fast_path >/dev/null )
id9="$(basename "$(cat "$repo9/.agent-firm/CURRENT_RUN")")"
( cd "$repo9" && git branch "integration/$id9" )
assert_rc "a --run naming a nonexistent run is refused" 2 \
  sh -c "cd '$repo9' && '$QAC' --run .agent-firm/runs/never-created"
assert_output "…the resolver names the specific violation" "does not exist" \
  sh -c "cd '$repo9' && '$QAC' --run .agent-firm/runs/never-created 2>&1"
assert_output "…and firm-qa-checkout says IT stopped, over run selection" \
  "cannot resolve the run named by --run" \
  sh -c "cd '$repo9' && '$QAC' --run .agent-firm/runs/never-created 2>&1"
assert_no_file "nothing was materialized for a selector it refused" "$repo9/.agent-firm/qa-checkout"
assert_rc "--run with no value is a usage error, not a silent fallback" 2 \
  sh -c "cd '$repo9' && '$QAC' --run"
assert_rc "an unknown option is refused" 2 sh -c "cd '$repo9' && '$QAC' --bogus"
# The other failures in this script must NOT collapse into the run-selection one. This run resolves
# perfectly; it is the BRANCH that is missing, and the message has to keep saying so.
repo9b="$(mk_repo)"
( cd "$repo9b" && "$NEW_RUN" branch-missing fast_path >/dev/null )
assert_output "a missing integration branch is still its own failure" "run firm-integrate first" \
  sh -c "cd '$repo9b' && '$QAC' 2>&1"
assert_ok "…and is not reported as a run-resolution failure" \
  sh -c "cd '$repo9b' && ! '$QAC' 2>&1 | grep -q 'resolve the run'"

t_case "WO-2/AC-008 · containment is enforced on the EXPLICIT selector at this call site"
# The hazard of adding a flag is a second front door that skips the lock the first one had. The
# resolver holds the line (tests/test-run-resolve.sh proves the check set); this asserts that
# firm-qa-checkout actually routes through it rather than around it.
repo10="$(mk_repo)"
( cd "$repo10" && "$NEW_RUN" containment fast_path >/dev/null )
id10="$(basename "$(cat "$repo10/.agent-firm/CURRENT_RUN")")"
( cd "$repo10" && git branch "integration/$id10" )
elsewhere10="$(mktemp -d "${TMPDIR:-/tmp}/firm-qac-elsewhere.XXXXXX")"; t_track "$elsewhere10"
printf 'sentinel\n' > "$elsewhere10/PRECIOUS.txt"
ln -s "$elsewhere10" "$repo10/.agent-firm/runs/linked"
assert_rc "a symlinked run selector is refused" 2 \
  sh -c "cd '$repo10' && '$QAC' --run .agent-firm/runs/linked"
assert_output "…naming the containment violation, not a generic error" "is a symlink" \
  sh -c "cd '$repo10' && '$QAC' --run .agent-firm/runs/linked 2>&1"
assert_rc "a traversal selector is refused" 2 \
  sh -c "cd '$repo10' && '$QAC' --run .agent-firm/runs/../runs/$id10"
assert_rc "a selector outside .agent-firm/runs/ is refused" 2 \
  sh -c "cd '$repo10' && '$QAC' --run .agent-firm"
other10="$(mk_repo)"
( cd "$other10" && "$NEW_RUN" other-checkout fast_path >/dev/null )
other_id10="$(basename "$(cat "$other10/.agent-firm/CURRENT_RUN")")"
assert_rc "a well-formed run belonging to a DIFFERENT checkout is refused" 2 \
  sh -c "cd '$repo10' && '$QAC' --run '$other10/.agent-firm/runs/$other_id10'"
assert_no_file "no checkout was materialized by any of those refusals" \
  "$repo10/.agent-firm/qa-checkout"
assert_file "the symlink target is untouched" "$elsewhere10/PRECIOUS.txt"
assert_no_file "…and received no checkout of its own" "$elsewhere10/$id10"

# ---------------------------------------------------------------------------
t_case "AC-010: --help states how the run is selected, on stdout, exit 0, materializing nothing"
# --run arrived on this tool in this run; the statement of what it OUTRANKS did not, and `--help` fell
# into the `-*` catch-all and exited 2 with "unknown option --help". A producer could therefore only
# learn the precedence by reading the source, which is the condition AC-010 names.
repo11="$(mk_repo)"
( cd "$repo11" && "$NEW_RUN" qac-help fast_path >/dev/null )
help11="$( (cd "$repo11" && "$QAC" --help) 2>/dev/null )"; rc11=$?
assert_eq "--help exits 0" 0 "$rc11"
assert_output "the synopsis is on stdout" "usage: firm-qa-checkout" printf '%s' "$help11"
assert_output "it names the selector in the accepted two-word spelling" "--run <run-dir>" \
  printf '%s' "$help11"
assert_output "it says the explicit selector is authoritative" "AUTHORITATIVE" printf '%s' "$help11"
assert_output "…and that the ambient pointer is then not read at all" "CURRENT_RUN is not" \
  printf '%s' "$help11"
assert_output "…naming the ambient pointer it beats" ".agent-firm/CURRENT_RUN" printf '%s' "$help11"
assert_output "…in the wording shared across every in-scope tool" "Explicit beats ambient" \
  printf '%s' "$help11"
assert_no_file "--help materialized no QA checkout" "$repo11/.agent-firm/qa-checkout"
help11b="$( (cd "$repo11" && "$QAC" -h) 2>/dev/null )"; rc11b=$?
assert_eq "-h exits 0 too" 0 "$rc11b"
assert_eq "-h prints the byte-identical synopsis" "$help11" "$help11b"
assert_rc "an unrelated option is still refused, and rc 2 is still its status" 2 \
  sh -c "cd '$repo11' && '$QAC' --bogus"
assert_output "…and the refusal now carries the same run-selection statement" "Explicit beats ambient" \
  sh -c "cd '$repo11' && '$QAC' --bogus 2>&1"

t_summary
