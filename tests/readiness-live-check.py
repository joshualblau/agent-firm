#!/usr/bin/env python3
"""Bind the wrapper's READINESS declaration to the REAL installed provider CLIs.

The drift assertion asked for by system-changes/20260821T203252Z-readiness-probes-ask-shapes-the-
clis-do-not-have.md: *every declared response key must be one a real CLI actually emits*. Nothing
here is hardcoded per provider; everything is read from `--print-capability-contract`, so the check
follows the declaration wherever it goes.

For each provider CLI installed on this host it runs the declared readiness command twice:

  (A) in this host's ambient environment, and
  (B) with HOME, CODEX_HOME, CLAUDE_CONFIG_DIR and XDG_CONFIG_HOME pointed at a fresh empty
      directory, which is a logged-out CLI that has not been logged out.

Then it applies the declaration — the same matching rule the wrapper applies — to both responses:

  * (B) MUST classify as the declared `unavailable` answer, body and exit status together. This arm
    is deterministic on any host, authenticated or not, so it is a hard requirement: if the CLI
    stops saying "Not logged in" / `loggedIn:false`, or starts saying it with a different exit
    status, this fails and the declaration is stale.
  * (A) must classify as `ready` on an authenticated host. On a logged-out host it will classify as
    `unavailable`, which is reported as NOT EXERCISED rather than failed — but if it classifies as
    NEITHER, that is drift and it fails. "Unrecognised" is the answer the wrapper turns into a BLOCK,
    and a host whose real CLI produces it would have no working second voice.
  * Every declared JSON key must be present in a real payload from at least one arm. A key no CLI
    emits is the original defect written down (the old code read `status`/`authentication`; the CLI
    emits `loggedIn`), and it must not survive being declared.

Fails closed PER PROVIDER: a declared provider whose CLI is not installed is an unverified
declaration and therefore a failure, not a "NOT CHECKED" line in a green log. An earlier revision
only failed when NO CLI was present, so a host with one of the two passed on the other's strength
while an entire declaration went unchecked — "could not check" reported as "checked and fine", in
the guard written to refuse exactly that. A host that genuinely has one provider can say so out
loud with FIRM_READINESS_LIVE_ALLOW_MISSING=gpt (comma-separated), which still prints the provider
as unverified; there is no silent path.

The two arms rot differently, and both rot safely:

  * The UNAVAILABLE half is pinned on every host, authenticated or not, because the logged-out arm
    is forced. It fires the day either vendor changes "Not logged in", `loggedIn:false`, or their
    exit statuses.
  * The READY half is only pinned on an authenticated host. On a logged-out one it is reported as
    NOT EXERCISED with a WARNING line, so a green log still says which half was checked. A ready
    declaration that goes stale unnoticed produces a false BLOCK, never a false available.

Nothing here costs subscription spend — both declared commands are local status queries; neither
starts a model turn.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

EXECUTABLE = {"gpt": "codex", "claude": "claude"}
PROBE_TIMEOUT = 60


def run(argv, env=None):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=PROBE_TIMEOUT, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"{type(exc).__name__}: {exc}"
    # The wrapper merges the child's stderr into the captured stream (firm-bounded-exec is given no
    # --stderr-output for these phases), and it has to: `codex login status` writes its answer to
    # STDERR. Reading stdout alone here would check a stream the wrapper does not read.
    return done.returncode, (done.stdout or "") + (done.stderr or "")


def answer_node(declaration, data):
    """The object readiness_answer() reads its answer OUT OF, or None.

    A declaration may name an envelope the whole report must match, a path to the entry that carries
    the answer, and fields that entry must use to identify itself. `codex doctor --json` needs all
    three: it reports the whole installation, so `status` at the top level is the WRONG status and
    `checks["auth.credentials"]` is the right one only when it says it is the auth check."""
    for key, expected in (declaration.get("envelope") or {}).items():
        if data.get(key) != expected:
            return None
    node = data
    for step in (declaration.get("path") or []):
        node = node.get(step) if isinstance(node, dict) else None
    if not isinstance(node, dict):
        return None
    for key, expected in (declaration.get("require_fields") or {}).items():
        if node.get(key) != expected:
            return None
    return node


def classify(declaration, exit_code, text):
    """Apply the declaration exactly as readiness_answer() in bin/firm-reviewer-common does."""
    matched = []
    if declaration["shape"] == "json":
        try:
            data = json.loads(text)
        except Exception:
            return None
        if not isinstance(data, dict):
            return None
        node = answer_node(declaration, data)
        if node is None:
            return None
        for answer in declaration["answers"]:
            value = node.get(answer["key"], None)
            if isinstance(answer["value"], bool):
                if isinstance(value, bool) and value is answer["value"]:
                    matched.append(answer)
            elif isinstance(value, str) and value == answer["value"]:
                matched.append(answer)
    else:
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        for answer in declaration["answers"]:
            if any(re.fullmatch(answer["line"], line) for line in lines):
                matched.append(answer)
    if len(matched) != 1:
        return None
    # `exit_codes: None` is declared only alongside exit_status_is_the_answer False, and only for a
    # surface measured to summarise unrelated checks in its status. It is mirrored here rather than
    # reimplemented, because this file exists to apply the wrapper's own rule to a real CLI.
    codes = matched[0]["exit_codes"]
    if codes is not None and exit_code not in codes:
        return None
    return matched[0]["answer"]


def ambient_environment(name, contract, scratch):
    """The ambient environment, with the provider's config directory redirected onto a scratch copy
    of the declared credential. Returns None (meaning "inherit ambient unchanged") when there is no
    file credential to copy, so nothing is silently withheld from the probe."""
    declared = ((contract.get("credentials") or {}).get(name) or {}).get("materialize") or []
    copies = [item for item in declared if item.get("kind") == "copy"]
    if not copies:
        return None
    env = dict(os.environ)
    provider_home = os.path.join(scratch, "provider")
    os.makedirs(provider_home, mode=0o700, exist_ok=True)
    seeded = False
    for item in copies:
        spec = item["source"]
        if spec.startswith("${CODEX_HOME:-~/.codex}"):
            base = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
            source = os.path.join(base, spec[len("${CODEX_HOME:-~/.codex}/"):])
        else:
            source = os.path.expanduser(spec)
        target = os.path.join(provider_home, os.path.basename(item["destination"]))
        try:
            shutil.copyfile(source, target)
            os.chmod(target, 0o400)
            seeded = True
        except OSError:
            continue
    if not seeded:
        return None
    if name == "gpt":
        env["CODEX_HOME"] = provider_home
    return env


def logged_out_environment(scratch):
    env = {key: value for key, value in os.environ.items()
           if key in ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "SYSTEMROOT", "TERM")}
    env.update({"HOME": scratch, "XDG_CONFIG_HOME": os.path.join(scratch, "xdg"),
                "CODEX_HOME": os.path.join(scratch, "codex"),
                "CLAUDE_CONFIG_DIR": os.path.join(scratch, "claude"),
                "TMPDIR": os.path.join(scratch, "tmp"), "PYTHONUTF8": "1"})
    for name in ("xdg", "codex", "claude", "tmp"):
        os.makedirs(os.path.join(scratch, name), exist_ok=True)
    return env


def main():
    common = sys.argv[1]
    done = subprocess.run([common, "gpt", "--print-capability-contract"],
                          capture_output=True, text=True)
    if done.returncode != 0:
        print(f"FAIL: --print-capability-contract exited {done.returncode}: {done.stderr.strip()}")
        return 1
    contract = json.loads(done.stdout)
    if "readiness" not in contract:
        print("FAIL: the wrapper declares no readiness contract to check")
        return 1
    readiness = contract["readiness"]

    problems = []
    checked = []
    for name in sorted(readiness):
        declaration = readiness[name]
        if declaration["command"] != declaration["probe_argv"]:
            problems.append(f"{name}: declared command {declaration['command']} is not the argv the "
                            f"wrapper runs {declaration['probe_argv']}")
        executable = shutil.which(EXECUTABLE[name])
        if not executable:
            waived = [item.strip() for item
                      in os.environ.get("FIRM_READINESS_LIVE_ALLOW_MISSING", "").split(",")
                      if item.strip()]
            if name in waived:
                print(f"UNVERIFIED {name}: {EXECUTABLE[name]} is not installed and was explicitly "
                      f"waived by FIRM_READINESS_LIVE_ALLOW_MISSING; its declaration was NOT checked")
            else:
                problems.append(
                    f"{name} is declared but {EXECUTABLE[name]} is not installed, so its readiness "
                    f"declaration — command, response keys and exit statuses — was not verified. "
                    f"Set FIRM_READINESS_LIVE_ALLOW_MISSING={name} to state that on purpose")
            continue
        checked.append(name)
        argv = [executable] + list(declaration["probe_argv"])
        label = " ".join([EXECUTABLE[name]] + list(declaration["probe_argv"]))
        print(f"  {name}: declared readiness probe `{label}` ({declaration['shape']})")

        payloads = []

        # (B) the forced logged-out arm — deterministic on every host.
        with tempfile.TemporaryDirectory(prefix="firm-readiness-") as scratch:
            rc, text = run(argv, env=logged_out_environment(scratch))
        if rc is None:
            problems.append(f"{name}: `{label}` could not run with an empty config root: {text}")
        else:
            payloads.append(text)
            answer = classify(declaration, rc, text)
            first = " / ".join(text.strip().splitlines()[:1]) or "<no output>"
            print(f"    empty config root -> exit {rc}, classified {answer!r}   [{first[:80]}]")
            if answer != "unavailable":
                problems.append(
                    f"{name}: with an empty config root `{label}` exited {rc} and classified "
                    f"{answer!r}, but the declaration says that response is the trusted "
                    f"`unavailable` answer. The declared shape no longer matches the real CLI")

        # (A) the ambient arm — 'ready' here is what lets a second voice run at all.
        #
        # IT RUNS AGAINST A COPY OF THE CREDENTIAL, NEVER AGAINST THE OPERATOR'S STORE. The declared
        # gpt probe is `codex doctor --json`, and codex doctor WRITES: measured 2026-08-25, it
        # creates `tmp/arg0/...` inside whatever CODEX_HOME it is given. A check that runs it with
        # the ambient CODEX_HOME therefore mutates the operator's real ~/.codex as a side effect of
        # testing a declaration, which this file must not do -- and running the probe in the
        # operator's whole profile was never what the ambient arm was for anyway. What it is for is
        # "does a real, AUTHENTICATED CLI classify as ready", and the thing that makes it
        # authenticated is exactly the artifact CREDENTIAL_CONTRACT copies. So the arm is given the
        # same environment the judge gets: a scratch provider directory holding a copy of the
        # declared credential and nothing else. If the credential is absent the arm still runs
        # ambient, because then there is nothing to protect and nothing to copy.
        with tempfile.TemporaryDirectory(prefix="firm-readiness-live-") as live_scratch:
            ambient_env = ambient_environment(name, contract, live_scratch)
            rc, text = run(argv, env=ambient_env)
        if rc is None:
            problems.append(f"{name}: `{label}` could not run in the ambient environment: {text}")
        else:
            payloads.append(text)
            answer = classify(declaration, rc, text)
            print(f"    ambient environment -> exit {rc}, classified {answer!r}")
            if answer is None:
                problems.append(
                    f"{name}: `{label}` exited {rc} in the ambient environment and matched NO "
                    f"declared answer. The wrapper turns that into a BLOCK, so this host has no "
                    f"working {name} second voice — the declaration has drifted from the CLI")
            elif answer == "unavailable":
                print(f"    WARNING: NOT EXERCISED {name}: this host is logged out of "
                      f"{EXECUTABLE[name]}, so the 'ready' half of its declaration was NOT confirmed "
                      f"against a real authenticated CLI. Only the unavailable half is pinned here")

        # Every declared response key must be emitted by a real CLI -- AT THE PLACE THE DECLARATION
        # SAYS IT READS IT. Looking at the top level would call `status` emitted for `codex doctor
        # --json`, which prints several unrelated ones, while the declaration reads exactly the one
        # inside the identified auth entry. Asking the shallower question would let a key that is
        # real somewhere else pass as a key that is real HERE, which is the same class of mistake as
        # the union-satisfaction defect on the capability side.
        for key in declaration["keys"]:
            emitted = False
            for text in payloads:
                try:
                    data = json.loads(text)
                except Exception:
                    continue
                if not isinstance(data, dict):
                    continue
                node = answer_node(declaration, data)
                if isinstance(node, dict) and key in node:
                    emitted = True
            print(f"    declared key {key!r}: {'emitted by the real CLI' if emitted else 'NOT EMITTED'}")
            if not emitted:
                problems.append(
                    f"{name}: declared response key {key!r} appears in no real response from "
                    f"`{label}`. Reading a key the CLI does not emit is the defect this check exists "
                    f"to refuse")

    if not checked:
        print("FAIL: no provider CLI is installed, so no declaration was verified. 'Could not check' "
              "is reported as a failure on purpose.")
        return 1
    print(f"CHECKED against a real CLI: {', '.join(checked)}")
    for line in problems:
        print("FAIL: " + line)
    if problems:
        return 1
    print(f"PASS: the readiness declaration matches the installed CLI for: {', '.join(checked)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
