#!/usr/bin/env bash
# tests/test-doctor-retired-check.sh — firm-doctor's retired-permission-rules check must not report a
# clean PASS on a settings.json it could not actually inspect, AND must not let a non-verifying
# outcome exit 0.
#
# Two rounds of the same fail-open live here.
#
# Round 1: the first version of the check swallowed every parse failure with
# `except Exception: sys.exit(0)`, silently printing "carries no retired permission rules" for a file
# that was invalid JSON, or whose `permissions` key was shaped as a list instead of an object.
#
# Round 2 (what most of this file now pins): the repair downgraded that false PASS to a WARN — and
# WARN does not reach firm-doctor's exit code, which is gated on FAILS alone. So `firm-doctor &&
# <run the firm>` still proceeded on a settings file nobody could read, printed as "OK with warnings".
# The check's own header says "This is a FAIL, not a warning"; three lines later it wasn't one.
# A fail-closed check has to charge the same price for "this is broken" and "I could not verify this",
# or it is advice, not a gate. Same for the policy file itself: it used to be read under a bare
# `if [ -f ... ]` with no `else`, so DELETING agent-firm/policy/retired-permissions.json made a whole
# FAIL-class check evaporate with no output at all.
#
# HOW THE EXIT-CODE CLAIM IS PROVEN (and why not a bare `assert_rc 1`): firm-doctor reports on the
# whole environment, so an unrelated FAIL (e.g. jsonschema not importable under the test's isolated
# HOME) can make it exit 1 for reasons having nothing to do with this check — an `assert_rc 1` would
# then pass while proving nothing. Every case below instead varies ONE input against a control run in
# the same environment and asserts the summary's FAIL counter went up by exactly one. The counter is
# what gates the exit code (`[ "$FAILS" -gt 0 ] && exit 1`), so +1 FAIL is the causal link, and the
# non-zero exit is asserted alongside it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOCTOR="$BIN/firm-doctor"

# Every line firm-doctor emits about retired rules — PASS, FAIL and the deny-list INFO alike. Kept
# deliberately wide: a filter that only matched the outcomes this file expects could hide a real
# regression by simply not selecting the line that changed.
RETIRED_LINE_RE='retired permission|retired-permission|retired rule|carry no retired'

doctor_in() { ( cd "$1" && HOME="$1/fake-home" "$DOCTOR" ); }
retired_lines() { doctor_in "$1" 2>&1 | grep -iE "$RETIRED_LINE_RE"; }

# ---- fixtures for varying the POLICY FILE itself --------------------------
# firm-doctor resolves the retirement policy relative to its own resolved location, so exercising a
# missing or corrupt policy file means giving it a different root to resolve against. These build a
# minimal one: just bin/firm-doctor plus (optionally) agent-firm/policy/retired-permissions.json.
GOOD_POLICY='{ "retired": [ { "rule": "Bash(cat:*)", "scope": ["allow","ask"] } ] }'

mk_doctor_root() { # <policy-json | MISSING> -> echoes root path
  _r="$(mktemp -d "${TMPDIR:-/tmp}/firm-droot.XXXXXX")"
  mkdir -p "$_r/bin" "$_r/agent-firm/policy"
  cp "$BIN/firm-doctor" "$_r/bin/firm-doctor"
  # firm-doctor runs the interpreter bin/firm-python resolves, so the resolver is part of the minimum
  # root now: without its sibling the doctor fails closed (loudly) before it reaches any check.
  cp "$BIN/firm-python" "$_r/bin/firm-python"
  [ "$1" = MISSING ] || printf '%s\n' "$1" > "$_r/agent-firm/policy/retired-permissions.json"
  printf '%s' "$_r"
}
mk_proj() { # <settings-json | NONE> -> echoes project path
  _p="$(mktemp -d "${TMPDIR:-/tmp}/firm-dproj.XXXXXX")"
  mkdir -p "$_p/.claude" "$_p/fake-home"
  [ "$1" = NONE ] || printf '%s\n' "$1" > "$_p/.claude/settings.json"
  printf '%s' "$_p"
}
doctor_at()    { ( cd "$2" && HOME="$2/fake-home" "$1/bin/firm-doctor" 2>&1 ); }
doctor_run()   { ( cd "$2" && HOME="$2/fake-home" "$1/bin/firm-doctor" >/dev/null 2>&1 ); }
# The summary's FAIL counter, e.g. "Summary: 2 PASS · 3 WARN · 1 FAIL" -> 1
fails_at()     { doctor_at "$1" "$2" | sed -n 's/.*· \([0-9][0-9]*\) FAIL.*/\1/p'; }
lines_at()     { doctor_at "$1" "$2" | grep -iE "$RETIRED_LINE_RE"; }

CLEAN_SETTINGS='{ "permissions": { "allow": [], "ask": [], "deny": [] } }'

# ---------------------------------------------------------------------------
t_case "malformed JSON is a FAIL, never a silent PASS and never a mere WARN"
proj="$(mk_repo)"; mkdir -p "$proj/.claude" "$proj/fake-home"
printf '{ this is not valid json\n' > "$proj/.claude/settings.json"

out="$(retired_lines "$proj")"
assert_output "project line FAILs on the parse failure" "FAIL" retired_lines "$proj"
assert_ok "project line does NOT claim PASS" sh -c "! printf '%s' \"\$1\" | grep -q 'PASS project settings carry no retired'" _ "$out"
assert_ok "project line is NOT downgraded to a WARN" sh -c "! printf '%s' \"\$1\" | grep -q 'WARN project settings.json could not be checked'" _ "$out"
assert_output "names the fix (re-run after repair)" "re-run firm-doctor" retired_lines "$proj"
assert_output "says why an unverifiable file is not clean" "UNVERIFIED, not clean" doctor_in "$proj"

# ---------------------------------------------------------------------------
t_case "permissions as the wrong JSON type is a FAIL, never a silent PASS"
proj2="$(mk_repo)"; mkdir -p "$proj2/.claude" "$proj2/fake-home"
printf '{ "permissions": [] }\n' > "$proj2/.claude/settings.json"

out2="$(retired_lines "$proj2")"
assert_output "project line FAILs on the type mismatch" "FAIL" retired_lines "$proj2"
assert_ok "project line does NOT claim PASS" sh -c "! printf '%s' \"\$1\" | grep -q 'PASS project settings carry no retired'" _ "$out2"

# ---------------------------------------------------------------------------
t_case "a bucket of the wrong JSON type is a FAIL, never a silent PASS"
proj3="$(mk_repo)"; mkdir -p "$proj3/.claude" "$proj3/fake-home"
printf '{ "permissions": { "allow": "Bash(cat:*)", "ask": [], "deny": [] } }\n' > "$proj3/.claude/settings.json"

assert_output "project line FAILs when a bucket isn't an array" "FAIL" retired_lines "$proj3"

# ---------------------------------------------------------------------------
t_case "a genuinely stale project still FAILs (the check still works when it CAN parse)"
proj4="$(mk_repo)"; mkdir -p "$proj4/.claude" "$proj4/fake-home"
printf '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": [], "deny": [] } }\n' > "$proj4/.claude/settings.json"

assert_output "project line FAILs on a real retired grant" "FAIL project settings still grant RETIRED" retired_lines "$proj4"

# ---------------------------------------------------------------------------
t_case "a clean, well-formed project still PASSes"
proj5="$(mk_repo)"; mkdir -p "$proj5/fake-home"
( cd "$proj5" && HOME="$proj5/fake-home" "$BIN/firm-install" ) >/dev/null 2>&1

assert_output "project line PASSes on a fresh install" "PASS project settings carry no retired" retired_lines "$proj5"

# ===========================================================================
# EXIT CODE — each finding must reach FAILS, which is the only thing that gates `exit 1`.
# One axis varies per comparison; the control run supplies the environment's baseline FAIL count.
# ===========================================================================
good_root="$(mk_doctor_root "$GOOD_POLICY")";  t_track "$good_root"
clean_proj="$(mk_proj "$CLEAN_SETTINGS")";     t_track "$clean_proj"

base_fails="$(fails_at "$good_root" "$clean_proj")"

t_case "control: a good policy + clean settings PASSes the retired check"
assert_output "control run PASSes the retired-rule line" "PASS project settings carry no retired" \
  lines_at "$good_root" "$clean_proj"
assert_ne "control run reports a FAIL count at all" "" "$base_fails"

# --- axis: the settings file (policy held constant) -------------------------
t_case "an unverifiable settings.json costs one FAIL and a non-zero exit"
bad_proj="$(mk_proj '{ nope')"; t_track "$bad_proj"
assert_eq "FAIL count is exactly one higher than the control" \
  "$((base_fails + 1))" "$(fails_at "$good_root" "$bad_proj")"
assert_fail "firm-doctor exits non-zero" doctor_run "$good_root" "$bad_proj"

t_case "a settings.json that still grants a retired rule costs one FAIL and a non-zero exit"
stale_proj="$(mk_proj '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": [], "deny": [] } }')"
t_track "$stale_proj"
assert_eq "FAIL count is exactly one higher than the control" \
  "$((base_fails + 1))" "$(fails_at "$good_root" "$stale_proj")"
assert_fail "firm-doctor exits non-zero" doctor_run "$good_root" "$stale_proj"

# --- axis: the policy file (settings held constant at $clean_proj) ----------
t_case "a MISSING retirement policy is a FAIL, not a silent skip"
# The whole check used to be wrapped in `if [ -f "$RETIRED_JSON" ]` with no `else`: deleting the
# policy file removed the check and its output entirely, and firm-doctor called that healthy.
gone_root="$(mk_doctor_root MISSING)"; t_track "$gone_root"
assert_output "says the check could not run" "SKIPPED, not passed" lines_at "$gone_root" "$clean_proj"
assert_output "reports it as a FAIL" "FAIL retired-permission policy NOT FOUND" lines_at "$gone_root" "$clean_proj"
assert_ok "does NOT silently claim the settings are clean" \
  sh -c "! printf '%s' \"\$1\" | grep -q 'PASS project settings carry no retired'" _ "$(lines_at "$gone_root" "$clean_proj")"
assert_eq "FAIL count is exactly one higher than the control (same settings file)" \
  "$((base_fails + 1))" "$(fails_at "$gone_root" "$clean_proj")"
assert_fail "firm-doctor exits non-zero" doctor_run "$gone_root" "$clean_proj"

t_case "an UNREADABLE retirement policy is a FAIL, not a silent skip"
junk_root="$(mk_doctor_root 'not json at all')"; t_track "$junk_root"
assert_output "reports it as a FAIL" "FAIL retired-permission policy" lines_at "$junk_root" "$clean_proj"
assert_output "says the check could not run" "SKIPPED, not passed" lines_at "$junk_root" "$clean_proj"
assert_eq "FAIL count is exactly one higher than the control (same settings file)" \
  "$((base_fails + 1))" "$(fails_at "$junk_root" "$clean_proj")"
assert_fail "firm-doctor exits non-zero" doctor_run "$junk_root" "$clean_proj"

t_case "a retirement policy that scopes a DENY rule for deletion is a FAIL"
# firm-install refuses such an entry outright (exit 4). firm-doctor must surface the same refusal
# rather than quietly reporting on a policy it would never honour.
deny_root="$(mk_doctor_root '{ "retired": [ { "rule": "Bash(sudo:*)", "scope": "deny" } ] }')"
t_track "$deny_root"
assert_output "names the deny-scoping problem" "scopes a DENY rule" lines_at "$deny_root" "$clean_proj"
assert_output "reports it as a FAIL" "FAIL" lines_at "$deny_root" "$clean_proj"
assert_eq "FAIL count is exactly one higher than the control (same settings file)" \
  "$((base_fails + 1))" "$(fails_at "$deny_root" "$clean_proj")"
assert_fail "firm-doctor exits non-zero" doctor_run "$deny_root" "$clean_proj"

t_case "one bad policy costs ONE FAIL, even with both a project and a user settings file"
# The policy is validated once, up front, rather than re-reported inside the per-scope loop. Two
# settings files must not turn one defective policy into two FAILs and two confusing "your
# settings.json could not be checked" lines about files that are actually fine.
two_proj="$(mk_proj "$CLEAN_SETTINGS")"; t_track "$two_proj"
mkdir -p "$two_proj/fake-home/.claude"
printf '%s\n' "$CLEAN_SETTINGS" > "$two_proj/fake-home/.claude/settings.json"
two_base="$(fails_at "$good_root" "$two_proj")"
assert_output "control: both scopes are checked, so both PASS" "PASS user settings carry no retired" \
  lines_at "$good_root" "$two_proj"
assert_eq "the deny-scoping policy defect adds exactly one FAIL, not one per settings file" \
  "$((two_base + 1))" "$(fails_at "$deny_root" "$two_proj")"
assert_ok "and it does not blame either settings file" \
  sh -c "! printf '%s' \"\$1\" | grep -q 'settings.json could not be checked'" _ "$(lines_at "$deny_root" "$two_proj")"

# ---------------------------------------------------------------------------
t_case "a retired rule sitting in \`deny\` is reported but is NOT a grant, so it costs no FAIL"
# `firm-install --migrate` will never delete a deny rule, so calling a deny hit "still grants a
# retired rule" and prescribing --migrate would be both wrong and unfixable — a permanent FAIL with
# no remedy. It stays visible as an INFO line instead.
deny_hit_proj="$(mk_proj '{ "permissions": { "allow": [], "ask": [], "deny": ["Bash(cat:*)"] } }')"
t_track "$deny_hit_proj"
assert_output "still reports the rule is there" "also list retired rule(s) under" lines_at "$good_root" "$deny_hit_proj"
assert_output "does not call a deny a grant" "PASS project settings carry no retired" lines_at "$good_root" "$deny_hit_proj"
assert_eq "FAIL count matches the control — no new failure" \
  "$base_fails" "$(fails_at "$good_root" "$deny_hit_proj")"

# ---------------------------------------------------------------------------
t_case "SEC-01 an interpreter that does not RUN cannot produce a PASS from any check"
# The retired-permission check read rc 0 plus empty stdout as "no hits", and a `#!/bin/sh` + `exit 0`
# shim produces exactly that. So a two-line shim named python3 got `PASS project settings carry no
# retired permission rules` and `PASS user settings carry no retired permission rules` printed about
# settings files nothing had opened -- directly contradicting this check's own comment ("in a
# fail-closed check it should not be able to produce a PASS from a policy it never checked, however
# it came to be run") and its header ("'Could not check' counts as a FAIL, not a WARN"). The same
# shim also produced PASS for jsonschema, for pyyaml and for the hook-adapter manifest check.
#
# bin/firm-python refuses that shim as a CANDIDATE now, but $FIRM_PYTHON on a host where nothing is
# compliant still becomes the degraded argv, and a fail-closed check has no business depending on a
# fix one layer down. Every one of those probes now carries proof of execution, so the answer is a
# FAIL that gates the exit code.
#
# Modelled the way tests/test-python-interpreter.sh models it: a resolver copy whose expectations no
# interpreter can satisfy, so the degraded path is taken on every host this suite runs on, plus a
# $FIRM_PYTHON that is executable and is not an interpreter.
shim_root="$(mk_doctor_root "$GOOD_POLICY")"; t_track "$shim_root"
sed 's/^FIRM_PYTHON_EXPECT_VERSION=.*/FIRM_PYTHON_EXPECT_VERSION="0.0.0"/' \
  "$BIN/firm-python" > "$shim_root/bin/firm-python"
chmod +x "$shim_root/bin/firm-python"
shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/firm-dshim.XXXXXX")"; t_track "$shim_dir"
printf '#!/bin/sh\nexit 0\n' > "$shim_dir/notpython"; chmod +x "$shim_dir/notpython"
shim_proj="$(mk_proj "$CLEAN_SETTINGS")"; t_track "$shim_proj"

assert_rc "precondition: the stand-in interpreter really does exit 0 for any program" 0 \
  "$shim_dir/notpython" - -c 'print("never runs")'
assert_output "precondition: the resolver degrades to it and says p2=no" "p2=no" \
  env FIRM_PYTHON="$shim_dir/notpython" "$shim_root/bin/firm-python" --status
shim_argv="$(env FIRM_PYTHON="$shim_dir/notpython" "$shim_root/bin/firm-python" --print-argv | sed -n '1p')"
assert_eq "precondition: and it is the argv every check below will run" \
  "$shim_dir/notpython" "$shim_argv"

doctor_shim() { ( cd "$shim_proj" && HOME="$shim_proj/fake-home" \
  FIRM_PYTHON="$shim_dir/notpython" "$shim_root/bin/firm-doctor" 2>&1 ); }
shim_out="$(doctor_shim)"
for claim in \
  "PASS project settings carry no retired" \
  "PASS user settings carry no retired" \
  "PASS python jsonschema present" \
  "PASS python pyyaml present" \
  "PASS repository manifests declare one plugin-owned"; do
  case "$shim_out" in
    *"$claim"*) _t_no "a non-executing interpreter cannot produce: $claim" "$(_t_ctx "$shim_out")" ;;
    *) _t_ok "a non-executing interpreter cannot produce: $claim" ;;
  esac
done
assert_output "the retired-rule check says it was SKIPPED, not passed" \
  "were NOT checked for retired permission rules" doctor_shim
assert_output "the hook-adapter check says the same" \
  "plugin hook ownership was NOT verified" doctor_shim
assert_output "and both point at the interpreter to verify" "bin/firm-python --status" doctor_shim
shim_rc=0
( cd "$shim_proj" && HOME="$shim_proj/fake-home" FIRM_PYTHON="$shim_dir/notpython" \
    "$shim_root/bin/firm-doctor" >/dev/null 2>&1 ) || shim_rc=$?
assert_ne "and firm-doctor does not exit 0 on a host it could not inspect" "0" "$shim_rc"

# CONTROL. The same root and the same project with the SHIM REMOVED must reach those PASSes again,
# or the five assertions above would be satisfied by a doctor that had simply stopped passing
# anything. $FIRM_PYTHON is unset here; everything else is identical.
ctl_out="$( cd "$shim_proj" && HOME="$shim_proj/fake-home" "$shim_root/bin/firm-doctor" 2>&1 )"
assert_output "CONTROL: with a real interpreter the retired-rule check PASSes again" \
  "PASS project settings carry no retired" printf '%s' "$ctl_out"
# The scratch root deliberately holds no plugin manifests, so the hook-adapter check FAILS here
# either way -- which makes it the sharper control: the two failure modes must not be the same
# sentence. With a real interpreter it is "ambiguous or malformed" (the probe ran and found nothing);
# with the shim it is "was NOT verified" (the probe never ran). A doctor that had merely started
# failing everything would print the same line in both runs.
assert_output "CONTROL: with a real interpreter the hook check fails as MALFORMED, not as unverified" \
  "plugin hook ownership is ambiguous or malformed" printf '%s' "$ctl_out"
case "$ctl_out" in
  *"plugin hook ownership was NOT verified"*)
    _t_no "CONTROL: and does not claim the probe failed to run" "$(_t_ctx "$ctl_out")" ;;
  *) _t_ok "CONTROL: and does not claim the probe failed to run" ;;
esac


t_summary
