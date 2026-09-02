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
if [ "${STUB_LIST_WARNING:-}" = "$key" ]; then printf 'provider diagnostic warning\n' >&2; fi

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
if [ "$1 $2 $3 ${4:-}" = "plugin marketplace list --json" ]; then
  if [ -f "$market" ]; then cat "$market"
  elif [ "$provider" = claude ]; then printf '[]\n'
  else printf '{"marketplaces":[]}\n'
  fi
  exit 0
fi
if [ "$1 $2 ${3:-}" = "plugin list --json" ]; then
  if [ -f "$plugin" ]; then cat "$plugin"
  elif [ "$provider" = claude ]; then printf '[]\n'
  else printf '{"installed":[],"available":[]}\n'
  fi
  exit 0
fi

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
if [ "${STUB_FAIL_BEFORE_ACTION:-}" = "$action" ]; then exit 9; fi
if [ "${STUB_NO_WRITE_ACTION:-}" = "$action" ]; then exit 0; fi

case "$action" in
  claude:marketplace-add) printf '[{"name":"local","source":"directory","path":"%s","installLocation":"%s"}]\n' "$STUB_ROOT" "$STUB_ROOT" > "$market" ;;
  claude:marketplace-remove) rm -f "$market" ;;
  claude:plugin-install) printf '[{"id":"agent-firm@local","version":"%s","scope":"user","enabled":true}]\n' "$STUB_CLAUDE_VERSION" > "$plugin" ;;
  claude:plugin-uninstall) rm -f "$plugin" ;;
  claude:plugin-update) printf '[{"id":"agent-firm@local","version":"%s","scope":"user","enabled":true}]\n' "$STUB_CLAUDE_VERSION" > "$plugin" ;;
  codex:marketplace-add) printf '{"marketplaces":[{"name":"agent-firm-local","root":"%s","marketplaceSource":{"sourceType":"local","source":"%s"}}]}\n' "$STUB_ROOT" "$STUB_ROOT" > "$market" ;;
  codex:marketplace-remove) rm -f "$market" ;;
  codex:plugin-add) printf '{"installed":[{"pluginId":"agent-firm@agent-firm-local","version":"%s","installed":true,"enabled":true}],"available":[]}\n' "$STUB_CODEX_VERSION" > "$plugin" ;;
  codex:plugin-remove) rm -f "$plugin" ;;
esac

if [ "${STUB_FAIL_ACTION:-}" = "$action" ]; then exit 9; fi
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
    STUB_FAIL_BEFORE_ACTION="${STUB_FAIL_BEFORE_ACTION:-}" \
    STUB_NO_WRITE_ACTION="${STUB_NO_WRITE_ACTION:-}" \
    STUB_FAIL_LIST="${STUB_FAIL_LIST:-}" STUB_LIST_WARNING="${STUB_LIST_WARNING:-}" \
    STUB_OMIT_TOKEN="${STUB_OMIT_TOKEN:-}" STUB_HANG="${STUB_HANG:-}" \
    FIRM_BOOTSTRAP_TIMEOUT="${FIRM_BOOTSTRAP_TIMEOUT:-5}" FIRM_BOOTSTRAP_RECOVERY_DIR="$RECOVERY" \
    FIRM_SKIP_LINK=1 "$BOOT"
}

reset_fixture() { rm -f "$STATE"/* "$RECOVERY"/* "$LOG"; : > "$LOG"; }
write_market_state() {
  _provider="$1"; _root="$2"
  if [ "$_provider" = claude ]; then
    printf '[{"name":"local","source":"directory","path":"%s","installLocation":"%s"}]\n' "$_root" "$_root" > "$STATE/claude-market"
  else
    printf '{"marketplaces":[{"name":"agent-firm-local","root":"%s","marketplaceSource":{"sourceType":"local","source":"%s"}}]}\n' "$_root" "$_root" > "$STATE/codex-market"
  fi
}
write_plugin_state() {
  _provider="$1"; _version="$2"
  if [ "$_provider" = claude ]; then
    printf '[{"id":"agent-firm@local","version":"%s","scope":"user","enabled":true}]\n' "$_version" > "$STATE/claude-plugin"
  else
    printf '{"installed":[{"pluginId":"agent-firm@agent-firm-local","version":"%s","installed":true,"enabled":true}],"available":[]}\n' "$_version" > "$STATE/codex-plugin"
  fi
}
seed_existing() {
  write_market_state claude "$FIRM_ROOT"
  write_plugin_state claude 0.7.0
  write_market_state codex "$FIRM_ROOT"
  write_plugin_state codex 0.7.0
}
seed_exact() {
  write_market_state claude "$FIRM_ROOT"
  write_plugin_state claude "$CLAUDE_VERSION"
  write_market_state codex "$FIRM_ROOT"
  write_plugin_state codex "$CODEX_VERSION"
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
reset_fixture; STUB_FAIL_LIST='codex:plugin list --json' assert_rc "failed Codex prior-state capture blocks" 1 run_boot
assert_eq "state-capture failure causes no mutation" "" "$(provider_mutations)"
reset_fixture; STUB_HANG='claude:--version' FIRM_BOOTSTRAP_TIMEOUT=1 assert_rc "hung capability preflight is bounded" 1 run_boot
assert_eq "bounded capability timeout causes no mutation" "" "$(provider_mutations)"

t_case "selector/schema incompatibility blocks before either CLI mutation"
BADROOT="$WORK/bad-root"; mkdir -p "$BADROOT/bin" "$BADROOT/.claude-plugin" "$BADROOT/.codex-plugin" "$BADROOT/.agents/plugins"
cp "$BOOT" "$BADROOT/bin/firm-bootstrap"; cp "$BIN/firm-bounded-exec" "$BADROOT/bin/firm-bounded-exec"
cp "$BIN/firm-version" "$BADROOT/bin/firm-version"; cp "$FIRM_ROOT/VERSION" "$BADROOT/VERSION"
# firm-bootstrap and firm-bounded-exec both `. "$SELF/firm-python"` on their way in, so a root
# without that sibling dies at line 10 with "No such file or directory" and rc 1 -- which is the rc
# every assertion below expects, so all four passed while testing nothing (CR-03). The assertions are
# now bound to the MESSAGE as well as the code, so a fixture that dies early fails loudly.
cp "$BIN/firm-python" "$BADROOT/bin/firm-python"
cp "$FIRM_ROOT/.claude-plugin/plugin.json" "$BADROOT/.claude-plugin/plugin.json"
cp "$FIRM_ROOT/.codex-plugin/plugin.json" "$BADROOT/.codex-plugin/plugin.json"
cp "$FIRM_ROOT/.claude-plugin/marketplace.json" "$BADROOT/.claude-plugin/marketplace.json"
cp "$FIRM_ROOT/.agents/plugins/marketplace.json" "$BADROOT/.agents/plugins/marketplace.json"
python3 - "$BADROOT/.agents/plugins/marketplace.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['name']='wrong'; json.dump(d,open(p,'w'))
PY
reset_fixture
run_bad_boot() {
  env PATH="$STUB:/usr/bin:/bin" \
    STUB_LOG="$LOG" STUB_STATE="$STATE" STUB_ROOT="$BADROOT" STUB_CLAUDE_VERSION="$CLAUDE_VERSION" \
    STUB_CODEX_VERSION="$CODEX_VERSION" FIRM_SKIP_LINK=1 "$BADROOT/bin/firm-bootstrap"
}
# THE PRECONDITION IS THE POINT (CR-03). rc 1 is what a bootstrap that never started returns too, so
# on its own it proves nothing: with bin/firm-python absent from this root, firm-bootstrap died on
# its source line and these two assertions passed without reading a manifest. Both halves are pinned
# here -- the root really does run, and the refusal really is the selector/schema one.
assert_output "precondition: this root gets far enough to print its own banner" \
  "agent-firm dual-provider bootstrap" run_bad_boot
assert_rc "wrong Codex marketplace selector/schema is rejected" 1 run_bad_boot
assert_output "  and it is rejected for THAT reason, named" "selector/schema preflight mismatch" \
  run_bad_boot
assert_output "  naming the file whose selector was wrong" ".agents/plugins/marketplace.json" \
  run_bad_boot
assert_eq "schema mismatch invokes no provider mutation" "" "$(provider_mutations)"

t_case "provider output parsing rejects duplicates, collisions, case drift, and unparsable targets before mutation"
run_rejected_state() {
  _file="$1"; _payload="$2"
  reset_fixture; seed_exact; printf '%b' "$_payload" > "$STATE/$_file"
  run_boot
}
for spec in \
  "claude-market|[{\"name\":\"local\",\"path\":\"$FIRM_ROOT\"},{\"name\":\"local\",\"path\":\"$FIRM_ROOT\"}]\\n|duplicate exact Claude marketplace" \
  "claude-market|[{\"name\":\"LOCAL\",\"path\":\"$FIRM_ROOT\"}]\\n|case-drifted Claude selector" \
  "claude-market|[{\"name\":\"local\",\"path\":\"$FIRM_ROOT-copy\"}]\\n|suffix-collision Claude root" \
  "claude-market|Configured marketplaces:\\n\\n  ❯ local\\n    Source: Directory ($FIRM_ROOT)\\n|human-formatted Claude target" \
  "claude-plugin|[{\"id\":\"agent-firm@local\",\"version\":\"$CLAUDE_VERSION\"},{\"id\":\"agent-firm@local\",\"version\":\"$CLAUDE_VERSION\"}]\\n|duplicate exact Claude plugin" \
  "claude-plugin|[{\"id\":\"Agent-Firm@local\",\"version\":\"$CLAUDE_VERSION\"}]\\n|case-drifted Claude plugin" \
  "claude-plugin|[{\"id\":\"agent-firm@local-extra\",\"version\":\"$CLAUDE_VERSION\"}]\\n|suffix-collision Claude plugin" \
  "claude-plugin|[{\"id\":\"agent-firm@local\",\"id\":\"other@local\",\"version\":\"$CLAUDE_VERSION\"}]\\n|duplicate Claude JSON key" \
  "claude-plugin|[{\"id\":\"agent-firm@local\",\"version\":\"not-semver\"}]\\n|unparsable Claude version" \
  "codex-market|{\"marketplaces\":[{\"name\":\"agent-firm-local\",\"root\":\"$FIRM_ROOT\"},{\"name\":\"agent-firm-local\",\"root\":\"$FIRM_ROOT\"}]}\\n|duplicate exact Codex marketplace" \
  "codex-market|{\"marketplaces\":[{\"name\":\"AGENT-FIRM-LOCAL\",\"root\":\"$FIRM_ROOT\"}]}\\n|case-drifted Codex selector" \
  "codex-market|{\"marketplaces\":[{\"name\":\"agent-firm-local\",\"root\":\"$FIRM_ROOT-copy\"}]}\\n|suffix-collision Codex root" \
  "codex-market|{\"marketplaces\":{\"name\":\"agent-firm-local\",\"root\":\"$FIRM_ROOT\"}}\\n|unparsable Codex target" \
  "codex-plugin|{\"installed\":[{\"pluginId\":\"agent-firm@agent-firm-local\",\"version\":\"$CODEX_VERSION\"},{\"pluginId\":\"agent-firm@agent-firm-local\",\"version\":\"$CODEX_VERSION\"}]}\\n|duplicate exact Codex plugin" \
  "codex-plugin|{\"installed\":[{\"pluginId\":\"Agent-Firm@agent-firm-local\",\"version\":\"$CODEX_VERSION\"}]}\\n|case-drifted Codex plugin" \
  "codex-plugin|{\"installed\":[{\"pluginId\":\"agent-firm@agent-firm-local-extra\",\"version\":\"$CODEX_VERSION\"}]}\\n|suffix-collision Codex plugin" \
  "codex-plugin|{\"installed\":[{\"pluginId\":\"agent-firm@agent-firm-local\",\"version\":\"not-semver\"}]}\\n|unparsable Codex version"
do
  _file="${spec%%|*}"; _rest="${spec#*|}"; _payload="${_rest%%|*}"; _desc="${_rest#*|}"
  assert_rc "$_desc fails closed" 1 run_rejected_state "$_file" "$_payload"
  assert_eq "$_desc causes no provider mutation" "" "$(provider_mutations)"
done
reset_fixture; seed_exact; printf '\377' > "$STATE/claude-market"
assert_rc "invalid UTF-8 in structured provider state fails closed" 1 run_boot
assert_eq "invalid UTF-8 provider state causes no mutation" "" "$(provider_mutations)"

t_case "zero post-state and full SemVer lookalikes never satisfy exact success"
for provider in claude codex; do
  reset_fixture
  if [ "$provider" = claude ]; then action=claude:marketplace-add; else action=codex:marketplace-add; fi
  STUB_NO_WRITE_ACTION="$action" assert_rc "$provider zero marketplace post-state blocks" 1 run_boot
  for wrong in 10.9.0 0.9.0-rc.1; do
    reset_fixture; seed_exact
    if [ "$provider" = claude ]; then
      write_plugin_state claude "$wrong"
      action=claude:plugin-update
    else
      write_plugin_state codex "$wrong"
      action=codex:plugin-add
    fi
    STUB_NO_WRITE_ACTION="$action" assert_rc "$provider $wrong cannot satisfy exact $provider version" 1 run_boot
  done
done

CACHE_ROOT="$WORK/cache-root"
mkdir -p "$CACHE_ROOT/bin" "$CACHE_ROOT/.claude-plugin" "$CACHE_ROOT/.codex-plugin" "$CACHE_ROOT/.agents/plugins"
cp "$BOOT" "$CACHE_ROOT/bin/firm-bootstrap"; cp "$BIN/firm-bounded-exec" "$CACHE_ROOT/bin/firm-bounded-exec"
cp "$BIN/firm-version" "$CACHE_ROOT/bin/firm-version"; cp "$FIRM_ROOT/VERSION" "$CACHE_ROOT/VERSION"
cp "$BIN/firm-python" "$CACHE_ROOT/bin/firm-python"    # see $BADROOT above (CR-03)
cp "$FIRM_ROOT/.claude-plugin/plugin.json" "$CACHE_ROOT/.claude-plugin/plugin.json"
cp "$FIRM_ROOT/.codex-plugin/plugin.json" "$CACHE_ROOT/.codex-plugin/plugin.json"
cp "$FIRM_ROOT/.claude-plugin/marketplace.json" "$CACHE_ROOT/.claude-plugin/marketplace.json"
cp "$FIRM_ROOT/.agents/plugins/marketplace.json" "$CACHE_ROOT/.agents/plugins/marketplace.json"
python3 - "$CACHE_ROOT" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
for provider,rel in [('claude','.claude-plugin/plugin.json'),('codex','.codex-plugin/plugin.json')]:
 p=root/rel; d=json.loads(p.read_text()); d['version']=f"0.9.0+{provider}.fresh"; p.write_text(json.dumps(d,indent=2)+"\n")
PY
CACHE_CLAUDE_VERSION=0.9.0+claude.fresh
CACHE_CODEX_VERSION=0.9.0+codex.fresh
run_cache_boot() {
  env PATH="$STUB:/usr/bin:/bin" STUB_LOG="$LOG" STUB_STATE="$STATE" STUB_ROOT="$CACHE_ROOT" \
    STUB_CLAUDE_VERSION="$CACHE_CLAUDE_VERSION" STUB_CODEX_VERSION="$CACHE_CODEX_VERSION" \
    STUB_NO_WRITE_ACTION="${STUB_NO_WRITE_ACTION:-}" FIRM_BOOTSTRAP_RECOVERY_DIR="$RECOVERY" \
    FIRM_SKIP_LINK=1 "$CACHE_ROOT/bin/firm-bootstrap"
}
for provider in claude codex; do
  reset_fixture
  write_market_state claude "$CACHE_ROOT"
  write_market_state codex "$CACHE_ROOT"
  write_plugin_state claude "$CACHE_CLAUDE_VERSION"
  write_plugin_state codex "$CACHE_CODEX_VERSION"
  if [ "$provider" = claude ]; then
    write_plugin_state claude 0.9.0; action=claude:plugin-update
  else
    write_plugin_state codex 0.9.0; action=codex:plugin-add
  fi
  # Same CR-03 precondition: without bin/firm-python this root died on its source line, so `rc 1`
  # was satisfied by a bootstrap that never reached the version check it is named for.
  STUB_NO_WRITE_ACTION="$action" assert_output \
    "precondition: the $provider cachebuster root reaches the provider transaction" \
    "agent-firm dual-provider bootstrap" run_cache_boot
  STUB_NO_WRITE_ACTION="$action" assert_rc "$provider stale provider cachebuster cannot satisfy exact success" 1 run_cache_boot
  STUB_NO_WRITE_ACTION="$action" assert_output \
    "  and it fails at the post-mutation VERSION verification, not before it" \
    "post-mutation-version-verification" run_cache_boot
done

t_case "fresh install, exact version verification, and idempotent repeat refresh"
reset_fixture
assert_ok "fresh dual-provider bootstrap succeeds" run_boot
assert_output "Claude marketplace target installed" "$FIRM_ROOT" cat "$STATE/claude-market"
assert_output "Claude plugin exact source version installed" "\"version\":\"$CLAUDE_VERSION\"" cat "$STATE/claude-plugin"
assert_output "Codex marketplace target installed" "$FIRM_ROOT" cat "$STATE/codex-market"
assert_output "Codex plugin exact source version installed" "\"version\":\"$CODEX_VERSION\"" cat "$STATE/codex-plugin"
assert_output "Claude marketplace capture requests structured output" "claude plugin marketplace list --json" cat "$LOG"
assert_output "Claude plugin capture requests structured output" "claude plugin list --json" cat "$LOG"
assert_output "Codex marketplace capture requests structured output" "codex plugin marketplace list --json" cat "$LOG"
assert_output "Codex plugin capture requests structured output" "codex plugin list --json" cat "$LOG"
assert_ok "repeat refresh succeeds against installed state" run_boot
assert_eq "repeat does not re-add either marketplace" "2" \
  "$(grep -c 'plugin marketplace add' "$LOG" | tr -d ' ')"
assert_output "repeat invokes Claude update" "claude plugin update agent-firm@local" cat "$LOG"
assert_output "repeat invokes Codex cache refresh" "codex plugin add agent-firm@agent-firm-local" cat "$LOG"
reset_fixture
STUB_LIST_WARNING='codex:plugin marketplace list --json' \
  assert_ok "provider stderr diagnostics do not contaminate JSON state" run_boot

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

t_case "existing-state refresh failures never reuse a forward command as a reverse"
reset_fixture; seed_existing
STUB_FAIL_BEFORE_ACTION=claude:plugin-update assert_rc "early failed Claude update blocks" 1 run_boot
assert_eq "early failure invokes Claude update exactly once" "1" \
  "$(grep -c '^claude plugin update agent-firm@local$' "$LOG" | tr -d ' ')"
assert_output "early failure leaves observed bytes old" '"version":"0.7.0"' cat "$STATE/claude-plugin"
rf="$(recovery_file)"
assert_eq "early failure recovery record is private" 600 \
  "$(t_file_mode "$rf")"
assert_ok "early failure records inverse-unavailable despite exact observed state" python3 -c \
  "import json; d=json.load(open('$rf')); assert d['status']=='BLOCKED_RECOVERY_REQUIRED'; assert d['exact_prior_state_restored'] is True; assert d['unavailable_reverses'][0]['phase']=='plugin-update'; assert d['completed_mutations']==[]"

reset_fixture; seed_existing
STUB_FAIL_ACTION=claude:plugin-update assert_rc "partial-write failed Claude update blocks" 1 run_boot
assert_eq "partial failure invokes Claude update exactly once" "1" \
  "$(grep -c '^claude plugin update agent-firm@local$' "$LOG" | tr -d ' ')"
assert_output "partial failure remains at the forward version" "\"version\":\"$CLAUDE_VERSION\"" cat "$STATE/claude-plugin"
rf="$(recovery_file)"
assert_ok "partial failure names prior/observed digests and unavailable reverse" python3 -c \
  "import json; d=json.load(open('$rf')); assert d['status']=='BLOCKED_RECOVERY_REQUIRED'; assert not d['exact_prior_state_restored']; assert d['captured_prior_state']['claude']['plugin_state_sha256'] != d['observed_recovery_state']['claude']['plugin_state_sha256']; assert d['unavailable_reverses'][0]['restore_kind']=='unavailable_existing_state'"

reset_fixture; seed_existing
STUB_FAIL_ACTION=codex:plugin-add assert_rc "later partial-write Codex refresh blocks" 1 run_boot
assert_eq "Claude forward update is never retried as compensation" "1" \
  "$(grep -c '^claude plugin update agent-firm@local$' "$LOG" | tr -d ' ')"
assert_eq "Codex forward add is never retried as compensation" "1" \
  "$(grep -c '^codex plugin add agent-firm@agent-firm-local$' "$LOG" | tr -d ' ')"
rf="$(recovery_file)"
assert_ok "later failure records completed Claude mutation and both unavailable reverses" python3 -c \
  "import json; d=json.load(open('$rf')); assert d['status']=='BLOCKED_RECOVERY_REQUIRED'; assert d['completed_mutations']==[{'provider':'claude','phase':'plugin-update','command':['plugin','update','agent-firm@local']}]; assert {x['phase'] for x in d['unavailable_reverses']}=={'plugin-update','plugin-refresh'}"

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
