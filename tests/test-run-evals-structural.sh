#!/usr/bin/env bash
# tests/test-run-evals-structural.sh — firm-run-evals --structural: the one mode CI actually runs (no
# claude login, no spend). Model-driven `run_one` is exercised manually only, per the plan.
#
# firm-run-evals hardcodes its evals directory to THIS repo's agent-firm/evals/ (resolved from the
# script's own location, not parametrized by CWD or an env var) -- so unlike every other test file
# here, this one cannot point the script at a synthetic scratch fixture. The positive paths below run
# against the real, real eval directories. The "BAD $name (structure)" negative path (a missing
# task.md/assertions.yaml/fixture/) is NOT covered here for that reason: the only way to trigger it
# would be writing a broken fixture into the real, git-tracked agent-firm/evals/ directory, even
# transiently -- worse than leaving a documented gap.
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

t_summary
