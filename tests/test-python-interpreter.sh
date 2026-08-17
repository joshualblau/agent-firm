#!/usr/bin/env bash
# tests/test-python-interpreter.sh — the firm runs ONE resolved interpreter, and says so when it can't.
#
# The defect this covers: every firm-* tool used to spawn a bare `python3` from PATH while the ledger
# gate admits exactly one interpreter row, so on an ordinary machine the tools, the doctor and the
# gate were three answers about three different pythons. The assertions below are about that identity
# (the resolver's expectations ARE the writer's literals), about fail-closed degradation (no silent
# substitution), and about the property that actually broke: a ledger write must not depend on which
# python3 happens to be first on PATH.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FP="$BIN/firm-python"
LOG="$BIN/firm-ledger-log"

# Classify the host through the SAME resolver production uses and the SAME row set the writer admits.
# Classifying with PATH's python3 would ask about a different machine -- which is the whole defect.
host_row="$("$FP" - "$LOG" <<'PY'
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
)" || host_row=""
[ -n "$host_row" ] || host_row=unsupported

t_case "the resolver's expectations are the writer's gate literals, not a second opinion"
assert_ok "every FIRM_PYTHON_EXPECT_* value is the literal bin/firm-ledger-log refuses on" \
  t_python - "$FP" "$LOG" <<'PY'
import pathlib, re, sys
resolver = pathlib.Path(sys.argv[1]).read_text()
producer = pathlib.Path(sys.argv[2]).read_text()
expect = dict(re.findall(r'^FIRM_PYTHON_EXPECT_(\w+)="([^"]*)"', resolver, re.M))
assert set(expect) == {"SYSTEM", "ARCH", "VERSION", "IMPL"}, expect
# The gate is one boolean expression in the writer; each clause below is the exact text it rejects on.
# If someone changes the admitted interpreter in one file only, this fails instead of the two files
# quietly disagreeing (a doctor and a gate reading different rows is the defect, one layer up).
clauses = [
    'system != "%s"' % expect["SYSTEM"],
    'architecture != "%s"' % expect["ARCH"],
    'python != (%s)' % ", ".join(expect["VERSION"].split(".")),
    'implementation != "%s"' % expect["IMPL"],
]
missing = [clause for clause in clauses if clause not in producer]
assert not missing, missing
PY
assert_ok "the OS-row half is NOT restated in the resolver (one source: SUPPORTED_P2_OS_ROWS)" \
  t_python -c '
import pathlib, re, sys
resolver = pathlib.Path(sys.argv[1]).read_text()
# a copy of the proven pairs here is what could drift; the resolver must not carry one
assert "SUPPORTED_P2_OS_ROWS = " not in resolver
assert not re.search(r"2[0-9]\.[0-9]+\.[0-9]+", resolver), "an OS version literal appears in the resolver"
' "$FP"

t_case "resolution is silent, absolute, and runnable"
assert_output "runs a program on the resolved interpreter" "resolved-ok" "$FP" -c 'print("resolved-ok")'
assert_eq "resolution writes nothing to stderr" "" "$("$FP" -c 'pass' 2>&1 1>/dev/null)"
argv0="$("$FP" --print-argv | sed -n '1p')"
case "$argv0" in
  /*) _t_ok "the resolved argv starts with an absolute path ($argv0)" ;;
  *)  _t_no "the resolved argv starts with an absolute path" "got '$argv0'" ;;
esac
assert_output "--status reports the resolved command" "argv=" "$FP" --status
assert_ok "sourcing defines the shared helper instead of a per-script copy" bash -c '
set -euo pipefail
. "$1"
[ "${#FIRM_PYTHON_ARGV[@]}" -ge 1 ]
out="$(firm_python - marker <<PY
import sys; print("sourced", sys.argv[1])
PY
)"
[ "$out" = "sourced marker" ]' _ "$FP"

t_case "the host classification the resolver reaches is the one the writer enforces"
if [ "$host_row" = exact ]; then
  assert_output "--status reports p2=yes on a supported host" "p2=yes" "$FP" --status
  assert_rc "--require-p2 runs the program here" 0 "$FP" --require-p2 -c 'pass'
  assert_ok "the resolved interpreter satisfies every interpreter clause of the gate" "$FP" -c '
import os, platform, sys
assert platform.system() == "Darwin", platform.system()
assert platform.machine() == "arm64", platform.machine()
assert tuple(sys.version_info[:3]) == (3, 9, 6), sys.version_info[:3]
assert sys.implementation.name == "cpython", sys.implementation.name
assert isinstance(sys.executable, str) and sys.executable and os.path.isabs(sys.executable)
'
else
  assert_output "--status reports p2=no on an unsupported host" "p2=no" "$FP" --status
  assert_output "--status names what it probed" "probed:" "$FP" --status
  assert_rc "--require-p2 fails closed with the write-unsupported class" 17 "$FP" --require-p2 -c 'pass'
fi

t_case "a host with NO compliant interpreter fails closed and never silently substitutes one"
# Modelled with a copy whose expectations no interpreter can satisfy, because the real answer depends
# on the machine the suite happens to run on and this behaviour must be proven on every one of them.
UNSAT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-python-unsat.XXXXXX")"; t_track "$UNSAT_DIR"
UNSAT="$UNSAT_DIR/firm-python"
sed 's/^FIRM_PYTHON_EXPECT_VERSION=.*/FIRM_PYTHON_EXPECT_VERSION="0.0.0"/' "$FP" > "$UNSAT"
chmod +x "$UNSAT"
assert_output "precondition: the copy really cannot be satisfied" 'FIRM_PYTHON_EXPECT_VERSION="0.0.0"' \
  cat "$UNSAT"
assert_output "status says p2=no" "p2=no" "$UNSAT" --status
assert_output "status names the missing row" "0.0.0" "$UNSAT" --status
assert_output "status names the candidates it probed" "probed:" "$UNSAT" --status
assert_rc "--require-p2 exits 17 rather than running a non-compliant interpreter" 17 \
  "$UNSAT" --require-p2 -c 'pass'
assert_output "--require-p2 says why" "no P2-compliant interpreter" "$UNSAT" --require-p2 -c 'pass'
assert_eq "--require-p2 runs no program at all" "" \
  "$("$UNSAT" --require-p2 -c 'print("this must not run")' 2>/dev/null)"
# Degrading is not the same as pretending: without --require-p2 the tools still run (that is what
# keeps the firm usable on the deliberately unsupported CI hosts) and the P2 verdict still says no.
assert_rc "without --require-p2 the tools still run on the plain interpreter" 0 "$UNSAT" -c 'pass'

t_case "a candidate that cannot answer the probe is skipped, not trusted"
# This is what resolution adds to the older shim threat (a PATH `python3` that returns a status
# without running the program it was handed): a candidate that cannot answer the probe as the
# admitted interpreter is not selected at all, so it cannot author anything. It is NOT a substitute
# for the proof-of-execution sentinel in firm-merge-guard -- a shim that answers the probe and then
# betrays the real run is still possible, and that case is asserted in tests/test-merge-guard.sh.
SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-python-shim.XXXXXX")"; t_track "$SHIM_DIR"
printf '#!/bin/sh\nexit 3\n' > "$SHIM_DIR/python3"; chmod +x "$SHIM_DIR/python3"
assert_eq "the shim is what PATH's python3 would be" "3" \
  "$(PATH="$SHIM_DIR:/usr/bin:/bin" python3 -c 'print(1)' >/dev/null 2>&1; printf '%s' "$?")"
if [ "$host_row" = exact ]; then
  assert_output "the resolver runs a real interpreter instead of the shim" "shim-was-not-used" \
    env PATH="$SHIM_DIR:/usr/bin:/bin" "$FP" -c 'print("shim-was-not-used")'
  assert_output "and still reports p2=yes" "p2=yes" env PATH="$SHIM_DIR:/usr/bin:/bin" "$FP" --status
fi

t_case "no firm tool spawns a bare PATH python3"
assert_ok "every bin/firm-* runs the resolved interpreter (the resolver itself excepted)" \
  t_python - "$BIN" <<'PY'
import pathlib, re, sys
bin_dir = pathlib.Path(sys.argv[1])
# firm-python IS the resolver, so it is the one file that may name a bare `python3` (its candidate
# list). Everywhere else a bare python3 in COMMAND position is the defect this run closed: it is how
# the tools, the doctor and the write gate ended up reading three different interpreters.
command_position = re.compile(
    r"(?:^\s*|[|;&]\s*|\$\(\s*|!\s*|\b(?:exec|if|elif|while|until|then|else|do)\s+)python3\b")
offenders = {}
for path in sorted(bin_dir.glob("firm-*")):
    if path.name == "firm-python":
        continue
    hits = [
        (number, line.strip())
        for number, line in enumerate(path.read_text().splitlines(), 1)
        if not line.lstrip().startswith("#") and command_position.search(line)
    ]
    if hits:
        offenders[path.name] = hits
assert not offenders, offenders
PY
assert_ok "the PreToolUse guard resolves LAZILY so its zero-subprocess fast path stays free" \
  t_python -c '
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
# The resolver costs a probe; firm-merge-guard classifies 98.73% of commands without any subprocess
# at all, so the source must live inside the function that is only reached when a python start was
# already going to happen.
assert "_mg_python_ready()" in text
sources = [line for line in text.splitlines() if line.strip().startswith(". \"$SELF/firm-python\"")]
assert len(sources) == 1, sources
assert sources[0].startswith("    "), sources   # indented: inside _mg_python_ready, not at top level
assert text.count("_mg_python_ready") >= 3      # defined, plus both call sites
' "$BIN/firm-merge-guard"

if [ "$host_row" = exact ]; then
  t_case "a ledger write no longer depends on which python3 is first on PATH"
  # The exact production failure: PATH python3 was conda 3.8.13, the gate needs CPython 3.9.6, and
  # every write died with WRITE_CONFIGURATION_UNSUPPORTED: p2 -- including both providers' init.
  STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-python-stub.XXXXXX")"; t_track "$STUB_DIR"
  printf '#!/bin/sh\nexit 9\n' > "$STUB_DIR/python3"
  chmod +x "$STUB_DIR/python3"
  assert_rc "precondition: PATH's python3 in this fixture cannot run anything" 9 \
    env PATH="$STUB_DIR:/usr/bin:/bin" python3 -c 'pass'
  repo="$(mk_repo)"; mk_run "$repo" pathproof
  pathproof_run="$repo/.agent-firm/runs/pathproof"
  out="$(PATH="$STUB_DIR:/usr/bin:/bin" "$LOG" --run "$pathproof_run" --strict --print-event-id \
    --event-id evt-python-path-proof interpreter_probe class=path 2> "$repo/pathproof.err")"
  rc=$?
  assert_eq "the write succeeds with a broken PATH python3" 0 "$rc"
  assert_eq "and returns its exact receipt" "evt-python-path-proof" "$out"
  assert_file "the ledger was really appended" "$pathproof_run/run.jsonl"
  assert_eq "nothing was written to stderr" "" "$(cat "$repo/pathproof.err")"
  assert_ok "the appended record is the event that was asked for" t_python - \
    "$pathproof_run/run.jsonl" <<'PY'
import json, pathlib, sys
lines = [line for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
assert len(lines) == 1, lines
record = json.loads(lines[0])
assert record["event"] == "interpreter_probe" and record["event_id"] == "evt-python-path-proof", record
assert record["class"] == "path", record
PY
fi

t_summary
