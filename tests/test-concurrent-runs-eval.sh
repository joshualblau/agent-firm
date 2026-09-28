#!/usr/bin/env bash
# tests/test-concurrent-runs-eval.sh — runs the concurrent-runs-one-checkout golden eval's own check
# against THIS checkout, and proves the check has teeth by mutating the tools it guards.
#
# WHY THIS FILE EXISTS AT ALL, GIVEN THE EVAL EXISTS
# CI runs `firm-run-evals --structural`, which validates that every eval has a task, a fixture and a
# parseable assertions.yaml — and deliberately executes no assertion payload. So the golden check
# inside agent-firm/evals/concurrent-runs-one-checkout/ would never actually RUN in CI without this
# file. `test_passes: sh test/run-tests.sh` only fires during a real
# `firm-run-evals --provider <p> concurrent-runs-one-checkout`, which needs a subscription login and
# is never run in CI. An eval that only runs when someone spends money is not a regression guard.
#
# WHY THE MUTATION CASES ARE THE POINT
# AC-012 does not ask for an eval that passes. It asks for one that FAILS if the concurrent-run
# property asserted by AC-002 and AC-004 regresses. That is a claim about what the check does to a
# BROKEN tool, and the only honest way to assert it is to break one. Each case below copies the
# firm's bin/ to a scratch root, applies one targeted edit, points the check at that root, and
# requires it to go red naming the property that regressed. The blast radius is asserted too: the
# ledger-attribution mutation must turn the LEDGER assertions red and leave the merge-target ones
# green, because a check that fails at everything whenever anything changes localises nothing.
#
# Each mutation names the exact source line it replaces and requires it to occur EXACTLY ONCE. If
# firm-integrate or firm-qa-checkout is refactored so the line no longer matches, this file fails
# loudly rather than mutating nothing and then reporting that a no-op mutant was "caught".
#
# UNSUPPORTED LEDGER HOSTS. Four of the check's assertions need a real ledger write (P1.9, P2.7, P3.1,
# P3.7), and firm-ledger-log refuses every write outside a proven P2 row -- which includes the hosted
# CI runners, by design. There the clean case requires exactly those four to fail, each for that
# reason, and every other assertion to pass; the ledger-attribution mutant, which is only
# distinguishable through a ledger write, is skipped. The full contract still runs on a P2 row.
#
# RUNTIME. The full check is ~22s (it parks a real process inside a real merge loop and drives
# another to completion). The mutation cases use `--only` to run just the property each one targets,
# so this file lands around a minute rather than two.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVAL_DIR="$FIRM_ROOT/agent-firm/evals/concurrent-runs-one-checkout"
CHECK="$EVAL_DIR/fixture/test/concurrent-runs-check.py"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/firm-conc-out.XXXXXX")"; t_track "$OUT"

# ledger_writes_supported — t_p2_row_supported, but also false under firm-ledger-log's own guarded
# rejection seam, so the unsupported-host path can be exercised on a P2 host:
#   FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=linux bash tests/test-concurrent-runs-eval.sh
ledger_writes_supported() {
  [ "${FIRM_LEDGER_TEST_GUARD:-}" = 1 ] && [ -n "${FIRM_LEDGER_P2_TEST_REJECT:-}" ] && return 1
  t_p2_row_supported
}

# run_check <outfile> <firm-root> [args...] — run the golden check, capture everything, echo the rc
# into the file so later assertions can read it from the same place as the output.
run_check() {
  local dest="$1" root="$2"; shift 2
  FIRM_CONCURRENT_RUNS_ROOT="$root" t_python "$CHECK" "$@" > "$dest" 2>&1
  printf 'check-rc=%s\n' "$?" >> "$dest"
}

# mk_mutant <tool> <old-line> <new-line> — a firm root whose bin/ is a copy of this checkout's with
# ONE line replaced. Sibling top-level directories are symlinked, so templates and schemas resolve to
# the real ones and the only difference from the checkout under test is the mutation.
mk_mutant() {
  local tool="$1" old="$2" new="$3" m
  m="$(mktemp -d "${TMPDIR:-/tmp}/firm-conc-mutant.XXXXXX")" || return 1
  t_track "$m"
  cp -R "$FIRM_ROOT/bin" "$m/bin" || return 1
  local e
  for e in agent-firm agents commands docs hooks bench codex-skills VERSION; do
    [ -e "$FIRM_ROOT/$e" ] && ln -s "$FIRM_ROOT/$e" "$m/$e"
  done
  t_python - "$m/bin/$tool" "$old" "$new" <<'PY' >&2 || return 1
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
seen = text.count(old)
if seen != 1:
    raise SystemExit(
        "mutation target occurs %d time(s), expected exactly 1 -- the source has been refactored "
        "and this mutation no longer means what it says: %r" % (seen, old))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
  printf '%s' "$m"
}

# ---------------------------------------------------------------------------
t_case "the eval's directory has the three parts firm-run-evals requires, and its suite command is allow-listed"
assert_file "task.md"        "$EVAL_DIR/task.md"
assert_file "assertions.yaml" "$EVAL_DIR/assertions.yaml"
assert_file "fixture/"        "$EVAL_DIR/fixture"
assert_file "the golden check itself" "$CHECK"
assert_file "the fixture suite entry point" "$EVAL_DIR/fixture/test/run-tests.sh"
assert_ok "firm-run-evals --structural accepts it" \
  "$BIN/firm-run-evals" --structural concurrent-runs-one-checkout
# The README's standing warning: a fixture's test command must be an EXACT allow-listed rule in
# firm-run-evals, or the agent inside the eval cannot execute it. assertions.yaml says
# `sh test/run-tests.sh`, so that exact string has to be in --allowedTools.
assert_output "the fixture's suite command is exactly the allow-listed rule" \
  "Bash(sh test/run-tests.sh)" cat "$BIN/firm-run-evals"
assert_output "assertions.yaml invokes that same command and no variant of it" \
  "test_passes: sh test/run-tests.sh" cat "$EVAL_DIR/assertions.yaml"

# ---------------------------------------------------------------------------
t_case "the golden check PASSES against this checkout, and its pass includes the overlap evidence"
run_check "$OUT/clean.txt" "$FIRM_ROOT"
if ledger_writes_supported; then
  assert_output "it exits 0" "check-rc=0" cat "$OUT/clean.txt"
  assert_output "…and says so in its own words" "CONCURRENT-RUNS CHECK: PASS" cat "$OUT/clean.txt"
  assert_eq "no assertion failed" "0" "$(grep -c '^FAIL:' "$OUT/clean.txt")"
  assert_eq "all 36 assertions ran" "36" "$(grep -c '^ok  :' "$OUT/clean.txt")"
else
  # Not a skip: the ledger must refuse, and it must be the ONLY thing that fails.
  assert_output "it exits 1 on a host outside every P2 row" "check-rc=1" cat "$OUT/clean.txt"
  assert_eq "exactly the four ledger-bound assertions fail" "P1.9 P2.7 P3.1 P3.7" \
    "$(sed -n 's/^FAIL: \(P[0-9.]*\) .*/\1/p' "$OUT/clean.txt" | tr '\n' ' ' | sed 's/ $//')"
  assert_output "…because the ledger refused the write, not for any other reason" \
    "WRITE_CONFIGURATION_UNSUPPORTED: p2" cat "$OUT/clean.txt"
  assert_eq "every other assertion passes" "32" "$(grep -c '^ok  :' "$OUT/clean.txt")"
fi
# A green run whose overlap assertions did not run would be the sequential fixture AC-012 forbids,
# wearing a passing exit code. These three are the ones a sequential fixture cannot satisfy, so the
# pass is only worth anything if they are among the passes.
assert_output "P1's overlap was proven, not assumed" \
  "ok  : P1.2 the two runs genuinely overlapped" cat "$OUT/clean.txt"
assert_output "P2's overlap likewise" \
  "ok  : P2.2 the two runs genuinely overlapped" cat "$OUT/clean.txt"
assert_output "P3's overlap likewise" \
  "ok  : P3.2 the two captures genuinely overlapped" cat "$OUT/clean.txt"
assert_output "the rollback residual (AC-011) was exercised, not just described" \
  "ok  : P4.3 \`git worktree remove\` takes it cleanly" cat "$OUT/clean.txt"

# ---------------------------------------------------------------------------
t_case "it fails CLOSED rather than passing when it cannot evaluate"
empty="$(mktemp -d "${TMPDIR:-/tmp}/firm-conc-empty.XXXXXX")"; t_track "$empty"
# PATH is narrowed so an installed ~/.local/bin/firm-* cannot rescue the lookup: the case is about
# what happens when there is genuinely no firm to test, and a host that happens to have one on PATH
# must not silently turn this into a different case.
assert_rc "no firm at all is exit 2, not a pass" 2 \
  env PATH=/usr/bin:/bin FIRM_CONCURRENT_RUNS_ROOT="$empty" python3 "$CHECK"
assert_output "…and it names what it could not find" "cannot locate a firm checkout" \
  env PATH=/usr/bin:/bin FIRM_CONCURRENT_RUNS_ROOT="$empty" python3 "$CHECK"
assert_rc "an unknown --only property is exit 2, not a silent empty run" 2 \
  env FIRM_CONCURRENT_RUNS_ROOT="$FIRM_ROOT" python3 "$CHECK" --only p9
assert_rc "an unknown argument is exit 2" 2 \
  env FIRM_CONCURRENT_RUNS_ROOT="$FIRM_ROOT" python3 "$CHECK" --not-a-flag

# ---------------------------------------------------------------------------
t_case "MUTANT · the merge loop back on the caller's working tree (the F2 hazard, reintroduced)"
# This is the defect WO-4 removed: merging where the CALLER's HEAD points instead of in the run's own
# integration worktree. AC-004 exists for exactly this, so the check must not survive it.
m1="$(mk_mutant firm-integrate \
      'if git -C "$int_dir" merge --no-edit "$b"' \
      'if git -C "$repo" merge --no-edit "$b"')"
assert_ne "the mutant root was built" "" "$m1"
if [ -n "$m1" ]; then
  run_check "$OUT/m1.txt" "$m1" --only p1
  assert_output "the check goes red" "check-rc=1" cat "$OUT/m1.txt"
  assert_output "…and refuses to report a pass" "CONCURRENT-RUNS CHECK: FAIL" cat "$OUT/m1.txt"
  assert_output "…naming run A's merges as the thing that moved" \
    "P1.3 run A's merges all landed on run A's own integration branch" cat "$OUT/m1.txt"
  assert_output "…and the caller's own HEAD as what received them" \
    "P1.7 the caller's own HEAD was not written through" cat "$OUT/m1.txt"
fi

# ---------------------------------------------------------------------------
t_case "MUTANT · the ledger call loses its explicit --run (F3: right merge, wrong run's evidence)"
# The half of AC-002 that is easiest to lose and hardest to notice, because the merge still looks
# correct. The blast radius is asserted as well as the failure: this must turn the LEDGER assertions
# red and leave the merge-target ones green.
m2="$(mk_mutant firm-integrate \
      '"$SELF/firm-ledger-log" --run "$run_dir" integrated' \
      '"$SELF/firm-ledger-log" integrated')"
assert_ne "the mutant root was built" "" "$m2"
if [ -n "$m2" ] && ! ledger_writes_supported; then
  # With every ledger write refused, the correct tool and this mutant record the same nothing.
  t_skip "ledger-attribution mutant" "requires a supported P2 ledger write host"
elif [ -n "$m2" ]; then
  run_check "$OUT/m2.txt" "$m2" --only p1,p2
  assert_output "the check goes red" "check-rc=1" cat "$OUT/m2.txt"
  assert_output "…naming the ambient-pointer attribution under the zero-argument form" \
    "FAIL: P1.9 each run's integration event is recorded in that run's own ledger" cat "$OUT/m2.txt"
  assert_output "…and the same thing under the explicit selector" \
    "FAIL: P2.7 each run's integration event is recorded in that run's own ledger" cat "$OUT/m2.txt"
  assert_output "…and the decoy run receiving evidence it never asked for" \
    "FAIL: P2.8 the ambient pointer's run received nothing at all" cat "$OUT/m2.txt"
  assert_output "the merges themselves are still correct, so the failure LOCALISES" \
    "ok  : P1.3 run A's merges all landed on run A's own integration branch" cat "$OUT/m2.txt"
  assert_output "…and the caller's HEAD is still untouched" \
    "ok  : P1.7 the caller's own HEAD was not written through" cat "$OUT/m2.txt"
fi

# ---------------------------------------------------------------------------
t_case "MUTANT · firm-qa-checkout's explicit selector falls back to the ambient pointer"
# AC-001: the explicit selector must be sufficient ON ITS OWN. A --run that quietly defers to
# CURRENT_RUN is the shape this whole item exists to remove, and it is invisible whenever the two
# happen to agree — so the fixture makes them disagree.
m3="$(mk_mutant firm-qa-checkout \
      'run_dir="$(firm_run_resolve --run "$run_sel")"' \
      'run_dir="$(firm_run_resolve)"')"
assert_ne "the mutant root was built" "" "$m3"
if [ -n "$m3" ]; then
  run_check "$OUT/m3.txt" "$m3" --only p3
  assert_output "the check goes red" "check-rc=1" cat "$OUT/m3.txt"
  assert_output "…naming the capture that could not be reached" \
    "FAIL: P3.2 the two captures genuinely overlapped" cat "$OUT/m3.txt"
  assert_output "…and quoting the tool's own words rather than just an exit code" \
    "The tool's own output was:" cat "$OUT/m3.txt"
  # The assertions downstream of a broken rendezvous are reported as NOT EVALUATED and counted as
  # failures. That is the property that keeps an unrun check from reading as a passing one.
  assert_output "downstream assertions are counted as failures, not skipped" \
    "NOT EVALUATED" cat "$OUT/m3.txt"
  assert_output "…and say so explicitly" "counted as a failure, never as a pass" cat "$OUT/m3.txt"
fi

t_summary
