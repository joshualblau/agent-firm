#!/usr/bin/env bash
# tests/test-ledger-platform-gate.sh — the real host either matches exact P2 or fails closed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$BIN/firm-ledger-log"
RESOLVER="$BIN/firm-model-resolve"
# The OS half of the row is a closed allowlist of proven (macOS, Darwin) pairs. Read it out of the
# writer itself rather than restating it here: a second hand-maintained copy could drift and make
# this suite assert a row the production gate does not actually admit.
host_row="$(python3 - "$LOG" <<'PY'
import ast, pathlib, platform, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"^SUPPORTED_P2_OS_ROWS = frozenset\((\{.*?\})\)", source, re.M | re.S)
if match is None:
    raise SystemExit("cannot read SUPPORTED_P2_OS_ROWS from the production writer")
rows = ast.literal_eval(match.group(1))
exact = (
    platform.system() == "Darwin"
    and (platform.mac_ver()[0], platform.release()) in rows
    and platform.machine() == "arm64"
    and tuple(sys.version_info[:3]) == (3, 9, 6)
    and sys.implementation.name == "cpython"
)
print("exact" if exact else "unsupported")
PY
)"

t_case "the OS half of the P2 row stays a closed set of proven pairs, not a version floor"
allowlist_row="$(python3 - "$LOG" <<'PY'
import ast, itertools, pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"^SUPPORTED_P2_OS_ROWS = frozenset\((\{.*?\})\)", source, re.M | re.S)
if match is None:
    raise SystemExit("cannot read SUPPORTED_P2_OS_ROWS from the production writer")
rows = ast.literal_eval(match.group(1))
# A closed set of literal (macOS, Darwin) pairs — no floors, ranges, prefixes or wildcards can be
# expressed in this shape, so an unproven future OS row cannot be admitted without a reviewed edit.
closed = (
    isinstance(rows, (set, frozenset)) and len(rows) >= 1
    and all(
        isinstance(row, tuple) and len(row) == 2
        and all(isinstance(value, str) and value for value in row)
        for row in rows
    )
)
proven = ("26.5.1", "25.5.0") in rows and ("26.6.1", "25.6.0") in rows
# The values FIRM_LEDGER_P2_TEST_REJECT injects for the macOS/kernel mismatch and unverifiable cases
# must not pair into a member against ANY counterpart the allowlist knows, including "".
macos_values = sorted({row[0] for row in rows}) + [""]
kernel_values = sorted({row[1] for row in rows}) + [""]
unpairable = not any(
    pair in rows for pair in itertools.chain(
        itertools.product(("26.5.0", ""), kernel_values),
        itertools.product(macos_values, ("25.4.0", "")),
    )
)
# Membership is by whole row: a macOS value from one proven row must not pair with the kernel value
# of a different row. That is what a per-dimension (macos in ... and kernel in ...) gate would lose.
cross = not any((a[0], b[1]) in rows for a, b in itertools.permutations(sorted(rows), 2))
print("closed_pairs=%s proven_rows=%s injected_unpairable=%s cross_row_unpairable=%s" % tuple(
    "yes" if flag else "no" for flag in (closed, proven, unpairable, cross)
))
PY
)"
assert_eq "OS-row allowlist is a closed set of proven, unpairable pairs" \
  "closed_pairs=yes proven_rows=yes injected_unpairable=yes cross_row_unpairable=yes" \
  "$allowlist_row"

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
