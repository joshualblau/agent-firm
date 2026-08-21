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

    # (3) Well-formedness. No duplicate control token anywhere in the declaration: with no alias or
    #     normalisation step left, a duplicate is the only remaining way two distinct controls could
    #     collapse into one checked entry.
    all_controls = [flag for surface in declared for flag in surface["controls"]]
    duplicates = sorted({flag for flag in all_controls if all_controls.count(flag) > 1})
    if duplicates:
        problems.append(f"{name}: control(s) {duplicates} are declared more than once")
    option_tokens = [token for token in argv if token.startswith("-")]
    argv_duplicates = sorted({t for t in option_tokens if option_tokens.count(t) > 1})
    if argv_duplicates:
        problems.append(f"{name}: the invocation passes {argv_duplicates} more than once")
    if len(option_tokens) != len(all_controls):
        problems.append(
            f"{name}: the invocation carries {len(option_tokens)} option tokens but the declaration "
            f"names {len(all_controls)} controls — every option passed must be declared exactly once")
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
  python3 - "$target" "$2" "$3" <<'PY'
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
  python3 "$WORK/drift-check.py" "$COMMON"

t_case "the declaration says what it must about each provider's real surfaces"
assert_ok "gpt passes -a at top level and everything else under exec; claude is top level only" \
  python3 - "$COMMON" <<'PY'
import json, subprocess, sys
d = json.loads(subprocess.run([sys.argv[1], "gpt", "--print-capability-contract"],
                              capture_output=True, text=True, check=True).stdout)
gpt = d["providers"]["gpt"]["declared_surfaces"]
claude = d["providers"]["claude"]["declared_surfaces"]
assert [s["subcommand"] for s in gpt] == [[], ["exec"]], gpt
assert gpt[0]["controls"] == ["-a"], gpt[0]
assert "-a" not in gpt[1]["controls"], gpt[1]
assert [s["subcommand"] for s in claude] == [[]], claude
# The invocation must place -a BEFORE the subcommand: `codex exec -a never ...` exits 2 on the real
# CLI ("unexpected argument '-a' found"), verified against codex-cli 0.149.0.
argv = d["providers"]["gpt"]["invocation_argv"]
assert argv.index("-a") < argv.index("exec"), argv
PY
assert_output "introspection carries no path, prompt or credential" "SCHEMA_PATH" \
  "$COMMON" gpt --print-capability-contract
assert_rc "introspection refuses to share an invocation with a real run" 2 \
  "$COMMON" gpt --print-capability-contract /some/run
assert_rc "introspection refuses to share an invocation with a bound option" 2 \
  "$COMMON" gpt --print-capability-contract --judge-timeout 300

t_case "it bites: an invocation flag added without declaring it"
m="$(mutate extra-invocation-flag '("--ephemeral", None), ("-s", "read-only")' \
     '("--ephemeral", None), ("--undeclared-control", None), ("-s", "read-only")')"
assert_fail "an undeclared invocation flag is caught" python3 "$WORK/drift-check.py" "$m"
assert_output "and it is named" "--undeclared-control" python3 "$WORK/drift-check.py" "$m"

t_case "it bites: a declared control nothing passes"
m="$(mutate unused-required-control '"controls": ["--skip-git-repo-check",' \
     '"controls": ["--never-passed", "--skip-git-repo-check",')"
assert_fail "a declared control the wrapper never passes is caught" python3 "$WORK/drift-check.py" "$m"
assert_output "and it is named" "--never-passed" python3 "$WORK/drift-check.py" "$m"

t_case "it bites: the ORIGINAL defect — probing only the top level while invoking a subcommand"
m="$(mutate wrong-surface '{"subcommand": ["exec"],
             "controls": ["--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                          "--ephemeral", "-s", "-m", "-c", "--output-schema", "-o"]},' '')"
assert_fail "reintroducing the top-level-only probe is caught" python3 "$WORK/drift-check.py" "$m"
assert_output "and the unprobed invoked surface is named" "exec" python3 "$WORK/drift-check.py" "$m"

t_case "it bites: the REVIEW'S defeat — a control satisfied on a surface it is not passed on"
# The false-positive blocker: -a is declared/probed at top level (where codex has it) while the
# invocation passes it to `codex exec` (which rejects it). Under the old union rule this passed.
m="$(mutate union-satisfaction '{"subcommand": [], "options": [("-a", "never")]},
            {"subcommand": ["exec"], "options": [
                ("--skip-git-repo-check", None),' \
     '{"subcommand": [], "options": []},
            {"subcommand": ["exec"], "options": [
                ("-a", "never"), ("--skip-git-repo-check", None),')"
assert_fail "passing a control to a surface that does not declare it is caught" \
  python3 "$WORK/drift-check.py" "$m"
assert_output "and the surface it was wrongly passed on is named" "exec --help" \
  python3 "$WORK/drift-check.py" "$m"

t_case "it bites: the REVIEW'S defeat — extra probed surfaces the wrapper never invokes"
m="$(mutate extra-surfaces '{"subcommand": [], "controls": ["-a"]},' \
     '{"subcommand": [], "controls": ["-a"]},
            {"subcommand": ["login"], "controls": []},
            {"subcommand": ["mcp"], "controls": []},')"
assert_fail "probing login/mcp help, which the wrapper never invokes, is caught" \
  python3 "$WORK/drift-check.py" "$m"
assert_output "and the mismatch names the surfaces" "login" python3 "$WORK/drift-check.py" "$m"

t_case "it bites: the REVIEW'S defeat — alias laundering has no surface left to attack"
# The previous revision normalised short options onto canonical long ones through a flag_aliases map.
# Review added real controls -x and --search plus {"-x": "--model", "--search": "--model"}; both
# normalised to --model, de-duplicated, and the comparator reported zero violations. There is no
# alias map now — controls are the exact tokens passed — so the same attack must surface as two
# undeclared controls.
m="$(mutate alias-laundering '("-m", model), ("-c", ' \
     '("-m", model), ("-x", model), ("--search", model), ("-c", ')"
assert_fail "two smuggled controls cannot collapse into one declared control" \
  python3 "$WORK/drift-check.py" "$m"
assert_output "and the first is named" "-x" python3 "$WORK/drift-check.py" "$m"
assert_output "and the second is named" "--search" python3 "$WORK/drift-check.py" "$m"

t_summary
