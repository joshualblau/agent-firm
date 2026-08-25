#!/usr/bin/env bash
# tests/test-ledger-platform-gate.sh — the real host either matches exact P2 or fails closed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$BIN/firm-ledger-log"
RESOLVER="$BIN/firm-model-resolve"
# The OS half of the row is a closed allowlist of proven (macOS, Darwin) pairs. Read it out of the
# writer itself rather than restating it here: a second hand-maintained copy could drift and make
# this suite assert a row the production gate does not actually admit.
host_row="$(t_python - "$LOG" <<'PY'
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
allowlist_row="$(t_python - "$LOG" <<'PY'
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

t_case "SEC-02 the P2 test seam cannot be reached by pointing \$TMPDIR at a real run"
# The seam defined "inside a temp dir" with tempfile.gettempdir(), which honours \$TMPDIR/\$TEMP/\$TMP.
# Pointing it at any ancestor of a production run directory made the seam reachable on a fully
# supported host, where it forges a byte-identical `WRITE_CONFIGURATION_UNSUPPORTED: p2`. The
# vocabulary is negative-only so it can never ADMIT an unproven write -- but it can SUPPRESS a
# lifecycle record while emitting the firm's own canonical, deliberately-sanitized "this host cannot
# write" signal, which is exactly what an operator has been taught to read as "your OS row has not
# been proven". Reproduced before the fix from a run directory outside every temp root: rc 17 and no
# record; after it, INPUT_INVALID (2), which no platform refusal ever returns.
#
# The fixture has to live OUTSIDE the temp roots or it proves nothing, so it is built under
# \$HOME/.cache (created and torn down here, never a path the firm uses) rather than under \$TMPDIR
# like every other fixture in the suite.
seam_home="${HOME:-}"
if [ -n "$seam_home" ] && [ -d "$seam_home" ]; then
  seam_parent="$seam_home/.cache/firm-seam-test.$$"
  mkdir -p "$seam_parent" 2>/dev/null
fi
if [ -n "${seam_parent:-}" ] && [ -d "${seam_parent:-}" ]; then
  seam_repo="$seam_parent/repo"
  mkdir -p "$seam_repo"
  (
    cd "$seam_repo" || exit 1
    git init -q .
    git symbolic-ref HEAD refs/heads/main
    git config user.email test@agent-firm.local
    git config user.name "firm tests"
    git config commit.gpgsign false
    printf 'seed\n' > seed.txt
    git add -A
    git commit -qm seed
  ) >/dev/null 2>&1
  seam_run="$seam_repo/.agent-firm/runs/seamprobe"
  mkdir -p "$seam_run"
  printf '%s\n' ".agent-firm/runs/seamprobe" > "$seam_repo/.agent-firm/CURRENT_RUN"

  # PRECONDITION. The whole case is about a run directory that is NOT inside a temp root; if the
  # fixture accidentally is, every assertion below would pass for the wrong reason.
  assert_ok "precondition: the fixture run is outside /tmp, /var/tmp and the Darwin user temp dir" \
    t_python -c '
import os, sys
run = os.path.realpath(sys.argv[1])
roots = ["/tmp", "/var/tmp"]
try:
    darwin = os.confstr(65537)
except Exception:
    darwin = None
if darwin:
    roots.append(darwin)
for root in roots:
    root = os.path.realpath(root)
    try:
        assert os.path.commonpath((root, run)) != root, (root, run)
    except ValueError:
        pass
' "$seam_run"

  if [ "$host_row" = exact ]; then
    # CONTROL FIRST: an ordinary write to this very run directory succeeds, so the refusals below
    # are about the seam and not about a run directory the writer would have rejected anyway.
    seam_ok="$("$LOG" --run "$seam_run" --strict --print-event-id \
      --event-id evt-seam-control seam_probe class=control 2>/dev/null)"
    assert_eq "CONTROL: an ordinary write to the fixture run succeeds" "evt-seam-control" "$seam_ok"
  fi
  for seam_tmp in "$seam_parent" "$seam_repo" "$seam_repo/.agent-firm" "/"; do
    assert_rc "TMPDIR=$seam_tmp cannot reach the P2 seam" 2 \
      env TMPDIR="$seam_tmp" FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=linux \
      "$LOG" --run "$seam_run" --strict --print-event-id --event-id evt-seam-forged \
      seam_probe class=forged
    assert_output "  and says INPUT_INVALID rather than the platform refusal" "INPUT_INVALID" \
      env TMPDIR="$seam_tmp" FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=linux \
      "$LOG" --run "$seam_run" --strict --print-event-id --event-id evt-seam-forged \
      seam_probe class=forged
  done
  # And a forged rejection must never be mistakable for the real one.
  seam_forged="$(env TMPDIR="$seam_repo" FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=linux \
    "$LOG" --run "$seam_run" --strict --print-event-id --event-id evt-seam-forged \
    seam_probe class=forged 2>&1 >/dev/null)"
  case "$seam_forged" in
    *WRITE_CONFIGURATION_UNSUPPORTED*)
      _t_no "a forged rejection does not wear the platform refusal's message" "$(_t_ctx "$seam_forged")" ;;
    *) _t_ok "a forged rejection does not wear the platform refusal's message" ;;
  esac
  rm -rf "$seam_parent"
else
  _t_no "SEC-02 seam fixture could not be created outside the temp roots" \
    "no writable \$HOME/.cache; this case did NOT run"
fi

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
  assert_ok "native receipt names the retained event" t_python -c \
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
