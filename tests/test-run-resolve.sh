#!/usr/bin/env bash
# tests/test-run-resolve.sh — bin/firm-run-resolve is the ONE run resolver the firm's tools call.
#
# It replaces five hand-copied spellings of the same containment check, so a defect here is a defect
# in every caller at once — which is exactly why the consolidation is worth testing harder than any
# one of the copies was. Three properties carry the weight:
#
#   1. PRECEDENCE. An explicit --run is authoritative and CURRENT_RUN is not consulted at all. The
#      failure this closes is not "wrong answer" but "right answer for the wrong run": a tool that
#      quietly prefers the ambient pointer produces a valid-looking artifact bound to another run.
#   2. FAIL CLOSED, AUDIBLY (AC-007). Every refusal names the specific violation and exits non-zero
#      with NOTHING on stdout. A resolver that exits 0 having resolved nothing hands its caller an
#      empty string, and an empty string concatenated into a path is a write somewhere else.
#   3. CONTAINMENT (AC-008). Symlinked, foreign-owned, non-directory, out-of-tree and unsafely named
#      selectors are refused — and refused for the EXPLICIT selector exactly as for the ambient one,
#      since a new front door that skips the lock is the whole hazard of adding a flag.
#
# Every case builds its own throwaway repo via mk_repo, so nothing here touches the real checkout.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVE="$BIN/firm-run-resolve"
RUN_A="20260907T000000Z-run-alpha"
RUN_B="20260907T000000Z-run-bravo"

# resolve <repo> [args...] — run the tool from inside <repo>. stdout AND stderr, for assert_rc.
resolve() { local _r="$1"; shift; ( cd "$_r" && "$RESOLVE" "$@" ); }
# resolve_out <repo> [args...] — stdout ONLY, so an assertion about the answer cannot be satisfied
# by a diagnostic that happens to contain the path.
resolve_out() { local _r="$1"; shift; ( cd "$_r" && "$RESOLVE" "$@" 2>/dev/null ); }
# physical <dir> — the spelling the resolver promises to print. mk_repo hands back a $TMPDIR path,
# and on macOS $TMPDIR is reached through /var -> /private/var, so the fixture path and the physical
# path are two spellings of one directory. Comparing against the wrong one makes every case red for
# a reason that has nothing to do with the code under test.
physical() { ( cd "$1" && pwd -P ); }

# mk_two_runs <repo> — run A and run B both exist; CURRENT_RUN names B. Echoes nothing.
mk_two_runs() {
  mk_run "$1" "$RUN_B"                        # writes .agent-firm/CURRENT_RUN -> run B
  mkdir -p "$1/.agent-firm/runs/$RUN_A"
}

# ---------------------------------------------------------------------------
t_case "an explicit --run wins over a PRESENT but different CURRENT_RUN"
# The core precedence property. CURRENT_RUN is not merely a weaker input here — it must not be
# consulted at all, which is why run B is present and valid rather than absent.
repo1="$(mk_repo)"; mk_two_runs "$repo1"; real1="$(physical "$repo1")"
assert_eq "resolves run A, the one --run named" \
  "$real1/.agent-firm/runs/$RUN_A" "$(resolve_out "$repo1" --run ".agent-firm/runs/$RUN_A")"
assert_eq "fixture precondition: CURRENT_RUN really does name the OTHER run" \
  ".agent-firm/runs/$RUN_B" "$(cat "$repo1/.agent-firm/CURRENT_RUN")"
assert_eq "the zero-argument form resolves run B, so the two really are different answers" \
  "$real1/.agent-firm/runs/$RUN_B" "$(resolve_out "$repo1")"
assert_eq "an ABSOLUTE --run is honoured the same way" \
  "$real1/.agent-firm/runs/$RUN_A" "$(resolve_out "$repo1" --run "$repo1/.agent-firm/runs/$RUN_A")"

t_case "--run is still authoritative when CURRENT_RUN is absent entirely (AC-001's scenario)"
# The exact shape AC-001 states, and the gap that made the source run hand-substitute a tool: no
# ambient pointer at all, and the explicit selector is sufficient on its own.
repo2="$(mk_repo)"; mk_two_runs "$repo2"; real2="$(physical "$repo2")"
rm -f "$repo2/.agent-firm/CURRENT_RUN"
assert_no_file "fixture precondition: there is no CURRENT_RUN" "$repo2/.agent-firm/CURRENT_RUN"
assert_eq "the explicit selector alone resolves" \
  "$real2/.agent-firm/runs/$RUN_A" "$(resolve_out "$repo2" --run ".agent-firm/runs/$RUN_A")"
assert_no_file "and resolving did not create the pointer it did not need" \
  "$repo2/.agent-firm/CURRENT_RUN"

t_case "the zero-argument form reads and validates CURRENT_RUN"
repo3="$(mk_repo)"; mk_run "$repo3" "$RUN_A"; real3="$(physical "$repo3")"
assert_eq "resolves the run CURRENT_RUN names" \
  "$real3/.agent-firm/runs/$RUN_A" "$(resolve_out "$repo3")"
assert_eq "and works from a subdirectory, because the pointer is read at the repository root" \
  "$real3/.agent-firm/runs/$RUN_A" \
  "$( mkdir -p "$repo3/sub" && cd "$repo3/sub" && "$RESOLVE" 2>/dev/null )"

# ---------------------------------------------------------------------------
# AC-007 · fail closed, and say which ambiguity. Each case asserts THREE things, because two of them
# are the ones that actually bite: a non-zero exit, an empty stdout (an empty string concatenated
# into a path by a caller is a write somewhere else), and a message that distinguishes this failure
# from the others rather than a generic "could not resolve".
# ---------------------------------------------------------------------------
t_case "AC-007 · absent CURRENT_RUN with no --run fails closed with a distinguishing message"
repo4="$(mk_repo)"; mkdir -p "$repo4/.agent-firm/runs/$RUN_A"
assert_rc "exit 2" 2 resolve "$repo4"
assert_eq "nothing on stdout" "" "$(resolve_out "$repo4")"
assert_output "names the missing pointer and the two ways out" "does not exist" resolve "$repo4"
assert_output "names --run as the remedy" "pass --run <run-dir>" resolve "$repo4"
assert_eq "it did NOT silently pick the one run that happens to exist" "" "$(resolve_out "$repo4")"

t_case "AC-007 · an EMPTY CURRENT_RUN is refused rather than treated as absent-or-anything"
repo5="$(mk_repo)"; mk_run "$repo5" "$RUN_A"
: > "$repo5/.agent-firm/CURRENT_RUN"
assert_rc "exit 2" 2 resolve "$repo5"
assert_output "says it is empty, not that it is missing" "is empty" resolve "$repo5"

t_case "AC-007 · an UNREADABLE CURRENT_RUN is distinguished from an absent one"
repo6="$(mk_repo)"; mk_run "$repo6" "$RUN_A"
chmod 000 "$repo6/.agent-firm/CURRENT_RUN"
if [ "$(id -u)" = "0" ]; then
  t_skip "unreadable CURRENT_RUN is refused" \
    "running as uid 0, which can read a mode-000 file, so this refusal is not constructible here"
else
  assert_rc "exit 2" 2 resolve "$repo6"
  assert_output "says it could not be READ, not that it is missing" "could not be read" resolve "$repo6"
fi
chmod 644 "$repo6/.agent-firm/CURRENT_RUN"

t_case "AC-007 · an EMPTY --run is refused and does NOT fall back to a valid CURRENT_RUN"
# The most dangerous shape of all: a caller that computed its selector wrong gets the ambient run's
# artifacts, correctly formed and bound to the wrong run. Refusing is the only safe answer.
repo7="$(mk_repo)"; mk_two_runs "$repo7"
assert_rc "exit 2" 2 resolve "$repo7" --run ""
assert_eq "nothing on stdout — it did not quietly resolve run B" "" "$(resolve_out "$repo7" --run "")"
assert_output "says why it refuses to fall back" "refusing to fall back" resolve "$repo7" --run ""

t_case "AC-007 · usage failures are named, not swallowed"
repo8="$(mk_repo)"; mk_run "$repo8" "$RUN_A"
assert_rc "--run with no value" 2 resolve "$repo8" --run
assert_output "…says the flag needs an argument" "--run needs a run directory" resolve "$repo8" --run
assert_rc "--run=<dir> (the wrong spelling) is refused" 2 resolve "$repo8" --run=".agent-firm/runs/$RUN_A"
assert_output "…and names the accepted spelling instead of 'unknown option'" \
  "two words" resolve "$repo8" --run=".agent-firm/runs/$RUN_A"
assert_rc "an unknown option" 2 resolve "$repo8" --bogus
assert_rc "a stray positional argument" 2 resolve "$repo8" extra
assert_output "outside a git repository it says so" "not a git repository" \
  sh -c "cd / && '$RESOLVE' 2>&1"

# ---------------------------------------------------------------------------
# AC-008 · containment. Every case below applies the violation to the EXPLICIT selector, because the
# ambient path already had these checks — the risk this work order introduces is a new front door
# that skips them.
# ---------------------------------------------------------------------------
t_case "AC-008 · a symlinked run directory is refused"
repo9="$(mk_repo)"; mk_run "$repo9" "$RUN_A"
elsewhere9="$(mktemp -d "${TMPDIR:-/tmp}/firm-rr-elsewhere.XXXXXX")"; t_track "$elsewhere9"
printf 'sentinel\n' > "$elsewhere9/PRECIOUS.txt"
ln -s "$elsewhere9" "$repo9/.agent-firm/runs/linked"
assert_rc "exit 2" 2 resolve "$repo9" --run ".agent-firm/runs/linked"
assert_output "says it is a symlink" "is a symlink" resolve "$repo9" --run ".agent-firm/runs/linked"
assert_eq "nothing on stdout" "" "$(resolve_out "$repo9" --run ".agent-firm/runs/linked")"
assert_file "and the symlink target was not touched" "$elsewhere9/PRECIOUS.txt"

t_case "AC-008 · a symlink ANYWHERE on the path is refused, not just the final component"
# The final-component check is the one people write; an intermediate symlink is the one that gets
# missed, and it is the stronger vector — it relocates the whole runs/ tree at once.
repo10="$(mk_repo)"; mk_run "$repo10" "$RUN_A"
elsewhere10="$(mktemp -d "${TMPDIR:-/tmp}/firm-rr-runsdir.XXXXXX")"; t_track "$elsewhere10"
mkdir -p "$elsewhere10/$RUN_A"
mv "$repo10/.agent-firm/runs" "$repo10/.agent-firm/runs.real"
ln -s "$elsewhere10" "$repo10/.agent-firm/runs"
assert_rc "a symlinked runs/ directory is refused" 2 resolve "$repo10" --run ".agent-firm/runs/$RUN_A"
assert_output "…and says which component" "runs directory" resolve "$repo10" --run ".agent-firm/runs/$RUN_A"
rm "$repo10/.agent-firm/runs"; mv "$repo10/.agent-firm/runs.real" "$repo10/.agent-firm/runs"
mv "$repo10/.agent-firm" "$repo10/.agent-firm.real"
ln -s "$repo10/.agent-firm.real" "$repo10/.agent-firm"
assert_rc "a symlinked .agent-firm/ directory is refused" 2 resolve "$repo10" --run ".agent-firm/runs/$RUN_A"
assert_rc "…and so is the zero-argument form, which would otherwise read a pointer through it" \
  2 resolve "$repo10"
rm "$repo10/.agent-firm"; mv "$repo10/.agent-firm.real" "$repo10/.agent-firm"
assert_eq "control: with the symlinks removed the same selector resolves" \
  "$(physical "$repo10")/.agent-firm/runs/$RUN_A" "$(resolve_out "$repo10" --run ".agent-firm/runs/$RUN_A")"

t_case "AC-008 · a symlinked CURRENT_RUN is refused rather than followed"
repo11="$(mk_repo)"; mk_run "$repo11" "$RUN_A"
mv "$repo11/.agent-firm/CURRENT_RUN" "$repo11/.agent-firm/pointer.real"
ln -s "$repo11/.agent-firm/pointer.real" "$repo11/.agent-firm/CURRENT_RUN"
assert_rc "exit 2" 2 resolve "$repo11"
assert_output "says it refuses to follow it" "refusing to follow" resolve "$repo11"

t_case "AC-008 · a run directory outside .agent-firm/runs/ is refused"
repo12="$(mk_repo)"; mk_run "$repo12" "$RUN_A"
mkdir -p "$repo12/.agent-firm/runs-elsewhere/$RUN_A" "$repo12/notruns/$RUN_A"
assert_rc "a sibling named runs-elsewhere is refused (a prefix match would accept it)" \
  2 resolve "$repo12" --run ".agent-firm/runs-elsewhere/$RUN_A"
assert_rc "a directory outside .agent-firm entirely is refused" 2 resolve "$repo12" --run "notruns/$RUN_A"
assert_rc ".agent-firm itself is not a run" 2 resolve "$repo12" --run ".agent-firm"
assert_output "names the required shape" "<repo>/.agent-firm/runs/<run-id>" \
  resolve "$repo12" --run "notruns/$RUN_A"

t_case "AC-008 · a well-formed run belonging to a DIFFERENT checkout is refused"
# Shape alone is satisfied — it really is <somewhere>/.agent-firm/runs/<safe-id>, owned by this uid,
# with no symlink anywhere. Only the identity check stands in front of it.
repo13="$(mk_repo)"; mk_run "$repo13" "$RUN_A"
other13="$(mk_repo)"; mk_run "$other13" "$RUN_B"
assert_rc "exit 2" 2 resolve "$repo13" --run "$other13/.agent-firm/runs/$RUN_B"
assert_output "says it is outside this working tree" "outside this working tree" \
  resolve "$repo13" --run "$other13/.agent-firm/runs/$RUN_B"
assert_eq "control: the same selector resolves from inside its OWN checkout" \
  "$(physical "$other13")/.agent-firm/runs/$RUN_B" "$(resolve_out "$other13" --run "$other13/.agent-firm/runs/$RUN_B")"

t_case "AC-008 · lexical traversal is rejected before normalization"
# abspath() collapses "..", so a check applied after it sees this as innocent. Pinned for the
# resolver for the same reason tests/test-qa-checkout.sh pins it for the tool being replaced.
repo14="$(mk_repo)"; mk_run "$repo14" "$RUN_A"
assert_rc "a contained-LOOKING traversal is refused" 2 \
  resolve "$repo14" --run ".agent-firm/runs/../runs/$RUN_A"
assert_output "says which component it objects to" "traversal component" \
  resolve "$repo14" --run ".agent-firm/runs/../runs/$RUN_A"
assert_rc "and an escaping traversal is refused too" 2 resolve "$repo14" --run ".agent-firm/runs/../../.."

t_case "AC-008 · an unsafe run id is refused"
repo15="$(mk_repo)"; mk_run "$repo15" "$RUN_A"
mkdir -p "$repo15/.agent-firm/runs/-leading-dash" "$repo15/.agent-firm/runs/has space" \
         "$repo15/.agent-firm/runs/.hidden"
assert_rc "a leading dash is refused" 2 resolve "$repo15" --run ".agent-firm/runs/-leading-dash"
assert_rc "a space is refused"        2 resolve "$repo15" --run ".agent-firm/runs/has space"
assert_rc "a leading dot is refused"  2 resolve "$repo15" --run ".agent-firm/runs/.hidden"
assert_output "names the pattern so the caller can fix the id" "safe-id pattern" \
  resolve "$repo15" --run ".agent-firm/runs/-leading-dash"

t_case "AC-008 · a run selector that is not a directory is refused"
repo16="$(mk_repo)"; mk_run "$repo16" "$RUN_A"
: > "$repo16/.agent-firm/runs/plainfile"
assert_rc "a regular file in runs/ is refused" 2 resolve "$repo16" --run ".agent-firm/runs/plainfile"
assert_output "says it is not a directory" "is not a directory" \
  resolve "$repo16" --run ".agent-firm/runs/plainfile"
assert_rc "a run directory that does not exist is refused" 2 \
  resolve "$repo16" --run ".agent-firm/runs/never-created"
assert_output "…and says so, rather than reporting a containment violation" "does not exist" \
  resolve "$repo16" --run ".agent-firm/runs/never-created"

t_case "AC-008 · a run directory not owned by the invoking uid is refused"
repo17="$(mk_repo)"; mk_run "$repo17" "$RUN_A"
if [ "$(id -u)" = "0" ]; then
  # Only constructible as root, and only then because root can hand a directory to another uid.
  foreign17="$repo17/.agent-firm/runs/foreign-owned"
  mkdir -p "$foreign17" && chown 65534 "$foreign17" 2>/dev/null
  if [ "$(t_python -c 'import os,sys; print(os.lstat(sys.argv[1]).st_uid)' "$foreign17")" = "65534" ]; then
    assert_rc "a foreign-owned run directory is refused" 2 \
      resolve "$repo17" --run ".agent-firm/runs/foreign-owned"
    assert_output "…and names the uid mismatch" "not the invoking uid" \
      resolve "$repo17" --run ".agent-firm/runs/foreign-owned"
  else
    t_skip "foreign-owned run directory is refused" \
      "running as uid 0 but chown to 65534 did not take on this filesystem"
  fi
else
  t_skip "foreign-owned run directory is refused" \
    "this host cannot construct a directory owned by another uid without root; the structural backstop below stands in for it"
fi

# A STRUCTURAL backstop for the one check this host cannot exercise, and its limits stated rather
# than implied. Measured with a mutation harness: deleting any other check in this file turns at
# least one case above red, and deleting the ownership comparison turned NOTHING red — a printed
# SKIP announces that a claim went unexamined, but it does not notice when the claim stops being
# true. So the ownership refusal is asserted where it can be: in the source, by parsing the embedded
# validator rather than grepping it, so a rename or a reformat cannot make this quietly decorative.
#
# WHAT IT PROVES: that the component loop still enumerates all four path components and still
# refuses on a uid mismatch. WHAT IT DOES NOT PROVE: that the refusal WORKS. Only a second uid can
# prove that, and the root branch above is where it happens on a host that has one.
struct17="$(mktemp -d "${TMPDIR:-/tmp}/firm-rr-struct.XXXXXX")"; t_track "$struct17"
t_python - "$RESOLVE" > "$struct17/report.txt" 2>&1 <<'PY'
import ast
import sys

source = open(sys.argv[1], encoding="utf-8").read()
marker = "_FIRM_RUN_RESOLVE_PY <<"
start = source.index("\n", source.index(marker)) + 1
program = source[start:source.index("\nPY\n", start)]

found = None
for node in ast.walk(ast.parse(program)):
    if not isinstance(node, ast.For) or not isinstance(node.iter, ast.Tuple):
        continue
    labels = []
    for element in node.iter.elts:
        if isinstance(element, ast.Tuple) and len(element.elts) == 2:
            value = element.elts[1]
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                labels.append(value.value)
    if labels:
        found = (node, labels)

if found is None:
    print("no component-validation loop found")
    raise SystemExit(0)
loop, labels = found
expected = ["repository root", ".agent-firm directory", "runs directory", "run directory"]
if labels != expected:
    print("component loop covers " + repr(labels) + ", expected " + repr(expected))
    raise SystemExit(0)
# The CONDITION, not the statement. Dumping the whole `if` body passes a mutant that neuters the
# test to `if False:` and leaves the unreachable message referencing st_uid -- measured, and it is
# how this assertion first went decorative. What has to hold is that some branch in the loop is
# TAKEN on a uid mismatch and refuses there.
guarded = False
for statement in loop.body:
    if not isinstance(statement, ast.If):
        continue
    condition = ast.dump(statement.test)
    if "st_uid" not in condition or "NotEq" not in condition:
        continue
    if "invoking uid" in "".join(ast.dump(inner) for inner in statement.body):
        guarded = True
if not guarded:
    print("no branch in the component loop refuses on a st_uid mismatch")
    raise SystemExit(0)
print("ok")
PY
assert_eq "the ownership refusal is still applied to all four path components" \
  "ok" "$(cat "$struct17/report.txt")"

# ---------------------------------------------------------------------------
t_case "AC-009 · resolving creates nothing and widens no access"
# The resolver's whole job is to answer a question. A resolver that MATERIALIZES what it was asked
# about turns a typo into a new run directory, and a subsequent tool into a writer to it.
repo18="$(mk_repo)"; mk_run "$repo18" "$RUN_A"
before18="$(ls -A "$repo18/.agent-firm" | sort | tr '\n' ' ')"
runs_before18="$(ls -A "$repo18/.agent-firm/runs" | sort | tr '\n' ' ')"
mode_before18="$(t_file_mode "$repo18/.agent-firm/runs/$RUN_A")"
resolve "$repo18" >/dev/null 2>&1
resolve "$repo18" --run ".agent-firm/runs/does-not-exist" >/dev/null 2>&1
resolve "$repo18" --run ".agent-firm/runs/$RUN_A" >/dev/null 2>&1
assert_eq "nothing was created in .agent-firm/" "$before18" "$(ls -A "$repo18/.agent-firm" | sort | tr '\n' ' ')"
assert_eq "nothing was created in runs/, not even the run it was asked about" \
  "$runs_before18" "$(ls -A "$repo18/.agent-firm/runs" | sort | tr '\n' ' ')"
assert_eq "the run directory's mode is unchanged — nothing was chmod'd wider" \
  "$mode_before18" "$(t_file_mode "$repo18/.agent-firm/runs/$RUN_A")"
assert_no_file "the run it refused was NOT brought into existence" \
  "$repo18/.agent-firm/runs/does-not-exist"

t_case "the output is the canonical physical path, whichever spelling was asked for"
# A caller compares this answer against another tool's, so two spellings of one run must not produce
# two strings. macOS ships the symlinked-TMPDIR case by default; the explicit link makes the case
# behave identically on Linux.
repo19="$(mk_repo)"; mk_run "$repo19" "$RUN_A"; real19="$(physical "$repo19")"
alias19="$(mktemp -d "${TMPDIR:-/tmp}/firm-rr-alias.XXXXXX")"; t_track "$alias19"
ln -s "$real19" "$alias19/repo-link"
assert_eq "an absolute selector spelled through a symlinked ANCESTOR still resolves…" \
  "$real19/.agent-firm/runs/$RUN_A" \
  "$(resolve_out "$repo19" --run "$alias19/repo-link/.agent-firm/runs/$RUN_A")"
assert_eq "…to the physical path, not the spelling it was handed" \
  "$real19/.agent-firm/runs/$RUN_A" \
  "$(resolve_out "$repo19" --run "$alias19/repo-link/.agent-firm/runs/$RUN_A")"

t_case "the file is sourceable, and sourcing it defines firm_run_resolve without running anything"
# WO-2/WO-3/WO-5 consume it this way rather than as a subprocess, so the sourced form is part of the
# frozen interface and not an implementation detail.
repo20="$(mk_repo)"; mk_two_runs "$repo20"; real20="$(physical "$repo20")"
assert_eq "the sourced function returns the same answer as the command" \
  "$real20/.agent-firm/runs/$RUN_A" \
  "$( cd "$repo20" && /bin/bash -c ". '$RESOLVE'; firm_run_resolve --run .agent-firm/runs/$RUN_A" 2>/dev/null )"
assert_eq "sourcing alone prints nothing at all" \
  "" "$( cd "$repo20" && /bin/bash -c ". '$RESOLVE'" 2>&1 )"
assert_output "the sourced function fails closed the same way" "does not exist" \
  sh -c "cd '$repo20' && /bin/bash -c \". '$RESOLVE'; firm_run_resolve --run .agent-firm/runs/nope\" 2>&1"
assert_ok "sourcing it under set -euo pipefail does not abort the caller" \
  sh -c "cd '$repo20' && /bin/bash -c 'set -euo pipefail; . \"$RESOLVE\"; firm_run_resolve >/dev/null'"

t_summary
