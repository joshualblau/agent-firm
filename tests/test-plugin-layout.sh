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
  bin/firm-claude-qa bin/firm-final-qa-check bin/firm-reviewer-common bin/firm-version \
  codex-skills/start/SKILL.md hooks/claude.json tests/test-bootstrap-dual.sh \
  tests/test-final-qa-check.sh tests/test-model-tiers.sh tests/test-plugin-layout.sh \
  tests/test-provider-reviewers.sh; do
  assert_ok "tracked intended input: $path" git -C "$FIRM_ROOT" ls-files --error-unmatch "$path"
done
for path in bin/firm-claude-qa bin/firm-final-qa-check bin/firm-version \
  tests/test-bootstrap-dual.sh tests/test-final-qa-check.sh tests/test-model-tiers.sh \
  tests/test-plugin-layout.sh tests/test-provider-reviewers.sh; do
  assert_output "executable Git mode: $path" "100755" sh -c \
    "git -C '$FIRM_ROOT' ls-files -s '$path' | cut -d' ' -f1"
done
assert_output "sourced reviewer library keeps non-executable mode" "100644" sh -c \
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
printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] && exit 0\nexit 0\n' > "$HOOK_PROJECT/provider-stubs/claude"
printf '#!/bin/sh\n[ "$1 $2" = "login status" ] && exit 0\nexit 0\n' > "$HOOK_PROJECT/provider-stubs/codex"
chmod +x "$HOOK_PROJECT/provider-stubs/claude" "$HOOK_PROJECT/provider-stubs/codex"
hook_before="$(shasum -a 256 "$HOOK_PROJECT/.codex/hooks.json" | cut -d' ' -f1)"
doctor_out="$(cd "$HOOK_PROJECT" && HOME="$HOOK_PROJECT/home" \
  PATH="$HOOK_PROJECT/provider-stubs:/usr/bin:/bin" "$BIN/firm-doctor" 2>&1)"; doctor_rc=$?
assert_output "doctor gives a human-reviewed removal action" \
  "remove that file manually after confirming it contains no project-specific hooks" printf '%s\n' "$doctor_out"
assert_eq "doctor does not rewrite the prototype" "$hook_before" \
  "$(shasum -a 256 "$HOOK_PROJECT/.codex/hooks.json" | cut -d' ' -f1)"
assert_ok "doctor result is not treated as proof of package readiness" sh -c "[ '$doctor_rc' -ne 0 ]"

t_case "shared contracts are the adapter boundary"
for role in architect implementer intake-analyst integrator packager qa-tester recruiter reviewer scout specialist; do
  assert_file "shared role contract: $role" "$FIRM_ROOT/agent-firm/contracts/roles/$role.md"
  assert_output "Claude adapter loads shared $role contract" "contracts/roles/$role.md" cat "$FIRM_ROOT/agents/$role.md"
done
assert_output "Codex start uses Codex-primary run metadata" "--primary codex" cat "$FIRM_ROOT/codex-skills/start/SKILL.md"
assert_output "Claude start uses Claude-primary run metadata" "--primary claude" cat "$FIRM_ROOT/commands/start.md"

t_summary
