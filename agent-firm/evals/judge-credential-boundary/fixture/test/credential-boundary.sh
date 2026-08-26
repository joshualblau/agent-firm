#!/bin/sh
# The eval's own guard for the judge's credential boundary. It runs the firm's offline credential
# declaration check (tests/test-reviewer-credential-contract.sh), which also carries the LIVE binding
# (tests/credential-live-check.py) against the installed provider CLIs.
#
# Nothing here passes under the defect this eval guards. Under that defect HOME, XDG_CONFIG_HOME,
# CODEX_HOME and CLAUDE_CONFIG_DIR all pointed at freshly created empty directories and no credential
# was ever seeded into any of them, so the declared passthrough would be empty, the live probe would
# answer "not logged in" / loggedIn:false in both directions, and the judge could never reach the
# judge phase at all. It also would not pass with a passthrough that authenticates by handing over
# the operator's home: the canary in the live check asserts that agent settings, hooks, plugins, MCP
# configuration, skills, session history and project files stay unreachable.
#
# Fails closed on every ambiguity: no wrapper on PATH, no provider CLI, a check that will not run are
# all CANNOT CHECK, never a pass. Neither readiness probe starts a model turn, so this costs no
# subscription spend.
set -e

wrapper=$(command -v firm-gpt-qa 2>/dev/null) || wrapper=""
[ -n "$wrapper" ] || { echo "credential-boundary: firm-gpt-qa is not on PATH; CANNOT CHECK" >&2; exit 1; }

dir=$(CDPATH='' cd -- "$(dirname -- "$wrapper")" && pwd)
while [ -L "$wrapper" ]; do
  target=$(readlink "$wrapper")
  case "$target" in /*) wrapper="$target" ;; *) wrapper="$dir/$target" ;; esac
  dir=$(CDPATH='' cd -- "$(dirname -- "$wrapper")" && pwd)
done
root=$(CDPATH='' cd -- "$dir/.." && pwd)

common="$root/bin/firm-reviewer-common"
drift="$root/tests/test-reviewer-credential-contract.sh"
live="$root/tests/credential-live-check.py"
[ -x "$common" ] || { echo "credential-boundary: missing $common; CANNOT CHECK" >&2; exit 1; }
[ -f "$drift" ]  || { echo "credential-boundary: missing $drift; CANNOT CHECK" >&2; exit 1; }
[ -f "$live" ]   || { echo "credential-boundary: missing $live; CANNOT CHECK" >&2; exit 1; }

echo "credential-boundary: firm root $root"
echo "credential-boundary: (1) offline credential declaration + transport projection check"
bash "$drift"

echo "credential-boundary: (2) declared passthrough vs installed CLIs: authenticates, canary, fails closed"
python3 "$live" "$root/bin"
