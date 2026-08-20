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
# without running the program it was handed). BOTH directions are driven here, and the second one is
# why this case exists at all: the file used to test only `exit 3` -- a candidate that says NO -- and
# an `exit 0` shim was therefore selected, reported p2=yes, and admitted by --require-p2 (SEC-01 /
# CR-04 / SEC-05). Exit 3 is the harmless direction; exit 0 is the fail-open one.
#
# The resolver now requires PROOF OF EXECUTION, exactly as bin/firm-merge-guard requires
# FIRM_MG_DECISION on stdout: the probe must return a sentinel line carrying a per-probe nonce it was
# handed on argv plus the four values it read out of its own process. `exit 0` emits nothing; a
# constant `echo` of the sentinel cannot know the nonce.
SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-python-shim.XXXXXX")"; t_track "$SHIM_DIR"
printf '#!/bin/sh\nexit 3\n' > "$SHIM_DIR/python3"; chmod +x "$SHIM_DIR/python3"
assert_eq "the shim is what PATH's python3 would be" "3" \
  "$(PATH="$SHIM_DIR:/usr/bin:/bin" python3 -c 'print(1)' >/dev/null 2>&1; printf '%s' "$?")"
if [ "$host_row" = exact ]; then
  assert_output "the resolver runs a real interpreter instead of the shim" "shim-was-not-used" \
    env PATH="$SHIM_DIR:/usr/bin:/bin" "$FP" -c 'print("shim-was-not-used")'
  assert_output "and still reports p2=yes" "p2=yes" env PATH="$SHIM_DIR:/usr/bin:/bin" "$FP" --status
fi

# The three shims, probed directly through the resolver's own predicate. Host-independent: this asks
# the function, not the machine.
OPEN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-python-open.XXXXXX")"; t_track "$OPEN_DIR"
printf '#!/bin/sh\nexit 0\n' > "$OPEN_DIR/python3"; chmod +x "$OPEN_DIR/python3"
# A shim that knows the format and the four expected values but not the nonce. This is what makes the
# sentinel more than a magic string: FIRM_PYTHON_EXPECT_* are readable in the file, the nonce is not.
GUESS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-python-guess.XXXXXX")"; t_track "$GUESS_DIR"
printf '#!/bin/sh\necho "FIRM_PYTHON_PROBE_OK guessed Darwin arm64 3.9.6 cpython"\nexit 0\n' \
  > "$GUESS_DIR/python3"; chmod +x "$GUESS_DIR/python3"
assert_rc "precondition: the exit-0 shim really does exit 0 for any program" 0 \
  "$OPEN_DIR/python3" -c 'print("this never runs")'
_probe_rc() { ( . "$FP" >/dev/null 2>&1; _firm_python_probe "$@" >/dev/null 2>&1; printf '%s' "$?" ); }
assert_ne "an exit-0 shim does NOT satisfy the probe (the fail-open direction)" "0" "$(_probe_rc "$OPEN_DIR/python3")"
assert_ne "an exit-3 shim does NOT satisfy the probe (the harmless direction)" "0" "$(_probe_rc "$SHIM_DIR/python3")"
assert_ne "a constant echo of the sentinel does NOT satisfy the probe" "0" "$(_probe_rc "$GUESS_DIR/python3")"
if [ "$host_row" = exact ]; then
  # The control uses the RESOLVED argv, not a bare path: on a translated parent the compliant form is
  # `/usr/bin/arch -arm64 <path>` and a bare path legitimately fails the arch clause. Asserting on the
  # bare path would make this control fail for the right reason and prove nothing about the sentinel.
  assert_eq "CONTROL: a real interpreter DOES satisfy the same probe" "0" \
    "$(_probe_rc "${FIRM_PYTHON_ARGV[@]}")"
fi

# End to end, on a resolver copy whose only reachable candidate is the shim. The absolute fallbacks
# are redirected into a directory that does not exist, so `command -v python3` (the shim) is the whole
# candidate list -- which is the world in which an exit-status-only probe hands the firm a p2=yes.
ONLY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-python-only.XXXXXX")"; t_track "$ONLY_DIR"
ONLY="$ONLY_DIR/firm-python"
sed 's#^    /#    /nonexistent-for-tests/#' "$FP" > "$ONLY"; chmod +x "$ONLY"
assert_ok "precondition: the copy has no absolute system interpreter left to fall back on" \
  t_python -c '
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
# Every candidate line in _firm_python_candidates is "    /abs/path" possibly with a trailing "\".
# All of them must have been redirected; if the function is ever reformatted this precondition fails
# loudly rather than letting the case below assert against a resolver that still has a real fallback.
survivors = [line for line in text.splitlines() if re.match(r"^    /(?!nonexistent-for-tests/)", line)]
assert not survivors, survivors
assert text.count("/nonexistent-for-tests/") == 4, text.count("/nonexistent-for-tests/")
' "$ONLY"
if [ "$host_row" = exact ]; then
  # CONTROL FIRST. Without it, a copy that is simply broken would "prove" the shim is refused just as
  # loudly, and the two negatives below would mean nothing.
  assert_output "CONTROL: the same copy still says p2=yes when PATH holds a real interpreter" "p2=yes" \
    env PATH="/usr/bin:/bin" "$ONLY" --status
fi
assert_output "an exit-0 shim as the only candidate is reported p2=no, not vouched for" "p2=no" \
  env PATH="$OPEN_DIR:/usr/bin:/bin" "$ONLY" --status
assert_rc "--require-p2 refuses it with the write-unsupported class instead of running it" 17 \
  env PATH="$OPEN_DIR:/usr/bin:/bin" "$ONLY" --require-p2 -c 'print("this must not run")'
assert_eq "--require-p2 runs no program at all" "" \
  "$(env PATH="$OPEN_DIR:/usr/bin:/bin" "$ONLY" --require-p2 -c 'print("this must not run")' 2>/dev/null)"
assert_output "the reason names what it probed rather than claiming compliance" "probed:" \
  env PATH="$OPEN_DIR:/usr/bin:/bin" "$ONLY" --status

t_case "AC-107 the DEGRADED fallback is probed too, and the resolver publishes what it proved"
# The half the exit-0-shim work above did NOT reach. Everything so far is about SELECTION: a shim
# cannot be selected as the P2 interpreter. But when nothing is compliant the resolver still has to
# hand every firm-* tool an argv, and that argv used to be chosen on `[ -x ]` alone -- which is true
# of a two-line `#!/bin/sh` + `exit 0` shim. bin/firm-merge-guard then ran it to decide a merge or a
# push and believed its exit status, so on such a host a caller-controlled $FIRM_PYTHON turned a
# BLOCK into a PERMIT (AC-107; the merge-guard half is driven in tests/test-merge-guard.sh).
#
# The resolver now re-probes the argv it actually chose and publishes FIRM_PYTHON_LIVE. The two bars
# are DIFFERENT QUESTIONS and the pair below is what proves that rather than asserting it: the SAME
# real interpreter, through the SAME probe program, fails the P2 bar on the unsatisfiable copy and
# passes the liveness bar. If liveness were secretly the P2 bar the second row would go red; if it
# were a no-op the shim rows would.
_unsat_p2_rc()   { ( . "$UNSAT" >/dev/null 2>&1; _firm_python_probe "$@"      >/dev/null 2>&1; printf '%s' "$?" ); }
_unsat_live_rc() { ( . "$UNSAT" >/dev/null 2>&1; _firm_python_live_probe "$@" >/dev/null 2>&1; printf '%s' "$?" ); }
REAL_PY="$(t_python -c 'import sys; print(sys.executable)')"
assert_ne "precondition: a REAL interpreter fails the unsatisfiable copy's P2 bar" "0" \
  "$(_unsat_p2_rc "$REAL_PY")"
assert_eq "  ...and the SAME interpreter passes the liveness bar (P2 and live are not one question)" "0" \
  "$(_unsat_live_rc "$REAL_PY")"
assert_ne "an exit-0 shim does NOT satisfy the liveness probe (the fail-open direction)" "0" \
  "$(_unsat_live_rc "$OPEN_DIR/python3")"
assert_ne "an exit-3 shim does NOT satisfy it either" "0" "$(_unsat_live_rc "$SHIM_DIR/python3")"
assert_ne "a constant echo of the sentinel does NOT satisfy it — the nonce is fresh per probe" "0" \
  "$(_unsat_live_rc "$GUESS_DIR/python3")"
# A shim that replays a sentinel line captured from an EARLIER probe of this same resolver. This is
# the assertion the constant-echo row cannot make: the format and all four values are correct and
# were observed, not guessed -- only the nonce is stale.
REPLAY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-python-replay.XXXXXX")"; t_track "$REPLAY_DIR"
_replay_seen="$REPLAY_DIR/seen"
{ printf '#!/bin/sh\n'
  printf '# harvest THIS probe'"'"'s nonce off argv, then answer it correctly\n'
  printf 'for a in "$@"; do case "$a" in fp*) printf "%%s" "$a" > "%s" ;; esac; done\n' "$_replay_seen"
  printf 'printf "FIRM_PYTHON_PROBE_OK %%s Darwin arm64 0.0.0 cpython\\n" "$(cat "%s")"\n' "$_replay_seen"
  printf 'exit 0\n'; } > "$REPLAY_DIR/harvest"
chmod +x "$REPLAY_DIR/harvest"
{ printf '#!/bin/sh\n'
  printf 'printf "FIRM_PYTHON_PROBE_OK %%s Darwin arm64 0.0.0 cpython\\n" "$(cat "%s")"\n' "$_replay_seen"
  printf 'exit 0\n'; } > "$REPLAY_DIR/replay"
chmod +x "$REPLAY_DIR/replay"
# CONTROL FIRST: the harvesting shim answers the nonce it was just handed, so the bar is reachable
# and the two negatives below are not passing because the format itself is wrong.
assert_eq "CONTROL: a shim that echoes back THIS probe's own nonce does satisfy it" "0" \
  "$(_unsat_live_rc "$REPLAY_DIR/harvest")"
assert_file "  and it really captured a nonce" "$_replay_seen"
assert_ne "REPLAY: the same, previously-valid line on a LATER probe does not" "0" \
  "$(_unsat_live_rc "$REPLAY_DIR/replay")"

# End to end through --status, on the resolver copy no host can satisfy. $FIRM_PYTHON is pinned to a
# real interpreter and then to the shim, so both rows are deterministic on every host rather than
# depending on what this machine happens to have first on PATH.
assert_output "a degraded host whose fallback IS an interpreter reports live=yes" "live=yes" \
  env FIRM_PYTHON="$REAL_PY" "$UNSAT" --status
assert_output "  and still refuses to call it P2" "p2=no" \
  env FIRM_PYTHON="$REAL_PY" "$UNSAT" --status
assert_output "a degraded host whose fallback is a SHIM reports live=no" "live=no" \
  env FIRM_PYTHON="$OPEN_DIR/python3" "$UNSAT" --status
assert_output "  and the reason names the fallback it could not vouch for" \
  "did not prove it executes python at all" env FIRM_PYTHON="$OPEN_DIR/python3" "$UNSAT" --status
# The program name has to be bound to the LIVE verdict, not merely present somewhere in the line:
# FIRM_PYTHON_TRIED already lists every candidate, so `assert_output ... "$OPEN_DIR/python3"` alone
# stays green against a resolver that vouches for the shim without probing it. Checked by mutation.
assert_output "  and names WHICH program that was" \
  "$OPEN_DIR/python3 did not prove it executes python at all" \
  env FIRM_PYTHON="$OPEN_DIR/python3" "$UNSAT" --status
# The compliant host says yes to both, so `live=` is not a field that is always no.
if [ "$host_row" = exact ]; then
  assert_output "CONTROL: a compliant host reports live=yes" "live=yes" "$FP" --status
  assert_output "CONTROL: and p2=yes with it" "p2=yes" "$FP" --status
fi
# Degrading is still not refusing: a real-but-wrong interpreter must stay runnable, which is what
# keeps the deliberately unsupported CI hosts usable.
assert_rc "a live-but-not-P2 fallback still runs programs (CI hosts stay usable)" 0 \
  env FIRM_PYTHON="$REAL_PY" "$UNSAT" -c 'pass'

t_case "an unusable \$FIRM_PYTHON degrades to a working interpreter, and is named"
# SEC-04 / CR-09: the fallback used to take $FIRM_PYTHON without the `[ -x ]` test every other
# candidate gets, so a typo made every firm-* tool exit 127 "command not found" -- not the documented
# 17 -- while FIRM_PYTHON_REASON listed three interpreters, none of them the one about to be run.
BOGUS="$ONLY_DIR/pyhton3-does-not-exist"
assert_no_file "precondition: the override really does not exist" "$BOGUS"
assert_rc "a typo'd override still runs a real interpreter (not exit 127)" 0 \
  env FIRM_PYTHON="$BOGUS" "$FP" -c 'pass'
argv_bogus="$(env FIRM_PYTHON="$BOGUS" "$FP" --print-argv | sed -n '1p')"
assert_ne "the resolver did not select the unusable override" "$BOGUS" "$argv_bogus"
UNSAT_BOGUS="$(env FIRM_PYTHON="$BOGUS" "$UNSAT" --status 2>&1)"
case "$UNSAT_BOGUS" in
  *"$BOGUS (not executable)"*) _t_ok "an unusable override is named in the reason it was skipped" ;;
  *) _t_no "an unusable override is named in the reason it was skipped" "got: $(_t_ctx "$UNSAT_BOGUS")" ;;
esac
case "$UNSAT_BOGUS" in
  *"argv=$BOGUS"*) _t_no "the degraded argv is a working interpreter, not the unusable override" \
                     "got: $(_t_ctx "$UNSAT_BOGUS")" ;;
  *) _t_ok "the degraded argv is a working interpreter, not the unusable override" ;;
esac
assert_rc "and the degraded path still runs (rc 0), which is what keeps CI hosts usable" 0 \
  env FIRM_PYTHON="$BOGUS" "$UNSAT" -c 'pass'

t_case "--help prints a whole document, not a truncated one"
# CC-11: the extraction was a fixed line range that stopped on the bare heading "WHY THIS EXISTS" and
# printed no body, which reads as a broken install. It is now addressed by an end marker, so the
# header can grow without truncating again.
help_out="$("$FP" --help)"
help_last="$(printf '%s\n' "$help_out" | sed -n '$p')"
assert_ne "the last line of --help is not empty" "" "$help_last"
# Every heading in this header is ALL CAPS, so a last line with no lowercase letter in it is the
# truncation symptom -- that is exactly what `sed -n '2,15p'` used to print ("WHY THIS EXISTS").
case "$help_last" in
  *[a-z]*) _t_ok "the last line of --help is prose, not a bare heading" ;;
  *) _t_no "the last line of --help is prose, not a bare heading" "got '$help_last'" ;;
esac
assert_output "--help documents itself" "--help" "$FP" --help
assert_output "--help documents the ENVIRONMENT it reads" "ENVIRONMENT" "$FP" --help
assert_output "--help names \$FIRM_PYTHON" '$FIRM_PYTHON' "$FP" --help
assert_output "--help reaches the degradation section" "HOW IT DEGRADES" "$FP" --help

t_case "no firm tool spawns a bare PATH python3"
assert_ok "every bin/firm-* runs the resolved interpreter (the resolver itself excepted)" \
  t_python - "$BIN" <<'PY'
import pathlib, re, sys
bin_dir = pathlib.Path(sys.argv[1])
# firm-python IS the resolver, so it is the one file that may name a bare `python3` (its candidate
# list). Everywhere else a bare python3 in COMMAND position is the defect this run closed: it is how
# the tools, the doctor and the write gate ended up reading three different interpreters.
#
# THE CLAIM IS INVERTED ON PURPOSE (CR-06). This used to enumerate COMMAND POSITION with a regex of
# five alternatives, and an enumeration of the ways a shell can start a command is never complete:
# `PYTHONPATH=x python3 ...`, `env FOO=1 python3 ...`, `timeout 30 python3 ...`, `command python3`
# and `out="$(python3 ...)"` are all command position and matched none of them -- so the exact defect
# this run closed could return with the pin still green. The assertion is therefore the small closed
# claim instead: OUTSIDE A COMMENT, EVERY `python3` TOKEN MUST BE INSIDE A QUOTED STRING, i.e.
# diagnostic text, never a word the shell will execute.
#
# shell_unquoted() keeps only the characters the shell would treat as CODE. It tracks single quotes,
# double quotes, backslash escapes, `$(...)` and backticks -- and command substitution re-enters code
# context even inside double quotes, which is exactly how the shell reads it and is why a naive
# strip-the-quoted-spans version missed `out="$(python3 ...)"`. Anything left over is an unquoted
# word. The helper is exercised against known-flag and known-clean lines in the next assertion, so a
# scanner that silently stopped finding things is itself caught.
def shell_unquoted(line):
    out = []
    stack = ["U"]                                  # U unquoted/code · S single · D double · B backtick
    i, n = 0, len(line)
    while i < n:
        ctx, char = stack[-1], line[i]
        if ctx == "S":                             # no escapes inside single quotes
            if char == "'":
                stack.pop()
            i += 1
        elif ctx == "D":
            if char == "\\":
                i += 2
            elif char == '"':
                stack.pop(); i += 1
            elif char == "$" and line[i + 1:i + 2] == "(":
                stack.append("U"); i += 2          # $( ) is code even inside " "
            elif char == "`":
                stack.append("B"); i += 1
            else:
                i += 1
        else:                                      # U or B: this is code, so keep it
            if char == "\\":
                i += 2
            elif char == "'":
                stack.append("S"); i += 1
            elif char == '"':
                stack.append("D"); i += 1
            elif char == "$" and line[i + 1:i + 2] == "(":
                stack.append("U"); i += 2
            elif char == "`":
                stack.pop() if ctx == "B" else stack.append("B")
                i += 1
            elif char == ")" and len(stack) > 1:
                stack.pop(); i += 1
            else:
                out.append(char); i += 1
    return "".join(out)

offenders = {}
for path in sorted(bin_dir.glob("firm-*")):
    if path.name == "firm-python":
        continue
    hits = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#") or "python3" not in line:
            continue
        if "python3" in shell_unquoted(line):
            hits.append((number, line.strip()))
    if hits:
        offenders[path.name] = hits
assert not offenders, offenders
PY
assert_ok "and that pin catches the launcher/assignment prefixes the old regex did not" \
  t_python - "$TESTS_DIR/test-python-interpreter.sh" <<'PY'
import pathlib, re, sys
# The pin's own scanner, lifted verbatim out of the assertion above so the two cannot drift, then
# driven over the shapes CR-06 named. A pin that stopped reporting these would be decorative and the
# resolver could be bypassed again with the suite green -- which is the whole reason CR-06 exists.
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"^def shell_unquoted\(line\):\n(?:(?:[ \t].*)?\n)+", source, re.M)
assert match, "shell_unquoted() is no longer extractable from the pin above"
namespace = {}
exec(compile(match.group(0), "shell_unquoted", "exec"), namespace)
shell_unquoted = namespace["shell_unquoted"]

must_flag = [
    'PYTHONPATH="$STUB" python3 - "$arg" <<\'X\'',
    'env FOO=1 python3 -c "pass"',
    'timeout 30 python3 -c "pass"',
    'command python3 -c "pass"',
    'exec python3 -c "pass"',
    '  out="$(python3 -c "pass")"',
    '  out=`python3 -c "pass"`',
    '  if python3 -c "pass"; then :; fi',
]
must_not_flag = [
    """    printf 'no usable python3 (bin/firm-python resolves it)\\n' >&2""",
    """  printf '  Install python3 (a declared firm prerequisite, see docs/INSTALL.md)\\n' >&2""",
    '''    "A heredoc body fed to a NON-shell (python3 <<'X' ... X) is skipped, so a `git push` line",''',
]
missed = [line for line in must_flag if "python3" not in shell_unquoted(line)]
assert not missed, missed
false_positives = [line for line in must_not_flag if "python3" in shell_unquoted(line)]
assert not false_positives, false_positives
PY
assert_ok "every fixture root that installs a resolver-dependent tool also installs the resolver" \
  t_python - "$BIN" "$TESTS_DIR" <<'PY'
import pathlib, re, sys
bin_dir, tests_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
# CR-03: six test files build a "minimum firm root" by copying a handful of bin/firm-* into a scratch
# bin/. Every one of those tools sources its sibling firm-python on the way in, so a root without it
# dies on line 10 with "No such file or directory" and rc 1 -- and rc 1 is what the fail-closed
# assertions in those files EXPECT, so four assertions in tests/test-bootstrap-dual.sh passed for two
# commits without reaching the code they name. Seven call sites across six files have to remember the
# same sibling; this is the check that remembers for them.
#
# Method: group `cp`/`ln`/`install` lines by the DIRECTORY they write a firm-* into (source paths
# under $BIN/$SELF/$FIRM_ROOT/bin are not deliveries), and require any directory that receives a
# resolver-dependent tool to receive firm-python too. Line continuations are not followed, which is
# a false-NEGATIVE only; nothing here can turn a real miss into a pass.
# Two spellings of the same source line are in use: `. "$SELF/firm-python"` and the inline
# `. "$(cd -P "$(dirname "$__src")" && pwd)/firm-python"`. Match on the trailing path either way.
sources_python = re.compile(r'^\s*\.\s+\S.*?/firm-python"', re.M)
needs = {path.name for path in bin_dir.glob("firm-*")
         if path.name != "firm-python" and sources_python.search(path.read_text())}
assert {"firm-bootstrap", "firm-bounded-exec", "firm-merge-guard"} <= needs, sorted(needs)
SOURCE_DIRS = {"$BIN", "$SELF", "$FIRM_ROOT/bin", "$ROOT/bin"}
place = re.compile(r"""["']([^"'\n]*?)/(firm-[A-Za-z0-9-]+)["']""")
delivered, wants = set(), {}
for path in sorted(tests_dir.glob("*.sh")):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#") or not re.match(r"(cp|ln|install)\b", stripped):
            continue
        for target_dir, tool in place.findall(line):
            if target_dir in SOURCE_DIRS:
                continue
            key = (path.name, target_dir)
            if tool == "firm-python":
                delivered.add(key)
            elif tool in needs:
                wants.setdefault(key, []).append((number, tool))
missing = {key: hits for key, hits in wants.items() if key not in delivered}
assert not missing, missing
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
# INDENTED, i.e. inside _mg_python_ready rather than at top level. The exact indent is not the
# claim -- it was 4 spaces while the source sat inside an `if`, and that `if` was itself the SEC-03
# fail-open, so pinning the column would have made removing the vulnerability look like a regression.
assert sources[0][:1].isspace(), sources
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
