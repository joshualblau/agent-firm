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

# inventory_of <repo> — everything firm-new-run could possibly have created, plus the exact bytes of
# CURRENT_RUN, as one comparable string.
#
# THIS IS THE LOAD-BEARING HALF OF EVERY REFUSAL CASE BELOW, and it exists because the exit status is
# NOT. `firm-new-run --help` used to exit 0 and print nothing wrong while scaffolding a complete run
# directory named 20260821T011819Z---help, seeding every template into it, writing a run_started event
# and repointing CURRENT_RUN. A guard placed after the first mkdir reproduces exactly that: every
# status assertion in this file stays green and the refusal leaves a partial run behind. Only a
# before/after comparison of the tree can tell those apart, so every AC-001/AC-002/AC-003 case pairs
# its status assertion with one of these.
#
# .git is pruned because firm-new-run never writes there and git's own bookkeeping is not this file's
# subject. Absence of CURRENT_RUN is recorded as its own value, so "unchanged" and "still absent if it
# was absent" are one comparison rather than two.
inventory_of() {
  ( cd "$1" 2>/dev/null || exit 0
    find . -path ./.git -prune -o -print 2>/dev/null | LC_ALL=C sort
    printf 'CURRENT_RUN='
    cat .agent-firm/CURRENT_RUN 2>/dev/null || printf '<absent>' )
}

# json_field <file> <key> — the EXACT value of one top-level key of the file's first JSON line.
# Exact, not a substring match, because a substring assertion on run.jsonl cannot discriminate here:
# `"base_sha":"<sha>"` also appears inside the record when default_branch_start_sha holds the same
# sha, and the whole point of the AC-003 explicit-base case is which of two fields got which value.
json_field() { t_python -c '
import json,sys
with open(sys.argv[1]) as fh: d=json.loads(fh.readline())
sys.stdout.write(str(d.get(sys.argv[2],"<missing>")))' "$1" "$2"; }

# json_keys <file> — the file's top-level field names, sorted, space-joined.
json_keys() { t_python -c '
import json,sys
with open(sys.argv[1]) as fh: d=json.load(fh)
sys.stdout.write(" ".join(sorted(d)))' "$1"; }

# The nine field names bin/firm-new-run:65-68 compares run-metadata.json against for EXACT set
# equality before it will read a run. Transcribed literally from the reader, sorted, because that is
# the interface AC-005 pins: the reader fails closed on ANY difference, so one added field would break
# --metadata-view for every run that already exists on disk.
READER_REQUIRED_FIELDS="accepted_base_sha approval_eligible git_common_dir historical primary_provider repository_root run_id schema_version track"

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
assert_output "legacy invocation defaults primary to Claude" '"primary_provider":"claude"' cat "$rd/run.jsonl"
assert_file "run metadata written" "$rd/run-metadata.json"
assert_output "metadata records Claude primary" '"primary_provider":"claude"' cat "$rd/run-metadata.json"
assert_output "normalized current view is approval eligible" '"approval_eligible":true' "$NEW_RUN" --metadata-view "$rd"
assert_output "normalized current view is not historical" '"historical":false' "$NEW_RUN" --metadata-view "$rd"

t_case "explicit Codex-primary run"
repoC="$(mk_repo)"
outC="$( (cd "$repoC" && "$NEW_RUN" --primary codex codex-engagement fast_path) )"
rdC="$repoC/$outC"
assert_output "run event records Codex primary" '"primary_provider":"codex"' cat "$rdC/run.jsonl"
assert_output "metadata records Codex primary" '"primary_provider":"codex"' cat "$rdC/run-metadata.json"
assert_rc "unknown primary provider is rejected" 2 sh -c "cd '$repoC' && '$NEW_RUN' --primary other nope"

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
# Capture the REAL exit code on the line that produces it. `rc4=$?` must be the very next statement:
# any command in between (including an assert_*) overwrites $?. The earlier version of this case
# discarded the return code here and then "checked" it with `assert_ok ... true`, which is a
# tautology — the literal `true` always exits 0, so that assertion reported ok even when
# firm-new-run aborted. Reintroducing the templates/visual/ regression left it green while 20 other
# assertions in this file correctly went red.
out4="$( (cd "$repo4" && "$NEW_RUN" tmpl-check) )"; rc4=$?
rd4="$repo4/$out4"
assert_file "00-intake.md seeded"                 "$rd4/00-intake.md"
assert_file "01-acceptance-criteria.yaml seeded"   "$rd4/01-acceptance-criteria.yaml"
assert_file "08-qa-verdict.json seeded"            "$rd4/08-qa-verdict.json"
assert_no_file "visual/ was NOT copied as a file"  "$rd4/visual"
# The regression this guards: `cp -n` on a directory fails, and under the script's `set -e` that used
# to abort run creation entirely — so the exit code, not just the resulting files, is the evidence.
assert_eq "script exited 0 despite templates/visual/ being a directory" 0 "$rc4"
assert_ne "and it printed a run dir rather than dying mid-scaffold" "" "$out4"

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
# THE ONE PRE-EXISTING INVOCATION THIS CHANGE TOUCHES, and it must supply "$feature_sha". Opening a
# run from a feature branch is now refused unless the base is stated (AC-003), so this case needs an
# explicit one. Supplying "$main_sha" would ALSO make the case pass — and would silently destroy what
# it asserts, because the supplied base and the default branch's SHA would then be the same value and
# the assertion below could no longer tell them apart. With "$feature_sha" the three values stay
# distinct: supplied base = HEAD = feature_sha, recorded default branch = main_sha. Both assertions
# below are unchanged.
out6="$( (cd "$repo6" && "$NEW_RUN" --base "$feature_sha" on-a-feature-branch) )"
assert_output "records main's sha, not the checked-out feature branch's" \
  "\"default_branch_start_sha\":\"$main_sha\"" cat "$repo6/$out6/run.jsonl"
assert_ne "fixture precondition: main and the feature branch actually differ" "$main_sha" "$feature_sha"

# ---------------------------------------------------------------------------
t_case "no baseline is written when no default branch can be resolved (fail-closed downstream)"
nogit="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; t_track "$nogit"
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
empty="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; t_track "$empty"
( cd "$empty" && git init -q . && git symbolic-ref HEAD refs/heads/main ) >/dev/null 2>&1
outE="$( (cd "$empty" && "$NEW_RUN" zero-commits) )"
assert_no_file "no run-baseline.json with zero commits" "$empty/$outE/run-baseline.json"

t_case "untouched pre-provider metadata absence is read-only Claude provenance and never approval eligible"
legacy_repo="$(mk_repo)"; legacy_id="20250101T000000Z-legacy"; legacy_run="$legacy_repo/.agent-firm/runs/$legacy_id"
mkdir -p "$legacy_run"
legacy_sha="$(sha_of "$legacy_repo" main)"
printf '{"event":"run_started","run_id":"%s","track":"full_track","base_sha":"%s"}\n' "$legacy_id" "$legacy_sha" > "$legacy_run/run.jsonl"
legacy_before="$(shasum -a 256 "$legacy_run/run.jsonl" | awk '{print $1}')"
legacy_view="$( (cd "$legacy_repo" && "$NEW_RUN" --metadata-view "$legacy_run") )"
assert_output "historical view defaults display/provenance to Claude" '"primary_provider":"claude"' printf '%s' "$legacy_view"
assert_output "historical flag is explicit" '"historical":true' printf '%s' "$legacy_view"
assert_output "historical view cannot approve" '"approval_eligible":false' printf '%s' "$legacy_view"
assert_no_file "reader does not rewrite history" "$legacy_run/run-metadata.json"
assert_eq "historical ledger stays byte-identical" "$legacy_before" "$(shasum -a 256 "$legacy_run/run.jsonl" | awk '{print $1}')"

t_case "metadata absence is historical only when the ledger predates provider awareness"
current_repo="$(mk_repo)"; current_out="$( (cd "$current_repo" && "$NEW_RUN" current-missing) )"; current_run="$current_repo/$current_out"
rm -f "$current_run/run-metadata.json"
assert_rc "provider-aware missing metadata is malformed current state" 2 "$NEW_RUN" --metadata-view "$current_run"
printf '{bad\n' > "$rd/run-metadata.json"
assert_rc "malformed current metadata fails closed" 2 "$NEW_RUN" --metadata-view "$rd"

# ===========================================================================
# AC-001 / AC-002 / AC-003 / AC-005 — input validation, the base guard, and the metadata field set.
#
# Every refusal case below asserts THREE things and the third is the one that matters: the exit
# status, the diagnostic, and inventory_of before == inventory_of after. The first two are satisfied
# by a guard placed anywhere at all, including after the scaffold has already been written; only the
# third distinguishes "refused" from "refused loudly after creating the run anyway", which is the
# exact shape of the defect these criteria exist to close.

# ---------------------------------------------------------------------------
t_case "--help prints a synopsis to stdout and creates nothing (AC-001)"
repoH="$(mk_repo)"
inv_h_before="$(inventory_of "$repoH")"
# stderr is discarded, so this variable can only hold what went to STDOUT — which is where AC-001
# requires the synopsis, and is the opposite of where the refusal path sends the same text.
help_out="$( (cd "$repoH" && "$NEW_RUN" --help) 2>/dev/null )"; rc_h=$?
inv_h_after="$(inventory_of "$repoH")"
assert_eq "--help exits 0" 0 "$rc_h"
assert_output "--help writes a usage synopsis to stdout" "usage: firm-new-run" printf '%s' "$help_out"
assert_output "the synopsis names --base, the flag the base guard demands" "--base" printf '%s' "$help_out"
assert_eq "--help creates no run dir, no run.jsonl, no metadata, and does not touch CURRENT_RUN" \
  "$inv_h_before" "$inv_h_after"

t_case "-h is help too, and stays help in a repo that already holds a run (AC-001)"
repoH2="$(mk_repo)"
outH2="$( (cd "$repoH2" && "$NEW_RUN" already-here) )"
inv_h2_before="$(inventory_of "$repoH2")"
help_out2="$( (cd "$repoH2" && "$NEW_RUN" -h) 2>/dev/null )"; rc_h2=$?
inv_h2_after="$(inventory_of "$repoH2")"
assert_eq "-h exits 0" 0 "$rc_h2"
assert_output "-h writes the same synopsis to stdout" "usage: firm-new-run" printf '%s' "$help_out2"
# Without this the two inventories could be equal because the snapshot sees nothing at all — a
# comparison that cannot fail. It proves the snapshot really does contain the pre-existing run.
case "$inv_h2_before" in
  *"$outH2"*) _t_ok "fixture precondition: the snapshot actually contains the pre-existing run" ;;
  *) _t_no "fixture precondition: the snapshot actually contains the pre-existing run" "got: $(_t_ctx "$inv_h2_before")" ;;
esac
assert_eq "-h adds no second run and leaves CURRENT_RUN's bytes unchanged" \
  "$inv_h2_before" "$inv_h2_after"

# ---------------------------------------------------------------------------
t_case "a flag-shaped slug is refused, before anything is created (AC-002)"
repoS1="$(mk_repo)"
inv_s1_before="$(inventory_of "$repoS1")"
# `2>&1 1>/dev/null` in this order captures ONLY stderr: fd2 is pointed at the substitution's pipe
# first, then fd1 is sent to /dev/null. AC-002 requires the diagnostic on stderr specifically.
err_s1="$( (cd "$repoS1" && "$NEW_RUN" --not-a-flag) 2>&1 1>/dev/null )"; rc_s1=$?
inv_s1_after="$(inventory_of "$repoS1")"
assert_eq "a leading-hyphen slug exits 2" 2 "$rc_s1"
assert_output "the stderr diagnostic names the rejected slug --not-a-flag" "--not-a-flag" printf '%s' "$err_s1"
assert_eq "no <ts>---not-a-flag run dir, and no partial scaffold, is left behind" "$inv_s1_before" "$inv_s1_after"

t_case "a slug the sanitizer strips to nothing is refused, before anything is created (AC-002)"
repoS2="$(mk_repo)"
inv_s2_before="$(inventory_of "$repoS2")"
err_s2="$( (cd "$repoS2" && "$NEW_RUN" '###') 2>&1 1>/dev/null )"; rc_s2=$?
inv_s2_after="$(inventory_of "$repoS2")"
assert_eq "a slug that sanitizes to nothing exits 2" 2 "$rc_s2"
assert_output "the stderr diagnostic names the rejected slug ###" "###" printf '%s' "$err_s2"
assert_eq "no bare-timestamp run dir, and no partial scaffold, is left behind" "$inv_s2_before" "$inv_s2_after"

# ---------------------------------------------------------------------------
# AC-003. accepted_base_sha is what firm-qa-checkout, firm-traceability-check, firm-qa-clean-check and
# firm-reviewer-common all treat as ALREADY REVIEWED. Deriving it from HEAD marks whatever HEAD is
# sitting on as pre-approved, silently — which is how the source engagement nearly shipped its most
# security-sensitive commit without review.
t_case "HEAD off the default branch tip with no stated base is refused, and creates nothing (AC-003)"
repoB="$(mk_repo)"
( cd "$repoB" && git checkout -q -b unreviewed-work && echo more >> seed.txt && git add -A && git commit -qm more ) >/dev/null 2>&1
b_main_sha="$(sha_of "$repoB" main)"
b_head_sha="$(sha_of "$repoB" unreviewed-work)"
inv_b_before="$(inventory_of "$repoB")"
err_b="$( (cd "$repoB" && "$NEW_RUN" would-be-silent) 2>&1 1>/dev/null )"; rc_b=$?
inv_b_after="$(inventory_of "$repoB")"
assert_ne "fixture precondition: HEAD is genuinely not the default branch's tip" "$b_main_sha" "$b_head_sha"
assert_eq "an unstated base is refused with exit 2" 2 "$rc_b"
assert_output "the diagnostic states which branch HEAD is on" "unreviewed-work" printf '%s' "$err_b"
assert_output "the diagnostic states the base it would otherwise have recorded" "$b_head_sha" printf '%s' "$err_b"
assert_eq "a refused run leaves the repository tree and CURRENT_RUN unchanged" "$inv_b_before" "$inv_b_after"

t_case "a stated --base is what gets recorded, and it is not HEAD (AC-003)"
# The supplied base MUST differ from HEAD here, for the mirror of the reason the feature-branch case
# above must supply "$feature_sha": if --base were HEAD's own sha, every assertion below would pass
# against an implementation that ignored --base entirely and recorded HEAD.
outB="$( (cd "$repoB" && "$NEW_RUN" --base "$b_main_sha" stated-base) )"; rc_ok=$?
rdB="$repoB/$outB"
assert_eq "a stated base is accepted, exit 0" 0 "$rc_ok"
assert_eq "run.jsonl's base_sha is the stated commit's full sha" "$b_main_sha" "$(json_field "$rdB/run.jsonl" base_sha)"
assert_eq "run-metadata.json's accepted_base_sha is the same full sha" "$b_main_sha" "$(json_field "$rdB/run-metadata.json" accepted_base_sha)"
assert_ne "accepted_base_sha is NOT HEAD's sha" "$b_head_sha" "$(json_field "$rdB/run-metadata.json" accepted_base_sha)"
recorded_base="$(json_field "$rdB/run-metadata.json" accepted_base_sha)"
assert_eq "and it is the full 40-character sha, which is what the reader demands of an eligible run" \
  40 "${#recorded_base}"
assert_eq "the ledger records HOW the base was chosen" "explicit" "$(json_field "$rdB/run.jsonl" base_source)"

t_case "a detached HEAD sitting ON the default branch's tip is allowed, silently (AC-003)"
# THE CASE THAT MAKES THE DESIGN OBSERVABLE. The guard compares SHAs, never branch names. An
# implementation that asked "is HEAD's branch the default branch?" would pass every other case in this
# file and refuse right here, because a detached HEAD has no branch name at all — so without this
# case, "by SHA, not by name" is a claim in a comment rather than a tested property.
repoD="$(mk_repo)"
d_main_sha="$(sha_of "$repoD" main)"
( cd "$repoD" && git checkout -q --detach main ) >/dev/null 2>&1
assert_fail "fixture precondition: HEAD is genuinely detached, so there is no branch name to match on" \
  git -C "$repoD" symbolic-ref --quiet HEAD
outD="$( (cd "$repoD" && "$NEW_RUN" detached-at-the-tip) )"; rc_d=$?
assert_eq "a detached HEAD at the default tip needs no --base" 0 "$rc_d"
assert_eq "and it records that tip as the base" "$d_main_sha" "$(json_field "$repoD/$outD/run.jsonl" base_sha)"
assert_eq "and says the base came from the default branch's tip" \
  "default_branch_tip" "$(json_field "$repoD/$outD/run.jsonl" base_source)"

t_case "commits exist but NO default branch can be resolved: refused, and creates nothing (AC-003)"
# The fail-closed case the guard exists for at its edge: unknown is not the same as HEAD. A repo whose
# only branch is neither main nor master and which has no origin/HEAD (a clone --single-branch, or a
# trunk/develop convention) cannot say what its default branch is, so it cannot say that HEAD is that
# branch's tip either. Refusing here is USER-VISIBLE BREAKAGE beyond the feature-branch case, taken
# deliberately: the tool must not invent an answer about what was already reviewed. The two shapes
# where HEAD resolves to NOTHING are the opposite case and must keep working untouched — the two
# pre-existing "no baseline is written..." cases above are what hold that line.
repo7="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; t_track "$repo7"
( cd "$repo7" && git init -q . && git symbolic-ref HEAD refs/heads/trunk \
  && git config user.email test@agent-firm.local && git config user.name "firm tests" \
  && git config commit.gpgsign false \
  && printf '%s\n' '.agent-firm/' >> .git/info/exclude \
  && printf 'seed\n' > seed.txt && git add -A && git commit -qm seed ) >/dev/null 2>&1
trunk_sha="$(sha_of "$repo7" trunk)"
assert_fail "fixture precondition: there is no local main branch" git -C "$repo7" show-ref --verify --quiet refs/heads/main
assert_fail "fixture precondition: there is no local master branch" git -C "$repo7" show-ref --verify --quiet refs/heads/master
assert_ne "fixture precondition: HEAD does resolve to a commit, so a base WOULD have been recorded" "" "$trunk_sha"
inv_7_before="$(inventory_of "$repo7")"
err_7="$( (cd "$repo7" && "$NEW_RUN" no-default-branch) 2>&1 1>/dev/null )"; rc_7=$?
inv_7_after="$(inventory_of "$repo7")"
assert_eq "an unresolvable default branch is refused with exit 2, not treated as agreement" 2 "$rc_7"
assert_output "the diagnostic says the default branch could not be resolved" \
  "no resolvable default branch" printf '%s' "$err_7"
assert_output "and still names the base it would otherwise have recorded" "$trunk_sha" printf '%s' "$err_7"
assert_eq "nothing is created for a repo whose default branch is unknown" "$inv_7_before" "$inv_7_after"

t_case "and the same repo opens cleanly once the base is stated (AC-003)"
out7="$( (cd "$repo7" && "$NEW_RUN" --base "$trunk_sha" no-default-branch) )"; rc_7b=$?
assert_eq "--base is the documented way out of that refusal" 0 "$rc_7b"
assert_eq "the stated base is recorded" "$trunk_sha" "$(json_field "$repo7/$out7/run.jsonl" base_sha)"
assert_no_file "and no run-baseline.json is written, because the default branch is still unknown" \
  "$repo7/$out7/run-baseline.json"

# ---------------------------------------------------------------------------
# AC-005. --metadata-view compares run-metadata.json's parsed field set for EXACT equality against
# nine names and fails closed on any difference, so the record of HOW the base was chosen cannot live
# there: one added field would break the reader for every run already on disk. It goes on the
# append-only run_started event instead, and these cases are what hold that line.
t_case "--metadata-view still succeeds through every accepted path, with an unchanged field set (AC-005)"
assert_output "default-branch-tip run: --metadata-view succeeds" '"historical":false' "$NEW_RUN" --metadata-view "$rd5"
assert_output "explicit-base run: --metadata-view succeeds" '"historical":false' "$NEW_RUN" --metadata-view "$rdB"
assert_eq "default-branch-tip run: metadata carries exactly the field set the reader requires" \
  "$READER_REQUIRED_FIELDS" "$(json_keys "$rd5/run-metadata.json")"
assert_eq "explicit-base run: metadata carries exactly the field set the reader requires" \
  "$READER_REQUIRED_FIELDS" "$(json_keys "$rdB/run-metadata.json")"
assert_eq "the base decision is recorded on the append-only ledger event" \
  "default_branch_tip" "$(json_field "$rd5/run.jsonl" base_source)"

t_case "one extra field in run-metadata.json makes --metadata-view fail closed (AC-005)"
# The permanent, artifact-level form of AC-005's mutation proof: inject a field into a dedicated
# fixture run's metadata and watch the reader refuse it. Kept as a case rather than only as a
# one-off experiment, because the property it pins — that this reader is exact-set and unforgiving —
# is the whole reason base_source is on the ledger and not here.
repoM="$(mk_repo)"
outM="$( (cd "$repoM" && "$NEW_RUN" metadata-field-set) )"
rdM="$repoM/$outM"
assert_ok "the fixture run reads cleanly before the injection" "$NEW_RUN" --metadata-view "$rdM"
t_python -c '
import json,sys
path=sys.argv[1]
with open(path) as fh: data=json.load(fh)
data["base_source"]="explicit"
with open(path,"w") as fh: json.dump(data,fh,separators=(",",":"))' "$rdM/run-metadata.json"
assert_rc "one extra field and the reader refuses the run" 2 "$NEW_RUN" --metadata-view "$rdM"

t_summary
