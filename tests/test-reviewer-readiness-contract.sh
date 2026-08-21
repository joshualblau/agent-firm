#!/usr/bin/env bash
# tests/test-reviewer-readiness-contract.sh
#
# The READINESS DRIFT CHECK, sibling to tests/test-reviewer-capability-contract.sh and written for
# the same defect class: a firm probe asks a provider a question the provider does not answer in that
# form, and the firm records the non-answer as a fact about the provider.
#
# What it was: the wrapper ran `codex login status --json`, `codex models list --json`,
# `claude auth status --json` and `claude models list --json`, and looked for `status` or
# `authentication` in the reply. Three of those four commands do not exist in that form (rc=2, rc=2,
# rc=1) and the fourth reports authentication as `loggedIn: true`, so a fully authenticated host was
# judged "not a trusted structured available result" and the cross-provider second voice could not
# run in either direction.
#
# Three checks, all reading the declaration rather than restating it:
#
#   (1) OFFLINE well-formedness and single-construction: the argv the wrapper runs is built from the
#       declared command, exactly one `ready` answer exists, `ready` and `unavailable` exit statuses
#       are disjoint, declared JSON keys and answer keys agree in both directions, and no declared
#       matcher accepts an ambiguity corpus of responses that must never be read as an answer.
#   (2) OFFLINE source binding: the readiness phase runs the declared probe and NOTHING else. This
#       is what forbids quietly re-adding `models list`, whose removal is half this change.
#   (3) LIVE binding against the installed CLIs (tests/readiness-live-check.py), which is where
#       "every declared response key is one a real CLI emits" is actually settled.
#
# Then it MUTATES copies of the wrapper and requires each check to FAIL. A check that cannot fail is
# decoration.
#
# Offline apart from (3): `--print-capability-contract` prints a static declaration and exits before
# any run directory, ledger write or provider execution. (3) runs two local status queries per
# installed CLI; neither starts a model turn, so it costs no subscription spend.
#
# NOT covered here, deliberately, and covered in tests/test-provider-reviewers.sh instead: that the
# runtime CONSUMES the classification faithfully — ready proceeds, a declared unavailable answer is
# exit 3, and anything else is BLOCK exit 1. This file reads the declaration; only a stub-driven end
# to end run can pin what the wrapper does with it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMON="$BIN/firm-reviewer-common"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-readycontract.XXXXXX")"; t_track "$WORK"

cat > "$WORK/readiness-drift.py" <<'PY'
import ast
import json
import pathlib
import re
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
readiness = contract.get("readiness") or {}
if not readiness:
    problems.append("the wrapper declares no readiness contract")
for name in sorted(contract.get("providers") or {}):
    if name not in readiness:
        problems.append(f"{name}: has a capability declaration but no readiness declaration")

# Responses that must never be read as an answer. Every one is real: the first four are what the
# CLIs actually said to the probes this change removed, and the last two are the review's attack —
# a phrase embedded in a longer line, and an answer-shaped body from a command that failed.
AMBIGUITY_CORPUS = [
    "error: unexpected argument '--json' found",
    "error: unknown option '--json'",
    "error: unexpected argument 'list' found",
    "",
    "not logged in token=secret",
    "Not logged in to the account you wanted, but logged in",
]

for name in sorted(readiness):
    entry = readiness[name]
    command = entry["command"]
    answers = entry["answers"]

    # Single construction: the wrapper builds its argv from the declared command, so there is no
    # second place for a probe to be written down.
    if command != entry["probe_argv"]:
        problems.append(f"{name}: declares command {command} but runs {entry['probe_argv']}")
    if not command:
        problems.append(f"{name}: declares an empty readiness command")

    ready = [a for a in answers if a["answer"] == "ready"]
    unavailable = [a for a in answers if a["answer"] == "unavailable"]
    if len(ready) != 1:
        problems.append(f"{name}: must declare exactly one `ready` answer, found {len(ready)}")
    if not unavailable:
        problems.append(f"{name}: declares no trusted `unavailable` answer, so the legitimate exit 3 "
                        f"waiver path could never be reached")
    # firm-bounded-exec exits 124 for a timeout and 125 for a turn limit — its own statuses, not the
    # CLI's. Declaring either lets a phase that was KILLED mid-answer satisfy a declared answer, which
    # is how a partial stream could buy a trusted exit 3. The ordering of the runtime checks defends
    # this too; this makes the declaration unable to ask for it in the first place.
    RESERVED_SUPERVISOR_STATUSES = {124: "timeout", 125: "turn limit"}
    for answer in answers:
        for code in answer.get("exit_codes") or []:
            if code in RESERVED_SUPERVISOR_STATUSES:
                problems.append(
                    f"{name}: answer {answer['answer']!r} declares exit status {code}, which is the "
                    f"supervisor's {RESERVED_SUPERVISOR_STATUSES[code]} status and not something the "
                    f"CLI ever returns — a killed phase must not be able to satisfy a declared answer")
        if answer["answer"] not in ("ready", "unavailable"):
            problems.append(f"{name}: unknown declared answer {answer['answer']!r} — the wrapper has "
                            f"three outcomes and the third one is not declarable")
        if not answer.get("exit_codes"):
            problems.append(f"{name}: answer {answer['answer']!r} declares no exit status, so the "
                            f"body would decide alone")
        if answer["answer"] == "unavailable" and not answer.get("reason"):
            problems.append(f"{name}: an unavailable answer must name its reason")

    # Body and status must agree: if `ready` and `unavailable` could arrive with the same exit
    # status, the status is not being checked at all.
    ready_codes = {code for a in ready for code in a["exit_codes"]}
    unavailable_codes = {code for a in unavailable for code in a["exit_codes"]}
    overlap = sorted(ready_codes & unavailable_codes)
    if overlap:
        problems.append(f"{name}: `ready` and `unavailable` share exit status {overlap}; body and "
                        f"status must agree for an answer to be trusted")

    if entry["shape"] == "json":
        keys = set(entry["keys"])
        answer_keys = {a.get("key") for a in answers}
        if None in answer_keys:
            problems.append(f"{name}: a json answer declares no key to read")
            answer_keys.discard(None)
        if keys != answer_keys:
            problems.append(f"{name}: declared keys {sorted(keys)} are not the keys the answers read "
                            f"{sorted(answer_keys)} — a key nothing reads is a key nothing checks")
        for a in answers:
            if not isinstance(a.get("value"), bool):
                problems.append(f"{name}: json answer {a['answer']!r} matches a non-boolean value; "
                                f"only an identity-strict boolean cannot be forged by `1` or `\"true\"`")
    elif entry["shape"] == "text":
        if entry["keys"]:
            problems.append(f"{name}: a text response has no keys, but {entry['keys']} are declared")
        for a in answers:
            pattern = a.get("line")
            if not pattern:
                problems.append(f"{name}: text answer {a['answer']!r} declares no line to match")
                continue
            try:
                compiled = re.compile(pattern)
            except re.error as exc:
                problems.append(f"{name}: text answer {a['answer']!r} has an invalid pattern: {exc}")
                continue
            for sample in AMBIGUITY_CORPUS:
                if compiled.fullmatch(sample):
                    problems.append(
                        f"{name}: declared {a['answer']!r} pattern {pattern!r} accepts {sample!r}, "
                        f"which is not an answer any CLI gave")
    else:
        problems.append(f"{name}: unknown declared response shape {entry['shape']!r}")

# (2) Source binding, over the PARSED module rather than a regex. The earlier revision matched
# `run_phase\(\s*(f?"[^"]+")`, which only sees a call whose phase name is a string literal: a
# re-added probe written `run_phase(phase_name, readiness_timeout, ...)` produced no match and was
# therefore not reported. Every call site is now visited, and a phase named by anything other than a
# literal is itself the finding.
source = pathlib.Path(wrapper).read_text(encoding="utf-8")
try:
    module = source.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    tree = ast.parse(module)
except Exception as exc:
    problems.append(f"the wrapper's python module could not be parsed, so nothing below was "
                    f"checked: {type(exc).__name__}: {exc}")
    tree = None

if tree is not None:
    ALLOWED_PHASES = {"'discovery'", "f'discovery-{surface_index + 1}'", "'authentication'", "'judge'"}

    # The discovery loop legitimately passes a variable, assigned from a literal conditional, so a
    # phase name is resolved one level through assignments and conditionals. Anything that cannot be
    # resolved to literals THAT WAY is the finding: a phase whose name is computed at runtime cannot
    # be compared with the declaration, which is the whole point of the check.
    assignments = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    assignments.setdefault(target.id, []).append(node.value)

    def literal_phase_names(node, depth=0):
        if depth > 3 or node is None:
            return None
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return [ast.unparse(node)]
        if isinstance(node, ast.JoinedStr):
            return [ast.unparse(node)]
        if isinstance(node, ast.IfExp):
            left = literal_phase_names(node.body, depth + 1)
            right = literal_phase_names(node.orelse, depth + 1)
            return None if left is None or right is None else left + right
        if isinstance(node, ast.Name):
            bound = assignments.get(node.id)
            if not bound:
                return None
            resolved = []
            for value in bound:
                names = literal_phase_names(value, depth + 1)
                if names is None:
                    return None
                resolved.extend(names)
            return resolved
        return None

    calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
             and isinstance(node.func, ast.Name) and node.func.id == "run_phase"]
    if not calls:
        problems.append("no run_phase() call site was found at all — this check has stopped checking")
    authentication_calls = []
    for call in calls:
        first = call.args[0] if call.args else None
        rendered = ast.unparse(first) if first is not None else "<no argument>"
        names = literal_phase_names(first)
        if names is None:
            problems.append(
                f"a run_phase() call names its phase `{rendered}`, which does not resolve to a "
                f"literal. A bounded provider phase must be nameable by reading the source; a name "
                f"computed at runtime cannot be checked against the declaration")
            continue
        for phase in names:
            if phase not in ALLOWED_PHASES:
                problems.append(
                    f"the wrapper runs bounded provider phase {phase}, which this check does not "
                    f"know about. If that is a new readiness probe it must be declared in "
                    f"READINESS_CONTRACT (and checked against a real CLI) before it can gate a run")
        if names == ["'authentication'"]:
            authentication_calls.append(call)
    if len(authentication_calls) != 1:
        problems.append(f"expected exactly one authentication phase, found {len(authentication_calls)}")
    for call in authentication_calls:
        command = ast.unparse(call.args[2]) if len(call.args) > 2 else "<no command argument>"
        if command != "readiness_invocation(provider, executable)":
            problems.append(f"the authentication phase runs `{command}`, not "
                            f"readiness_invocation(provider, executable); its command is written "
                            f"somewhere the declaration does not reach")
    # A `models list` argv anywhere in the module, however it is assembled. Precise where the old
    # whole-file substring scan was crude: it is the list ELEMENT that matters, not the word.
    for node in ast.walk(tree):
        if isinstance(node, ast.List):
            elements = [item.value for item in node.elts
                        if isinstance(item, ast.Constant) and isinstance(item.value, str)]
            if "models" in elements:
                problems.append(
                    f"the wrapper builds `{ast.unparse(node)}`: `models list` exists on neither CLI "
                    f"— on codex it parses as the prompt operand, on claude it IS a prompt and bills "
                    f"a model turn — so it must not come back as a gate")

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

t_case "the readiness declaration is well formed and is the only thing the wrapper asks a provider"
assert_ok "the shipped wrapper has no readiness declaration/probe drift" \
  python3 "$WORK/readiness-drift.py" "$COMMON"

t_case "the declaration says what it must about each CLI's real answer"
assert_ok 'codex answers login status in text; claude answers auth status --json under loggedIn' \
  python3 - "$COMMON" <<'PY'
import json, subprocess, sys
d = json.loads(subprocess.run([sys.argv[1], "gpt", "--print-capability-contract"],
                              capture_output=True, text=True, check=True).stdout)["readiness"]
# codex-cli 0.149.0: `codex login status --json` exits 2, "unexpected argument '--json' found".
assert d["gpt"]["command"] == ["login", "status"], d["gpt"]["command"]
assert "--json" not in d["gpt"]["command"], d["gpt"]["command"]
assert d["gpt"]["shape"] == "text", d["gpt"]
# Claude Code 2.1.238 reports authentication as loggedIn, not status/authentication.
assert d["claude"]["command"] == ["auth", "status", "--json"], d["claude"]["command"]
assert d["claude"]["keys"] == ["loggedIn"], d["claude"]["keys"]
ready = [a for a in d["claude"]["answers"] if a["answer"] == "ready"][0]
assert ready["key"] == "loggedIn" and ready["value"] is True, ready
# The removed gate must not have been re-declared under another name.
assert not any("models" in " ".join(entry["command"]) for entry in d.values()), d
PY

t_case "it bites: re-adding a models-list gate the CLIs cannot answer"
m="$(mutate models-gate '    # NO MODEL-READINESS PROBE, deliberately.' \
     '    rc, result, raw = run_phase("model", readiness_timeout, [executable, "models", "list", "--json"])
    # NO MODEL-READINESS PROBE, deliberately.')"
assert_fail "an undeclared readiness probe is caught" python3 "$WORK/readiness-drift.py" "$m"
assert_output "and the phase is named" "'model'" python3 "$WORK/readiness-drift.py" "$m"

t_case "it bites: reading a key the answers do not read"
m="$(mutate phantom-key '"keys": ["loggedIn"],' '"keys": ["status"],')"
assert_fail "a declared key nothing reads is caught" python3 "$WORK/readiness-drift.py" "$m"
assert_output "and it is named" "status" python3 "$WORK/readiness-drift.py" "$m"

t_case "it bites: THE ORIGINAL DEFECT — reading a key no CLI emits"
# The exact shape of the bug: the old code read data['status'] / data['authentication'] while Claude
# Code emits loggedIn. Offline this is well formed; only the live CLI can refuse it, which is why
# check (3) exists.
m="$(mutate wrong-key '"keys": ["loggedIn"],
        "answers": [
            {"answer": "ready", "exit_codes": [0], "key": "loggedIn", "value": True},
            {"answer": "unavailable", "reason": "authentication", "exit_codes": [1],
             "key": "loggedIn", "value": False},' \
     '"keys": ["authentication"],
        "answers": [
            {"answer": "ready", "exit_codes": [0], "key": "authentication", "value": True},
            {"answer": "unavailable", "reason": "authentication", "exit_codes": [1],
             "key": "authentication", "value": False},')"
assert_ok "the offline check alone does NOT catch it (which is the point of the live one)" \
  python3 "$WORK/readiness-drift.py" "$m"
assert_fail "the live check catches a key no installed CLI emits" \
  python3 "$HERE/readiness-live-check.py" "$m"
assert_output "and it says the CLI never emitted it" "NOT EMITTED" \
  python3 "$HERE/readiness-live-check.py" "$m"

t_case "it bites: a ready answer that would accept any exit status"
m="$(mutate ready-any-status '{"answer": "ready", "exit_codes": [0], "key": "loggedIn", "value": True},' \
     '{"answer": "ready", "exit_codes": [0, 1], "key": "loggedIn", "value": True},')"
assert_fail "overlapping ready/unavailable exit statuses are caught" \
  python3 "$WORK/readiness-drift.py" "$m"
assert_output "and the shared status is named" "share exit status" python3 "$WORK/readiness-drift.py" "$m"

t_case "it bites: a catch-all text pattern that would read an error as an answer"
m="$(mutate catch-all-pattern '{"answer": "ready", "exit_codes": [0], "line": r"Logged in using .+"},' \
     '{"answer": "ready", "exit_codes": [0], "line": r".*"},')"
assert_fail "a pattern that accepts a CLI error message is caught" \
  python3 "$WORK/readiness-drift.py" "$m"
assert_output "and the response it wrongly accepts is quoted" "unexpected argument" \
  python3 "$WORK/readiness-drift.py" "$m"

t_case "it bites: a readiness phase whose name is computed rather than declared"
m="$(mutate computed-phase-name '    # NO MODEL-READINESS PROBE, deliberately.' \
     '    model_phase = os.environ.get("FIRM_MODEL_PHASE", "model")
    rc, result, raw = run_phase(model_phase, readiness_timeout, [executable, "models", "list", "--json"])
    # NO MODEL-READINESS PROBE, deliberately.')"
assert_fail "a phase named by a variable is caught" python3 "$WORK/readiness-drift.py" "$m"
assert_output "and the check says why it cannot be checked" "does not resolve to a literal" \
  python3 "$WORK/readiness-drift.py" "$m"

t_case "it bites: declaring the supervisor's own timeout status as a CLI answer"
# The combination review's ordering finding actually needs: with 124 declared AND the runtime checks
# reordered, a phase killed mid-answer satisfies the trusted unavailable branch and returns exit 3.
# Reordering alone cannot do it, and neither can this alone; the declaration half is refused here.
m="$(mutate reserved-status '{"answer": "unavailable", "reason": "authentication", "exit_codes": [1],
             "line": r"Not logged in"},' \
     '{"answer": "unavailable", "reason": "authentication", "exit_codes": [1, 124],
             "line": r"Not logged in"},')"
assert_fail "declaring exit 124 as an answer is caught" python3 "$WORK/readiness-drift.py" "$m"
assert_output "and it names it as the supervisor's status" "supervisor's timeout status" \
  python3 "$WORK/readiness-drift.py" "$m"

t_case "the declaration is bound to the installed provider CLIs, both answers, and fails closed"
assert_ok "declared commands, keys and exit statuses match the real CLIs on this host" \
  python3 "$HERE/readiness-live-check.py" "$COMMON"
assert_output "the forced logged-out arm really ran and classified as trusted-unavailable" \
  "empty config root" python3 "$HERE/readiness-live-check.py" "$COMMON"
# One provider missing is also a failure: passing on the other's strength would leave a whole
# declaration unverified and call the log green.
ONLY_ONE="$WORK/only-one-cli"; mkdir -p "$ONLY_ONE"
if command -v codex >/dev/null 2>&1; then ln -sf "$(command -v codex)" "$ONLY_ONE/codex"; fi
assert_ok "ONE provider CLI missing is a recorded FAILURE, not a pass on the other's strength" \
  env PATH="$ONLY_ONE:/usr/bin:/bin" python3 - "$HERE/readiness-live-check.py" "$COMMON" <<'PY'
import subprocess, sys
done = subprocess.run([sys.executable, sys.argv[1], sys.argv[2]], capture_output=True, text=True)
assert done.returncode != 0, done.stdout
assert "not installed, so its readiness declaration" in done.stdout, done.stdout
assert "FIRM_READINESS_LIVE_ALLOW_MISSING" in done.stdout, done.stdout
PY
assert_ok "and an explicit waiver still reports the provider as UNVERIFIED, never as checked" \
  env PATH="$ONLY_ONE:/usr/bin:/bin" FIRM_READINESS_LIVE_ALLOW_MISSING=claude \
  python3 - "$HERE/readiness-live-check.py" "$COMMON" <<'PY'
import subprocess, sys
done = subprocess.run([sys.executable, sys.argv[1], sys.argv[2]], capture_output=True, text=True)
assert "UNVERIFIED claude" in done.stdout, done.stdout
assert "CHECKED against a real CLI: gpt" in done.stdout, done.stdout
PY
assert_ok "no provider CLI installed is reported as a FAILURE, never as a pass" \
  env PATH=/usr/bin:/bin python3 - "$HERE/readiness-live-check.py" "$COMMON" <<'PY'
import subprocess, sys
done = subprocess.run([sys.executable, sys.argv[1], sys.argv[2]], capture_output=True, text=True)
assert done.returncode != 0, done.stdout
assert "no provider CLI is installed" in done.stdout, done.stdout
PY

t_summary
