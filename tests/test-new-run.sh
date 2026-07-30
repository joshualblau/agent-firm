#!/usr/bin/env bash
# tests/test-new-run.sh — firm-new-run: ledger scaffold, template seeding, slug sanitization, and
# (new in PR 2) the default_branch / default_branch_start_sha baseline that no_default_branch_merge
# and final_gate_pending now depend on to fail closed instead of guessing from commit counts.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NEW_RUN="$BIN/firm-new-run"

# run_dir_of <repo> — the single run dir a fixture created (glob, not CURRENT_RUN, so it works even
# when a test deliberately doesn't rely on CURRENT_RUN).
run_dir_of() { d="$(ls -d "$1"/.agent-firm/runs/*/ 2>/dev/null | head -1)"; printf '%s' "${d%/}"; }

# ---------------------------------------------------------------------------
t_case "usage error with no slug"
repo="$(mk_repo)"
assert_rc "no args -> exit 2" 2 sh -c "cd '$repo' && '$NEW_RUN'"

# ---------------------------------------------------------------------------
t_case "basic scaffold"
repo="$(mk_repo)"
out1="$( (cd "$repo" && "$NEW_RUN" my-engagement fast_path) )"
rd="$repo/$out1"
# Check CURRENT_RUN's content BEFORE any assert_* call touches it — assert_ok/assert_output run in
# THIS shell (not a subshell) and their internals are `local`-scoped as of this PR, but the read of
# CURRENT_RUN itself doesn't need to race that at all: capture it straight into its own variable.
current_run_contents="$(cat "$repo/.agent-firm/CURRENT_RUN" 2>/dev/null)"
assert_ok "run dir created"                 sh -c "[ -d '$rd' ]"
assert_ok "05-work-orders/ created"          sh -c "[ -d '$rd/05-work-orders' ]"
assert_ok "09-test-evidence/ created"        sh -c "[ -d '$rd/09-test-evidence' ]"
assert_ok "CURRENT_RUN written"              sh -c "[ -f '$repo/.agent-firm/CURRENT_RUN' ]"
assert_eq "CURRENT_RUN points at the run dir" "$out1" "$current_run_contents"
assert_output "run_started event in run.jsonl" '"event":"run_started"' cat "$rd/run.jsonl"
assert_output "track recorded"               '"track":"fast_path"'    cat "$rd/run.jsonl"

t_case "track defaults to full_track when omitted"
repo2="$(mk_repo)"
out2="$( (cd "$repo2" && "$NEW_RUN" no-track-given) )"
assert_output "default track is full_track" '"track":"full_track"' cat "$repo2/$out2/run.jsonl"

# ---------------------------------------------------------------------------
t_case "slug sanitization"
repo3="$(mk_repo)"
out3="$( (cd "$repo3" && "$NEW_RUN" "My Cool Engagement") )"
case "$out3" in
  *"-my-cool-engagement") _t_ok "uppercase -> lowercase, spaces -> dashes" ;;
  *) _t_no "uppercase -> lowercase, spaces -> dashes" "got: $out3" ;;
esac

repo3b="$(mk_repo)"
out3b="$( (cd "$repo3b" && "$NEW_RUN" "Fix Bug #123!") )"
case "$out3b" in
  *"-fix-bug-123") _t_ok "punctuation (#, !) is stripped, not just letters/spaces translated" ;;
  *) _t_no "punctuation (#, !) is stripped, not just letters/spaces translated" "got: $out3b" ;;
esac

# ---------------------------------------------------------------------------
t_case "template seeding: files copied, the visual/ DIRECTORY is skipped (not a crash)"
repo4="$(mk_repo)"
out4="$( (cd "$repo4" && "$NEW_RUN" tmpl-check) )"
rd4="$repo4/$out4"
assert_file "00-intake.md seeded"                 "$rd4/00-intake.md"
assert_file "01-acceptance-criteria.yaml seeded"   "$rd4/01-acceptance-criteria.yaml"
assert_file "08-qa-verdict.json seeded"            "$rd4/08-qa-verdict.json"
assert_no_file "visual/ was NOT copied as a file"  "$rd4/visual"
# The regression this guards: `cp -n` on a directory fails, and under the script's `set -e` that used
# to abort run creation entirely. If firm-new-run got this far and returned 0, the regression holds.
assert_ok "script exited 0 despite templates/visual/ being a directory" true

# ---------------------------------------------------------------------------
t_case "default_branch / default_branch_start_sha baseline (new in PR 2)"
repo5="$(mk_repo)"
real_sha="$(sha_of "$repo5" main)"
out5="$( (cd "$repo5" && "$NEW_RUN" baseline-check) )"
rd5="$repo5/$out5"
assert_output "default_branch recorded in run_started"          '"default_branch":"main"' cat "$rd5/run.jsonl"
assert_output "default_branch_start_sha recorded in run_started" "\"default_branch_start_sha\":\"$real_sha\"" cat "$rd5/run.jsonl"
assert_file "run-baseline.json written"                          "$rd5/run-baseline.json"
assert_output "run-baseline.json has the right branch"           '"default_branch":"main"' cat "$rd5/run-baseline.json"
assert_output "run-baseline.json has the right sha"              "\"default_branch_start_sha\":\"$real_sha\"" cat "$rd5/run-baseline.json"
assert_ok "run-baseline.json is valid JSON" python3 -c "import json; json.load(open('$rd5/run-baseline.json'))"
assert_eq "the recorded sha is the FULL sha (40 chars), not the short base_sha" 40 "${#real_sha}"

t_case "baseline uses the DEFAULT branch, not whatever HEAD happens to be on"
repo6="$(mk_repo)"
( cd "$repo6" && git checkout -q -b some-feature-branch && echo more >> seed.txt && git add -A && git commit -qm more ) >/dev/null 2>&1
main_sha="$(sha_of "$repo6" main)"
feature_sha="$(sha_of "$repo6" some-feature-branch)"
out6="$( (cd "$repo6" && "$NEW_RUN" on-a-feature-branch) )"
assert_output "records main's sha, not the checked-out feature branch's" \
  "\"default_branch_start_sha\":\"$main_sha\"" cat "$repo6/$out6/run.jsonl"
assert_ne "fixture precondition: main and the feature branch actually differ" "$main_sha" "$feature_sha"

# ---------------------------------------------------------------------------
t_case "no baseline is written when no default branch can be resolved (fail-closed downstream)"
nogit="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $nogit"
outN="$( (cd "$nogit" && "$NEW_RUN" no-git-at-all) )"
assert_no_file "no run-baseline.json outside a git repo" "$nogit/$outN/run-baseline.json"
assert_output "empty default_branch fields recorded, not omitted or garbled" \
  '"default_branch":"","default_branch_start_sha":""' cat "$nogit/$outN/run.jsonl"
assert_ok "run.jsonl is still valid JSON" python3 -c "
import json
with open('$nogit/$outN/run.jsonl') as f:
    json.loads(f.readline())
"

t_case "no baseline is written for a repo with zero commits"
empty="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $empty"
( cd "$empty" && git init -q . && git symbolic-ref HEAD refs/heads/main ) >/dev/null 2>&1
outE="$( (cd "$empty" && "$NEW_RUN" zero-commits) )"
assert_no_file "no run-baseline.json with zero commits" "$empty/$outE/run-baseline.json"

t_summary
