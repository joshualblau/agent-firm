#!/bin/sh
# The eval's own guard for the integrity of the evidence handed to the cross-provider judge. It runs
# the firm's offline check (tests/test-judge-input-integrity.sh), which exercises the real redaction
# helpers extracted from bin/firm-reviewer-common rather than a reimplementation of them.
#
# Nothing here passes under the defect this eval guards. Under that defect the wrapper wrote every
# controlled file through a TEXTUAL redact(): a ledger record containing `\n@pytest.hookimpl(...)`
# had the escape's `n` consumed by the email pattern (`n@pytest.hookimpl` reads as an address), and
# the copy the judge received no longer parsed as JSONL -- while the wrapper had validated the same
# file as well-formed moments earlier and never re-read its own output.
#
# It also does not pass with a fix that merely tightened the email pattern: the checked file pins the
# structural path, the secret-named-key redaction that keeps structure from regressing disclosure,
# and the fail-closed post-redaction invariant, none of which a narrower regex provides.
#
# Fails closed on every ambiguity: no wrapper on PATH, no firm checkout, a check that will not run
# are all CANNOT CHECK, never a pass. Starts no model turn, so this costs no subscription spend.
set -e

wrapper=$(command -v firm-reviewer-common 2>/dev/null) || wrapper=""
if [ -z "$wrapper" ]; then
  wrapper=$(command -v firm-gpt-qa 2>/dev/null) || wrapper=""
fi
[ -n "$wrapper" ] || { echo "judge-input-integrity: no reviewer wrapper on PATH; CANNOT CHECK" >&2; exit 1; }

# Resolve through symlinks to the firm checkout that owns the wrapper, the same way the sibling
# credential guard does. ~/.local/bin/firm-* are links into the repo's bin/.
dir=$(CDPATH='' cd -- "$(dirname -- "$wrapper")" && pwd)
while [ -L "$wrapper" ]; do
  target=$(readlink "$wrapper")
  case "$target" in
    /*) wrapper="$target" ;;
    *)  wrapper="$dir/$target" ;;
  esac
  dir=$(CDPATH='' cd -- "$(dirname -- "$wrapper")" && pwd)
done
root=$(CDPATH='' cd -- "$dir/.." && pwd)

check="$root/tests/test-judge-input-integrity.sh"
[ -f "$check" ] || { echo "judge-input-integrity: $check is missing; CANNOT CHECK" >&2; exit 1; }
[ -f "$root/bin/firm-reviewer-common" ] || {
  echo "judge-input-integrity: $root/bin/firm-reviewer-common is missing; CANNOT CHECK" >&2; exit 1; }

echo "judge-input-integrity: checking $root/bin/firm-reviewer-common"
out=$(bash "$check" 2>&1) || {
  printf '%s\n' "$out" >&2
  echo "judge-input-integrity: the redaction integrity check FAILED" >&2
  exit 1
}
printf '%s\n' "$out"

# The summary line must show a non-zero number of passing cases and zero failures. A suite that
# silently ran nothing would otherwise read as a pass -- the same "green means nothing was examined"
# failure this eval exists to prevent.
printf '%s\n' "$out" | grep -Eq '── [1-9][0-9]* passed, 0 failed' || {
  echo "judge-input-integrity: the check did not report passing cases with zero failures; CANNOT CHECK" >&2
  exit 1
}

echo "judge-input-integrity: OK"
