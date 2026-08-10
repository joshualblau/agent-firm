#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOT="$BIN/firm-bootstrap"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-bootstrap-test.XXXXXX")"; t_track "$WORK"
STUB="$WORK/stub"; STATE="$WORK/state"; RECOVERY="$WORK/recovery"; LOG="$WORK/calls.log"
mkdir -p "$STUB" "$STATE" "$RECOVERY"

cat > "$STUB/provider-fixture" <<'SH'
#!/bin/sh
provider="$(basename "$0")"
key="$provider:$*"
printf '%s %s\n' "$provider" "$*" >> "$STUB_LOG"

if [ "${STUB_HANG:-}" = "$key" ]; then sleep 5; fi
if [ "${STUB_FAIL_LIST:-}" = "$key" ]; then exit 8; fi

if [ "$1" = "--version" ]; then echo "$provider fixture 1.0.0"; exit 0; fi
if [ "$1 $2" = "plugin --help" ]; then
  if [ "$provider" = claude ]; then words="marketplace list install update uninstall"; else words="marketplace list add remove"; fi
  for word in $words; do
    [ "${STUB_OMIT_TOKEN:-}" = "$provider:plugin-help:$word" ] || printf '%s\n' "$word"
  done
  exit 0
fi
if [ "$1 $2 $3" = "plugin marketplace --help" ]; then
  for word in list add remove; do
    [ "${STUB_OMIT_TOKEN:-}" = "$provider:marketplace-help:$word" ] || printf '%s\n' "$word"
  done
  exit 0
fi

market="$STUB_STATE/$provider-market"
plugin="$STUB_STATE/$provider-plugin"
if [ "$1 $2 $3" = "plugin marketplace list" ]; then [ -f "$market" ] && cat "$market"; exit 0; fi
if [ "$1 $2" = "plugin list" ]; then [ -f "$plugin" ] && cat "$plugin"; exit 0; fi

action=""
case "$provider:$1:$2:$3" in
  claude:plugin:marketplace:add) action="claude:marketplace-add" ;;
  claude:plugin:marketplace:remove) action="claude:marketplace-remove" ;;
  claude:plugin:install:*) action="claude:plugin-install" ;;
  claude:plugin:update:*) action="claude:plugin-update" ;;
  claude:plugin:uninstall:*) action="claude:plugin-uninstall" ;;
  codex:plugin:marketplace:add) action="codex:marketplace-add" ;;
  codex:plugin:marketplace:remove) action="codex:marketplace-remove" ;;
  codex:plugin:add:*) action="codex:plugin-add" ;;
  codex:plugin:remove:*) action="codex:plugin-remove" ;;
esac
[ -n "$action" ] || exit 64

if [ "${STUB_FAIL_COMPENSATION:-}" = "$action" ]; then exit 12; fi

case "$action" in
  claude:marketplace-add) printf '%s marketplace=local\n' "$STUB_ROOT" > "$market" ;;
  claude:marketplace-remove) rm -f "$market" ;;
  claude:plugin-install) printf 'agent-firm@local version=%s\n' "$STUB_CLAUDE_VERSION" > "$plugin" ;;
  claude:plugin-uninstall) rm -f "$plugin" ;;
  claude:plugin-update)
    if [ -f "$STUB_STATE/failed-claude-plugin-update" ] || \
       { [ -n "${STUB_FAIL_ACTION:-}" ] && [ "$(cat "$plugin" 2>/dev/null)" = "agent-firm@local version=$STUB_CLAUDE_VERSION" ]; }; then
      printf '%s\n' "${STUB_PRIOR_CLAUDE_PLUGIN:-agent-firm@local version=old}" > "$plugin"
    else
      printf 'agent-firm@local version=%s\n' "$STUB_CLAUDE_VERSION" > "$plugin"
    fi
    ;;
  codex:marketplace-add) printf 'marketplace=agent-firm-local path=%s\n' "$STUB_ROOT" > "$market" ;;
  codex:marketplace-remove) rm -f "$market" ;;
  codex:plugin-add)
    if [ -f "$STUB_STATE/failed-codex-plugin-add" ] || \
       { [ -n "${STUB_FAIL_ACTION:-}" ] && [ "$(cat "$plugin" 2>/dev/null)" = "agent-firm@agent-firm-local version=$STUB_CODEX_VERSION" ]; }; then
      printf '%s\n' "${STUB_PRIOR_CODEX_PLUGIN:-agent-firm@agent-firm-local version=old}" > "$plugin"
    else
      printf 'agent-firm@agent-firm-local version=%s\n' "$STUB_CODEX_VERSION" > "$plugin"
    fi
    ;;
  codex:plugin-remove) rm -f "$plugin" ;;
esac

if [ "${STUB_FAIL_ACTION:-}" = "$action" ] && [ ! -f "$STUB_STATE/failed-${action%%:*}-${action#*:}" ]; then
  : > "$STUB_STATE/failed-${action%%:*}-${action#*:}"
  exit 9
fi
exit 0
SH
chmod +x "$STUB/provider-fixture"
ln -s provider-fixture "$STUB/claude"; ln -s provider-fixture "$STUB/codex"

CLAUDE_VERSION="$(python3 -c 'import json; print(json.load(open("'$FIRM_ROOT'/.claude-plugin/plugin.json"))["version"])')"
CODEX_VERSION="$(python3 -c 'import json; print(json.load(open("'$FIRM_ROOT'/.codex-plugin/plugin.json"))["version"])')"

run_boot() {
  env PATH="$STUB:/usr/bin:/bin" STUB_LOG="$LOG" STUB_STATE="$STATE" STUB_ROOT="$FIRM_ROOT" \
    STUB_CLAUDE_VERSION="$CLAUDE_VERSION" STUB_CODEX_VERSION="$CODEX_VERSION" \
    STUB_FAIL_ACTION="${STUB_FAIL_ACTION:-}" STUB_FAIL_COMPENSATION="${STUB_FAIL_COMPENSATION:-}" \
    STUB_FAIL_LIST="${STUB_FAIL_LIST:-}" STUB_OMIT_TOKEN="${STUB_OMIT_TOKEN:-}" STUB_HANG="${STUB_HANG:-}" \
    FIRM_BOOTSTRAP_TIMEOUT="${FIRM_BOOTSTRAP_TIMEOUT:-5}" FIRM_BOOTSTRAP_RECOVERY_DIR="$RECOVERY" \
    FIRM_SKIP_LINK=1 "$BOOT"
}

reset_fixture() { rm -f "$STATE"/* "$RECOVERY"/* "$LOG"; : > "$LOG"; }
seed_existing() {
  printf '%s marketplace=local\n' "$FIRM_ROOT" > "$STATE/claude-market"
  printf 'agent-firm@local version=old\n' > "$STATE/claude-plugin"
  printf 'marketplace=agent-firm-local path=%s\n' "$FIRM_ROOT" > "$STATE/codex-market"
  printf 'agent-firm@agent-firm-local version=old\n' > "$STATE/codex-plugin"
}
provider_mutations() { grep -E 'plugin marketplace (add|remove)|plugin (install|update|uninstall|add|remove)' "$LOG" || true; }
recovery_file() { find "$RECOVERY" -type f -name 'bootstrap-*.json' | head -1; }

t_case "both CLIs and every required capability preflight before mutation"
ONLY_CLAUDE="$WORK/only-claude"; mkdir -p "$ONLY_CLAUDE"; cp "$STUB/provider-fixture" "$ONLY_CLAUDE/claude"
reset_fixture
assert_rc "missing Codex fails before invoking Claude" 1 env PATH="$ONLY_CLAUDE:/usr/bin:/bin" \
  STUB_LOG="$LOG" STUB_STATE="$STATE" FIRM_SKIP_LINK=1 "$BOOT"
assert_eq "missing peer caused no provider call" "" "$(cat "$LOG")"
ONLY_CODEX="$WORK/only-codex"; mkdir -p "$ONLY_CODEX"; cp "$STUB/provider-fixture" "$ONLY_CODEX/codex"
reset_fixture
assert_rc "missing Claude fails before invoking Codex" 1 env PATH="$ONLY_CODEX:/usr/bin:/bin" \
  STUB_LOG="$LOG" STUB_STATE="$STATE" FIRM_SKIP_LINK=1 "$BOOT"
assert_eq "missing peer caused no provider call" "" "$(cat "$LOG")"
assert_output "help states the joint prerequisite" "Both CLIs are mandatory" "$BOOT" --help

for missing in claude:plugin-help:update claude:marketplace-help:remove codex:plugin-help:add codex:marketplace-help:remove; do
  reset_fixture; STUB_OMIT_TOKEN="$missing" assert_rc "incompatible CLI missing $missing is rejected" 1 run_boot
  assert_eq "$missing causes no mutation" "" "$(provider_mutations)"
done
reset_fixture; STUB_FAIL_LIST='codex:plugin list' assert_rc "failed Codex prior-state capture blocks" 1 run_boot
assert_eq "state-capture failure causes no mutation" "" "$(provider_mutations)"
reset_fixture; STUB_HANG='claude:--version' FIRM_BOOTSTRAP_TIMEOUT=1 assert_rc "hung capability preflight is bounded" 1 run_boot
assert_eq "bounded capability timeout causes no mutation" "" "$(provider_mutations)"

t_case "selector/schema incompatibility blocks before either CLI mutation"
BADROOT="$WORK/bad-root"; mkdir -p "$BADROOT/bin" "$BADROOT/.claude-plugin" "$BADROOT/.codex-plugin" "$BADROOT/.agents/plugins"
cp "$BOOT" "$BADROOT/bin/firm-bootstrap"; cp "$BIN/firm-bounded-exec" "$BADROOT/bin/firm-bounded-exec"
cp "$BIN/firm-version" "$BADROOT/bin/firm-version"; cp "$FIRM_ROOT/VERSION" "$BADROOT/VERSION"
cp "$FIRM_ROOT/.claude-plugin/plugin.json" "$BADROOT/.claude-plugin/plugin.json"
cp "$FIRM_ROOT/.codex-plugin/plugin.json" "$BADROOT/.codex-plugin/plugin.json"
cp "$FIRM_ROOT/.claude-plugin/marketplace.json" "$BADROOT/.claude-plugin/marketplace.json"
cp "$FIRM_ROOT/.agents/plugins/marketplace.json" "$BADROOT/.agents/plugins/marketplace.json"
python3 - "$BADROOT/.agents/plugins/marketplace.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['name']='wrong'; json.dump(d,open(p,'w'))
PY
reset_fixture
assert_rc "wrong Codex marketplace selector/schema is rejected" 1 env PATH="$STUB:/usr/bin:/bin" \
  STUB_LOG="$LOG" STUB_STATE="$STATE" STUB_ROOT="$BADROOT" STUB_CLAUDE_VERSION="$CLAUDE_VERSION" \
  STUB_CODEX_VERSION="$CODEX_VERSION" FIRM_SKIP_LINK=1 "$BADROOT/bin/firm-bootstrap"
assert_eq "schema mismatch invokes no provider mutation" "" "$(provider_mutations)"

t_case "fresh install, exact version verification, and idempotent repeat refresh"
reset_fixture
assert_ok "fresh dual-provider bootstrap succeeds" run_boot
assert_output "Claude marketplace target installed" "$FIRM_ROOT marketplace=local" cat "$STATE/claude-market"
assert_output "Claude plugin exact source version installed" "version=$CLAUDE_VERSION" cat "$STATE/claude-plugin"
assert_output "Codex marketplace target installed" "marketplace=agent-firm-local path=$FIRM_ROOT" cat "$STATE/codex-market"
assert_output "Codex plugin exact source version installed" "version=$CODEX_VERSION" cat "$STATE/codex-plugin"
assert_ok "repeat refresh succeeds against installed state" run_boot
assert_eq "repeat does not re-add either marketplace" "2" \
  "$(grep -c 'plugin marketplace add' "$LOG" | tr -d ' ')"
assert_output "repeat invokes Claude update" "claude plugin update agent-firm@local" cat "$LOG"
assert_output "repeat invokes Codex cache refresh" "codex plugin add agent-firm@agent-firm-local" cat "$LOG"

t_case "every provider mutation failure compensates to exact fresh prior state"
for point in claude:marketplace-add claude:plugin-install codex:marketplace-add codex:plugin-add; do
  reset_fixture
  STUB_FAIL_ACTION="$point" run_boot > "$WORK/last-bootstrap.out" 2>&1; boot_rc=$?
  assert_eq "$point failure blocks bootstrap with rc 1" "1" "$boot_rc"
  assert_eq "$point restores all four target entries to absent" "" "$(find "$STATE" -type f ! -name 'failed-*' -print)"
  rf="$(recovery_file)"
  if [ -n "$rf" ] && [ -f "$rf" ]; then _t_ok "$point writes a recovery record"
  else _t_no "$point writes a recovery record" "$(_t_ctx "$(cat "$WORK/last-bootstrap.out")")"; fi
  assert_ok "$point record proves exact compensation" python3 -c \
    "import json; d=json.load(open('$rf')); assert d['status']=='recovered' and d['exact_prior_state_restored'] is True"
done

t_case "failed compensation remains BLOCKED with exact recovery state"
for reverse in claude:marketplace-remove claude:plugin-uninstall codex:marketplace-remove codex:plugin-remove; do
  reset_fixture
  STUB_FAIL_ACTION=codex:plugin-add STUB_FAIL_COMPENSATION="$reverse" \
    run_boot > "$WORK/last-bootstrap.out" 2>&1; boot_rc=$?
  assert_eq "$reverse compensation failure blocks with rc 1" "1" "$boot_rc"
  rf="$(recovery_file)"
  if [ -n "$rf" ] && [ -f "$rf" ]; then _t_ok "$reverse failure retains a recovery record"
  else _t_no "$reverse failure retains a recovery record" "$(_t_ctx "$(cat "$WORK/last-bootstrap.out")")"; fi
  assert_ok "$reverse record identifies incomplete recovery and safe action" python3 -c \
    "import json; d=json.load(open('$rf')); assert d['status']=='BLOCKED_RECOVERY_REQUIRED'; assert d['exact_prior_state_restored'] is False; assert 'restore only the agent-firm' in d['safe_corrective_action']"
done

t_case "existing-state update failures compensate to captured version lines"
reset_fixture; seed_existing
before="$(cat "$STATE/claude-plugin")|$(cat "$STATE/codex-plugin")"
STUB_FAIL_ACTION=claude:plugin-update assert_rc "failed Claude update blocks" 1 run_boot
assert_eq "Claude update compensation restores both exact prior plugin states" "$before" \
  "$(cat "$STATE/claude-plugin")|$(cat "$STATE/codex-plugin")"

reset_fixture; seed_existing
before="$(cat "$STATE/claude-plugin")|$(cat "$STATE/codex-plugin")"
STUB_FAIL_ACTION=codex:plugin-add assert_rc "failed Codex refresh blocks" 1 run_boot
assert_eq "later Codex failure compensates both providers to exact prior versions" "$before" \
  "$(cat "$STATE/claude-plugin")|$(cat "$STATE/codex-plugin")"

t_case "default bootstrap preserves unrelated project configuration"
reset_fixture
PROJECT="$WORK/project"; mkdir -p "$PROJECT/.claude" "$PROJECT/.codex"
printf '{"permissions":{"allow":["Bash(project-only:*)"]},"hooks":{"custom":true}}\n' > "$PROJECT/.claude/settings.json"
printf '{"project":"codex-only"}\n' > "$PROJECT/.codex/config.json"
before_claude="$(shasum -a 256 "$PROJECT/.claude/settings.json" | cut -d' ' -f1)"
before_codex="$(shasum -a 256 "$PROJECT/.codex/config.json" | cut -d' ' -f1)"
assert_ok "bootstrap succeeds from configured disposable project" sh -c \
  "cd '$PROJECT' && PATH='$STUB:/usr/bin:/bin' STUB_LOG='$LOG' STUB_STATE='$STATE' STUB_ROOT='$FIRM_ROOT' STUB_CLAUDE_VERSION='$CLAUDE_VERSION' STUB_CODEX_VERSION='$CODEX_VERSION' FIRM_BOOTSTRAP_RECOVERY_DIR='$RECOVERY' FIRM_SKIP_LINK=1 '$BOOT'"
assert_eq "Claude project settings remain byte-identical" "$before_claude" "$(shasum -a 256 "$PROJECT/.claude/settings.json" | cut -d' ' -f1)"
assert_eq "Codex project config remains byte-identical" "$before_codex" "$(shasum -a 256 "$PROJECT/.codex/config.json" | cut -d' ' -f1)"

t_summary
