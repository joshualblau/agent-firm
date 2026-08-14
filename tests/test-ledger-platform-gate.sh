#!/usr/bin/env bash
# tests/test-ledger-platform-gate.sh — the real host either matches exact P2 or fails closed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$BIN/firm-ledger-log"
RESOLVER="$BIN/firm-model-resolve"
host_row="$(python3 - <<'PY'
import platform, sys
exact = (
    platform.system() == "Darwin"
    and platform.mac_ver()[0] == "26.5.1"
    and platform.release() == "25.5.0"
    and platform.machine() == "arm64"
    and tuple(sys.version_info[:3]) == (3, 9, 6)
    and sys.implementation.name == "cpython"
)
print("exact" if exact else "unsupported")
PY
)"

t_case "ordinary writes follow the production host classification"
repo="$(mk_repo)"; mk_run "$repo" ordinary
run="$repo/.agent-firm/runs/ordinary"
ordinary_out="$("$LOG" --run "$run" --strict --print-event-id \
  --event-id evt-platform-ordinary platform_probe class=host 2> "$repo/ordinary.err")"
ordinary_rc=$?
if [ "$host_row" = exact ]; then
  assert_eq "exact P2 host permits the ordinary write" 0 "$ordinary_rc"
  assert_eq "ordinary receipt is retained exactly" evt-platform-ordinary "$ordinary_out"
  assert_file "ordinary ledger exists on exact P2" "$run/run.jsonl"
else
  assert_eq "unsupported host rejects the ordinary write with the P2 class" 17 "$ordinary_rc"
  assert_eq "unsupported ordinary write emits no success receipt" "" "$ordinary_out"
  assert_output "ordinary rejection is sanitized" "WRITE_CONFIGURATION_UNSUPPORTED: p2" \
    cat "$repo/ordinary.err"
  assert_no_file "ordinary rejection creates no ledger" "$run/run.jsonl"
  assert_no_file "ordinary rejection creates no coordination lock" "$run/run.jsonl.lock"
  assert_eq "ordinary rejection creates no transaction temp" 0 \
    "$(find "$run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
fi

t_case "native role starts use the same production host classification"
mk_run "$repo" native
native_run="$repo/.agent-firm/runs/native"
mkdir -p "$native_run/role-contracts" "$repo/.agent-firm/runs/source"
printf '%s\n' '{"run_id":"native","historical":false,"approval_eligible":true}' \
  > "$native_run/run-metadata.json"
printf '%s\n' 'sealed platform-gate role contract' > "$native_run/role-contracts/R-01-implementer.md"
printf '%s\n' \
  '{"ts":"2026-08-13T00:00:00Z","event":"human_architecture_decision","event_id":"evt-platform-authority","run_id":"source","decision":"option_a","target_run_id":"native"}' \
  > "$repo/.agent-firm/runs/source/run.jsonl"
chmod 644 "$native_run/run-metadata.json" "$native_run/role-contracts/R-01-implementer.md"
chmod 600 "$repo/.agent-firm/runs/source/run.jsonl"
activation="$("$RESOLVER" --provider codex --role implementer --format activation)"
authority='[{"source_run":".agent-firm/runs/source","event_id":"evt-platform-authority","expect":{"event":"human_architecture_decision","run_id":"source","fields":{"decision":"option_a","target_run_id":"native"}}}]'
native_out="$("$LOG" --run "$native_run" --strict --role-start \
  --stage build/platform-probe --role implementer --contract role-contracts/R-01-implementer.md \
  --event build_started --authority-json "$authority" --agent /root/platform_probe \
  --activation-json "$activation" 2> "$repo/native.err")"
native_rc=$?
if [ "$host_row" = exact ]; then
  assert_eq "exact P2 host permits the native role start" 0 "$native_rc"
  assert_ok "native receipt names the retained event" python3 -c \
    'import json,sys; assert json.loads(sys.argv[1])["event"] == "build_started"' "$native_out"
  assert_file "native ledger exists on exact P2" "$native_run/run.jsonl"
else
  assert_eq "unsupported host rejects the native role start with the P2 class" 17 "$native_rc"
  assert_eq "unsupported native start emits no success receipt" "" "$native_out"
  assert_output "native rejection is sanitized" "WRITE_CONFIGURATION_UNSUPPORTED: p2" \
    cat "$repo/native.err"
  assert_no_file "native rejection creates no ledger" "$native_run/run.jsonl"
  assert_no_file "native rejection creates no coordination lock" "$native_run/run.jsonl.lock"
  assert_eq "native rejection creates no transaction temp" 0 \
    "$(find "$native_run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
fi

t_summary
