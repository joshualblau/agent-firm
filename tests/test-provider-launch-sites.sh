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
CLEAN="$(python3 "$SCAN" "$REPO" 2>&1)"; clean_rc=$?
assert_eq "the repository-wide scan passes" "0" "$clean_rc"
printf '%s\n' "$CLEAN" | sed 's/^/      /'
assert_ok "the scan actually scanned files rather than finding nothing to do" \
  sh -c "printf '%s' \"\$1\" | grep -qE 'scanned [0-9]{2,} tracked files'" sh "$CLEAN"
for owner in bin/firm-doctor bin/firm-run-evals bin/firm-bootstrap; do
  assert_ok "a launch site in $owner was derived from source and checked" \
    sh -c "printf '%s' \"\$1\" | grep -q '$owner'" sh "$CLEAN"
done

# A mutant per defect actually found in the wild, plus one per rule that could be quietly relaxed.
mutant() { # <name> <expected substring> <mutation>...
  local name="$1" expect="$2" out rc
  shift 2
  local args=()
  local one
  for one in "$@"; do args+=(--mutate "$one"); done
  out="$(python3 "$SCAN" "$REPO" "${args[@]}" 2>&1)"; rc=$?
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
# THE ONE THAT WAS REAL, in the file where it was real.
mutant "the 2026-08-23 defect itself: -a moved after exec in firm-run-evals" \
  'is passed on `codex exec --help`' \
  'bin/firm-run-evals:codex -a never exec --ephemeral:codex exec -a never --ephemeral'
# THE SECOND COPY, in firm-doctor, whose failure path is only a warn.
mutant "the same defect in firm-doctor's probe" \
  'is passed on `codex exec --help`' \
  'bin/firm-doctor:codex -a never exec --skip-git-repo-check:codex exec -a never --skip-git-repo-check'
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

t_summary
