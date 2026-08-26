#!/bin/sh
# The eval's own guard for the reviewer readiness gate. It runs the firm's readiness drift check
# (tests/test-reviewer-readiness-contract.sh), which is offline declaration checking plus mutants
# PLUS a live binding of the declaration against the installed provider CLIs
# (tests/readiness-live-check.py) in two states: this host's ambient environment, and a forced
# logged-out one made by pointing HOME/CODEX_HOME/CLAUDE_CONFIG_DIR at an empty directory.
#
# Nothing here passes under the defect this eval guards. The declared commands would be
# `login status --json` and `models list --json`, which exit 2 on the real codex; the declared key
# would be `status`, which no real response contains; and the wrapper would run a model-readiness
# phase that is undeclared and, on claude, is a PROMPT that bills a model turn rather than a query.
#
# Fails closed on every ambiguity: no wrapper on PATH, no provider CLI installed, a probe that will
# not run. "Could not check" is never reported as "checked and fine" — that conflation is the exact
# shape of the bug this eval guards. Neither declared probe starts a model turn, so this costs no
# subscription spend.
set -e

wrapper=$(command -v firm-gpt-qa 2>/dev/null) || wrapper=""
[ -n "$wrapper" ] || { echo "readiness-probes: firm-gpt-qa is not on PATH; CANNOT CHECK" >&2; exit 1; }

# Resolve through the firm's install symlink to the real bin/, the same way the wrappers do.
dir=$(CDPATH='' cd -- "$(dirname -- "$wrapper")" && pwd)
while [ -L "$wrapper" ]; do
  target=$(readlink "$wrapper")
  case "$target" in /*) wrapper="$target" ;; *) wrapper="$dir/$target" ;; esac
  dir=$(CDPATH='' cd -- "$(dirname -- "$wrapper")" && pwd)
done
root=$(CDPATH='' cd -- "$dir/.." && pwd)

common="$root/bin/firm-reviewer-common"
drift="$root/tests/test-reviewer-readiness-contract.sh"
live="$root/tests/readiness-live-check.py"
[ -x "$common" ] || { echo "readiness-probes: missing $common; CANNOT CHECK" >&2; exit 1; }
[ -f "$drift" ]  || { echo "readiness-probes: missing $drift; CANNOT CHECK" >&2; exit 1; }
[ -f "$live" ]   || { echo "readiness-probes: missing $live; CANNOT CHECK" >&2; exit 1; }

echo "readiness-probes: firm root $root"
echo "readiness-probes: (1) offline readiness declaration/probe drift check, with mutants"
bash "$drift"

echo "readiness-probes: (2) declared readiness commands, keys and exit statuses vs installed CLIs"
python3 "$live" "$common"
