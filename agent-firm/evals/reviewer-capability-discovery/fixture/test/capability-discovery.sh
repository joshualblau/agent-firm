#!/bin/sh
# The eval's own guard for the reviewer capability probe. Two checks:
#
#   1. the firm's offline discovery/invocation drift check (tests/test-reviewer-capability-contract.sh)
#   2. a LIVE binding of each provider's declared surfaces against the installed CLI's real help
#      text, plus a parse check of the real invocation argv (test/surfaces.py, beside this file)
#
# Neither passes under either defect this eval guards. Against the original (probe `codex --help`,
# invoke `codex exec ...`): (1) fails because an invoked surface is not a probed surface, and (2)
# fails because `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--output-schema` and
# `--output-last-message` are absent from the only declared surface. Against the union rule that
# briefly replaced it: (2) fails twice over — `-a` is not on the `codex exec --help` surface it would
# be passed on, and the invocation itself does not parse (`codex exec -a never ... --help` exits 2).
#
# Fails closed on every ambiguity: no wrapper on PATH, no provider CLI installed, an unreadable help
# surface. "Could not check" is never reported as "checked and fine" — that conflation is the exact
# shape of the bug this eval guards.
set -e

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

wrapper=$(command -v firm-gpt-qa 2>/dev/null) || wrapper=""
[ -n "$wrapper" ] || { echo "capability-discovery: firm-gpt-qa is not on PATH; CANNOT CHECK" >&2; exit 1; }

# Resolve through the firm's install symlink to the real bin/, the same way the wrappers do.
dir=$(CDPATH='' cd -- "$(dirname -- "$wrapper")" && pwd)
while [ -L "$wrapper" ]; do
  target=$(readlink "$wrapper")
  case "$target" in /*) wrapper="$target" ;; *) wrapper="$dir/$target" ;; esac
  dir=$(CDPATH='' cd -- "$(dirname -- "$wrapper")" && pwd)
done
root=$(CDPATH='' cd -- "$dir/.." && pwd)

common="$root/bin/firm-reviewer-common"
drift="$root/tests/test-reviewer-capability-contract.sh"
[ -x "$common" ] || { echo "capability-discovery: missing $common; CANNOT CHECK" >&2; exit 1; }
[ -f "$drift" ]  || { echo "capability-discovery: missing $drift; CANNOT CHECK" >&2; exit 1; }

echo "capability-discovery: firm root $root"
echo "capability-discovery: (1) offline discovery/invocation drift check"
bash "$drift"

echo "capability-discovery: (2) declared help surfaces vs installed provider CLIs"
python3 "$here/surfaces.py" "$common"
