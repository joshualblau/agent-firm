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
        if not answer.get("exit_codes") and entry.get("exit_status_is_the_answer", True):
            problems.append(f"{name}: answer {answer['answer']!r} declares no exit status, so the "
                            f"body would decide alone")
        if answer["answer"] == "unavailable" and not answer.get("reason"):
            problems.append(f"{name}: an unavailable answer must name its reason")

    # Body and status must agree -- ON A SURFACE WHERE THE STATUS IS AN AUTH ANSWER. If `ready` and
    # `unavailable` could arrive with the same exit status, the status is not being checked at all.
    #
    # THAT IS NOT EVERY SURFACE, and pretending it is caused the defect one branch of this merge
    # measured: `codex doctor --json` reports the WHOLE installation, so its exit status summarises
    # app-server, git, MCP, terminal, update and network checks. It exited 1 against a fixture
    # CODEX_HOME whose ONLY problem was the auth entry, and it exits 1 on a host whose auth is
    # perfect and whose update check failed. A declaration that let that status veto the auth entry
    # would BLOCK a working judge for an unrelated reason.
    #
    # So a surface may declare `exit_status_is_the_answer: False`, and it BUYS A STRICTER
    # OBLIGATION rather than an exemption: the document itself must be pinned, by an envelope the
    # report has to match and by an identified entry at a declared path, so the answer still cannot
    # come from "some field called status somewhere in the output".
    if entry.get("exit_status_is_the_answer", True):
        ready_codes = {code for a in ready for code in (a["exit_codes"] or [])}
        unavailable_codes = {code for a in unavailable for code in (a["exit_codes"] or [])}
        overlap = sorted(ready_codes & unavailable_codes)
        if overlap:
            problems.append(f"{name}: `ready` and `unavailable` share exit status {overlap}; body and "
                            f"status must agree for an answer to be trusted")
    else:
        if any(a.get("exit_codes") for a in answers):
            problems.append(f"{name}: declares exit_status_is_the_answer False but still constrains "
                            f"exit statuses — say one thing or the other")
        if not entry.get("envelope"):
            problems.append(f"{name}: the exit status is declared not to be the answer, so the "
                            f"document must be pinned by an envelope; none is declared")
        if not entry.get("path"):
            problems.append(f"{name}: the exit status is declared not to be the answer, so the "
                            f"answer must come from a declared path in the document, not the top "
                            f"level where any field could supply it")
        if not entry.get("require_fields"):
            problems.append(f"{name}: the entry at the declared path must identify itself "
                            f"(require_fields), or an unrelated check at that path answers the "
                            f"authentication question")

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
            value = a.get("value")
            if isinstance(value, bool):
                continue
            # A STRING ENUM IS ALLOWED, AND ONLY UNDER THE STRICTER REGIME. `codex doctor --json`
            # answers `status: "ok" | "fail"`; there is no boolean to demand. readiness_answer()
            # compares it type-strictly (`isinstance(value, str) and value == declared`), so `1`,
            # `True` and `"OK"` are all non-answers, and the entry it reads has to identify itself
            # by id and category first -- which is more than a bare boolean at the top level ever
            # had to prove.
            if isinstance(value, str) and value and not entry.get("exit_status_is_the_answer", True) \
                    and entry.get("require_fields") and entry.get("path"):
                continue
            problems.append(f"{name}: json answer {a['answer']!r} matches a value that is neither an "
                            f"identity-strict boolean nor a string enum read from an identified "
                            f"entry at a declared path; a bare non-boolean can be forged by `1` or "
                            f"`\"true\"`")
        # The envelope and the identified entry must not be decorative: every field named in them
        # has to be a literal the reader can compare, or the pin proves nothing.
        for field, expected in list((entry.get("envelope") or {}).items()) + \
                               list((entry.get("require_fields") or {}).items()):
            if isinstance(expected, (dict, list)) or expected is None:
                problems.append(f"{name}: the pin on {field!r} is {expected!r}, which is not a "
                                f"literal the reader can compare")
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
    # `model` is back, and it is HERE rather than in READINESS_CONTRACT because it is not a readiness
    # probe: it reads a catalog, it cannot answer "is this CLI authenticated", and the exit-3 waiver
    # it can produce means something else. It is declared in MODEL_CATALOG_CONTRACT and built by
    # model_invocation(), and the binding below is what stops this line becoming a hole: a `model`
    # phase is admitted only if that declaration and that single construction both exist and the
    # phase runs the argv the construction returned.
    ALLOWED_PHASES = {"'discovery'", "f'discovery-{surface_index + 1}'", "'authentication'",
                      "'model'", "'judge'"}

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
    # The model phase pays the same entry fee the readiness phase pays: one declaration, one
    # construction, and the phase may only run the argv that construction returned. Without this,
    # naming "'model'" above would be a blanket permit for any command at all under that name --
    # which is how `models list --json`, a command NO CLI has, lived here for the whole history of
    # this wrapper.
    source_text = pathlib.Path(wrapper).read_text(encoding="utf-8")
    if "MODEL_CATALOG_CONTRACT = {" not in source_text:
        problems.append("a `model` phase runs but MODEL_CATALOG_CONTRACT is not declared")
    if "def model_invocation(" not in source_text:
        problems.append("a `model` phase runs but model_invocation() is not its single construction")
    for call in calls:
        if literal_phase_names(call.args[0] if call.args else None) != ["'model'"]:
            continue
        argument = call.args[2] if len(call.args) > 2 else None
        rendered = ast.unparse(argument) if argument is not None else "<no argument>"
        if rendered != "model_surface":
            problems.append(
                f"the model phase runs `{rendered}` rather than the argv model_invocation() "
                f"returned; a catalog command that is not the declared one is exactly the shape "
                f"`models list --json` had")
    for call in authentication_calls:
        command = ast.unparse(call.args[2]) if len(call.args) > 2 else "<no command argument>"
        if command != "readiness_invocation(provider, executable)":
            problems.append(f"the authentication phase runs `{command}`, not "
                            f"readiness_invocation(provider, executable); its command is written "
                            f"somewhere the declaration does not reach")
    # A `models list` argv anywhere in the module, however it is assembled. Precise where the old
    # whole-file substring scan was crude: it is the list ELEMENT that matters, not the word.
    # THE BANNED COMMAND IS `models list`, NOT THE WORD "models".
    #
    # This rule used to reject any list literal containing the string "models" anywhere. That was a
    # proxy for the real defect and it caught the wrong thing the moment a REAL catalog surface came
    # back: `codex debug models` is a command codex actually has ("Render the raw model catalog as
    # JSON"), and the rule rejected it for containing the word.
    #
    # What must never return is the command NO CLI HAS. Measured: `codex models list --json` is rc 2
    # (`models` parses as the PROMPT operand and `list` is then unexpected); `claude models list
    # --json` is `unknown option`, and dropping the flag is worse -- bare `claude models list` is
    # taken as a PROMPT and starts a billed session. So the rule now rejects the ADJACENT PAIR
    # `models`, `list`, and rejects a bare `models` operand, which is the same prompt trap one word
    # shorter. `debug models` passes; nothing that could bill a turn does.
    for node in ast.walk(tree):
        if not isinstance(node, ast.List):
            continue
        elements = [item.value for item in node.elts
                    if isinstance(item, ast.Constant) and isinstance(item.value, str)]
        pairs = list(zip(elements, elements[1:]))
        banned = ("models", "list") in pairs
        if not banned and "models" in elements:
            index = elements.index("models")
            preceding = elements[index - 1] if index else None
            banned = preceding != "debug"
        if banned:
            problems.append(
                f"the wrapper builds `{ast.unparse(node)}`: `models list` exists on neither CLI "
                f"— on codex it parses as the prompt operand, on claude it IS a prompt and bills "
                f"a model turn — so it must not come back as a gate. The only catalog surface that "
                f"exists is `codex debug models`.")

for line in problems:
    print(line)
sys.exit(1 if problems else 0)
PY

# mutate <name> <old> <new> — copy the wrapper and apply one textual mutation. Echoes the copy path.
mutate() {
  local target="$WORK/mutant-$1"
  cp "$COMMON" "$target"
  # bin/firm-reviewer-common sources its SIBLING `firm-python` on line 8 to resolve the one
  # interpreter the firm admits, so a copy on its own exits 1 there before parsing a byte of the
  # program. Every `and it is named` assertion below then failed on the harness rather than on the
  # mutation. The sibling travels with the mutant.
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

t_case "the readiness declaration is well formed and is the only thing the wrapper asks a provider"
assert_ok "the shipped wrapper has no readiness declaration/probe drift" \
  t_python "$WORK/readiness-drift.py" "$COMMON"

t_case "the declaration says what it must about each CLI's real answer"
assert_ok 'codex answers doctor --json at an identified auth entry; claude answers loggedIn' \
  t_python - "$COMMON" <<'PY'
import json, subprocess, sys
d = json.loads(subprocess.run([sys.argv[1], "gpt", "--print-capability-contract"],
                              capture_output=True, text=True, check=True).stdout)["readiness"]
# WHAT CHANGED HERE, AND WHY IT IS NOT A RELAXATION.
# This case used to pin `codex login status`, in text, with the note that `codex login status
# --json` exits 2. Both halves of that note are still true and were re-measured on the installed
# codex-cli 0.147.0 (rc 2 `unexpected argument '--json' found`; and bare `login status` prints the
# one line "Not logged in" to STDERR at rc 1). What was wrong was the conclusion. A prose line
# cannot establish availability: agent-firm/contracts/lifecycle.md says "Only structured readiness
# output can establish availability, read at the surface the installed CLI actually publishes", and
# codex DOES publish one -- `codex doctor --json`, "Emit a redacted machine-readable report",
# schemaVersion 1, checks["auth.credentials"].status "ok" | "fail". Measured against a fixture
# CODEX_HOME so no operator credential was read.
assert d["gpt"]["command"] == ["doctor", "--json"], d["gpt"]["command"]
assert d["gpt"]["shape"] == "json", d["gpt"]
# The prose surface must not come back as a readiness answer for either provider.
assert not any(entry["shape"] == "text" for entry in d.values()), d
# The structured surface is only trustworthy BECAUSE it is pinned: `codex doctor --json` reports the
# whole installation, so the answer has to come from an entry that identifies itself, inside a report
# whose envelope matches, and its exit status must not be read as an auth answer.
assert d["gpt"]["exit_status_is_the_answer"] is False, d["gpt"]
assert d["gpt"]["envelope"] == {"schemaVersion": 1}, d["gpt"]
assert d["gpt"]["path"] == ["checks", "auth.credentials"], d["gpt"]
assert d["gpt"]["require_fields"] == {"id": "auth.credentials", "category": "auth"}, d["gpt"]
gpt_ready = [a for a in d["gpt"]["answers"] if a["answer"] == "ready"][0]
assert gpt_ready["key"] == "status" and gpt_ready["value"] == "ok", gpt_ready
# Claude Code reports authentication as loggedIn, not status/authentication, and there the exit
# status IS the auth answer, so it stays pinned to the booleans and to its exit codes.
assert d["claude"]["command"] == ["auth", "status", "--json"], d["claude"]["command"]
assert d["claude"]["keys"] == ["loggedIn"], d["claude"]["keys"]
assert d["claude"]["exit_status_is_the_answer"] is True, d["claude"]
ready = [a for a in d["claude"]["answers"] if a["answer"] == "ready"][0]
assert ready["key"] == "loggedIn" and ready["value"] is True, ready
# `models list --json` must not have been re-declared as a READINESS answer under any name. The
# model catalog is a separate phase with its own declaration; it can never answer authentication.
assert not any("models" in " ".join(entry["command"]) for entry in d.values()), d
PY

t_case "it bites: re-adding a models-list gate the CLIs cannot answer"
# The anchor is the model-phase comment, which is where such a gate would actually be written. The
# mutant adds a SECOND model phase running the impossible command, so this stays a test about the
# command rather than about whether a model phase exists at all -- one does now, and it runs
# `codex debug models`, which is real.
m="$(mutate models-gate '    # MODEL READINESS. What used to be here was' \
     '    rc, result, raw = run_phase("model", readiness_timeout, [executable, "models", "list", "--json"])
    # MODEL READINESS. What used to be here was')"
assert_fail "an undeclared readiness probe is caught" t_python "$WORK/readiness-drift.py" "$m"
assert_output "and the command is named" "models', 'list', '--json" \
  t_python "$WORK/readiness-drift.py" "$m"

t_case "it bites: reading a key the answers do not read"
m="$(mutate phantom-key '"keys": ["loggedIn"],' '"keys": ["status"],')"
assert_fail "a declared key nothing reads is caught" t_python "$WORK/readiness-drift.py" "$m"
assert_output "and it is named" "status" t_python "$WORK/readiness-drift.py" "$m"

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
  t_python "$WORK/readiness-drift.py" "$m"
# THESE TWO NEED A REAL PROVIDER CLI ON THE HOST. readiness-live-check.py interrogates the
# installed binaries; with none present it reports "not installed" and never reaches the
# key-not-emitted finding this case is about. Guarded with the same visible-SKIP idiom
# test-reviewer-credential-contract.sh and test-provider-launch-sites.sh already use, so a hosted
# runner says out loud that the live half was not checked instead of failing on its absence.
if command -v codex >/dev/null 2>&1 || command -v claude >/dev/null 2>&1; then
  assert_fail "the live check catches a key no installed CLI emits" \
    t_python "$HERE/readiness-live-check.py" "$m"
  assert_output "and it says the CLI never emitted it" "NOT EMITTED" \
    t_python "$HERE/readiness-live-check.py" "$m"
else
  printf '      SKIP (a provider CLI is not installed; the live key check was NOT checked)\n'
fi

t_case "it bites: a ready answer that would accept any exit status"
m="$(mutate ready-any-status '{"answer": "ready", "exit_codes": [0], "key": "loggedIn", "value": True},' \
     '{"answer": "ready", "exit_codes": [0, 1], "key": "loggedIn", "value": True},')"
assert_fail "overlapping ready/unavailable exit statuses are caught" \
  t_python "$WORK/readiness-drift.py" "$m"
assert_output "and the shared status is named" "share exit status" t_python "$WORK/readiness-drift.py" "$m"

t_case "it bites: a catch-all text pattern that would read an error as an answer"
# NO SURFACE IS DECLARED `text` ANY MORE -- lifecycle.md admits only structured readiness output, and
# codex publishes one. The rule that refuses a catch-all pattern must not therefore go untested: a
# future CLI with no JSON surface is exactly when someone reaches for `line`, and that is exactly
# when a `.*` would read `error: unexpected argument '--json' found` as "ready". The mutant supplies
# the text surface the shipped wrapper no longer has.
m="$(mutate catch-all-pattern '        "shape": "json",
        "exit_status_is_the_answer": True,
        "envelope": {},
        "path": [],
        "require_fields": {},
        "keys": ["loggedIn"],
        "answers": [
            {"answer": "ready", "exit_codes": [0], "key": "loggedIn", "value": True},
            {"answer": "unavailable", "reason": "authentication", "exit_codes": [1],
             "key": "loggedIn", "value": False},' \
     '        "shape": "text",
        "exit_status_is_the_answer": True,
        "envelope": {},
        "path": [],
        "require_fields": {},
        "keys": [],
        "answers": [
            {"answer": "ready", "exit_codes": [0], "line": r".*"},
            {"answer": "unavailable", "reason": "authentication", "exit_codes": [1],
             "line": r"Not logged in"},')"
assert_fail "a pattern that accepts a CLI error message is caught" \
  t_python "$WORK/readiness-drift.py" "$m"
assert_output "and the response it wrongly accepts is quoted" "unexpected argument" \
  t_python "$WORK/readiness-drift.py" "$m"

t_case "it bites: a readiness phase whose name is computed rather than declared"
m="$(mutate computed-phase-name '    # MODEL READINESS. What used to be here was' \
     '    model_phase = os.environ.get("FIRM_MODEL_PHASE", "model")
    rc, result, raw = run_phase(model_phase, readiness_timeout, [executable, "debug", "models"])
    # MODEL READINESS. What used to be here was')"
assert_fail "a phase named by a variable is caught" t_python "$WORK/readiness-drift.py" "$m"
assert_output "and the check says why it cannot be checked" "does not resolve to a literal" \
  t_python "$WORK/readiness-drift.py" "$m"

t_case "it bites: declaring the supervisor's own timeout status as a CLI answer"
# The combination review's ordering finding actually needs: with 124 declared AND the runtime checks
# reordered, a phase killed mid-answer satisfies the trusted unavailable branch and returns exit 3.
# Reordering alone cannot do it, and neither can this alone; the declaration half is refused here.
m="$(mutate reserved-status '{"answer": "unavailable", "reason": "authentication", "exit_codes": [1],
             "key": "loggedIn", "value": False},' \
     '{"answer": "unavailable", "reason": "authentication", "exit_codes": [1, 124],
             "key": "loggedIn", "value": False},')"
assert_fail "declaring exit 124 as an answer is caught" t_python "$WORK/readiness-drift.py" "$m"
assert_output "and it names it as the supervisor's status" "supervisor's timeout status" \
  t_python "$WORK/readiness-drift.py" "$m"

t_case "the declaration is bound to the installed provider CLIs, both answers, and fails closed"
# EVERYTHING IN THIS CASE EXCEPT THE FINAL no-CLI ASSERTION REQUIRES A REAL PROVIDER CLI.
# The first two interrogate the installed binaries directly. The two after them build a
# one-CLI-only PATH by symlinking the real codex — on a host with neither binary that fixture is
# empty, so they assert about a shape the host cannot produce and fail on the absence rather than
# on the property. Hosted CI runners have neither CLI, which is what turned this suite red on both
# platforms; the exact-p2 self-hosted job has both and is where this binding is actually proved.
# The final assertion is deliberately left outside the guard: "no provider CLI installed is a
# FAILURE" is exactly the state a hosted runner is in, so it is checked there rather than skipped.
if command -v codex >/dev/null 2>&1 || command -v claude >/dev/null 2>&1; then
assert_ok "declared commands, keys and exit statuses match the real CLIs on this host" \
  t_python "$HERE/readiness-live-check.py" "$COMMON"
assert_output "the forced logged-out arm really ran and classified as trusted-unavailable" \
  "empty config root" t_python "$HERE/readiness-live-check.py" "$COMMON"
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
else
  printf '      SKIP (no provider CLI is installed; the live declaration binding was NOT checked)\n'
fi
assert_ok "no provider CLI installed is reported as a FAILURE, never as a pass" \
  env PATH=/usr/bin:/bin python3 - "$HERE/readiness-live-check.py" "$COMMON" <<'PY'
import subprocess, sys
done = subprocess.run([sys.executable, sys.argv[1], sys.argv[2]], capture_output=True, text=True)
assert done.returncode != 0, done.stdout
assert "no provider CLI is installed" in done.stdout, done.stdout
PY

t_summary
