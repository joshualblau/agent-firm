#!/usr/bin/env python3
"""Bind the judge's credential passthrough to the CLIs actually installed on this host.

Offline declaration checking cannot prove a passthrough authenticates, and it cannot prove the seal
still holds around it — both are facts about the vendor's binaries and this machine. So this script
builds the SAME environment the reviewer builds, from the SAME published declaration, and measures:

  1. With the declared passthrough, the declared readiness probe answers READY.
  2. With the passthrough withheld, the same probe answers the declared UNAVAILABLE — the fail-closed
     path, which must stay a trusted classified answer and never a ready judge.
  3. The canary: from inside the passthrough environment, the operator's agent settings, hooks,
     plugins, MCP configuration, skills, session history and project files are NOT reachable.

Neither probe starts a model turn, so this costs no subscription spend. It fails CLOSED: a CLI that
is absent, a declaration that cannot be read, a probe that will not run are all reported as CANNOT
CHECK and exit nonzero. "Could not check" is never reported as "checked and fine".

usage: credential-live-check.py <bin-dir> [gpt|claude ...]
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

bin_dir = Path(sys.argv[1])
wanted = sys.argv[2:] or ["gpt", "claude"]
EXECUTABLE = {"gpt": "codex", "claude": "claude"}
failures = []
notes = []


def cannot_check(message):
    print(f"credential-live-check: {message}; CANNOT CHECK", file=sys.stderr)
    raise SystemExit(2)


try:
    published = json.loads(subprocess.check_output(
        [str(bin_dir / "firm-gpt-qa"), "--print-capability-contract"], text=True))
except Exception as exc:                                        # noqa: BLE001
    cannot_check(f"the published contract could not be read: {exc}")

# The canary set. Each is a real operator surface the judge must not reach, named as a path relative
# to the operator's REAL home, and checked for reachability from inside the judge's sealed home.
CANARY = {
    "agent_settings": ".claude/settings.json",
    "hooks": ".claude/hooks",
    "plugins": ".claude/plugins",
    "mcp_servers": ".claude.json",
    "skills": ".claude/skills",
    "session_history": ".claude/history.jsonl",
    "operator_projects": ".claude/projects",
    "codex_history": ".codex/history.jsonl",
    "codex_global_state": ".codex/.codex-global-state.json",
}


def build_environment(provider, home, seal_only):
    """The reviewer's phase environment, reconstructed from the published declaration."""
    declared = published["credentials"][provider]
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / "xdg"),
        "CODEX_HOME": str(home / "codex"),
        "CLAUDE_CONFIG_DIR": str(home / "claude"),
        "TMPDIR": str(home / "tmp"),
        "PYTHONUTF8": "1",
    }
    for name in ("LANG", "LC_ALL", "LC_CTYPE"):
        if name in os.environ:
            env[name] = os.environ[name]
    for directory in ("xdg", "codex", "claude", "tmp"):
        (home / directory).mkdir(parents=True, exist_ok=True, mode=0o700)
    if seal_only:
        return env
    for name in declared["unset_environment"]:
        env.pop(name, None)
    for name in declared["inherit_environment"]:
        value = os.environ.get(name)
        if value is not None and re.fullmatch(r"[A-Za-z0-9._-]{1,64}", value):
            env[name] = value
    for item in declared["materialize"]:
        source = Path(os.path.expanduser(item["source"]))
        destination = home.joinpath(*Path(item["destination"]).parts)
        if not source.is_file() or source.is_symlink():
            cannot_check(f"declared credential source is missing or unsafe: {item['source']}")
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if item["kind"] == "copy":
            shutil.copyfile(source, destination)
            os.chmod(destination, 0o400)
        else:
            os.symlink(os.path.realpath(source), destination)
    return env


def probe(provider, env):
    declared = published["readiness"][provider]
    executable = shutil.which(EXECUTABLE[provider], path=env["PATH"])
    if not executable:
        cannot_check(f"{EXECUTABLE[provider]} is not on PATH")
    done = subprocess.run([executable] + declared["command"], env=env, capture_output=True,
                          timeout=120)
    body = (done.stdout + done.stderr).decode("utf-8", "replace")
    matched = []
    for answer in declared["answers"]:
        if declared["shape"] == "json":
            try:
                data = json.loads(body)
            except Exception:                                   # noqa: BLE001
                continue
            value = data.get(answer["key"]) if isinstance(data, dict) else None
            if isinstance(value, bool) and value is answer["value"]:
                matched.append(answer)
        else:
            lines = [line.strip() for line in body.splitlines() if line.strip()]
            if any(re.fullmatch(answer["line"], line) for line in lines):
                matched.append(answer)
    if len(matched) != 1 or done.returncode not in matched[0]["exit_codes"]:
        return None, None
    return matched[0]["answer"], matched[0].get("reason")


for provider in wanted:
    if provider not in published["credentials"]:
        cannot_check(f"no published credential declaration for {provider}")
    with tempfile.TemporaryDirectory() as work:
        home = Path(work) / "credentialed"
        home.mkdir(mode=0o700)
        env = build_environment(provider, home, seal_only=False)
        answer, reason = probe(provider, env)
        if answer != "ready":
            failures.append(
                f"{provider}: the declared passthrough did NOT authenticate "
                f"(answer={answer!r} reason={reason!r}). The judge cannot run in this direction.")
        else:
            notes.append(f"{provider}: declared passthrough authenticates (readiness = ready)")

        # THE CANARY, AND EXACTLY WHAT IT IS. It asks one narrow question: does a path INSIDE the
        # sealed home resolve onto the operator's real surface? That is a question about the SHAPE
        # OF THE SEALED HOME, and it is the only question the seal itself can answer.
        #
        # It is NOT a filesystem-isolation check, and the earlier version of this file read as if it
        # were. In the gpt direction it cannot be one: `-s read-only` denies writes and permits reads
        # everywhere, so a judge that opens an ABSOLUTE path never touches the sealed home and
        # nothing it reads that way can ever appear here. Review demonstrated precisely that,
        # returning ~/.codex/history.jsonl and ~/.claude/settings.json verbatim from inside this
        # environment. See READ_BOUNDARY in bin/firm-reviewer-common for what bounds reads per
        # provider — uid for gpt, the permission system for claude.
        real_home = Path(os.path.expanduser("~"))
        checked = []
        absent = []
        for label, relative in CANARY.items():
            operator_path = real_home / relative
            if not operator_path.exists():
                # Counted and NAMED, never credited. The old line said "clean over 9 surfaces" while
                # silently skipping every surface this host happens not to have — on the review host
                # that was 9 reported for 7 actually checked, which is the same "could not check
                # reported as checked and fine" this file's own docstring refuses to do.
                absent.append(label)
                continue
            checked.append(label)
            sealed_path = home / relative
            reachable = sealed_path.exists() and (
                os.path.realpath(sealed_path) == os.path.realpath(operator_path))
            if reachable:
                failures.append(
                    f"{provider}: SEAL BREACH — the operator's {label} ({relative}) is reachable "
                    f"THROUGH THE SEALED HOME; authentication does not require it.")
        summary = (f"{provider}: no operator surface is reachable through the sealed home "
                   f"({len(checked)} of {len(CANARY)} checked")
        summary += (f"; {len(absent)} absent on this host: {', '.join(absent)})"
                    if absent else ")")
        notes.append(summary)
        boundary = published["credentials"][provider]["read_boundary"]
        notes.append(f"{provider}: this proves nothing about absolute-path reads — the declared "
                     f"read boundary is `{boundary['bounded_by']}`")
        # Print the caveats on whatever this passthrough exposes, beside the clean result they
        # qualify. A canary that reports "clean" and stops reads as a broader assurance than it is,
        # and for the claude keychain the two qualifications ARE the story: the surface is writable
        # by the CLI, and this check cannot see inside it.
        for item in published["credentials"][provider]["materialize"]:
            for caveat in item.get("caveats", []):
                notes.append(f"{provider}: CAVEAT on {item['exposes']} — {caveat}")

    with tempfile.TemporaryDirectory() as work:
        home = Path(work) / "sealed"
        home.mkdir(mode=0o700)
        env = build_environment(provider, home, seal_only=True)
        answer, reason = probe(provider, env)
        if answer != "unavailable" or reason != "authentication":
            failures.append(
                f"{provider}: with the passthrough withheld the outcome was not a trusted "
                f"classified unavailable (answer={answer!r} reason={reason!r}).")
        else:
            notes.append(f"{provider}: withheld passthrough fails closed (unavailable/authentication)")

for note in notes:
    print(f"ok   {note}")
for failure in failures:
    print(f"FAIL {failure}", file=sys.stderr)
raise SystemExit(1 if failures else 0)
