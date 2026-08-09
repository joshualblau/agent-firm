#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOT="$BIN/firm-bootstrap"
VERSION_TOOL="$BIN/firm-version"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-bootstrap.XXXXXX")"; t_track "$WORK"
STUB="$WORK/stub"; mkdir -p "$STUB"
LOG="$WORK/calls.log"

cat > "$STUB/claude" <<'SH'
#!/bin/sh
printf 'claude %s\n' "$*" >> "$STUB_LOG"
if [ "$1 $2 $3" = "plugin marketplace list" ]; then [ "${STUB_INSTALLED:-0}" = 1 ] && echo "$STUB_ROOT"; exit 0; fi
if [ "$1 $2" = "plugin list" ]; then [ "${STUB_INSTALLED:-0}" = 1 ] && echo agent-firm@local; exit 0; fi
exit 0
SH
cat > "$STUB/codex" <<'SH'
#!/bin/sh
printf 'codex %s\n' "$*" >> "$STUB_LOG"
if [ "$1 $2 $3" = "plugin marketplace list" ]; then [ "${STUB_INSTALLED:-0}" = 1 ] && echo "$STUB_ROOT"; exit 0; fi
if [ "$1 $2" = "plugin list" ]; then [ "${STUB_INSTALLED:-0}" = 1 ] && echo agent-firm@agent-firm-local; exit 0; fi
exit 0
SH
chmod +x "$STUB/claude" "$STUB/codex"

boot_env() {
  env PATH="$STUB:/usr/bin:/bin" STUB_LOG="$LOG" STUB_ROOT="$FIRM_ROOT" STUB_INSTALLED="${1:-0}" \
    FIRM_SKIP_LINK=1 "$BOOT"
}

t_case "both CLIs are preflighted before any installation"
ONLY_CLAUDE="$WORK/only-claude"; mkdir -p "$ONLY_CLAUDE"; cp "$STUB/claude" "$ONLY_CLAUDE/claude"
: > "$LOG"
assert_rc "missing Codex fails bootstrap" 1 env PATH="$ONLY_CLAUDE:/usr/bin:/bin" STUB_LOG="$LOG" STUB_ROOT="$FIRM_ROOT" FIRM_SKIP_LINK=1 "$BOOT"
assert_eq "Claude was not invoked before the joint preflight passed" "" "$(cat "$LOG")"
ONLY_CODEX="$WORK/only-codex"; mkdir -p "$ONLY_CODEX"; cp "$STUB/codex" "$ONLY_CODEX/codex"
: > "$LOG"
assert_rc "missing Claude fails bootstrap" 1 env PATH="$ONLY_CODEX:/usr/bin:/bin" STUB_LOG="$LOG" STUB_ROOT="$FIRM_ROOT" FIRM_SKIP_LINK=1 "$BOOT"
assert_eq "Codex was not invoked before the joint preflight passed" "" "$(cat "$LOG")"
assert_output "help states the joint prerequisite" "Both CLIs are mandatory" "$BOOT" --help

t_case "fresh dual install and idempotent refresh"
: > "$LOG"
assert_ok "fresh install succeeds" boot_env 0
assert_output "Claude marketplace added" "claude plugin marketplace add $FIRM_ROOT" cat "$LOG"
assert_output "Claude plugin installed" "claude plugin install agent-firm@local" cat "$LOG"
assert_output "Codex marketplace added" "codex plugin marketplace add $FIRM_ROOT" cat "$LOG"
assert_output "Codex plugin installed" "codex plugin add agent-firm@agent-firm-local" cat "$LOG"
: > "$LOG"
assert_ok "second run succeeds" boot_env 1
assert_output "Claude cache updated" "claude plugin update agent-firm@local" cat "$LOG"
assert_output "Codex cache refreshed again" "codex plugin add agent-firm@agent-firm-local" cat "$LOG"
assert_ok "configured Codex marketplace is not re-added" sh -c "! grep -q 'codex plugin marketplace add' '$LOG'"

t_case "default bootstrap preserves project configuration"
PROJECT="$WORK/project"; mkdir -p "$PROJECT/.claude" "$PROJECT/.codex"
printf '{"permissions":{"allow":["Bash(project-only:*)"]}}\n' > "$PROJECT/.claude/settings.json"
printf '{"project":"codex-only"}\n' > "$PROJECT/.codex/config.json"
before_claude="$(shasum -a 256 "$PROJECT/.claude/settings.json" | cut -d' ' -f1)"
before_codex="$(shasum -a 256 "$PROJECT/.codex/config.json" | cut -d' ' -f1)"
: > "$LOG"
assert_ok "bootstrap succeeds from a configured project" sh -c \
  "cd '$PROJECT' && PATH='$STUB:/usr/bin:/bin' STUB_LOG='$LOG' STUB_ROOT='$FIRM_ROOT' STUB_INSTALLED=0 FIRM_SKIP_LINK=1 '$BOOT'"
assert_eq "Claude project settings are byte-identical" "$before_claude" \
  "$(shasum -a 256 "$PROJECT/.claude/settings.json" | cut -d' ' -f1)"
assert_eq "Codex project config is byte-identical" "$before_codex" \
  "$(shasum -a 256 "$PROJECT/.codex/config.json" | cut -d' ' -f1)"

t_case "version helper compares base versions and refreshes both provider caches"
ROOT2="$WORK/version-root"; mkdir -p "$ROOT2/bin" "$ROOT2/.claude-plugin" "$ROOT2/.codex-plugin" "$ROOT2/.agents/plugins"
cp "$VERSION_TOOL" "$ROOT2/bin/firm-version"; cp "$BOOT" "$ROOT2/bin/firm-bootstrap"; cp "$BIN/firm-link" "$ROOT2/bin/firm-link"
cp "$FIRM_ROOT/VERSION" "$ROOT2/VERSION"; cp "$FIRM_ROOT/.claude-plugin/plugin.json" "$ROOT2/.claude-plugin/plugin.json"
cp "$FIRM_ROOT/.codex-plugin/plugin.json" "$ROOT2/.codex-plugin/plugin.json"; cp "$FIRM_ROOT/.agents/plugins/marketplace.json" "$ROOT2/.agents/plugins/marketplace.json"
assert_ok "matching release bases pass" "$ROOT2/bin/firm-version" --check
python3 - "$ROOT2/.codex-plugin/plugin.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["version"]="9.9.9"; json.dump(d, open(p,"w"))
PY
assert_fail "base-version drift fails" "$ROOT2/bin/firm-version" --check
cp "$FIRM_ROOT/.codex-plugin/plugin.json" "$ROOT2/.codex-plugin/plugin.json"
: > "$LOG"
assert_ok "local refresh updates versions and reinstalls both" env PATH="$STUB:/usr/bin:/bin" STUB_LOG="$LOG" STUB_ROOT="$ROOT2" STUB_INSTALLED=1 FIRM_SKIP_LINK=1 "$ROOT2/bin/firm-version" --local-refresh test-cache
assert_output "Claude gets provider suffix" '"version": "0.8.0+claude.test-cache"' cat "$ROOT2/.claude-plugin/plugin.json"
assert_output "Codex gets provider suffix" '"version": "0.8.0+codex.test-cache"' cat "$ROOT2/.codex-plugin/plugin.json"
assert_output "refresh invokes Claude update" "claude plugin update agent-firm@local" cat "$LOG"
assert_output "refresh invokes Codex add" "codex plugin add agent-firm@agent-firm-local" cat "$LOG"

assert_ok "release mode writes the same new base to both manifests" "$ROOT2/bin/firm-version" --release 0.8.1
assert_output "release updates canonical version" "0.8.1" cat "$ROOT2/VERSION"
assert_output "release updates Claude manifest" '"version": "0.8.1"' cat "$ROOT2/.claude-plugin/plugin.json"
assert_output "release updates Codex manifest" '"version": "0.8.1"' cat "$ROOT2/.codex-plugin/plugin.json"

t_summary
