#!/usr/bin/env python3
"""Check each provider's DECLARED help surfaces against the REAL installed CLI.

This is the measurement the originating engagement had to make by hand, after a false
`unsupported_capability` sent it to a pointless `brew upgrade codex`. It reads the wrapper's own
declaration (`firm-reviewer-common <provider> --print-capability-contract`), runs exactly the help
surfaces that declaration names, and requires every declared control to appear in at least one of
them — the same rule discovery applies at runtime, checked against the binaries actually installed.

Fails closed:
  * no provider CLI installed at all      -> exit 1 (cannot evaluate, never "fine")
  * a declared help surface will not run  -> exit 1 (a broken probe is not a missing capability)
  * a required control found on no surface-> exit 1, naming the control and every surface searched
A provider whose CLI is absent is reported as NOT CHECKED and does not satisfy anything.
"""
import json
import shutil
import subprocess
import sys

EXECUTABLE = {"gpt": "codex", "claude": "claude"}
HELP_TIMEOUT = 30


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
        surfaces = [list(surface) for surface in entry["help_surfaces"]]
        labels = [" ".join([EXECUTABLE[name]] + surface) for surface in surfaces]
        texts = []
        for surface, label in zip(surfaces, labels):
            try:
                probe = subprocess.run([executable] + surface, capture_output=True, text=True,
                                       timeout=HELP_TIMEOUT)
            except (OSError, subprocess.SubprocessError) as exc:
                problems.append(f"{name}: declared help surface `{label}` could not run: {exc}")
                texts.append("")
                continue
            if probe.returncode != 0:
                problems.append(
                    f"{name}: declared help surface `{label}` exited {probe.returncode} — a probe "
                    f"that cannot run is not a provider that lacks a capability")
            texts.append((probe.stdout or "") + (probe.stderr or ""))
        print(f"  {name}: searched {len(labels)} surface(s): " + ", ".join(f"`{x}`" for x in labels))
        for flag in entry["required_flags"]:
            found = [label for label, text in zip(labels, texts) if flag in text]
            print(f"    {flag:26} {'found in ' + ', '.join(found) if found else 'NOT FOUND'}")
            if not found:
                problems.append(
                    f"{name}: required control {flag} appears in none of the declared help "
                    f"surfaces ({', '.join(labels)}) of {executable}")

    if not checked:
        print("FAIL: no provider CLI was installed, so nothing was verified. This check reports "
              "'cannot evaluate' as a failure on purpose; a probe that silently passes when it "
              "checked nothing is the defect it exists to catch.")
        return 1
    for line in problems:
        print("FAIL: " + line)
    if problems:
        return 1
    print(f"PASS: declared help surfaces carry every required control for: {', '.join(checked)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
