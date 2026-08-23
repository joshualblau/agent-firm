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

WHAT IT DOES NOT DO, DELIBERATELY
  * It never runs a provider CLI with anything but `--help`, and only on subcommand chains it has
    already confirmed from the parent's own `Commands:` block. Claude Code treats an unrecognised
    argument as a PROMPT and bills a real turn, so probing speculative tokens against it would buy
    prose and call it a fact — the defect firm-reviewer-common's readiness comment describes.
  * It does not model shell control flow. It reads command position, which is all a launch site is.

FAIL-CLOSED. A line that cannot be tokenised but contains a bare provider word in command position
is a FAILURE, not a skip. "Could not check" is never reported as "checked and fine".

usage: provider-launch-scan.py <repo-root> [--mutate <path>:<from>:<to>]
       --mutate rewrites one tracked file IN MEMORY before scanning, so a test can prove a check
       bites without editing a tracked file.
"""
import ast
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
PREFIX_WORDS = {"env", "command", "nohup", "time", "exec", "sudo", "-", "!", "run_capped"}
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
        index += 1
    return [(list(sub), controls) for sub, controls in surfaces if controls]


# Words after which a command may begin. `--` is here because every launch in the firm goes through
# firm-bounded-exec, whose argv separator is exactly that; a scanner that stops at `--` sees none of
# the supervised launches, which are all of them.
SEPARATORS = {";", "|", "&&", "||", "&", "(", "{", "then", "do", "else", ";;", "--",
              "if", "elif", "while", "until"}
MAX_CONTINUATION = 40


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
        if not re.search(r"(?<![\w./-])(codex|claude)(?![\w./-])", line):
            continue
        tokens = tokenise(line)
        if tokens is None:
            # Unparsable. Fail closed only if a provider still stands in command position with an
            # argument after it — otherwise this is prose or a pattern, not a launch.
            if re.search(r"(?:^|[;&|(]\s*|\s)(codex|claude)\s+[-a-z]", line):
                fail(f"{relative}: a line launching a provider CLI could not be tokenised, so its "
                     f"launch surface CANNOT BE CHECKED: {line.strip()[:120]}")
            continue
        position_open = True
        for index, token in enumerate(tokens):
            following = tokens[index + 1] if index + 1 < len(tokens) else None
            if (token in PROVIDERS and position_open and following is not None
                    and (following.startswith("-") or following in subcommands(token, []))):
                found.append((token, tokens[index + 1:]))
                position_open = False
            elif token in PREFIX_WORDS or ASSIGNMENT.match(token) or NUMBER.match(token):
                continue
            elif token in SEPARATORS:
                position_open = True
            else:
                position_open = False
    return found


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
                found.append((named[0], [e.value for e in argument.elts]))
    return found


# Controls a provider ACCEPTS but does not print in `--help`. The help text is the only offline
# evidence there is, so a control missing from it is a failure by default — but "missing from help"
# and "rejected by the CLI" are different facts, and collapsing them would be this scanner making
# the same mistake it exists to catch. An entry here is a written, dated MEASUREMENT, not a mute
# button: it says someone ran the control against the real CLI and recorded what happened. An
# unmeasured missing control still fails.
UNDOCUMENTED_CONTROLS = {
    # measured 2026-08-23, Claude Code 2.1.238:
    #   claude --max-turns 3 -p "Reply with exactly: ok" --output-format text \
    #     --permission-mode dontAsk --tools "" --no-session-persistence
    #   -> rc 0, "ok". Accepted and effective; simply absent from `claude --help`.
    ("claude", (), "--max-turns"): "measured 2026-08-23 on Claude Code 2.1.238: accepted, rc 0",
}


def check(relative, provider, tokens):
    for subcommand, controls in split_surfaces(provider, tokens):
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
            measured = UNDOCUMENTED_CONTROLS.get((provider, tuple(subcommand), control))
            if measured:
                notes.append(f"{relative}: `{control}` on `{surface}` is undocumented but "
                             f"{measured}")
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
