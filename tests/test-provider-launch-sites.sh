#!/usr/bin/env bash
# Every provider-CLI launch site in the REPOSITORY, not just in the reviewer.
#
# The defect this guards has now been found three times in three different files. Change #1 bound
# discovery to invocation inside bin/firm-reviewer-common; on 2026-08-23 the identical `-a never`
# after `exec` was found in bin/firm-run-evals (where it meant NO Codex-primary behavioural eval had
# ever run — rc 2, 9ms, zero turns) and again in bin/firm-doctor's --probe path (where the failure
# was only a warn, so it looked like a flaky provider). Both were outside the scope of every check
# that existed, which is precisely how they survived. So the unit of checking is the repository.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$TESTS_DIR/provider-launch-scan.py"
REPO="$FIRM_ROOT"

if ! command -v codex >/dev/null 2>&1 || ! command -v claude >/dev/null 2>&1; then
  printf '  · provider-launch-sites\n'
  printf '      SKIP (a provider CLI is not installed; launch surfaces were NOT checked)\n'
  t_summary
  exit 0
fi

t_case "every launch site in the repository is accounted for and lands on a surface that accepts it"
CLEAN="$(t_python "$SCAN" "$REPO" 2>&1)"; clean_rc=$?
assert_eq "the repository-wide scan passes" "0" "$clean_rc"
printf '%s\n' "$CLEAN" | sed 's/^/      /'
assert_ok "the scan actually scanned files rather than finding nothing to do" \
  sh -c "printf '%s' \"\$1\" | grep -qE 'scanned [0-9]{2,} tracked files'" sh "$CLEAN"
for owner in bin/firm-doctor bin/firm-run-evals bin/firm-bootstrap; do
  assert_ok "a launch site in $owner was derived from source and checked" \
    sh -c "printf '%s' \"\$1\" | grep -q '$owner'" sh "$CLEAN"
done

# A FIXTURE THAT NAMES A PROVIDER IS NOT A FIXTURE THAT LAUNCHES ONE. tests/fixtures/ac007-mutation-
# matrix.py passes "claude"/"codex" as an ORIENTATION LABEL and a list of SUB-CASE NAMES to a local
# `record()` helper that writes a dict; it launches nothing, and test-run-evals-structural.sh asserts
# separately that it cannot. The scanner read that shape as argv and reported an unaccounted launch
# site, which is a guard crying wolf about its own test data. The anchor assertion below runs first
# on purpose: without it, deleting or renaming the fixture would make the real assertion vacuous and
# still green.
FIXTURE="$REPO/tests/fixtures/ac007-mutation-matrix.py"
assert_ok "the fixture whose data labels the scanner used to misread is still present and unchanged in shape" \
  grep -q 'record("ac007_placeholder_argv", "claude", result, \["angle_bracket_placeholder_in_command_argv"\])' "$FIXTURE"
assert_ok "a fixture that passes a provider name as DATA is not reported as a launch site" \
  sh -c "! printf '%s' \"\$1\" | grep -q 'ac007-mutation-matrix.py'" sh "$CLEAN"

# A mutant per defect actually found in the wild, plus one per rule that could be quietly relaxed.
mutant() { # <name> <expected substring> <mutation>...
  local name="$1" expect="$2" out rc
  shift 2
  local args=()
  local one
  for one in "$@"; do args+=(--mutate "$one"); done
  out="$(t_python "$SCAN" "$REPO" ${args[@]+"${args[@]}"} 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    _t_no "mutant is caught: $name" "the scan PASSED a mutated repository"
    return
  fi
  if printf '%s' "$out" | grep -q -- "$expect"; then
    _t_ok "mutant is caught: $name"
  else
    _t_no "mutant is caught: $name" "failed for the wrong reason: $(_t_ctx "$out")"
  fi
}

t_case "the mutants that matter"
# MUTATION ANCHORS ARE SOURCE LITERALS, so they moved when the source did. `codex -a never exec`
# is no longer written anywhere: the merge that produced this comment measured that codex ACCEPTS a
# root-position `-a` and then DISCARDS it (rc 0, and not even validated -- `codex -s bogus exec
# --help` is rc 0 while `codex --sandbox bogus --help` is rc 2), so moving the control in front of
# the subcommand bought a clean exit status and no approval policy at all. Every mutant below still
# injects the SAME defect into the SAME file and still expects the same finding; only the `from`
# side of each rewrite changed, from the intermediate repair to the argv that is actually shipped.
#
# WHAT NO MUTANT HERE CAN CATCH, recorded because the gap is the interesting part: this scanner asks
# whether a surface ACCEPTS a control, never whether it HONOURS one. `codex -a never exec ...`
# passes every check in this file. A help text cannot answer the second question, so the defence is
# upstream -- state policy only through a control the INVOKED surface documents, and pair it with
# --strict-config so an unrecognised key is an error rather than a silent no-op.
#
# THE ONE THAT WAS REAL, in the file where it was real.
mutant "the 2026-08-23 defect itself: -a moved after exec in firm-run-evals" \
  'is passed on `codex exec --help`' \
  'bin/firm-run-evals:"$codex_command" exec --ephemeral:"$codex_command" exec -a never --ephemeral'
# THE SECOND COPY, in firm-doctor, whose failure path is only a warn.
mutant "the same defect in firm-doctor's probe" \
  'is passed on `codex exec --help`' \
  'bin/firm-doctor:codex exec --skip-git-repo-check:codex exec -a never --skip-git-repo-check'
# THE FOURTH COPY NOBODY HAS WRITTEN YET. A new file that launches a provider CLI and is not in
# LAUNCH_OWNERS must fail on the day it is written, not by accident two changes later.
mutant "an unregistered file that launches a provider CLI" \
  'not accounted for in LAUNCH_OWNERS' \
  "bin/firm-version:#!/usr/bin/env bash:#!/usr/bin/env bash
codex exec --ephemeral -s read-only 'unregistered launch'"
# The undocumented-control escape hatch must not be a blanket pass for anything missing from help.
mutant "a control that is in neither the help text nor the measured list" \
  'needs a measurement in UNDOCUMENTED_CONTROLS' \
  'bin/firm-run-evals:--json "$prompt":--not-a-real-control --json "$prompt"'
# The registry must not be able to become fiction: an owner whose launch has vanished is a failure,
# because "declared as checked" while nothing is checked is worse than no entry at all.
mutant "a LAUNCH_OWNERS entry whose launch site no longer exists" \
  'the scan found no launch site in it' \
  'bin/firm-bootstrap:"claude":"clauded"' \
  'bin/firm-bootstrap:"codex":"codexed"'

# THE PYTHON SIDE STILL BITES. Not matching a fixture's data labels is only correct if a REAL python
# launch in the SAME file still fails, so these three mutants inject one into the very file the
# scanner stopped flagging, plus one into the registered python owner. `login status` carries no
# control at all, so it can only be recognised by codex's OWN published subcommand list -- which is
# the half of the rule a "must contain a dash" shortcut would have thrown away.
mutant "a control-free python launch (subcommand-led argv) in a fixture is still unaccounted" \
  'not accounted for in LAUNCH_OWNERS' \
  'tests/fixtures/ac007-mutation-matrix.py:families = {}:families = {}
subprocess.run(launcher("codex", ["login", "status"]))'
mutant "a python launch whose argv opens with a control is still unaccounted" \
  'not accounted for in LAUNCH_OWNERS' \
  'tests/fixtures/ac007-mutation-matrix.py:families = {}:families = {}
subprocess.run(launcher("claude", ["-p", "unregistered python launch"]))'
# COVERAGE is not SURFACE: prove the derived_python path still splits argv and checks each control
# against its own help text, in the one file registered `derived_python`.
mutant "a control a python launcher passes that its surface does not accept" \
  'needs a measurement in UNDOCUMENTED_CONTROLS' \
  'bin/firm-bootstrap:require("claude", "version", ["--version"]):require("claude", "version", ["--version", "--not-a-real-control"])'

t_case "the scanner's own blind spots"
# Two blind spots the review measured against the real scan: an argv built from an array made the
# surface line SILENTLY VANISH from the output, and an executable held in a variable evaded both the
# surface check and the LAUNCH_OWNERS coverage rule.
mutant "controls built from an array expansion are CANNOT CHECK, not a silent skip" \
  'CANNOT BE CHECKED' \
  'bin/firm-run-evals:"$codex_command" exec --ephemeral:"$codex_command" "${badargs[@]}" --ephemeral'
mutant "an executable held in a variable is still a launch, and still needs an owner" \
  'not accounted for in LAUNCH_OWNERS' \
  "bin/firm-version:#!/usr/bin/env bash:#!/usr/bin/env bash
CLI=codex
\"\$CLI\" exec --ephemeral -s read-only 'variable launcher'"

t_case "the escape hatch itself carries evidence, and the evidence is checked"
# Review proved the first UNDOCUMENTED_CONTROLS was a targeted mute button: one free-text line
# re-muted the exact firm-run-evals defect this scanner was built to catch. The mutants above prove
# an UNLISTED control fails; these prove a LISTED one is not thereby excused. They go through
# --measurements because mutating the scanner's own SOURCE cannot change a registry the running
# process has already imported — which is precisely why the hatch was untested to begin with.
measured() { # <name> <expected substring> <registry-json> [mutation]...
  local name="$1" expect="$2" registry="$3" out rc
  shift 3
  local args=()
  local one
  for one in "$@"; do args+=(--mutate "$one"); done
  printf '%s' "$registry" > "$T_REGISTRY"
  out="$(t_python "$SCAN" "$REPO" --measurements "$T_REGISTRY" ${args[@]+"${args[@]}"} 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    _t_no "measurement is rejected: $name" "the scan PASSED with that measurement"
  elif printf '%s' "$out" | grep -q -- "$expect"; then
    _t_ok "measurement is rejected: $name"
  else
    _t_no "measurement is rejected: $name" "failed for the wrong reason: $(_t_ctx "$out")"
  fi
}
T_REGISTRY="$(mktemp "${TMPDIR:-/tmp}/firm-measurements.XXXXXX")"; t_track "$T_REGISTRY"
# The control fixture has to name the version that is INSTALLED, or it fails the staleness rule
# instead of proving the seam works -- which is what it did after this branch was written against
# an older Claude version and landed on a newer host. Re-measured locally on 2026-09-01 with an
# invalid numeric value, which proves the parser recognizes the control without starting a provider.
VALID='[{"provider":"claude","subcommand":[],"control":"--max-turns","measurement":{"cli":"claude","version":"2.1.251","date":"2026-09-01","argv":["claude","--max-turns","text","-p","x"],"rc":1,"observed":"rc 1: option --max-turns argument text is invalid and must be a number"}}]'

# Control: the real, well-formed measurement still passes through the seam, so the cases below fail
# for their own reason and not because the seam breaks everything.
CLEAN_SEAM="$(t_python "$SCAN" "$REPO" --measurements <(printf '%s' "$VALID") 2>&1)"; seam_rc=$?
assert_eq "a well-formed current measurement still passes through the seam" "0" "$seam_rc"

# THE ONE THAT MATTERS: a measurement must not launder the cross-surface union. `-a` is documented
# at the codex TOP level and rejected by `codex exec`, which is the whole reason this scanner exists.
measured "it cannot excuse a control the PARENT surface documents (the forbidden union)" \
  'cross-surface union this scanner exists to reject' \
  '[{"provider":"codex","subcommand":["exec"],"control":"-a","measurement":{"cli":"codex","version":"0.149.0","date":"2026-08-23","argv":["codex","exec","-a","never"],"rc":0,"observed":"fine, trust me"}}]' \
  'bin/firm-run-evals:"$codex_command" exec --ephemeral:"$codex_command" exec -a never --ephemeral'
measured "a measurement against a CLI version that is not installed is stale, not evidence" \
  'Stale evidence is not evidence' \
  '[{"provider":"claude","subcommand":[],"control":"--max-turns","measurement":{"cli":"claude","version":"0.0.0-not-installed","date":"2026-08-23","argv":["claude","--max-turns","3"],"rc":0,"observed":"ok"}}]'
measured "a measurement whose argv does not contain the control it claims to excuse" \
  'measured something else' \
  '[{"provider":"claude","subcommand":[],"control":"--max-turns","measurement":{"cli":"claude","version":"2.1.238","date":"2026-08-23","argv":["claude","-p","x"],"rc":0,"observed":"ok"}}]'
measured "free text is not a measurement" \
  'not a well-formed measurement' \
  '[{"provider":"claude","subcommand":[],"control":"--max-turns","measurement":"measured 2026-08-23: fine, trust me"}]'
measured "a measurement with no ISO date" \
  'no ISO date' \
  '[{"provider":"claude","subcommand":[],"control":"--max-turns","measurement":{"cli":"claude","version":"2.1.238","date":"recently","argv":["claude","--max-turns"],"rc":0,"observed":"ok"}}]'

t_summary
