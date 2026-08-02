#!/usr/bin/env bash
# tests/test-run-evals-structural.sh — firm-run-evals --structural: the one mode CI actually runs (no
# claude login, no spend). Model-driven `run_one` is exercised manually only, per the plan.
#
# firm-run-evals hardcodes its evals directory to THIS repo's agent-firm/evals/ (resolved from the
# script's own location, not parametrized by CWD or an env var), so the cases in the first half of
# this file run against the real eval directories.
#
# UPDATE (SEC-R15 section, second half): a synthetic evals tree IS reachable after all, without any
# new env var and without writing a broken fixture into the real, git-tracked agent-firm/evals/ --
# by giving the script a different location to resolve ITSELF from (mk_eval_root below copies it into
# a throwaway root). That is how the negative paths this header used to call untestable are now
# covered. The "BAD $name (structure)" path (a missing task.md/assertions.yaml/fixture/) is still not
# covered; mk_eval always builds a complete eval.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN_EVALS="$BIN/firm-run-evals"
EVALS_DIR="$FIRM_ROOT/agent-firm/evals"

# The real eval names, computed dynamically (not hardcoded) so this test doesn't silently go stale
# when PR 3 adds qa-blocks-broken-build or a later change adds/removes an eval.
real_eval_names() {
  for d in "$EVALS_DIR"/*/; do
    n="$(basename "$d")"
    [ "$n" = "README.md" ] && continue
    printf '%s\n' "$n"
  done
}

# ---------------------------------------------------------------------------
t_case "fixture precondition: the real evals directory looks like what this test assumes"
assert_ok "agent-firm/evals/ exists in this checkout" sh -c "[ -d '$EVALS_DIR' ]"
n_real="$(real_eval_names | wc -l | tr -d ' ')"
assert_ok "at least one real eval exists to test against" sh -c "[ '$n_real' -gt 0 ]"

# ---------------------------------------------------------------------------
t_case "--structural (no filter): walks every real eval, no model run, exits 0"
assert_rc "exits 0" 0 "$RUN_EVALS" --structural
out_all="$( "$RUN_EVALS" --structural 2>&1 )"
missing=0
for name in $(real_eval_names); do
  case "$out_all" in
    *"ok   $name"*) : ;;
    *) missing=1; echo "    (missing from output: $name)" ;;
  esac
done
assert_eq "every real eval is reported ok" 0 "$missing"
assert_output "summary line present" "all evals passed" "$RUN_EVALS" --structural

t_case "--structural does NOT invoke claude (no login/spend required, no envelope printed)"
assert_ok "no 'driving the firm headlessly' line (that's run_one's, not structural_check's)" \
  sh -c "! '$RUN_EVALS' --structural 2>&1 | grep -q 'driving the firm headlessly'"

# ---------------------------------------------------------------------------
t_case "--structural <name>: scopes to exactly that one eval"
# `real_eval_names | head -1` would close its read end after one line, SIGPIPE-ing the producer's
# later printf calls (harmless, but noisy "Broken pipe" stderr). Capture once, slice with sed instead.
all_names="$(real_eval_names)"
one_name="$(printf '%s\n' "$all_names" | sed -n '1p')"
out_one="$("$RUN_EVALS" --structural "$one_name" 2>&1)"
assert_rc "exits 0" 0 "$RUN_EVALS" --structural "$one_name"
case "$out_one" in
  *"ok   $one_name"*) _t_ok "the requested eval is reported" ;;
  *) _t_no "the requested eval is reported" "got: $(printf '%s' "$out_one" | tr '\n' ' ')" ;;
esac
# If there's a second real eval, confirm it was NOT processed when scoped to the first.
other_name="$(printf '%s\n' "$all_names" | sed -n '2p')"
if [ -n "$other_name" ]; then
  case "$out_one" in
    *"ok   $other_name"*) _t_no "a different eval was NOT also processed" "but it was: $other_name" ;;
    *) _t_ok "a different eval was NOT also processed" ;;
  esac
fi

t_case "--structural <unknown-name>: matches nothing, reports so, still exits 0"
assert_rc "exits 0 even with zero matches" 0 "$RUN_EVALS" --structural does-not-exist-eval-xyz
assert_output "says no evals matched" "no evals in" "$RUN_EVALS" --structural does-not-exist-eval-xyz

# ---------------------------------------------------------------------------
t_case "assertion count in the summary matches the real assertions.yaml independently"
one_dir="$EVALS_DIR/$one_name"
want_count="$(grep -cE '^[[:space:]]*-[[:space:]]' "$one_dir/assertions.yaml")"
assert_output "reported count matches an independent grep of the same file" \
  "($want_count assertions)" "$RUN_EVALS" --structural "$one_name"

# ===========================================================================================
# SEC-R15: --structural must REALLY invoke bin/firm-check-assertions.
#
# It used to grep dash-lines out of assertions.yaml and never run the checker, so every fail-closed
# guarantee in the checker (exit 2 for an empty/prose-only file, a YAML syntax error, or a fallback
# parse that dropped a list item) had ZERO coverage in the one mode CI runs — and the grep's count
# could silently disagree with the checker's real parsed count. The cases below pin all of that.
#
# The distinction they must hold apart, in both directions:
#   checker exit 1 = the assertions RAN and failed  -> structural PASSES (correct: satisfying an
#                    assertion needs a real model-driven run, which this mode explicitly is not)
#   checker exit 2 = the assertions COULD NOT RUN   -> structural FAILS  (a check that never ran has
#                    proven nothing, and must never read as green)
# ===========================================================================================

# ---- synthetic evals tree -------------------------------------------------
# firm-run-evals resolves its evals directory from its OWN location ("$SELF/../agent-firm/evals"), so
# the only way to hand it a deliberately broken eval — without writing one into the real, git-tracked
# agent-firm/evals/, which this file's header rules out — is to give it a different location to
# resolve from: a throwaway root holding a COPY of the script under test.
#
# It must be a COPY, not a symlink. The script deliberately resolves symlinks back to the real repo
# (that is how ~/.local/bin/firm-* finds it), so a symlinked fixture would quietly walk the REAL evals
# directory and every negative case below would pass for the wrong reason. The precondition case right
# after this proves the copy really is reading the synthetic tree. The sibling firm-check-assertions
# IS symlinked on purpose — the point is to exercise the real checker.
mk_eval_root() {
  d="$(mktemp -d "${TMPDIR:-/tmp}/firm-evalroot.XXXXXX")"
  t_track "$d"   # subshell-safe registration; see tests/lib.sh
  mkdir -p "$d/bin" "$d/agent-firm/evals" || return 1
  cp "$BIN/firm-run-evals" "$d/bin/firm-run-evals" || return 1
  chmod +x "$d/bin/firm-run-evals" || return 1
  printf '%s' "$d"
}

# mk_eval <root> <name> — a structurally complete eval (task.md + fixture/) whose assertions.yaml is
# read from STDIN, so each case can state its own broken/valid file inline.
mk_eval() {
  mkdir -p "$1/agent-firm/evals/$2/fixture"
  printf 'do the thing\n' > "$1/agent-firm/evals/$2/task.md"
  printf 'seed\n'         > "$1/agent-firm/evals/$2/fixture/seed.txt"
  cat > "$1/agent-firm/evals/$2/assertions.yaml"
}

root="$(mk_eval_root)"
ln -s "$BIN/firm-check-assertions" "$root/bin/firm-check-assertions"
FAKE="$root/bin/firm-run-evals"

# Well-formed, and deliberately IMPOSSIBLE to satisfy without a real run (no src/, no ledger, no
# verdict). This is the case that proves structural reports "evaluable", not "satisfied".
mk_eval "$root" synthetic-good <<'YAML'
name: synthetic-good
description: well-formed; both assertions can only be satisfied by a real model-driven run
assertions:
  - file_exists: src/nope.js
  - verdict_is: APPROVE
YAML

mk_eval "$root" synthetic-empty </dev/null

mk_eval "$root" synthetic-prose <<'YAML'
# Prose only: a description and not one assertion. The retired dash-line grep counted 0 here and
# still reported "ok   synthetic-prose (0 assertions)".
name: synthetic-prose
description: this eval asserts nothing at all
YAML

# Broken under BOTH parse paths, so the case means the same thing whether or not pyyaml is installed:
# pyyaml raises a scanner error on a plain scalar where the block sequence continues, and the regex
# fallback cannot turn that line into `- key: value`, so it DROPS it — and a dropped assertion is an
# unrun check, which is exit 2 either way.
mk_eval "$root" synthetic-badyaml <<'YAML'
name: synthetic-badyaml
assertions:
  - file_exists: src/a.js
  this line is neither a list item nor a key: and: breaks: the: block
YAML

# Parses cleanly (checker exit 1, verbs ran and failed) but the dash-line grep sees THREE dashes while
# only ONE is an assertion — the silent-disagreement case the old mode could not detect.
mk_eval "$root" synthetic-disagree <<'YAML'
name: synthetic-disagree
notes:
  - this dash line is not an assertion
  - neither is this one
assertions:
  - file_exists: src/a.js
YAML

# ---------------------------------------------------------------------------
t_case "fixture precondition: the synthetic root is really what the copied script walks"
out_syn="$("$FAKE" --structural 2>&1)"
case "$out_syn" in
  *synthetic-good*) _t_ok "the synthetic evals are the ones processed" ;;
  *) _t_no "the synthetic evals are the ones processed" "got: $(_t_ctx "$out_syn")" ;;
esac
case "$out_syn" in
  *"$one_name"*) _t_no "the REAL evals dir is NOT being walked (would make every case below vacuous)" \
                       "real eval '$one_name' appeared in the synthetic run" ;;
  *) _t_ok "the REAL evals dir is NOT being walked (would make every case below vacuous)" ;;
esac

# ---------------------------------------------------------------------------
t_case "well-formed assertions that CANNOT be satisfied offline still PASS --structural"
sb_good="$(mktemp -d "${TMPDIR:-/tmp}/firm-chk.XXXXXX")"; t_track "$sb_good"
assert_rc "precondition: firm-check-assertions EVALUATES this file and reports failures (exit 1)" 1 \
  "$BIN/firm-check-assertions" "$root/agent-firm/evals/synthetic-good/assertions.yaml" "$sb_good"
assert_rc "--structural exits 0 for it" 0 "$FAKE" --structural synthetic-good
assert_output "reports it ok with the checker's PARSED count" \
  "ok   synthetic-good (2 assertions)" "$FAKE" --structural synthetic-good
assert_output "says the count came from firm-check-assertions" \
  "EVALUABLE by firm-check-assertions" "$FAKE" --structural synthetic-good

t_case "structural-green is never presented as behavioural-green"
assert_output "the summary line disclaims a behavioural pass" \
  "NOT a behavioural pass" "$FAKE" --structural synthetic-good
assert_output "the header says a real run is what proves satisfaction" \
  "Does NOT prove" "$FAKE" --structural synthetic-good
# The checker's per-assertion verb lines are evaluated against an empty sandbox, so their PASS/FAIL is
# meaningless here. Echoing them would invite exactly the misreading above.
out_good="$("$FAKE" --structural synthetic-good 2>&1)"
case "$out_good" in
  *"  FAIL file_exists"*|*"  PASS file_exists"*)
    _t_no "per-assertion verb outcomes are NOT echoed" "leaked: $(_t_ctx "$out_good")" ;;
  *) _t_ok "per-assertion verb outcomes are NOT echoed" ;;
esac

# ---------------------------------------------------------------------------
t_case "an EMPTY assertions.yaml FAILS --structural (checker exit 2 surfaced, not swallowed)"
sb_e="$(mktemp -d "${TMPDIR:-/tmp}/firm-chk.XXXXXX")"; t_track "$sb_e"
assert_rc "precondition: firm-check-assertions CANNOT EVALUATE it (exit 2)" 2 \
  "$BIN/firm-check-assertions" "$root/agent-firm/evals/synthetic-empty/assertions.yaml" "$sb_e"
assert_rc "--structural exits 1" 1 "$FAKE" --structural synthetic-empty
assert_output "reports BAD, not ok" "BAD  synthetic-empty (assertions)" "$FAKE" --structural synthetic-empty
assert_output "surfaces the checker's own reason" "CANNOT EVALUATE" "$FAKE" --structural synthetic-empty
assert_output "the summary is a failure" "some evals FAILED" "$FAKE" --structural synthetic-empty

t_case "a PROSE-ONLY assertions.yaml (0 assertions) FAILS --structural"
sb_p="$(mktemp -d "${TMPDIR:-/tmp}/firm-chk.XXXXXX")"; t_track "$sb_p"
assert_rc "precondition: firm-check-assertions CANNOT EVALUATE it (exit 2)" 2 \
  "$BIN/firm-check-assertions" "$root/agent-firm/evals/synthetic-prose/assertions.yaml" "$sb_p"
assert_rc "--structural exits 1" 1 "$FAKE" --structural synthetic-prose
assert_output "reports BAD, not ok" "BAD  synthetic-prose (assertions)" "$FAKE" --structural synthetic-prose
# The old mode's exact wrong answer, pinned so it cannot come back.
out_prose="$("$FAKE" --structural synthetic-prose 2>&1)"
case "$out_prose" in
  *"ok   synthetic-prose"*) _t_no "does NOT report the retired 'ok ... (0 assertions)'" \
                                  "got: $(_t_ctx "$out_prose")" ;;
  *) _t_ok "does NOT report the retired 'ok ... (0 assertions)'" ;;
esac

t_case "a YAML SYNTAX ERROR in assertions.yaml FAILS --structural"
sb_y="$(mktemp -d "${TMPDIR:-/tmp}/firm-chk.XXXXXX")"; t_track "$sb_y"
assert_rc "precondition: firm-check-assertions CANNOT EVALUATE it (exit 2)" 2 \
  "$BIN/firm-check-assertions" "$root/agent-firm/evals/synthetic-badyaml/assertions.yaml" "$sb_y"
assert_rc "--structural exits 1" 1 "$FAKE" --structural synthetic-badyaml
assert_output "reports BAD, not ok" "BAD  synthetic-badyaml (assertions)" "$FAKE" --structural synthetic-badyaml
assert_output "surfaces the checker's own reason" "CANNOT EVALUATE" "$FAKE" --structural synthetic-badyaml

# ---------------------------------------------------------------------------
t_case "grep-count vs checker-parsed-count DISAGREEMENT is surfaced loudly, not reconciled"
sb_d="$(mktemp -d "${TMPDIR:-/tmp}/firm-chk.XXXXXX")"; t_track "$sb_d"
dis_yaml="$root/agent-firm/evals/synthetic-disagree/assertions.yaml"
# Both preconditions matter: the file IS evaluable (so the failure below is the disagreement itself,
# not a parse failure), and the two counting methods really do differ (so the case isn't vacuous).
assert_rc "precondition: the file is EVALUABLE (checker exit 1, not 2)" 1 \
  "$BIN/firm-check-assertions" "$dis_yaml" "$sb_d"
dis_grep="$(grep -cE '^[[:space:]]*-[[:space:]]' "$dis_yaml" | tr -cd '0-9')"
assert_eq "precondition: the dash-line grep over-counts (3)" 3 "$dis_grep"
assert_rc "--structural exits 1" 1 "$FAKE" --structural synthetic-disagree
assert_output "names the disagreement" "ASSERTION COUNT DISAGREEMENT" "$FAKE" --structural synthetic-disagree
assert_output "prints the grep's count" "grep counts 3" "$FAKE" --structural synthetic-disagree
assert_output "prints the checker's count" "PARSED 1" "$FAKE" --structural synthetic-disagree

# ---------------------------------------------------------------------------
t_case "no silent fallback: a missing firm-check-assertions FAILS instead of reverting to the grep"
root2="$(mk_eval_root)"          # deliberately WITHOUT the firm-check-assertions symlink
mk_eval "$root2" synthetic-good <<'YAML'
name: synthetic-good
assertions:
  - file_exists: src/nope.js
YAML
assert_rc "--structural exits 1" 1 "$root2/bin/firm-run-evals" --structural synthetic-good
assert_output "says the checker is missing" "firm-check-assertions is missing" \
  "$root2/bin/firm-run-evals" --structural synthetic-good
assert_output "explicitly refuses to guess" "will not guess" \
  "$root2/bin/firm-run-evals" --structural synthetic-good

# ---------------------------------------------------------------------------
# An uncaught Python traceback inside firm-check-assertions also exits 1 — the same code as the benign
# "assertions ran, some failed". Reading a crash as benign would be a fail-open in --structural itself,
# so it additionally requires the checker's own two landmarks (its parse line and its closing tally)
# before believing the run happened. Driven with STUB checkers, because a crash cannot be provoked in
# the real one without editing it. The third stub is the control: identical exit code, landmarks
# present, must PASS — without it, these cases would pass merely because "a stub checker fails".
t_case "a firm-check-assertions that exits 1 WITHOUT completing is NOT read as a pass"
stub_eval='name: synthetic-stub
assertions:
  - file_exists: src/nope.js'

# (a) crash-shaped: exit 1, no landmarks
root_crash="$(mk_eval_root)"
printf '#!/bin/sh\necho "Traceback (most recent call last):" >&2\necho "FileNotFoundError" >&2\nexit 1\n' \
  > "$root_crash/bin/firm-check-assertions"; chmod +x "$root_crash/bin/firm-check-assertions"
printf '%s\n' "$stub_eval" | mk_eval "$root_crash" synthetic-stub
assert_rc "crash-shaped exit 1 -> --structural exits 1" 1 \
  "$root_crash/bin/firm-run-evals" --structural synthetic-stub
assert_output "says the checker did not complete" "did not complete" \
  "$root_crash/bin/firm-run-evals" --structural synthetic-stub

# (b) exit 0 but silent: still no landmarks, so still not evidence anything was evaluated
root_silent="$(mk_eval_root)"
printf '#!/bin/sh\nexit 0\n' > "$root_silent/bin/firm-check-assertions"
chmod +x "$root_silent/bin/firm-check-assertions"
printf '%s\n' "$stub_eval" | mk_eval "$root_silent" synthetic-stub
assert_rc "silent exit 0 -> --structural exits 1" 1 \
  "$root_silent/bin/firm-run-evals" --structural synthetic-stub

# (c) CONTROL: same exit 1, but it really did evaluate -> must PASS
root_ok="$(mk_eval_root)"
printf '#!/bin/sh\necho "assertions: 1 parsed from $1 via stub"\necho "  FAIL file_exists src/nope.js"\necho "--- 0/1 assertions passed"\nexit 1\n' \
  > "$root_ok/bin/firm-check-assertions"; chmod +x "$root_ok/bin/firm-check-assertions"
printf '%s\n' "$stub_eval" | mk_eval "$root_ok" synthetic-stub
assert_rc "completed exit 1 -> --structural exits 0" 0 \
  "$root_ok/bin/firm-run-evals" --structural synthetic-stub
assert_output "and reports the stub's parsed count" "ok   synthetic-stub (1 assertions)" \
  "$root_ok/bin/firm-run-evals" --structural synthetic-stub

# ---------------------------------------------------------------------------
# Invoking the real checker means its `test_passes` verb executes shell straight out of the eval file,
# and one SHIPPED eval's test_passes names firm-gpt-qa (which shells out to codex). --structural has to
# stay hermetic, so it replaces PATH with an allow-list that cannot reach any of those. Tripwires prove
# it: shadow the dangerous names on PATH, run --structural over the REAL evals, and require that not
# one of them was executed.
t_case "--structural stays hermetic: claude/codex/firm-gpt-qa/node are never invoked"
trip="$(mktemp -d "${TMPDIR:-/tmp}/firm-trip.XXXXXX")"; t_track "$trip"
mkdir -p "$trip/bin" "$trip/marks"
for b in claude codex firm-gpt-qa node npm npx pytest; do
  printf '#!/bin/sh\n: > "%s/%s"\nexit 0\n' "$trip/marks" "$b" > "$trip/bin/$b"
  chmod +x "$trip/bin/$b"
done
assert_ok "precondition: a SHIPPED eval's test_passes really does name firm-gpt-qa" \
  sh -c "grep -q 'firm-gpt-qa' $EVALS_DIR/*/assertions.yaml"
assert_ok "precondition: a SHIPPED eval's test_passes really does name node" \
  sh -c "grep -q 'node --test' $EVALS_DIR/*/assertions.yaml"
assert_output "precondition: the tripwires shadow the real binaries on PATH" \
  "$trip/bin/firm-gpt-qa" sh -c "PATH='$trip/bin:\$PATH' command -v firm-gpt-qa"
out_trip="$(PATH="$trip/bin:$PATH" "$RUN_EVALS" --structural 2>&1)"; rc_trip=$?
assert_eq "--structural still exits 0 over the real evals" 0 "$rc_trip"
fired="$(ls -A "$trip/marks" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "not one tripwire fired" "" "$fired"

# ---------------------------------------------------------------------------
t_case "regression: every shipped eval still passes --structural, at the checker's own parsed count"
out_reg="$("$RUN_EVALS" --structural 2>&1)"; rc_reg=$?
assert_eq "the whole real suite still exits 0" 0 "$rc_reg"
mismatch=0
for name in $(real_eval_names); do
  g="$(grep -cE '^[[:space:]]*-[[:space:]]' "$EVALS_DIR/$name/assertions.yaml" | tr -cd '0-9')"
  case "$out_reg" in
    *"ok   $name ($g assertions)"*) : ;;
    *) mismatch=$((mismatch+1)); echo "    (expected 'ok   $name ($g assertions)')" ;;
  esac
done
assert_eq "all $n_real shipped evals report ok, parsed count == independent grep count" 0 "$mismatch"

t_summary
