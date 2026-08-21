#!/usr/bin/env bash
# tests/test-reviewer-capability-contract.sh
#
# The DRIFT CHECK. Capability discovery and the judge invocation are two halves of one claim: "the
# controls this wrapper depends on exist on the surface it uses them through". On 2026-08-21 those
# halves were found pointing at different surfaces — `codex --help` was probed while `codex exec ...`
# was invoked — so a fully capable provider was published as `unsupported_capability` (exit 3) and
# the required cross-provider second voice was suppressed on every run, laundered into a routine
# waiver request. The surface fix alone leaves that CLASS open; this file closes it.
#
# It asserts, in both directions and per provider, that
#   (1) every control the wrapper passes on the invocation line is required by discovery, and
#   (2) every control discovery requires is one the wrapper actually passes, and
#   (3) the subcommand path the wrapper invokes is itself one of the probed help surfaces.
# Then it MUTATES a copy of the wrapper to add an invocation flag without declaring it, and asserts
# the same check FAILS — a check that cannot fail is decoration, not a guard.
#
# Offline: no run directory, no ledger write, no provider execution. `--print-capability-contract`
# prints a static declaration and exits before any of that, which is why this file runs on every
# profile including --unsupported-p2.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMON="$BIN/firm-reviewer-common"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-capcontract.XXXXXX")"; t_track "$WORK"

# The comparator. Takes a wrapper path; prints every violation it finds and exits 1 if there is one.
# Used against the real wrapper (must pass) and against a mutant (must fail).
cat > "$WORK/drift-check.py" <<'PY'
import json
import subprocess
import sys

wrapper = sys.argv[1]
done = subprocess.run([wrapper, "gpt", "--print-capability-contract"],
                      capture_output=True, text=True)
if done.returncode != 0:
    print(f"contract introspection exited {done.returncode}: {done.stderr.strip()}")
    sys.exit(2)
contract = json.loads(done.stdout)
problems = []
providers = contract["providers"]
if set(providers) != {"gpt", "claude"}:
    problems.append(f"contract must declare exactly gpt and claude, got {sorted(providers)}")

for name in sorted(providers):
    entry = providers[name]
    required = entry["required_flags"]
    passed = entry["invocation_flags"]
    argv = entry["invocation_argv"]
    surfaces = [tuple(surface) for surface in entry["help_surfaces"]]
    aliases = entry["flag_aliases"]

    if len(set(required)) != len(required):
        problems.append(f"{name}: required_flags contains duplicates: {required}")

    # (1) invocation -> discovery. A flag added to the invocation and not to discovery would
    #     otherwise only be discovered by a provider rejecting it mid-judge, in production.
    undeclared = [flag for flag in passed if flag not in required]
    if undeclared:
        problems.append(
            f"{name}: the wrapper passes {undeclared} on the invocation line but discovery does not "
            f"require them — add them to required_flags (or to flag_aliases if they are short forms)")

    # (2) discovery -> invocation. A required flag nothing passes is a probe that can only produce a
    #     false negative: it can fail the provider over a control the wrapper never uses.
    unused = [flag for flag in required if flag not in passed]
    if unused:
        problems.append(
            f"{name}: discovery requires {unused} but the wrapper never passes them on the "
            f"invocation line — drop them or start using them")

    # (3) the probed surfaces must include the one the wrapper is invoked through. This is the
    #     defect itself: gpt is invoked as `codex exec ...`, so `exec --help` must be probed.
    subcommand = []
    for token in argv:
        if token.startswith("-"):
            break
        subcommand.append(token)
    if tuple(subcommand + ["--help"]) not in surfaces:
        problems.append(
            f"{name}: the wrapper invokes the {subcommand or ['<top level>']} surface, but the "
            f"probed help surfaces are {[list(s) for s in surfaces]} — discovery would interrogate a "
            f"surface the wrapper does not use")
    if not surfaces:
        problems.append(f"{name}: declares no help surfaces")

    # Alias hygiene: an alias entry that maps a flag nobody passes is dead weight that can silently
    # satisfy direction (1) for a flag that was removed from the invocation.
    stale = [short for short in aliases if short not in argv]
    if stale:
        problems.append(f"{name}: flag_aliases maps {stale}, which the invocation does not pass")

for line in problems:
    print(line)
sys.exit(1 if problems else 0)
PY

t_case "discovery and the judge invocation agree in both directions, per provider"
assert_ok "the shipped wrapper has no discovery/invocation drift" \
  python3 "$WORK/drift-check.py" "$COMMON"

t_case "the declaration says what it must about each provider's real surface"
assert_ok "gpt probes both codex --help and codex exec --help; claude probes top level only" \
  python3 - "$COMMON" <<'PY'
import json, subprocess, sys
d = json.loads(subprocess.run([sys.argv[1], "gpt", "--print-capability-contract"],
                              capture_output=True, text=True, check=True).stdout)
gpt = d["providers"]["gpt"]["help_surfaces"]
claude = d["providers"]["claude"]["help_surfaces"]
assert gpt == [["--help"], ["exec", "--help"]], gpt
assert claude == [["--help"]], claude
PY
assert_output "introspection carries no path, prompt or credential" "SCHEMA_PATH" \
  "$COMMON" gpt --print-capability-contract
assert_ok "introspection runs no provider and needs no run directory" \
  sh -c "'$COMMON' claude --print-capability-contract >/dev/null"

t_case "the drift check bites: an invocation flag added without declaring it fails"
cp "$COMMON" "$WORK/mutant-extra-invocation-flag"
python3 - "$WORK/mutant-extra-invocation-flag" <<'PY'
import sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
old = '"--ephemeral", "-s", "read-only"'
assert text.count(old) == 1, "mutation anchor is not unique; update this test"
open(p, "w", encoding="utf-8").write(text.replace(old, '"--ephemeral", "--undeclared-control", "-s", "read-only"'))
PY
chmod +x "$WORK/mutant-extra-invocation-flag"
assert_fail "an undeclared invocation flag is caught" \
  python3 "$WORK/drift-check.py" "$WORK/mutant-extra-invocation-flag"
assert_output "and it is named in the failure" "--undeclared-control" \
  python3 "$WORK/drift-check.py" "$WORK/mutant-extra-invocation-flag"

t_case "the drift check bites: a required flag nothing passes fails"
cp "$COMMON" "$WORK/mutant-unused-required-flag"
python3 - "$WORK/mutant-unused-required-flag" <<'PY'
import sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
old = '"required_flags": ["--skip-git-repo-check",'
assert text.count(old) == 1, "mutation anchor is not unique; update this test"
open(p, "w", encoding="utf-8").write(text.replace(old, '"required_flags": ["--never-passed", "--skip-git-repo-check",'))
PY
chmod +x "$WORK/mutant-unused-required-flag"
assert_fail "a required flag the wrapper never passes is caught" \
  python3 "$WORK/drift-check.py" "$WORK/mutant-unused-required-flag"
assert_output "and it is named in the failure" "--never-passed" \
  python3 "$WORK/drift-check.py" "$WORK/mutant-unused-required-flag"

t_case "the drift check bites: probing a surface the wrapper does not invoke fails"
cp "$COMMON" "$WORK/mutant-wrong-surface"
python3 - "$WORK/mutant-wrong-surface" <<'PY'
import sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
old = '"help_surfaces": [["--help"], ["exec", "--help"]],'
assert text.count(old) == 1, "mutation anchor is not unique; update this test"
# This is the ORIGINAL defect, reintroduced: probe only the top level while invoking `codex exec`.
open(p, "w", encoding="utf-8").write(text.replace(old, '"help_surfaces": [["--help"]],'))
PY
chmod +x "$WORK/mutant-wrong-surface"
assert_fail "reintroducing the original top-level-only probe is caught" \
  python3 "$WORK/drift-check.py" "$WORK/mutant-wrong-surface"
assert_output "and the unprobed invoked surface is named" "exec" \
  python3 "$WORK/drift-check.py" "$WORK/mutant-wrong-surface"

t_summary
