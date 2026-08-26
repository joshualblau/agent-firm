#!/usr/bin/env bash
# tests/test-reviewer-capability-contract.sh
#
# The DRIFT CHECK. Capability discovery and the judge invocation are two halves of one claim: "every
# control this wrapper passes exists on the surface it passes it on". Both halves have now been found
# broken, in opposite directions:
#
#   * discovery probed `codex --help` while the wrapper invoked `codex exec ...`, so a capable
#     provider was published as unsupported_capability (exit 3) and the required second voice was
#     silently suppressed on every run;
#   * the first fix probed the UNION of both surfaces, which certified `--ask-for-approval` as ready
#     because it is in `codex --help` — while the invocation passed it to `codex exec`, which rejects
#     it (`codex exec -a never ...` exits 2). Same wrong question, inverted answer.
#
# So the relation asserted here is per-surface and BIDIRECTIONAL:
#   (1) the declared surfaces are exactly the surfaces the invocation passes controls on, in order;
#   (2) on each surface, the declared controls are exactly the options the invocation passes there;
#   (3) the declaration and the invocation are internally well formed — no duplicate control token
#       anywhere, and every declared control really appears in argv.
# Then it MUTATES copies of the wrapper and asserts the check FAILS on each. A check that cannot fail
# is decoration; three of the five mutants below are the review's own successful defeats of the
# previous revision, kept as regressions.
#
# Offline: no run directory, no ledger write, no provider execution. `--print-capability-contract`
# prints a static declaration and exits before any of that, which is why this file runs on every
# profile including --unsupported-p2.
#
# NOT covered here, deliberately, and covered in tests/test-provider-reviewers.sh instead: that the
# runtime loop CONSUMES the declaration faithfully. This file reads the declaration, so a mutation
# like `capability["surfaces"][:1]` in the loop is invisible to it. The stub assertions in
# test-provider-reviewers.sh require both `args=--help` and `args=exec --help` in the provider call
# log and require exit 0, which is what actually pins the loop.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMON="$BIN/firm-reviewer-common"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-capcontract.XXXXXX")"; t_track "$WORK"

cat > "$WORK/drift-check.py" <<'PY'
import json
import subprocess
import sys
from collections import Counter

def _multiset_difference(left, right):
    """Elements of `left` not covered by `right`, WITH multiplicity, so a control passed twice and
    declared once is reported once rather than vanishing into a set difference."""
    remaining = Counter(right)
    out = []
    for item in left:
        if remaining[item]:
            remaining[item] -= 1
        else:
            out.append(item)
    return out

wrapper = sys.argv[1]
done = subprocess.run([wrapper, "gpt", "--print-capability-contract"],
                      capture_output=True, text=True)
if done.returncode != 0:
    print(f"contract introspection exited {done.returncode}: {done.stderr.strip()}")
    sys.exit(2)
contract = json.loads(done.stdout)
problems = []
providers = contract["providers"]
if not providers:
    problems.append("contract declares no providers")

for name in sorted(providers):
    entry = providers[name]
    declared = entry["declared_surfaces"]
    invoked = entry["invocation_surfaces"]
    argv = entry["invocation_argv"]

    # (1) Surfaces, both directions and in order. One-directional was the structural permission slip
    #     the false-positive blocker walked through: `invoked subset of probed` lets a probed surface
    #     the wrapper never uses satisfy a control, and lets dead surfaces accumulate unnoticed.
    declared_paths = [tuple(surface["subcommand"]) for surface in declared]
    invoked_paths = [tuple(surface["subcommand"]) for surface in invoked]
    if declared_paths != invoked_paths:
        problems.append(
            f"{name}: discovery probes surfaces {[list(p) for p in declared_paths]} but the wrapper "
            f"passes controls on {[list(p) for p in invoked_paths]} — every probed surface must be "
            f"one the wrapper uses, and every used surface must be probed")
        continue

    # (2) Controls, per surface, both directions. Being present on a DIFFERENT surface is a miss.
    for declared_surface, invoked_surface in zip(declared, invoked):
        path = list(declared_surface["subcommand"])
        where = " ".join(path + ["--help"]) if path else "--help"
        required = set(declared_surface["controls"])
        passed = set(invoked_surface["controls"])
        undeclared = sorted(passed - required)
        if undeclared:
            problems.append(
                f"{name}: the wrapper passes {undeclared} on the `{where}` surface but discovery "
                f"does not require them there — add them to that surface's controls")
        unused = sorted(required - passed)
        if unused:
            problems.append(
                f"{name}: discovery requires {unused} on the `{where}` surface but the wrapper never "
                f"passes them there — drop them, or move them to the surface that does")

    # (3) Well-formedness, as a MULTISET rather than a set-plus-no-duplicates rule.
    #
    #     The original rule was "no control token may appear twice, anywhere". That was correct for
    #     the argv it was written against and is not correct for a CLI that takes the same option
    #     repeatedly: `codex exec` carries its typed overrides on `-c`, and the judge sends two of
    #     them (`model_reasoning_effort` and `approval_policy`). Under the old rule the honest argv
    #     was a drift error, which is a check telling the truth about a rule that had become false.
    #
    #     The property the rule EXISTS for is preserved exactly, and is if anything sharper: the
    #     multiset of option tokens in the argv must equal the multiset of declared controls. Two
    #     distinct controls still cannot collapse into one checked entry, because collapsing changes
    #     the counts; and a control passed twice must now be DECLARED twice, which is a statement
    #     about the surface rather than an exemption from one.
    all_controls = [flag for surface in declared for flag in surface["controls"]]
    option_tokens = [token for token in argv if token.startswith("-")]
    if sorted(option_tokens) != sorted(all_controls):
        extra = sorted(_multiset_difference(option_tokens, all_controls))
        missing = sorted(_multiset_difference(all_controls, option_tokens))
        problems.append(
            f"{name}: the invocation option multiset does not match the declared control multiset — "
            f"passed but not declared (with multiplicity): {extra}; declared but not passed: "
            f"{missing}. Every option passed must be declared, as many times as it is passed.")
    for flag in all_controls:
        if flag not in argv:
            problems.append(f"{name}: declared control {flag} does not appear in the invocation argv")

for line in problems:
    print(line)
sys.exit(1 if problems else 0)
PY

# mutate <name> <old> <new> — copy the wrapper and apply one textual mutation. Echoes the copy path.
mutate() {
  local target="$WORK/mutant-$1"
  cp "$COMMON" "$target"
  # THE MUTANT MUST BE RUNNABLE, and since the P2 interpreter remediation it is not runnable alone:
  # bin/firm-reviewer-common line 8 sources its SIBLING `firm-python` to resolve the one interpreter
  # the firm admits. A copy on its own exits 1 at that line before parsing a byte of the program, so
  # every `and it is named` assertion below failed on the harness rather than on the mutation --
  # loudly, but for entirely the wrong reason. The sibling is copied with it.
  cp "$BIN/firm-python" "$WORK/firm-python" 2>/dev/null || true
  t_python - "$target" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path, encoding="utf-8").read()
assert text.count(old) == 1, f"mutation anchor is not unique ({text.count(old)}); update this test"
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
  chmod +x "$target"
  printf '%s' "$target"
}

t_case "discovery and the judge invocation agree per surface, in both directions"
assert_ok "the shipped wrapper has no discovery/invocation drift" \
  t_python "$WORK/drift-check.py" "$COMMON"

t_case "the declaration says what it must about each provider's real surfaces"
assert_ok "gpt declares exec and only exec; claude is top level only; -a is nowhere" \
  t_python - "$COMMON" <<'PY'
import json, subprocess, sys
d = json.loads(subprocess.run([sys.argv[1], "gpt", "--print-capability-contract"],
                              capture_output=True, text=True, check=True).stdout)
gpt = d["providers"]["gpt"]["declared_surfaces"]
claude = d["providers"]["claude"]["declared_surfaces"]
assert [s["subcommand"] for s in gpt] == [["exec"]], gpt
assert [s["subcommand"] for s in claude] == [[]], claude
# `-a` USED TO BE DECLARED AT THE TOP LEVEL AND PASSED THERE, and this case pinned that as correct.
# It is not. Measured on the installed codex-cli 0.147.0 while merging the two fixes for it:
#   codex exec -a never --help    rc 2  unexpected argument '-a' found
#   codex -a never exec --help    rc 0  -- parses, and the value is then DISCARDED
#   codex -a bogus  exec --help   rc 0  -- root options are not even VALIDATED past a subcommand
#   codex --sandbox bogus --help  rc 2  invalid value 'bogus'     (the control, no subcommand)
#   codex -s bogus exec --help    rc 0  -- same option, same discard  (the control, with one)
# `codex --help` states the rule: "If no subcommand is specified, options will be forwarded to the
# interactive CLI." So the top-level surface bought a zero exit status and no approval policy, and
# this contract certified it because a help text says what a surface ACCEPTS, not what it HONOURS.
# The policy is now the typed override `codex exec` documents, paired with --strict-config so a
# mistyped key is an error rather than the same silent no-op wearing a different hat.
argv = d["providers"]["gpt"]["invocation_argv"]
assert "-a" not in argv and "--ask-for-approval" not in argv, argv
assert "--strict-config" in argv, argv
assert argv.count("-c") == 2, argv
assert gpt[0]["controls"].count("-c") >= 1 and "--strict-config" in gpt[0]["controls"], gpt[0]
PY
assert_output "introspection carries no path, prompt or credential" "SCHEMA_PATH" \
  "$COMMON" gpt --print-capability-contract
assert_rc "introspection refuses to share an invocation with a real run" 2 \
  "$COMMON" gpt --print-capability-contract /some/run
assert_rc "introspection refuses to share an invocation with a bound option" 2 \
  "$COMMON" gpt --print-capability-contract --judge-timeout 300

t_case "it bites: an invocation flag added without declaring it"
m="$(mutate extra-invocation-flag '("--ephemeral", None),
                ("-s", "read-only")' \
     '("--ephemeral", None), ("--undeclared-control", None),
                ("-s", "read-only")')"
assert_fail "an undeclared invocation flag is caught" t_python "$WORK/drift-check.py" "$m"
assert_output "and it is named" "--undeclared-control" t_python "$WORK/drift-check.py" "$m"

t_case "it bites: a declared control nothing passes"
m="$(mutate unused-required-control '"controls": ["--skip-git-repo-check",' \
     '"controls": ["--never-passed", "--skip-git-repo-check",')"
assert_fail "a declared control the wrapper never passes is caught" t_python "$WORK/drift-check.py" "$m"
assert_output "and it is named" "--never-passed" t_python "$WORK/drift-check.py" "$m"

t_case "it bites: the ORIGINAL defect — probing only the top level while invoking a subcommand"
m="$(mutate wrong-surface '             "controls": ["--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                          "--strict-config", "--ephemeral", "-s", "-m", "-c", "-c",
                          "--output-schema", "-o"]},' \
     '             "controls": []},
            {"subcommand": [],
             "controls": ["--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                          "--strict-config", "--ephemeral", "-s", "-m", "-c", "-c",
                          "--output-schema", "-o"]},')"
assert_fail "reintroducing the top-level-only probe is caught" t_python "$WORK/drift-check.py" "$m"
assert_output "and the unprobed invoked surface is named" "exec" t_python "$WORK/drift-check.py" "$m"

t_case "it bites: the REVIEW'S defeat — a control satisfied on a surface it is not passed on"
# The false-positive blocker, rebuilt on the argv that actually ships. The mutant declares a
# top-level surface carrying `-a` -- where codex really does document it -- and then passes `-a` to
# `codex exec`, which rejects it. Under the old union rule this passed. The declaration and the
# invocation are mutated INDEPENDENTLY, which is the whole point: it is the disagreement between
# them that must be caught, not the presence of a particular flag.
m="$(mutate union-satisfaction '{"subcommand": ["exec"], "options": [
                ("--skip-git-repo-check", None),' \
     '{"subcommand": ["exec"], "options": [
                ("-a", "never"), ("--skip-git-repo-check", None),')"
assert_fail "passing a control to a surface that does not declare it is caught" \
  t_python "$WORK/drift-check.py" "$m"
assert_output "and the surface it was wrongly passed on is named" "exec --help" \
  t_python "$WORK/drift-check.py" "$m"

t_case "it bites: the REVIEW'S defeat — extra probed surfaces the wrapper never invokes"
m="$(mutate extra-surfaces '        "surfaces": [
            # ONE surface.' \
     '        "surfaces": [
            {"subcommand": ["login"], "controls": []},
            {"subcommand": ["mcp"], "controls": []},
            # ONE surface.')"
assert_fail "probing login/mcp help, which the wrapper never invokes, is caught" \
  t_python "$WORK/drift-check.py" "$m"
assert_output "and the mismatch names the surfaces" "login" t_python "$WORK/drift-check.py" "$m"

t_case "it bites: the REVIEW'S defeat — alias laundering has no surface left to attack"
# The previous revision normalised short options onto canonical long ones through a flag_aliases map.
# Review added real controls -x and --search plus {"-x": "--model", "--search": "--model"}; both
# normalised to --model, de-duplicated, and the comparator reported zero violations. There is no
# alias map now — controls are the exact tokens passed — so the same attack must surface as two
# undeclared controls.
m="$(mutate alias-laundering '("-m", model), ("-c", ' \
     '("-m", model), ("-x", model), ("--search", model), ("-c", ')"
assert_fail "two smuggled controls cannot collapse into one declared control" \
  t_python "$WORK/drift-check.py" "$m"
assert_output "and the first is named" "-x" t_python "$WORK/drift-check.py" "$m"
assert_output "and the second is named" "--search" t_python "$WORK/drift-check.py" "$m"

t_summary
