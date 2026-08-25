#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

t_case "two manifests and one physical root source"
assert_ok "Claude and Codex manifests share base version" "$BIN/firm-version" --check
assert_ok "Codex manifest is tracked" git -C "$FIRM_ROOT" ls-files --error-unmatch .codex-plugin/plugin.json
assert_fail "Codex manifest is not ignored" git -C "$FIRM_ROOT" check-ignore -q .codex-plugin/plugin.json
assert_eq "only the manifest is tracked under .codex-plugin" ".codex-plugin/plugin.json" \
  "$(git -C "$FIRM_ROOT" ls-files .codex-plugin)"
assert_ok "another Codex-plugin file remains ignored" git -C "$FIRM_ROOT" check-ignore -q --no-index \
  .codex-plugin/local-cache.json
assert_ok "obsolete project Codex hooks are ignored" git -C "$FIRM_ROOT" check-ignore -q --no-index \
  .codex/hooks.json
assert_ok "timestamped Claude backups are ignored" git -C "$FIRM_ROOT" check-ignore -q --no-index \
  .claude/settings.json.20990101T000000Z.bak
assert_ok "Codex marketplace resolves to repository root" python3 -c "
import json
d=json.load(open('$FIRM_ROOT/.agents/plugins/marketplace.json'))
p=d['plugins'][0]
assert d['name']=='agent-firm-local'
assert p['source']=={'source':'local','path':'./'}
assert p['policy']=={'installation':'AVAILABLE','authentication':'ON_INSTALL'}
assert p['category']=='Productivity'
"
assert_ok "Codex exposes only its skill adapter" python3 -c "
import json
d=json.load(open('$FIRM_ROOT/.codex-plugin/plugin.json'))
assert d['skills']=='./codex-skills/'
assert 'hooks' not in d
"
assert_ok "Claude selects only its hook adapter" python3 -c "
import json
d=json.load(open('$FIRM_ROOT/.claude-plugin/plugin.json'))
assert d['hooks']=='./hooks/claude.json'
assert 'skills' not in d
"

t_case "provider hook manifests share binaries but not events"
assert_ok "Codex default hooks use Bash, guard exit path, and PermissionRequest notify" python3 -c "
import json
d=json.load(open('$FIRM_ROOT/hooks/hooks.json'))['hooks']
assert [x['matcher'] for x in d['PreToolUse']]==['Bash']
cmds=[x['command'] for x in d['PreToolUse'][0]['hooks']]
assert 'firm-ledger-hook' in cmds[0] and 'firm-merge-guard' in cmds[1]
assert 'PermissionRequest' in d and 'Notification' not in d
assert 'firm-notify' in d['PermissionRequest'][0]['hooks'][0]['command']
"
assert_ok "Claude hooks retain Notification" python3 -c "
import json
d=json.load(open('$FIRM_ROOT/hooks/claude.json'))['hooks']
assert 'Notification' in d and 'PermissionRequest' not in d
"
assert_rc "notify-only permission side channel always succeeds" 0 sh -c "printf '{\"message\":\"permission needed\"}' | FIRM_NOTIFY_ADAPTER=none '$BIN/firm-notify'"

t_case "intended inventory is tracked with executable closure"
for path in \
  .agents/plugins/marketplace.json .codex-plugin/plugin.json VERSION agent-firm/contracts/lifecycle.md \
  agent-firm/contracts/roles/architect.md agent-firm/contracts/roles/implementer.md \
  agent-firm/contracts/roles/intake-analyst.md agent-firm/contracts/roles/integrator.md \
  agent-firm/contracts/roles/packager.md agent-firm/contracts/roles/qa-tester.md \
  agent-firm/contracts/roles/recruiter.md agent-firm/contracts/roles/reviewer.md \
  agent-firm/contracts/roles/scout.md agent-firm/contracts/roles/specialist.md \
  bin/firm-claude-qa bin/firm-final-qa-check bin/firm-python bin/firm-reviewer-common bin/firm-version \
  codex-skills/start/SKILL.md hooks/claude.json tests/test-bootstrap-dual.sh \
  tests/test-final-qa-check.sh tests/test-model-tiers.sh tests/test-plugin-layout.sh \
  tests/test-provider-reviewers.sh; do
  assert_ok "tracked intended input: $path" git -C "$FIRM_ROOT" ls-files --error-unmatch "$path"
done
for path in bin/firm-claude-qa bin/firm-final-qa-check bin/firm-python bin/firm-version \
  tests/test-bootstrap-dual.sh tests/test-final-qa-check.sh tests/test-model-tiers.sh \
  tests/test-plugin-layout.sh tests/test-provider-reviewers.sh; do
  assert_output "executable Git mode: $path" "100755" sh -c \
    "git -C '$FIRM_ROOT' ls-files -s '$path' | cut -d' ' -f1"
done
assert_output "shared reviewer engine has executable Git mode" "100755" sh -c \
  "git -C '$FIRM_ROOT' ls-files -s bin/firm-reviewer-common | cut -d' ' -f1"

t_case "isolated candidate resolves and excludes local state"
CANDIDATE="$(mktemp -d "${TMPDIR:-/tmp}/firm-package.XXXXXX")"; t_track "$CANDIDATE"
assert_ok "construct candidate from the exact Git inventory" python3 - "$FIRM_ROOT" "$CANDIDATE" <<'PY'
import os, shutil, subprocess, sys
root, dst = sys.argv[1:]
paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
for rel in paths:
    if not rel:
        continue
    src = os.path.join(root, rel)
    if not os.path.lexists(src):  # tracked deletion in the candidate
        continue
    target = os.path.join(dst, rel)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if os.path.islink(src):
        os.symlink(os.readlink(src), target)
    else:
        shutil.copy2(src, target)
PY
assert_file "candidate contains Codex manifest" "$CANDIDATE/.codex-plugin/plugin.json"
assert_ok "candidate manifests resolve without dirty-tree inputs" "$CANDIDATE/bin/firm-version" --check
assert_no_file "candidate excludes Git metadata" "$CANDIDATE/.git"
assert_no_file "candidate excludes run evidence" "$CANDIDATE/.agent-firm"
assert_no_file "candidate excludes obsolete project Codex hooks" "$CANDIDATE/.codex/hooks.json"
assert_no_file "candidate excludes timestamped settings backup" "$CANDIDATE/.claude/settings.json.20260807T163208Z.bak"
assert_eq "candidate contains no auth cache" "" "$(find "$CANDIDATE" -name auth.json -print)"

t_case "obsolete Codex hook prototype is diagnosed without mutation"
HOOK_PROJECT="$(mktemp -d "${TMPDIR:-/tmp}/firm-hook-project.XXXXXX")"; t_track "$HOOK_PROJECT"
mkdir -p "$HOOK_PROJECT/.codex" "$HOOK_PROJECT/home" "$HOOK_PROJECT/provider-stubs"
printf '{"hooks":{"PreToolUse":[{"command":"firm-ledger-hook"}]}}\n' > "$HOOK_PROJECT/.codex/hooks.json"
cat > "$HOOK_PROJECT/provider-stubs/claude" <<'SH'
#!/bin/sh
printf 'claude' >> "$FIRM_TEST_PROVIDER_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >> "$FIRM_TEST_PROVIDER_LOG"; done
printf '\n' >> "$FIRM_TEST_PROVIDER_LOG"
exit 0
SH
cat > "$HOOK_PROJECT/provider-stubs/codex" <<'SH'
#!/bin/sh
printf 'codex' >> "$FIRM_TEST_PROVIDER_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >> "$FIRM_TEST_PROVIDER_LOG"; done
printf '\n' >> "$FIRM_TEST_PROVIDER_LOG"
exit 0
SH
chmod +x "$HOOK_PROJECT/provider-stubs/claude" "$HOOK_PROJECT/provider-stubs/codex"
provider_log="$HOOK_PROJECT/provider.log"
: > "$provider_log"
# Build this fixture from the interpreter the FIRM resolves (bin/firm-python), not from PATH's
# python3. firm-doctor probes its own resolved interpreter, so a PYTHONPATH computed from a different
# one hands it site-packages built for the wrong version -- the fixture would then manufacture the
# very "installed package fails to import" failure this suite is not trying to test.
python_exe="$("$BIN/firm-python" -c 'import sys; print(sys.executable)')"
hook_pythonpath="$("$BIN/firm-python" -c 'import jsonschema,os,yaml; print(":".join(sorted({os.path.dirname(os.path.dirname(jsonschema.__file__)),os.path.dirname(os.path.dirname(yaml.__file__))})))')"
ln -s "$python_exe" "$HOOK_PROJECT/provider-stubs/python3"
hook_before="$(shasum -a 256 "$HOOK_PROJECT/.codex/hooks.json" | cut -d' ' -f1)"
hook_mode="$(t_file_mode "$HOOK_PROJECT/.codex/hooks.json")"
doctor_out="$(cd "$HOOK_PROJECT" && HOME="$HOOK_PROJECT/home" PYTHONPATH="$hook_pythonpath" \
  FIRM_TEST_PROVIDER_LOG="$provider_log" PATH="$HOOK_PROJECT/provider-stubs:/usr/bin:/bin" \
  "$BIN/firm-doctor" 2>&1)"; doctor_rc=$?
assert_output "doctor bounds static hook ownership to declarations and defers runtime selection" \
  "repository manifests declare one plugin-owned ledger/merge-guard hook adapter per runtime; runtime loader selection is unverified until Q-02" \
  printf '%s\n' "$doctor_out"
assert_output "doctor gives a human-reviewed removal action" \
  "remove that file manually only after confirming it contains no project-specific hooks" printf '%s\n' "$doctor_out"
assert_eq "doctor does not rewrite the prototype" "$hook_before" \
  "$(shasum -a 256 "$HOOK_PROJECT/.codex/hooks.json" | cut -d' ' -f1)"
assert_eq "doctor preserves prototype mode" "$hook_mode" \
  "$(t_file_mode "$HOOK_PROJECT/.codex/hooks.json")"
assert_eq "confirmed Codex duplicate blocks readiness" "1" "$doctor_rc"
rm -f "$HOOK_PROJECT/.codex/hooks.json"
doctor_clean_out="$(cd "$HOOK_PROJECT" && HOME="$HOOK_PROJECT/home" PYTHONPATH="$hook_pythonpath" \
  FIRM_TEST_PROVIDER_LOG="$provider_log" PATH="$HOOK_PROJECT/provider-stubs:/usr/bin:/bin" \
  "$BIN/firm-doctor" 2>&1)"; doctor_clean_rc=$?
assert_eq "readiness returns after the duplicate-only prototype is removed" "0" "$doctor_clean_rc"

t_case "doctor binds both provider probes to the canonical reviewer envelope"
: > "$provider_log"
doctor_probe_out="$(cd "$HOOK_PROJECT" && HOME="$HOOK_PROJECT/home" PYTHONPATH="$hook_pythonpath" \
  FIRM_TEST_PROVIDER_LOG="$provider_log" PATH="$HOOK_PROJECT/provider-stubs:/usr/bin:/bin" \
  "$BIN/firm-doctor" --probe 2>&1)"; doctor_probe_rc=$?
assert_eq "canonical disposable provider probes pass" "0" "$doctor_probe_rc"
assert_output "doctor reports both canonical reviewer displays, models, and xhigh effort" \
  "canonical reviewer models: GPT=GPT-5.6 sol (gpt-5.6-sol, xhigh) · Claude=Opus 5 (opus, xhigh)" \
  printf '%s\n' "$doctor_probe_out"
assert_ok "Claude and Codex receive their exact full native reviewer envelopes" python3 - "$provider_log" <<'PY'
import pathlib, sys
calls=[line.split("\t") for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert calls == [
    ["claude", "auth", "status"],
    ["claude", "-p", "Reply with exactly: ok", "--model", "opus", "--effort", "xhigh",
     "--output-format", "text", "--permission-mode", "dontAsk", "--tools", "", "--no-session-persistence"],
    ["codex", "login", "status"],
    # `-a never` is NOT here, in EITHER position, and the assertion below pins that.
    #
    # This expectation used to read
    #   ["codex","exec","--skip-git-repo-check","--ephemeral","-s","read-only","-a","never",...]
    # which is the 2026-08-23 defect written down as a passing test: `codex exec` rejects `-a`
    # outright ("unexpected argument '-a' found", rc 2), so firm-doctor --probe could never have
    # completed a Codex reviewer probe on any real host. The stub accepted it, so the test agreed
    # with the stub and nothing else. That much is settled.
    #
    # The tempting repair -- move `-a never` in FRONT of `exec` -- was measured and rejected. On
    # codex-cli 0.147.0 `codex -a never exec --help` does exit 0, but only because the root options
    # are DISCARDED once a subcommand appears; `codex --help` says so ("If no subcommand is
    # specified, options will be forwarded to the interactive CLI") and the control experiment
    # proves it, since clap does not even validate them: `codex --sandbox bogus --help` is rc 2
    # "invalid value", while `codex -s bogus exec --help` is rc 0. So that form buys a clean exit
    # status and no approval policy at all -- a probe that looks fixed and is not.
    #
    # `codex exec --help` documents no --ask-for-approval in any spelling, so the never-ask policy
    # is stated as the typed -c override exec does accept, which is what the real judge sends too.
    # tests/test-provider-launch-sites.sh checks this argv against `codex exec --help` itself,
    # which is the check that does not depend on a stub.
    ["codex", "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
     "-m", "gpt-5.6-sol", "-c", 'model_reasoning_effort="xhigh"',
     "-c", 'approval_policy="never"', "Reply with exactly: ok"],
], calls
assert not any("-a" in call for call in calls), calls
PY

for mismatch in claude codex; do
  : > "$provider_log"
  if [ "$mismatch" = claude ]; then
    mismatch_out="$(cd "$HOOK_PROJECT" && HOME="$HOOK_PROJECT/home" PYTHONPATH="$hook_pythonpath" \
      FIRM_CLAUDE_QA_MODEL=not-the-canonical-model FIRM_TEST_PROVIDER_LOG="$provider_log" \
      PATH="$HOOK_PROJECT/provider-stubs:/usr/bin:/bin" "$BIN/firm-doctor" --probe 2>&1)"; mismatch_rc=$?
    mismatch_name="Claude"
  else
    mismatch_out="$(cd "$HOOK_PROJECT" && HOME="$HOOK_PROJECT/home" PYTHONPATH="$hook_pythonpath" \
      FIRM_GPT_QA_MODEL=not-the-canonical-model FIRM_TEST_PROVIDER_LOG="$provider_log" \
      PATH="$HOOK_PROJECT/provider-stubs:/usr/bin:/bin" "$BIN/firm-doctor" --probe 2>&1)"; mismatch_rc=$?
    mismatch_name="Codex"
  fi
  assert_eq "$mismatch_name compatibility override mismatch blocks doctor" "1" "$mismatch_rc"
  assert_output "$mismatch_name mismatch identifies the canonical-envelope block" \
    "canonical $mismatch_name reviewer envelope" printf '%s\n' "$mismatch_out"
  assert_eq "$mismatch_name mismatch occurs before any provider fixture" "" "$(cat "$provider_log")"
done

cat > "$HOOK_PROJECT/check-doctor-envelope.py" <<'PY'
import pathlib, sys
text=pathlib.Path(sys.argv[1]).read_text()
required={
 "claude.provider": 'resolve_reviewer_tuple claude "${FIRM_CLAUDE_QA_MODEL+x}"',
 "claude.model": '--model "$CLAUDE_REVIEW_MODEL"',
 "claude.display": 'Claude=$CLAUDE_REVIEW_DISPLAY ($CLAUDE_REVIEW_MODEL, $CLAUDE_REVIEW_EFFORT)',
 "claude.effort": '--effort "$CLAUDE_REVIEW_EFFORT"',
 "codex.provider": 'resolve_reviewer_tuple codex "${FIRM_GPT_QA_MODEL+x}"',
 "codex.model": '-m "$CODEX_REVIEW_MODEL"',
 "codex.display": 'GPT=$CODEX_REVIEW_DISPLAY ($CODEX_REVIEW_MODEL, $CODEX_REVIEW_EFFORT)',
 "codex.effort": '-c "model_reasoning_effort=\\"$CODEX_REVIEW_EFFORT\\""',
}
bad=[name for name, needle in required.items() if text.count(needle) != 1]
if bad:
    raise SystemExit("invalid doctor reviewer envelope fields: " + ", ".join(bad))
PY
assert_ok "doctor source carries each provider/model/display/effort binding exactly once" \
  python3 "$HOOK_PROJECT/check-doctor-envelope.py" "$BIN/firm-doctor"
assert_ok "independent mutations kill every reviewer-envelope field for both providers" \
  python3 - "$BIN/firm-doctor" "$HOOK_PROJECT/check-doctor-envelope.py" "$HOOK_PROJECT" <<'PY'
import pathlib, subprocess, sys
source, checker, target_dir = map(pathlib.Path, sys.argv[1:])
text=source.read_text()
mutations={
 "claude.provider": ('resolve_reviewer_tuple claude "${FIRM_CLAUDE_QA_MODEL+x}"',
                     'resolve_reviewer_tuple codex "${FIRM_CLAUDE_QA_MODEL+x}"'),
 "claude.model": ('--model "$CLAUDE_REVIEW_MODEL"', '--model "mutant-claude-model"'),
 "claude.display": ('Claude=$CLAUDE_REVIEW_DISPLAY ($CLAUDE_REVIEW_MODEL, $CLAUDE_REVIEW_EFFORT)',
                    'Claude=Mutant ($CLAUDE_REVIEW_MODEL, $CLAUDE_REVIEW_EFFORT)'),
 "claude.effort": ('--effort "$CLAUDE_REVIEW_EFFORT"', '--effort "high"'),
 "codex.provider": ('resolve_reviewer_tuple codex "${FIRM_GPT_QA_MODEL+x}"',
                    'resolve_reviewer_tuple claude "${FIRM_GPT_QA_MODEL+x}"'),
 "codex.model": ('-m "$CODEX_REVIEW_MODEL"', '-m "mutant-codex-model"'),
 "codex.display": ('GPT=$CODEX_REVIEW_DISPLAY ($CODEX_REVIEW_MODEL, $CODEX_REVIEW_EFFORT)',
                   'GPT=Mutant ($CODEX_REVIEW_MODEL, $CODEX_REVIEW_EFFORT)'),
 "codex.effort": ('-c "model_reasoning_effort=\\"$CODEX_REVIEW_EFFORT\\""',
                  '-c "model_reasoning_effort=\\"high\\""'),
}
for name,(old,new) in mutations.items():
    assert text.count(old)==1, (name, text.count(old))
    mutant=target_dir/f"doctor-mutant-{name}"
    mutant.write_text(text.replace(old,new,1))
    proc=subprocess.run([sys.executable, str(checker), str(mutant)], capture_output=True, text=True)
    assert proc.returncode != 0, (name, proc.stdout, proc.stderr)
PY

t_case "shared contracts are the adapter boundary"
for role in architect implementer intake-analyst integrator packager qa-tester recruiter reviewer scout specialist; do
  assert_file "shared role contract: $role" "$FIRM_ROOT/agent-firm/contracts/roles/$role.md"
  assert_output "Claude adapter loads shared $role contract" "contracts/roles/$role.md" cat "$FIRM_ROOT/agents/$role.md"
done
assert_output "Codex start uses Codex-primary run metadata" "--primary codex" cat "$FIRM_ROOT/codex-skills/start/SKILL.md"
assert_output "Claude start uses Claude-primary run metadata" "--primary claude" cat "$FIRM_ROOT/commands/start.md"

t_case "provider adapters share one resolver-bound role-start boundary"
assert_ok "adapter blocks, call sites, lifecycle, and inventory preserve provider parity" \
  t_python - "$FIRM_ROOT" <<'PY'
import copy, pathlib, re, sys, yaml

root = pathlib.Path(sys.argv[1])
sources = {"claude": root / "commands/start.md", "codex": root / "codex-skills/start/SKILL.md"}
native = {"claude": "claude_native_agent", "codex": "codex_native_subagent"}

def flat(text):
    return " ".join(text.split())

def adapter(text):
    matches = re.findall(r"^```firm-native-role-adapter\n(.*?)^```$", text, re.M | re.S)
    assert len(matches) == 1, len(matches)
    return yaml.safe_load(matches[0])

def neutral(value):
    value = copy.deepcopy(value)
    value["provider"] = "<provider>"
    value["resolver_argv"][2] = "<provider>"
    value["native_launch"] = "<provider-native-launch>"
    return value

def required_callsite(provider):
    provider_launch = "Claude native agent launch" if provider == "claude" else "Codex native subagent launch"
    return [
        f"firm-model-resolve --provider {provider} --role <role> --format activation",
        "firm-ledger-log --run <run> --strict --role-start",
        "--stage <stage-instance> --role <role> --contract <run-relative-contract>",
        "--event <expected-start-event> --authority-json <authority-json>",
        "--agent <native-agent-id> --activation-json <exact-resolver-activation-json>",
        "[--activation-justification <text>]",
        "Parse success stdout only as the closed proof-instant receipt",
        "activation.apply.model", "activation.apply.display", "activation.apply.effort",
        provider_launch,
        "retains the exact returned `event_id` from the same parsed result",
        "The producer validates and records; it does not invoke a provider",
        "perform a second model resolution",
        "Ordinary non-role milestones continue through ordinary `firm-ledger-log`",
        "Ledger writes in this release are supported only on a closed allowlist of proven P2 rows: macOS 26.5.1 with Darwin 25.5.0, or macOS 26.6.1 with Darwin 25.6.0, each on arm64, local APFS, and CPython 3.9.6",
        "A row is matched whole and exactly; the allowlist is never a floor, range, prefix or wildcard",
        "Linux and every other mismatched or unverifiable environment are unsupported and fail closed without a success result; ordinary best-effort mode is not a fallback",
    ]

blocks = {}
for provider, path in sources.items():
    text = path.read_text()
    flattened = flat(text)
    for phrase in required_callsite(provider):
        assert flat(phrase) in flattened, (provider, phrase)
    blocks[provider] = adapter(text)
    assert blocks[provider]["provider"] == provider
    assert blocks[provider]["resolver_argv"][2] == provider
    assert blocks[provider]["native_launch"] == native[provider]

assert neutral(blocks["claude"]) == neutral(blocks["codex"]), blocks

lifecycle = flat((root / "agent-firm/contracts/lifecycle.md").read_text())
for phrase in (
    "firm-ledger-log --run <run> --strict --role-start",
    "--agent <native-agent-id> --activation-json <exact-resolver-activation-json>",
    "All contextual identity is explicit",
    "applies its exact `activation.apply.model`",
    "retains its exact `event_id` for downstream start, stop, block, and completion records",
    "The producer validates and records; it does not invoke or simulate either provider",
    "`firm-model-resolve` remains the sole role-to-tier/model authority",
    "Record ordinary non-role milestones through ordinary `firm-ledger-log`",
    "Ledger writes in this release are supported only on a closed allowlist of proven P2 rows: macOS 26.5.1 with Darwin 25.5.0, or macOS 26.6.1 with Darwin 25.6.0, each on arm64, local APFS, and CPython 3.9.6",
    "A row is matched whole and exactly; the allowlist is never a floor, range, prefix or wildcard",
    "Linux and every other mismatched or unverifiable environment are unsupported and fail closed without a success result; ordinary best-effort mode is not a fallback",
):
    assert flat(phrase) in lifecycle, phrase

readme = flat((root / "README.md").read_text())
for phrase in (
    "single canonical `firm-ledger-log --run <run> --strict --role-start` producer",
    "does not invoke a provider",
    "retains the same returned `event_id`",
    "a second model resolution are not valid paths",
    "Ordinary non-role milestones continue through ordinary `firm-ledger-log`",
    "Ledger writes in this release are supported only on a closed allowlist of proven P2 rows: macOS 26.5.1 with Darwin 25.5.0, or macOS 26.6.1 with Darwin 25.6.0, each on arm64, local APFS, and CPython 3.9.6",
    "A row is matched whole and exactly; the allowlist is never a floor, range, prefix or wildcard",
    "Linux and every other mismatched or unverifiable environment are unsupported and fail closed without a success result; ordinary best-effort mode is not a fallback",
):
    assert flat(phrase) in readme, phrase

for path in (*sources.values(), root / "agent-firm/contracts/lifecycle.md", root / "README.md"):
    text = path.read_text()
    assert "firm-role-start" not in text, path
    assert "--print-event-id" not in text, path
    assert not re.search(r"firm-ledger-log(?:\s+--[^\s`]+(?:\s+[^\s`]+)?)*\s+[a-z0-9_]+_started\b", text), path

# The producer may run the canonical resolver, but no literal Claude/Codex executable may be a
# process-launch target. Native provider launch belongs exclusively to the Lead adapter.
producer = (root / "bin/firm-ledger-log").read_text()
launcher_forms = (
    r"\b(?:subprocess\.)?(?:run|Popen|call|check_call|check_output)\s*\(\s*[\[(]\s*['\"](?:claude|codex)['\"]",
    r"\bos\.(?:system|execl|execlp|execv|execvp)\s*\(\s*['\"](?:claude|codex)['\"]",
    r"(?m)^\s*(?:claude|codex)(?:\s|$)",
)
for pattern in launcher_forms:
    assert not re.search(pattern, producer), pattern
PY

t_case "the user-facing P2 prose names exactly the rows the writer admits"
# The four copies (README, lifecycle contract, and BOTH provider init instructions) are the only
# statement a human reads before starting a run, and they went stale the moment the allowlist grew:
# they still promised a single exact row while the writer had admitted two. Lock them to the writer
# itself rather than to a restated literal -- a second hand-maintained copy of the row set is exactly
# what drifted. The phrase assertions above keep the sentence present; this keeps it TRUE.
# t_python, not bare `python3` (SEC-07/CC-08). The three sibling blocks in this file were converted
# in the same commit that added this one and this one was missed. It reads bin/firm-ledger-log, which
# is the firm's own source, so it must be read by the interpreter the firm runs -- and on a host with
# no PATH python3 but a resolvable firm interpreter (the shape tests/test-python-interpreter.sh
# exists to protect) the bare form makes this file go red for a reason unrelated to what it tests.
assert_ok "prose rows are read from SUPPORTED_P2_OS_ROWS and the four copies stay identical" \
  t_python - "$FIRM_ROOT" <<'PY'
import ast, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
source = (root / "bin/firm-ledger-log").read_text()
match = re.search(r"^SUPPORTED_P2_OS_ROWS = frozenset\((\{.*?\})\)", source, re.M | re.S)
if match is None:
    raise SystemExit("cannot read SUPPORTED_P2_OS_ROWS from the production writer")
rows = ast.literal_eval(match.group(1))

copies = [
    root / "README.md",
    root / "agent-firm/contracts/lifecycle.md",
    root / "commands/start.md",
    root / "codex-skills/start/SKILL.md",
]
paragraph = re.compile(
    r"Ledger writes in this release are supported only on a closed allowlist of proven P2 rows:"
    r".*?proving evidence\.",
    re.S,
)
seen = {}
for path in copies:
    text = path.read_text()
    found = paragraph.findall(text)
    assert len(found) == 1, (path, len(found))
    flat = " ".join(found[0].split())
    # Every proven row is named, and NO row is named that the writer does not admit.
    listed = set(re.findall(r"macOS (\S+?) with Darwin ([0-9][^,\s]*)", flat))
    assert listed == set(rows), (path, sorted(listed), sorted(rows))
    # BYTE-IDENTICAL MEANS BYTE-IDENTICAL (CC-07). This keyed the comparison on `flat`, the
    # whitespace-NORMALISED text, while the comment and the assertion both said "byte-identical" --
    # so reflowing one copy onto a single physical line left the check passing and the stated
    # invariant false. Reproduced against scratch copies. `flat` is kept for the row extraction
    # above, where normalisation is what makes the regex robust across line wrapping; the identity
    # of the four copies is judged on the raw paragraph. The claim and the assertion now match, and
    # the stronger of the two was chosen: these four are generated-by-hand duplicates of one
    # sentence, a prose linter or an editor reflowing one of them is precisely the drift worth
    # catching, and the cost of the stricter rule is that a deliberate rewrap must touch all four.
    seen.setdefault(found[0], []).append(path.name)
assert len(seen) == 1, {text[:40]: names for text, names in seen.items()}
PY

assert_ok "independent mutations kill both provider call patterns" python3 - "$FIRM_ROOT" <<'PY'
import pathlib, sys

root = pathlib.Path(sys.argv[1])
sources = {"claude": root / "commands/start.md", "codex": root / "codex-skills/start/SKILL.md"}

def flat(text):
    return " ".join(text.split())

def required(provider):
    native = "Claude native agent launch" if provider == "claude" else "Codex native subagent launch"
    return [
        f"firm-model-resolve --provider {provider} --role <role> --format activation",
        "firm-ledger-log --run <run> --strict --role-start",
        "--stage <stage-instance> --role <role> --contract <run-relative-contract>",
        "--event <expected-start-event> --authority-json <authority-json>",
        "--agent <native-agent-id> --activation-json <exact-resolver-activation-json>",
        "Parse success stdout only as the closed proof-instant receipt",
        "activation.apply.model", "activation.apply.display", "activation.apply.effort",
        native,
        "retains the exact returned `event_id` from the same parsed result",
        "The producer validates and records; it does not invoke a provider",
        "perform a second model resolution",
        "Ordinary non-role milestones continue through ordinary `firm-ledger-log`",
        "Ledger writes in this release are supported only on a closed allowlist of proven P2 rows: macOS 26.5.1 with Darwin 25.5.0, or macOS 26.6.1 with Darwin 25.6.0, each on arm64, local APFS, and CPython 3.9.6",
        "A row is matched whole and exactly; the allowlist is never a floor, range, prefix or wildcard",
        "Linux and every other mismatched or unverifiable environment are unsupported and fail closed without a success result; ordinary best-effort mode is not a fallback",
    ]

for provider, path in sources.items():
    baseline = flat(path.read_text().split("```firm-native-role-adapter", 1)[0])
    phrases = required(provider)
    for phrase in phrases:
        needle = flat(phrase)
        assert needle in baseline, (provider, phrase)
        mutant = baseline.replace(needle, "MUTATED", 1)
        missing = [candidate for candidate in phrases if flat(candidate) not in mutant]
        assert phrase in missing, (provider, phrase, missing)
PY

t_case "Packager compatibility and reviewer raw-retention docs match the lifecycle contract"
assert_ok "pre-index fallback remains bounded and persistent raw retention stays unsupported" python3 - "$FIRM_ROOT" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
flat=lambda value:' '.join(value.split())
packager=flat((root/'agent-firm/contracts/roles/packager.md').read_text())
for phrase in (
    'once indexed state exists',
    'pre-index runs with no `integration-summaries/index.json`',
    'from their legacy `integration-summary.md`',
    'a missing legacy summary blocks packaging',
):
    assert phrase in packager, phrase
for rel in ('docs/PHASE3.md','docs/ENFORCEMENT.md'):
    body=flat((root/rel).read_text())
    for phrase in (
        'Persistent raw retention is unsupported',
        'every nonzero `--retain-raw-seconds` request is rejected before provider execution',
        '.agent-firm/private-reviewer-control/',
    ):
        assert phrase in body,(rel,phrase)
    for forbidden in ('.agent-firm/private-reviewer-raw/','raw retention is opt-in','purges expired records'):
        assert forbidden not in body,(rel,forbidden)
PY

t_case "current docs reject readiness, recovery, duplicate, loader, and Final-handoff contradictions"
assert_ok "reference and historical docs preserve one candidate-readiness story" python3 - "$FIRM_ROOT" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1])
paths=[root/'README.md',*(root/'docs'/name for name in (
 'README.md','ENFORCEMENT.md','INSTALL.md','INTERACTIVE-TEST.md','PHASE3.md','PHASE4.md','PHASE5.md','WIRING.md'))]
text='\n'.join(p.read_text() for p in paths); low=text.lower()
for forbidden in (
    'phase 6 / 0.8.0 (done)',
    'two `gh` round trips',
    'firm-doctor warns about legacy',
    'exits 0 before handoff',
    'duplicates are detection-only',
    'continue to the final gate with a warning',
    'verified compensation, not atomicity',
    'the supported plugin selection has one hook source per runtime',
    'exactly one plugin hook source serves each runtime',
):
    assert forbidden not in low, forbidden
required={
 'README.md':['historical implementation milestones','blocked/unproved','blocked_recovery_required'],
 'docs/INSTALL.md':['unavailable_reverses','non-ship-ready draft','one fresh check'],
 'docs/ENFORCEMENT.md':['confirmed duplicate within the bounded modeled scopes',
                        'runtime loader selection and the supported external source set remain unverified until q-02',
                        'fixture counts do not prove real provider loader selection'],
 'docs/INTERACTIVE-TEST.md':['one final interaction, then one fresh check','blocked_recovery_required'],
 'docs/WIRING.md':['non-ship-ready draft','no proven exact inverse'],
}
for rel,phrases in required.items():
    body=(root/rel).read_text().lower()
    for phrase in phrases: assert phrase in body,(rel,phrase)
for name in ('PHASE3.md','PHASE4.md','PHASE5.md'):
    assert 'historical implementation here is not evidence' in (root/'docs'/name).read_text().lower(),name
phase4=' '.join((root/'docs/PHASE4.md').read_text().lower().split())
for phrase in ('repository manifests declare exactly one plugin hook adapter per runtime',
               'runtime loader selection and supported external scopes are unverified until q-02',
               'claude plugin+project+user produces three event pairs',
               'codex plugin+obsolete-project produces two'):
    assert phrase in phase4, phrase
PY

t_summary
