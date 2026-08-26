#!/usr/bin/env python3
"""Check the wrapper's capability declaration against the REAL installed provider CLIs.

Two checks, both against binaries actually on this host, both reading whatever the wrapper declares
rather than hardcoding any provider:

  (1) SURFACE OWNERSHIP. Every declared control must appear in the help text of the surface it is
      declared on — not "some surface". The union rule is what this eval exists to refuse: it
      certified `--ask-for-approval` because it is in `codex --help`, while the invocation passed it
      to `codex exec`, which rejects it outright.

  (2) INVOCATION PARSE. The provider's real invocation argv, with placeholders for operands and
      `--help` appended, must exit 0 on the real CLI. This is the check that catches (1)'s failure
      mode directly rather than by inference: `codex exec -a never ... --help` exits 2 with
      "unexpected argument '-a' found".

Check (2) self-tests its own discriminating power before it is trusted. Codex (clap) rejects unknown
arguments even when `--help` is present, so a clean exit 0 is real evidence. Claude Code (commander)
short-circuits on `--help` and exits 0 even for `--bogus-flag`, so for that CLI the check proves
nothing and is reported as NOT PARSE-CHECKED — never as a pass. A check that cannot fail must not be
counted as a check; that conflation is the defect class this whole eval guards.

Fails closed everywhere: no provider CLI installed, a declared surface that will not run, a control
missing from its own surface, a discriminating parse check that fails. `--help` short-circuits before
any model call on both CLIs (verified), so nothing here costs subscription spend.
"""
import json
import shutil
import subprocess
import sys

EXECUTABLE = {"gpt": "codex", "claude": "claude"}
PROBE_TIMEOUT = 60
BOGUS = "--firm-capability-probe-bogus-flag"


def run(argv):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=PROBE_TIMEOUT)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"{type(exc).__name__}: {exc}"
    return done.returncode, (done.stdout or "") + (done.stderr or "")


def main():
    common = sys.argv[1]
    done = subprocess.run([common, "gpt", "--print-capability-contract"],
                          capture_output=True, text=True)
    if done.returncode != 0:
        print(f"FAIL: --print-capability-contract exited {done.returncode}: {done.stderr.strip()}")
        return 1
    providers = json.loads(done.stdout)["providers"]

    problems = []
    checked = []
    for name in sorted(providers):
        entry = providers[name]
        executable = shutil.which(EXECUTABLE[name])
        if not executable:
            print(f"NOT CHECKED {name}: {EXECUTABLE[name]} is not installed on this host")
            continue
        checked.append(name)

        # (1) surface ownership
        for surface in entry["declared_surfaces"]:
            path = list(surface["subcommand"])
            label = " ".join([EXECUTABLE[name]] + path + ["--help"])
            rc, text = run([executable] + path + ["--help"])
            if rc is None:
                problems.append(f"{name}: declared help surface `{label}` could not run: {text}")
                continue
            if rc != 0:
                problems.append(
                    f"{name}: declared help surface `{label}` exited {rc} — a probe that cannot run "
                    f"is not a provider that lacks a capability")
                continue
            print(f"  {name}: surface `{label}` owns {len(surface['controls'])} control(s)")
            for flag in surface["controls"]:
                # Word boundary, matching the wrapper: plain containment would find `-s` inside
                # `--sandbox` and report every short option as supported by any help text at all.
                import re
                present = re.search(r"(?<![\w-])" + re.escape(flag) + r"(?![\w-])", text) is not None
                print(f"    {flag:26} {'found on ' + label if present else 'NOT FOUND on ' + label}")
                if not present:
                    problems.append(
                        f"{name}: control {flag} is declared on `{label}` but is not there. It is "
                        f"required on the surface the wrapper passes it on; presence on any other "
                        f"surface does not satisfy it")

        # (2) invocation parse, with a self-test of the check's own discriminating power
        argv = [token for token in entry["invocation_argv"]]
        bogus_rc, _ = run([executable] + argv + [BOGUS, "--help"])
        real_rc, real_text = run([executable] + argv + ["--help"])
        if bogus_rc == 0:
            print(f"  {name}: NOT PARSE-CHECKED — {EXECUTABLE[name]} exits 0 for `--help` even with "
                  f"{BOGUS} present, so a clean exit proves nothing about this argv")
        elif bogus_rc is None:
            problems.append(f"{name}: invocation parse self-test could not run")
        elif real_rc != 0:
            problems.append(
                f"{name}: the real judge invocation does not parse on {executable} (exit {real_rc}): "
                + " ".join(real_text.strip().splitlines()[:2])
                + f"  argv: {' '.join(argv)}")
        else:
            print(f"  {name}: invocation parses on {executable} (self-test: {BOGUS} correctly "
                  f"rejected with exit {bogus_rc})")

    if not checked:
        print("FAIL: no provider CLI was installed, so nothing was verified. This check reports "
              "'cannot evaluate' as a failure on purpose; a probe that silently passes when it "
              "checked nothing is the defect it exists to catch.")
        return 1
    for line in problems:
        print("FAIL: " + line)
    if problems:
        return 1
    print(f"PASS: every control is present on the surface that owns it, for: {', '.join(checked)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
