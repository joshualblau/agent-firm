#!/usr/bin/env python3
"""Every provider-CLI launch site in the repository, checked against the surface it launches on.

WHY THIS IS REPOSITORY-WIDE. On 2026-08-21 the reviewer wrapper was found passing `-a never` after
`exec`, where Codex rejects it, and change #1 bound discovery to invocation *inside
bin/firm-reviewer-common*. On 2026-08-23 the identical defect was found in a SECOND independent
copy, `bin/firm-run-evals`, and a THIRD, `bin/firm-doctor`. Neither was in scope of any check,
which is exactly how they survived: the guard was scoped to a file, and the defect is a property of
the repository. So the unit of checking here is the repository, not the file.

WHAT IT PROVES
  1. COVERAGE. Every tracked file is scanned. A file that launches a provider CLI and is not
     accounted for in LAUNCH_OWNERS fails. That is the check whose absence let copies two and three
     exist; a fourth copy fails this scan on the day it is written rather than by accident later.
  2. SURFACE. For every launch site whose argv can be derived from the source, the argv is split
     into (subcommand path -> controls passed AT THAT POINT) and every control must appear in the
     help text of ITS OWN surface. Satisfaction on a different surface is a miss, exactly as in
     firm-reviewer-common's CAPABILITY_CONTRACT. There is no alias map and no union.

SCOPE, STATED SO IT IS NOT MISTAKEN FOR MORE
  * TRACKED FILES ONLY (`git ls-files`). An untracked launcher sitting in a working tree is invisible
    to this scan. That is the right scope for a guard about what the REPOSITORY contains — an
    untracked file is not something the firm ships — but it means "the scan is clean" is a statement
    about committed content, not about the machine it ran on.
  * python_launches() reads LITERAL argv lists only: it needs an ast.Call carrying a Constant
    "codex"/"claude" together with an all-Constant list THAT OPENS THE WAY A PROVIDER ARGV OPENS —
    with a control, or with one of that provider's own published subcommands. That last test is the
    same one shell_launches applies to the word after a provider name, and it is there for the same
    reason: a provider name sitting next to an arbitrary word is data, not a command.
    `subprocess.run([exe] + declared["command"])` is invisible to it. That is acceptable here only
    because the one file that builds argv that way, bin/firm-reviewer-common, is registered
    `contract:` and covered by its own drift tests — it is not a general capability, and a new
    python launcher that composes argv would need either literal lists or its own declaration.

WHAT IT DOES NOT DO, DELIBERATELY
  * It never runs a provider CLI with anything but `--help`, and only on subcommand chains it has
    already confirmed from the parent's own `Commands:` block. Claude Code treats an unrecognised
    argument as a PROMPT and bills a real turn, so probing speculative tokens against it would buy
    prose and call it a fact — the defect firm-reviewer-common's readiness comment describes.
  * It does not model shell control flow. It reads command position, which is all a launch site is.

FAIL-CLOSED. A line that cannot be tokenised but contains a bare provider word in command position
is a FAILURE, not a skip. "Could not check" is never reported as "checked and fine".

usage: provider-launch-scan.py <repo-root> [--mutate <path>:<from>:<to>]
                                           [--measurements <json-file>]
       --mutate rewrites one tracked file IN MEMORY before scanning, so a test can prove a check
       bites without editing a tracked file.
       --measurements REPLACES the UNDOCUMENTED_CONTROLS registry from a file, so a test can prove
       the validation of a measurement bites. Mutating this file's own source cannot do that — the
       registry is already loaded in the running process — and a check whose escape hatch is
       untestable is a check whose escape hatch is untested. Using it prints a loud banner, and the
       production callers never pass it.
"""
import ast
import json
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

PROVIDERS = ("codex", "claude")

# Every file that launches a provider CLI, and how its argv is established. `derived_shell` and
# `derived_python` are CHECKED here, from the source. `contract` means the argv is constructed by a
# declaration that has its own drift check, named in the value, and is not re-derived here.
#
# ADDING A FILE TO THIS MAP IS A DECISION, NOT A FORMALITY: it is the moment someone states that a
# new place in the firm may talk to a provider CLI.
LAUNCH_OWNERS = {
    "bin/firm-doctor": "derived_shell",
    "bin/firm-run-evals": "derived_shell",
    "bin/firm-bootstrap": "derived_python",
    # judge/readiness/discovery argv is built by judge_plan()/readiness_invocation() and checked by
    # CAPABILITY_CONTRACT plus tests/test-reviewer-capability-contract.sh and
    # tests/test-reviewer-readiness-contract.sh.
    "bin/firm-reviewer-common": "contract:CAPABILITY_CONTRACT",
}

# Shell words that may precede the executable and do not end command position.
PREFIX_WORDS = {"env", "/usr/bin/env", "command", "nohup", "time", "exec", "sudo", "-", "!", "run_capped"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*=")
NUMBER = re.compile(r"^[0-9]+$")

failures = []
notes = []


def fail(message):
    failures.append(message)


def flag_present(flag, help_text):
    """Word-boundary match, not containment: `-s` occurs inside `--sandbox` and a hundred prose
    words, and `--model` must not be satisfied by `--models`. Same rule as firm-reviewer-common."""
    return re.search(r"(?<![\w-])" + re.escape(flag) + r"(?![\w-])", help_text) is not None


_help_cache = {}


def help_text(provider, subcommand):
    key = (provider, tuple(subcommand))
    if key in _help_cache:
        return _help_cache[key]
    executable = shutil.which(provider)
    if not executable:
        _help_cache[key] = None
        return None
    done = subprocess.run([executable] + list(subcommand) + ["--help"],
                          capture_output=True, timeout=60)
    text = (done.stdout + done.stderr).decode("utf-8", "replace")
    _help_cache[key] = text if done.returncode == 0 else None
    return _help_cache[key]


_subcommand_cache = {}


def subcommands(provider, path):
    """The subcommand names a surface publishes, read from its own `Commands:` block. Only ever
    called for a chain already confirmed, so no speculative token is ever sent to a provider."""
    key = (provider, tuple(path))
    if key in _subcommand_cache:
        return _subcommand_cache[key]
    text = help_text(provider, path)
    names = set()
    if text:
        inside = False
        for line in text.splitlines():
            if re.match(r"^\s*(Commands|SUBCOMMANDS):\s*$", line):
                inside = True
                continue
            if inside:
                if line.strip() and not line.startswith((" ", "\t")):
                    break
                match = re.match(r"^\s{2,}([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)*)(?:\s|$)", line)
                if match:
                    names.update(match.group(1).split("|"))
    _subcommand_cache[key] = names
    return names


def split_surfaces(provider, tokens):
    """argv (after the executable) -> ordered [(subcommand path, [controls passed there])].

    A control is attributed to the path in force AT THE POINT IT APPEARS, which is the whole point:
    `codex -a never exec ...` passes `-a` at the top level, `codex exec ... -a never` passes it to
    `exec`, and Codex accepts only the first."""
    path = []
    surfaces = [(tuple(path), [])]
    opaque = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            break
        if token.startswith("-") and len(token) > 1:
            surfaces[-1][1].append(token)
            following = tokens[index + 1] if index + 1 < len(tokens) else None
            if (following is not None and not following.startswith("-")
                    and following not in subcommands(provider, path)):
                index += 1                      # a value, not a subcommand
        elif token in subcommands(provider, path):
            path.append(token)
            surfaces.append((tuple(path), []))
        elif UNEXPANDED.search(token):
            # An expansion standing in ARGUMENT position, not consumed as some flag's value. It may
            # expand into any number of controls on any surface, so from here the argv is unknown.
            # A flag's value may be an expansion all it likes — this scanner never reads values.
            opaque.append(token)
        index += 1
    return [(list(sub), controls) for sub, controls in surfaces if controls], opaque


# Words after which a command may begin. `--` is here because every launch in the firm goes through
# firm-bounded-exec, whose argv separator is exactly that; a scanner that stops at `--` sees none of
# the supervised launches, which are all of them.
SEPARATORS = {";", "|", "&&", "||", "&", "(", "{", "then", "do", "else", ";;", "--",
              "if", "elif", "while", "until"}
MAX_CONTINUATION = 40


# `$x`, `${x}`, `${a[@]}`, `$(...)` already became SUBSTITUTION. Anything still carrying a `$` at
# this point is a value this scanner cannot read.
UNEXPANDED = re.compile(r"\$")
# `CLI=codex`, `readonly CLI=claude`, `CLI="codex"` — an assignment whose value is a provider name.
ALIAS_ASSIGNMENT = re.compile(
    r"(?:^|\s|;)(?:readonly\s+|declare\s+-\w+\s+|local\s+|export\s+)?"
    r"([A-Za-z_][A-Za-z_0-9]*)=[\"']?(codex|claude)[\"']?\s*(?:$|;|\s)", re.MULTILINE)


REDIRECTION = re.compile(r"^[0-9]*[<>]")
ARGV_TERMINATORS = {";", "|", "&&", "||", "&", ";;", "then", "do", "else", "fi", "done"}


def launch_argv(tokens):
    """The provider's OWN argv: everything up to the first shell terminator or redirection.

    Taking the whole rest of the logical line used to be harmless and is not any more. In
    `... codex login status >/dev/null 2>&1; then pass "codex login status OK under $CODEX_HOME"`
    the trailing prose belongs to `pass`, not to codex — and once an unexpanded expansion in argument
    position became a CANNOT CHECK, that borrowed token turned a correct launch into a false alarm.
    A guard that cries wolf gets switched off, so the argv has to end where the command does."""
    argv = []
    for token in tokens:
        if token in ARGV_TERMINATORS or REDIRECTION.match(token):
            break
        argv.append(token)
    return argv


def provider_aliases(text):
    """Shell variables assigned a bare provider name anywhere in the file, mapped to the `$NAME` and
    `${NAME}` forms a launch would use. Deliberately whole-file rather than flow-sensitive: this is
    a guard, and the conservative direction is to treat a variable that EVER holds a provider name as
    a provider launcher."""
    aliases = {}
    for name, provider in ALIAS_ASSIGNMENT.findall(text):
        aliases[f"${name}"] = provider
        aliases[f"${{{name}}}"] = provider
        aliases[name] = provider
    return aliases


def tokenise(line):
    """shell words, or None if the text does not close its quoting."""
    try:
        lexer = shlex.shlex(strip_substitutions(line), posix=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None


def buffer_can_continue(candidate):
    return candidate.count("\n") < MAX_CONTINUATION


def strip_heredocs(text):
    """Split shell from its heredoc bodies. The bodies are not shell — several of the firm's shell
    scripts embed whole python programs in `<<'PY' ... PY`, and reading those as shell finds `codex`
    in a variable name and calls it a launch site. They are NOT discarded: bin/firm-bootstrap and
    bin/firm-reviewer-common are bash files whose entire program, provider launches included, lives
    in a heredoc, so a scanner that dropped them would check nothing and report success."""
    output = []
    bodies = []
    body = []
    pending = None
    for line in text.splitlines():
        if pending is not None:
            if line.strip() == pending:
                bodies.append("\n".join(body))
                body = []
                pending = None
            else:
                body.append(line)
            continue
        match = re.search(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z_0-9]*)'?\"?\s*$", line)
        output.append(line)
        if match:
            pending = match.group(1)
    if body:
        bodies.append("\n".join(body))
    return "\n".join(output), bodies


def strip_substitutions(line):
    """Replace balanced `$( ... )` and backtick spans with an inert word. They are not part of the
    launch surface, and their nested quoting is what makes an otherwise fine line untokenisable."""
    result = []
    index = 0
    while index < len(line):
        if line.startswith("$(", index):
            depth = 1
            cursor = index + 2
            while cursor < len(line) and depth:
                if line[cursor] == "(":
                    depth += 1
                elif line[cursor] == ")":
                    depth -= 1
                cursor += 1
            result.append("SUBSTITUTION")
            index = cursor
        elif line[index] == "`":
            cursor = line.find("`", index + 1)
            cursor = len(line) if cursor == -1 else cursor + 1
            result.append("SUBSTITUTION")
            index = cursor
        else:
            result.append(line[index])
            index += 1
    return "".join(result)


def shell_launches(relative, text):
    """Command-position launches in a shell file, with the argv that follows."""
    found = []
    logical = []
    buffer = ""
    shell_text, heredoc_bodies = strip_heredocs(text)
    for body in heredoc_bodies:
        found.extend(python_launches(relative, body))
    # File-scoped, so it must be computed BEFORE the per-line filter below: the launch line of a
    # variable-held executable (`"$CLI" exec ...`) contains no literal provider name at all, and a
    # filter that only looks for `codex`/`claude` skips it before it is ever tokenised.
    aliases = provider_aliases(shell_text)
    alias_pattern = ("|".join(re.escape(name) for name in sorted(aliases)) or r"(?!)")
    for raw in shell_text.splitlines():
        stripped = raw.rstrip()
        if stripped.endswith("\\"):
            buffer += stripped[:-1] + " "
            continue
        candidate = buffer + stripped
        # A shell argument may be a quoted string that spans physical lines with no continuation
        # marker (firm-run-evals' --append-system-prompt is one). Keep accumulating until the line
        # tokenises, rather than declaring a perfectly ordinary launch unparsable.
        if tokenise(candidate) is None and buffer_can_continue(candidate):
            buffer = candidate + "\n"
            continue
        logical.append(candidate)
        buffer = ""
    if buffer:
        logical.append(buffer)
    for line in logical:
        if not (re.search(r"(?<![\w./-])(codex|claude)(?![\w./-])", line)
                or re.search(alias_pattern, line)):
            continue
        tokens = tokenise(line)
        if tokens is None:
            # Unparsable. Fail closed only if a provider still stands in command position with an
            # argument after it — otherwise this is prose or a pattern, not a launch.
            if re.search(r"(?:^|[;&|(]\s*|\s)(codex|claude)\s+[-a-z]", line):
                fail(f"{relative}: a line launching a provider CLI could not be tokenised, so its "
                     f"launch surface CANNOT BE CHECKED: {line.strip()[:120]}")
            continue
        # A variable holding a provider name is still a launch. `CLI=codex` then `"$CLI" exec ...`
        # used to be invisible to BOTH the surface check and the LAUNCH_OWNERS coverage rule, so the
        # "a fourth copy fails on the day it is written" guarantee held only for a literal in command
        # position — which is a guarantee about spelling, not about launching.
        position_open = True
        for index, token in enumerate(tokens):
            following = tokens[index + 1] if index + 1 < len(tokens) else None
            resolved = token if token in PROVIDERS else aliases.get(token)
            if (resolved in PROVIDERS and position_open and following is not None
                    and (following.startswith("-") or following in subcommands(resolved, [])
                         or UNEXPANDED.search(following))):
                found.append((resolved, launch_argv(tokens[index + 1:])))
                position_open = False
            elif token in PREFIX_WORDS or ASSIGNMENT.match(token) or NUMBER.match(token):
                continue
            elif token in SEPARATORS:
                position_open = True
            else:
                position_open = False
    return found


def opens_provider_argv(provider, elements):
    """Does this literal list begin the way that provider's OWN argv begins?

    THE SAME TEST shell_launches ALREADY APPLIES, and for the same reason. A shell line only counts
    as a launch when the word after the provider is a control, one of the provider's published
    subcommands, or an expansion; `claude` standing next to an arbitrary word is prose, not a
    command. The python side carried no such test, so ANY all-Constant list of strings travelling
    beside a `"claude"`/`"codex"` Constant was read as argv — and
    `record("ac007_placeholder_argv", "claude", result, ["angle_bracket_placeholder_in_command_argv"])`
    in tests/fixtures/ac007-mutation-matrix.py matched it exactly: a provider ORIENTATION LABEL next
    to a list of SUB-CASE NAMES, in a fixture that launches nothing and asserts it launches nothing.
    Reporting that as an unaccounted launch site is the cry-wolf failure launch_argv() was written to
    stop; here it buried the scan's one real finding under nine lines of noise.

    WHY NOT DECIDE IT BY WHO IS CALLED. `record()` is a plain record builder, and the tempting rule
    is "the callee must reach subprocess". bin/firm-bootstrap's `mutation()` is a plain record
    builder too, and its records ARE executed later, from a list, by `call()`. That rule would
    therefore drop a genuine launch descriptor. The shape of the argv travels with the data; the
    identity of the helper that carries it does not.

    THE BLIND SPOT THIS ACCEPTS, STATED. A launch whose first argv word is neither a control nor a
    published subcommand — `claude "some prompt"` — is not recognised. That is the blind spot the
    shell side has carried since it was written; this makes it the same on both sides rather than a
    new one. It also means a missing provider CLI (no help text, so no subcommand list) narrows the
    test to controls alone, which is why tests/test-provider-launch-sites.sh refuses to run at all
    unless both CLIs are installed rather than reporting a thinner scan as a pass.
    """
    head = elements[0]
    return head.startswith("-") or head in subcommands(provider, [])


def python_launches(relative, text):
    """argv lists in a python file that travel with a provider name in the same call."""
    found = []
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return found
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        named = [a.value for a in node.args
                 if isinstance(a, ast.Constant) and a.value in PROVIDERS]
        if not named:
            continue
        for argument in node.args:
            if isinstance(argument, (ast.List, ast.Tuple)) and argument.elts and all(
                    isinstance(e, ast.Constant) and isinstance(e.value, str)
                    for e in argument.elts):
                elements = [e.value for e in argument.elts]
                if not opens_provider_argv(named[0], elements):
                    continue
                found.append((named[0], elements))
    return found


# Controls a provider ACCEPTS but does not print in `--help`. The help text is the only offline
# evidence there is, so a control missing from it fails by default — but "missing from help" and
# "rejected by the CLI" are different facts, and collapsing them would be this scanner committing
# the mistake it exists to catch.
#
# THE FIRST VERSION OF THIS WAS A MUTE BUTTON. Review proved it: the value was free text, so one
# line on a copy —
#     ("codex", ("exec",), "-a"): "measured 2026-08-23: fine, trust me"
# — made the real firm-run-evals defect pass with a cheerful `ok`. Nothing parsed the date, nothing
# bound it to a CLI version, nothing expired it, and, worst of all, `-a` IS documented at the codex
# TOP level, so the hatch could grant exactly the cross-surface union the scanner's core rule
# forbids. An escape hatch that can re-mute the defect the guard was built for is not an exception,
# it is a bypass.
#
# So an entry must now carry evidence a machine can check:
#   * a fixed record shape (cli, version, date, argv, rc) — a missing or malformed field is CANNOT
#     CHECK, not a pass;
#   * a `version` that must equal the INSTALLED CLI version. A measurement against a version that is
#     no longer here is stale, and stale evidence is not evidence — it fails and asks to be re-taken;
#   * an `argv` that must actually contain the control, so the record cannot describe a different
#     experiment from the one it claims;
#   * and a hard refusal, checked below, of any control that IS present in a PARENT surface's help.
#     That case is a union, not a measurement, and the union is the thing this scanner exists to
#     reject.
UNDOCUMENTED_CONTROLS = {
    # RE-MEASURED 2026-09-01 because the installed CLI changed. An invalid numeric value proves the
    # parser recognizes --max-turns and stops locally before any provider or network operation.
    ("claude", (), "--max-turns"): {
        "cli": "claude",
        "version": "2.1.251",
        "date": "2026-09-01",
        "argv": ["claude", "--max-turns", "text", "-p", "x"],
        "rc": 1,
        "observed": "rc 1: option --max-turns argument text is invalid and must be a number",
    },
}
MEASUREMENT_FIELDS = {"cli", "version", "date", "argv", "rc", "observed"}
_version_cache = {}


def installed_version(provider):
    if provider in _version_cache:
        return _version_cache[provider]
    executable = shutil.which(provider)
    version = None
    if executable:
        done = subprocess.run([executable, "--version"], capture_output=True, timeout=60)
        text = (done.stdout + done.stderr).decode("utf-8", "replace")
        match = re.search(r"[0-9]+\.[0-9]+\.[0-9]+", text)
        version = match.group(0) if match else None
    _version_cache[provider] = version
    return version


def measurement_ok(relative, provider, subcommand, control, surface):
    """A measurement is only allowed to excuse a control if it is well formed, current, about THIS
    control, and not merely restating that a parent surface documents it."""
    record = UNDOCUMENTED_CONTROLS.get((provider, tuple(subcommand), control))
    if record is None:
        return None
    if not isinstance(record, dict) or set(record) != MEASUREMENT_FIELDS:
        fail(f"{relative}: the UNDOCUMENTED_CONTROLS entry for `{control}` on `{surface}` is not a "
             f"well-formed measurement (needs exactly {sorted(MEASUREMENT_FIELDS)}); CANNOT CHECK")
        return False
    if record["cli"] != provider:
        fail(f"{relative}: the measurement for `{control}` on `{surface}` names cli "
             f"{record['cli']!r}, not {provider!r}; CANNOT CHECK")
        return False
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", str(record["date"])):
        fail(f"{relative}: the measurement for `{control}` on `{surface}` has no ISO date; "
             f"CANNOT CHECK")
        return False
    if control not in record["argv"]:
        fail(f"{relative}: the measurement for `{control}` on `{surface}` records an argv that does "
             f"not contain that control, so it measured something else; CANNOT CHECK")
        return False
    if not isinstance(record["rc"], int) or isinstance(record["rc"], bool):
        fail(f"{relative}: the measurement for `{control}` on `{surface}` has no integer rc; "
             f"CANNOT CHECK")
        return False
    # A control documented on a PARENT surface is the union this scanner forbids, and no measurement
    # may launder it. `-a` on `codex exec` is exactly this shape: documented at the codex top level,
    # rejected by `codex exec`, and the whole reason the guard exists.
    for depth in range(len(subcommand)):
        parent = subcommand[:depth]
        parent_text = help_text(provider, parent)
        if parent_text and flag_present(control, parent_text):
            parent_surface = " ".join([provider] + list(parent) + ["--help"])
            fail(f"{relative}: `{control}` is passed on `{surface}` and excused by a measurement, "
                 f"but it IS documented on the parent surface `{parent_surface}`. That is the "
                 f"cross-surface union this scanner exists to reject, and a measurement cannot "
                 f"launder it — remove the UNDOCUMENTED_CONTROLS entry and move the control")
            return False
    current = installed_version(provider)
    if current is None:
        fail(f"{relative}: cannot read the installed {provider} version to check the measurement "
             f"for `{control}` on `{surface}`; CANNOT CHECK")
        return False
    if current != record["version"]:
        fail(f"{relative}: the measurement for `{control}` on `{surface}` was taken against "
             f"{provider} {record['version']} but {current} is installed. Stale evidence is not "
             f"evidence; re-measure and update the record")
        return False
    return True


def check(relative, provider, tokens):
    surfaces, opaque = split_surfaces(provider, tokens)
    if opaque:
        # A surface that STOPS being checked must not be indistinguishable from one that passed.
        # Before this, `codex "${badargs[@]}" --ephemeral` returned rc 0 and the `codex exec --help`
        # line simply vanished from the output — silence reading as success, which is the exact
        # conflation this scanner refuses everywhere else.
        fail(f"{relative}: a {provider} launch takes arguments from an unexpanded expansion "
             f"({', '.join(sorted(set(opaque))[:3])}), so the controls it passes and the surfaces "
             f"it passes them on CANNOT BE CHECKED. Spell the controls literally at the launch "
             f"site, or move the launch behind a declaration that has its own drift check")
    for subcommand, controls in surfaces:
        surface = " ".join([provider] + subcommand + ["--help"])
        text = help_text(provider, subcommand)
        if text is None:
            fail(f"{relative}: cannot read the help surface `{surface}` that {relative} passes "
                 f"{', '.join(controls)} on; CANNOT CHECK")
            continue
        clean = True
        for control in controls:
            if flag_present(control, text):
                continue
            verdict = measurement_ok(relative, provider, subcommand, control, surface)
            if verdict is True:
                record = UNDOCUMENTED_CONTROLS[(provider, tuple(subcommand), control)]
                notes.append(f"{relative}: `{control}` on `{surface}` is undocumented but measured "
                             f"{record['date']} against {record['cli']} {record['version']}: "
                             f"rc={record['rc']}, {record['observed']}")
                continue
            if verdict is False:
                clean = False          # measurement_ok already recorded the specific reason
                continue
            clean = False
            fail(f"{relative}: `{control}` is passed on `{surface}` but that surface does not "
                 f"accept it (being accepted on a different surface does not satisfy it, and an "
                 f"undocumented control needs a measurement in UNDOCUMENTED_CONTROLS)")
        if clean:
            notes.append(f"{relative}: `{surface}` accepts {' '.join(controls)}")


def main():
    root = Path(sys.argv[1]).resolve()
    mutations = []
    arguments = sys.argv[2:]
    while arguments:
        if arguments[0] == "--mutate":
            path, source, target = arguments[1].split(":", 2)
            mutations.append((path, source, target))
            arguments = arguments[2:]
        elif arguments[0] == "--measurements":
            print("provider-launch-scan: MEASUREMENT REGISTRY OVERRIDDEN FROM FILE — test mode; "
                  "this is not a production configuration", file=sys.stderr)
            try:
                loaded = json.loads(Path(arguments[1]).read_text(encoding="utf-8"))
                UNDOCUMENTED_CONTROLS.clear()
                for item in loaded:
                    UNDOCUMENTED_CONTROLS[
                        (item["provider"], tuple(item["subcommand"]), item["control"])
                    ] = item["measurement"]
            except Exception as exc:                                # noqa: BLE001
                print(f"provider-launch-scan: cannot load measurements: {exc}", file=sys.stderr)
                return 2
            arguments = arguments[2:]
        else:
            print(f"provider-launch-scan: unknown argument {arguments[0]}", file=sys.stderr)
            return 2
    try:
        tracked = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"]).split(b"\0")
    except subprocess.SubprocessError as exc:
        print(f"provider-launch-scan: cannot list tracked files: {exc}; CANNOT CHECK",
              file=sys.stderr)
        return 2

    scanned = 0
    accounted = set()
    for raw in tracked:
        if not raw:
            continue
        relative = raw.decode("utf-8", "replace")
        path = root / relative
        if not path.is_file() or path.is_symlink():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for path, source, target in mutations:
            if path != relative:
                continue
            if source not in text:
                print(f"provider-launch-scan: mutation source not found in {relative}",
                      file=sys.stderr)
                return 2
            text = text.replace(source, target)
        scanned += 1
        # A launch site is only ever in a file the firm executes. Fixtures and eval kickoff prose
        # describe provider commands; they do not run them, and the shebang says so.
        first = text.split("\n", 1)[0]
        is_script = first.startswith("#!")
        launches = []
        if is_script and ("sh" in first or "bash" in first):
            launches = shell_launches(relative, text)
        elif is_script and "python" in first:
            launches = python_launches(relative, text)
        elif relative.endswith(".py"):
            launches = python_launches(relative, text)
        elif is_script:
            launches = shell_launches(relative, text)
        if not launches:
            continue
        owner = LAUNCH_OWNERS.get(relative)
        if owner is None:
            fail(f"{relative}: launches a provider CLI but is not accounted for in LAUNCH_OWNERS. "
                 f"Every place the firm may talk to a provider CLI is a decision that has to be "
                 f"written down; this one is not. Sites found: "
                 + "; ".join(f"{p} {' '.join(t[:4])}..." for p, t in launches))
            continue
        accounted.add(relative)
        if owner.startswith("contract:"):
            notes.append(f"{relative}: argv is built by {owner.split(':', 1)[1]} and checked by its "
                         f"own drift test; not re-derived here")
            continue
        for provider, tokens in launches:
            check(relative, provider, tokens)

    for relative, owner in LAUNCH_OWNERS.items():
        if not (root / relative).is_file():
            fail(f"{relative}: declared in LAUNCH_OWNERS but no longer exists; the registry is stale")
        elif relative not in accounted and not owner.startswith("contract:"):
            # A registry entry that no longer matches anything is worse than no entry: it reads as
            # "this file is checked" while nothing is checked. Either the launch moved, or the
            # scanner stopped seeing it — both need a person, not a silent pass.
            fail(f"{relative}: declared in LAUNCH_OWNERS as `{owner}` but the scan found no launch "
                 f"site in it. Either the launch moved and the registry is stale, or the scanner no "
                 f"longer recognises the shape it is written in; this is not a pass")

    print(f"provider-launch-scan: scanned {scanned} tracked files, "
          f"{len(LAUNCH_OWNERS)} accounted launch owners")
    for note in sorted(set(notes)):
        print(f"ok   {note}")
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
