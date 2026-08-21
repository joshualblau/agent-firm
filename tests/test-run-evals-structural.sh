#!/usr/bin/env bash
# Structural confinement and behavioral turn supervision. Provider commands here are inert stubs.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN="$BIN/firm-run-evals"
W="$(mktemp -d "${TMPDIR:-/tmp}/firm-evals-structural.XXXXXX")"; t_track "$W"

real_names() {
  for d in "$FIRM_ROOT"/agent-firm/evals/*/; do [ -d "$d" ] && basename "$d"; done
}

t_case "shipped evals are parse/shape valid without making a behavioral claim"
assert_rc "all shipped evals parse" 0 "$RUN" --structural
assert_output "output explicitly says payloads were not executed" "payloads not executed" "$RUN" --structural
assert_output "summary disclaims behavioral proof" "NOT a behavioural pass" "$RUN" --structural

one="$(real_names | sed -n '1p')"
t_case "explicit selectors fail closed and listing is a separate non-claiming operation"
assert_rc "known selector succeeds" 0 "$RUN" --structural "$one"
assert_rc "unknown structural selector is usage failure" 2 "$RUN" --structural definitely-not-an-eval
assert_rc "unknown behavioral selector fails before a provider lookup" 2 "$RUN" definitely-not-an-eval
assert_output "unknown selector gives valid names" "valid eval names:" "$RUN" --structural definitely-not-an-eval
assert_output "unknown selector gives a copyable correction" "firm-run-evals --list" "$RUN" --structural definitely-not-an-eval
assert_rc "list is successful" 0 "$RUN" --list
assert_output "list makes no behavioral or structural claim" "listing only" "$RUN" --list

mk_root() {
  local root="$1"
  mkdir -p "$root/bin" "$root/agent-firm/evals" "$root/agent-firm/contracts" "$root/.claude"
  cp "$RUN" "$root/bin/firm-run-evals"
  chmod +x "$root/bin/firm-run-evals"
  # firm-run-evals resolves its interpreter through its sibling bin/firm-python, so the scratch root
  # needs that sibling too (one python for the tools, the doctor and the write gate).
  ln -s "$BIN/firm-python" "$root/bin/firm-python"
  ln -s "$BIN/firm-check-assertions" "$root/bin/firm-check-assertions"
  ln -s "$BIN/firm-bounded-exec" "$root/bin/firm-bounded-exec"
  printf '# lifecycle fixture\n' > "$root/agent-firm/contracts/lifecycle.md"
  printf '{}\n' > "$root/.claude/settings.json"
}

mk_eval() {
  local root="$1" name="$2"
  mkdir -p "$root/agent-firm/evals/$name/fixture"
  printf 'fixture task\n' > "$root/agent-firm/evals/$name/task.md"
  printf 'seed\n' > "$root/agent-firm/evals/$name/fixture/seed.txt"
}

ROOT="$W/parse-root"; mk_root "$ROOT"; mk_eval "$ROOT" confined
OUTSIDE="$W/outside-write"; HIT="$W/listener-hit"; LISTENER_FIFO="$W/listener.fifo"
STUB="$W/stub"; mkdir "$STUB"
for command in claude codex firm-gpt-qa firm-claude-qa git sh python payload-project curl; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$0" >> "$FIRM_SENTINEL_CALLS"\n: > "$FIRM_SENTINEL_TRIP"\nexit 99\n' > "$STUB/$command"
  chmod +x "$STUB/$command"
done
CALLS="$W/calls"; TRIP="$W/trip"

# A real local IPC listener makes the listener axis observable in sandboxes that forbid every socket
# bind. It writes HIT only after a writer connects to the named pipe; structural mode must leave it
# waiting. This is test-harness setup, not an assertion payload.
mkfifo "$LISTENER_FIFO"
( IFS= read listener_value < "$LISTENER_FIFO"; printf '%s\n' "$listener_value" > "$HIT" ) &
LISTENER_PID=$!
assert_ok "precondition: local listener is ready" sh -c "[ -p '$LISTENER_FIFO' ] && kill -0 '$LISTENER_PID'"

cat > "$ROOT/agent-firm/evals/confined/assertions.yaml" <<YAML
name: confined
assertions:
  - file_exists: harmless.txt
  - test_passes: sh -c 'touch "$W/shell-trip"'
  - test_passes: payload-project --mutate
  - test_passes: git status
  - test_passes: python -c 'open("$W/interpreter-trip","w").close()'
  - test_passes: /usr/bin/touch "$W/absolute-trip"
  - test_passes: firm-gpt-qa "$W"
  - test_passes: firm-claude-qa "$W"
  - test_passes: curl http://127.0.0.1:9/
  - test_passes: /bin/sh -c 'printf connected > "$LISTENER_FIFO"'
  - test_passes: /usr/bin/touch "$OUTSIDE"
YAML

t_case "structural mode validates vocabulary but executes no assertion or payload class"
assert_rc "tripwire-rich eval is structurally valid" 0 env PATH="$STUB:/usr/bin:/bin" \
  FIRM_SENTINEL_CALLS="$CALLS" FIRM_SENTINEL_TRIP="$TRIP" "$ROOT/bin/firm-run-evals" --structural confined
assert_no_file "no stubbed shell/project/provider/reviewer/git/interpreter/network command ran" "$TRIP"
assert_no_file "no stub call was logged" "$CALLS"
for sentinel in shell-trip interpreter-trip absolute-trip outside-write listener-hit; do
  assert_no_file "payload sentinel $sentinel remains absent" "$W/$sentinel"
done
kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true

t_case "unknown vocabulary, empty values, and invalid value domains fail parse-only"
mk_eval "$ROOT" unknown
printf 'assertions:\n  - made_up_operation: value\n' > "$ROOT/agent-firm/evals/unknown/assertions.yaml"
assert_rc "unknown assertion fails structural validation" 1 "$ROOT/bin/firm-run-evals" --structural unknown
assert_output "valid vocabulary is actionable" "valid names:" "$ROOT/bin/firm-run-evals" --structural unknown
mk_eval "$ROOT" empty-value
printf 'assertions:\n  - file_exists: ""\n' > "$ROOT/agent-firm/evals/empty-value/assertions.yaml"
assert_rc "empty string fails" 1 "$ROOT/bin/firm-run-evals" --structural empty-value
mk_eval "$ROOT" bad-bool
printf 'assertions:\n  - final_gate_pending: perhaps\n' > "$ROOT/agent-firm/evals/bad-bool/assertions.yaml"
assert_rc "invalid boolean fails" 1 "$ROOT/bin/firm-run-evals" --structural bad-bool
mk_eval "$ROOT" bad-verdict
printf 'assertions:\n  - verdict_is: MAYBE\n' > "$ROOT/agent-firm/evals/bad-verdict/assertions.yaml"
assert_rc "invalid verdict fails" 1 "$ROOT/bin/firm-run-evals" --structural bad-verdict

t_case "a checker cannot fake parse-only completion"
FAKE_ROOT="$W/fake-checker"; mk_root "$FAKE_ROOT"; mk_eval "$FAKE_ROOT" fake
printf 'assertions:\n  - file_exists: x\n' > "$FAKE_ROOT/agent-firm/evals/fake/assertions.yaml"
rm "$FAKE_ROOT/bin/firm-check-assertions"
printf '#!/bin/sh\necho "assertions: 1 parsed from $2 via fake"\nexit 0\n' > "$FAKE_ROOT/bin/firm-check-assertions"
chmod +x "$FAKE_ROOT/bin/firm-check-assertions"
assert_rc "missing parse-only marker fails" 1 "$FAKE_ROOT/bin/firm-run-evals" --structural fake

t_case "Codex streamed turn cap preemptively terminates the provider process group"
TURN_ROOT="$W/turn-root"; mk_root "$TURN_ROOT"; mk_eval "$TURN_ROOT" gradual
printf 'assertions:\n  - file_exists: done\n' > "$TURN_ROOT/agent-firm/evals/gradual/assertions.yaml"
TURN_STUB="$W/turn-stub"; mkdir "$TURN_STUB"
cat > "$TURN_STUB/codex" <<'SH'
#!/bin/sh
( sleep 20; : > "$TURN_CHILD_DONE" ) &
echo $! > "$TURN_CHILD_PID"
i=0
while [ "$i" -lt 8 ]; do
  i=$((i+1))
  printf '{"type":"turn.completed","n":%s}\n' "$i"
  sleep 1
done
: > "$TURN_PROVIDER_DONE"
SH
chmod +x "$TURN_STUB/codex"
PROVIDER_DONE="$W/provider-done"; CHILD_DONE="$W/child-done"; CHILD_PID="$W/child-pid"
assert_rc "turn-limit result is blocking" 1 env PATH="$TURN_STUB:/usr/bin:/bin" \
  TURN_PROVIDER_DONE="$PROVIDER_DONE" TURN_CHILD_DONE="$CHILD_DONE" TURN_CHILD_PID="$CHILD_PID" \
  FIRM_EVAL_MAX_TURNS=2 FIRM_EVAL_TIMEOUT_SECONDS=20 FIRM_EVAL_KILL_GRACE=1 \
  "$TURN_ROOT/bin/firm-run-evals" --provider codex gradual
assert_no_file "provider did not complete turns beyond the cap" "$PROVIDER_DONE"
assert_no_file "provider descendant did not complete" "$CHILD_DONE"
if [ -s "$CHILD_PID" ]; then
  child_pid="$(sed -n '1p' "$CHILD_PID")"
  assert_ok "bounded process-group termination reaped the descendant" sh -c "! kill -0 '$child_pid' 2>/dev/null"
else
  _t_no "bounded process-group termination recorded the descendant pid" "pid file missing"
fi

t_case "Claude behavioral adapter passes a provider-native turn cap"
CLAUDE_STUB="$W/claude-stub"; mkdir "$CLAUDE_STUB"
cat > "$CLAUDE_STUB/claude" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$CLAUDE_ARGS"
printf '{"num_turns":1,"subtype":"success","is_error":false}\n'
SH
chmod +x "$CLAUDE_STUB/claude"
CLAUDE_ARGS="$W/claude-args"
env PATH="$CLAUDE_STUB:/usr/bin:/bin" CLAUDE_ARGS="$CLAUDE_ARGS" FIRM_EVAL_MAX_TURNS=3 \
  "$TURN_ROOT/bin/firm-run-evals" --provider claude gradual >/dev/null 2>&1 || true
assert_output "native --max-turns is explicit" "--max-turns 3" cat "$CLAUDE_ARGS"

# CR-11 deleted-regression axis inventory (predecessor -> retained R-E executable proof):
#   selected/nonselected routing -> provider call-log identity for both orientations
#   exactly one attempt/no retry -> nonzero provider call count remains exactly one
#   wall timeout -> stalled Codex stub is killed and produces one call
#   total-case cap -> two cases with cap one produce one provider call and a blocking result
#   invalid bounds -> zero/negative/nonnumeric/excess for every bound, all pre-provider
#   malformed/empty/prose result -> provider output is rejected before checker dispatch
#   missing checker -> preflight blocks before provider dispatch
#   checker crash/exit -> rc 1, rc 2, and unsupported rc are classified distinctly

BEHAVIOR_ROOT="$W/behavior-root"; mk_root "$BEHAVIOR_ROOT"
mk_eval "$BEHAVIOR_ROOT" bounded-one
printf 'assertions:\n  - file_exists: seed.txt\n' > "$BEHAVIOR_ROOT/agent-firm/evals/bounded-one/assertions.yaml"
mv "$BEHAVIOR_ROOT/bin/firm-check-assertions" "$BEHAVIOR_ROOT/bin/firm-check-assertions-real"
cat > "$BEHAVIOR_ROOT/bin/firm-check-assertions" <<'SH'
#!/bin/sh
printf 'checker\n' >> "$FIRM_CHECKER_CALLS"
case "${FIRM_CHECKER_STUB_MODE:-real}" in
  real) exec "$(dirname "$0")/firm-check-assertions-real" "$@" ;;
  assertions-failed) echo 'stub assertions failed' >&2; exit 1 ;;
  malformed) echo 'stub assertions malformed' >&2; exit 2 ;;
  crash) echo 'stub checker crash' >&2; exit 7 ;;
esac
exit 8
SH
chmod +x "$BEHAVIOR_ROOT/bin/firm-check-assertions"

BEHAVIOR_STUB="$W/behavior-stub"; mkdir "$BEHAVIOR_STUB"
cat > "$BEHAVIOR_STUB/claude" <<'SH'
#!/bin/sh
printf 'claude %s\n' "$*" >> "$FIRM_PROVIDER_CALLS"
case "${FIRM_PROVIDER_STUB_MODE:-ok}" in
  timeout) /bin/sleep 4 ;;
  fail) exit 9 ;;
  malformed) printf '{broken-json\n' ;;
  empty) : ;;
  prose) printf 'provider returned prose only\n' ;;
  excess) printf '{"num_turns":99,"is_error":false}\n' ;;
  *) printf '{"num_turns":1,"subtype":"success","is_error":false}\n' ;;
esac
SH
cat > "$BEHAVIOR_STUB/codex" <<'SH'
#!/bin/sh
printf 'codex %s\n' "$*" >> "$FIRM_PROVIDER_CALLS"
case "${FIRM_PROVIDER_STUB_MODE:-ok}" in
  timeout) /bin/sleep 4 ;;
  fail) exit 9 ;;
  malformed) printf '{broken-json\n' ;;
  empty) : ;;
  prose) printf 'provider returned prose only\n' ;;
  excess) printf '%s\n' '{"type":"turn.started"}' '{"type":"turn.started"}' '{"type":"turn.started"}' ;;
  *) printf '{"type":"turn.started"}\n' ;;
esac
SH
chmod +x "$BEHAVIOR_STUB/claude" "$BEHAVIOR_STUB/codex"
BEHAVIOR_RUN="$BEHAVIOR_ROOT/bin/firm-run-evals"
PROVIDER_CALLS="$W/behavior-provider-calls"
CHECKER_CALLS="$W/behavior-checker-calls"
: > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"

behavior_run() { # mode timeout turns cases provider [eval]
  env PATH="$BEHAVIOR_STUB:/usr/bin:/bin" FIRM_PROVIDER_CALLS="$PROVIDER_CALLS" \
    FIRM_CHECKER_CALLS="$CHECKER_CALLS" FIRM_PROVIDER_STUB_MODE="$1" \
    FIRM_CHECKER_STUB_MODE="${FIRM_CHECKER_TEST_MODE:-real}" \
    FIRM_EVAL_TIMEOUT_SECONDS="$2" FIRM_EVAL_MAX_TURNS="$3" FIRM_EVAL_MAX_CASES="$4" \
    FIRM_EVAL_KILL_GRACE=1 "$BEHAVIOR_RUN" --provider "$5" "${6:-bounded-one}"
}

t_case "behavioral provider selection excludes the nonselected provider"
: > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"
assert_rc "Claude selection succeeds" 0 behavior_run ok 3 2 2 claude
assert_eq "Claude selected exactly once" "1" "$(grep -c '^claude ' "$PROVIDER_CALLS" | tr -d ' ')"
assert_eq "Codex not selected" "0" "$(grep -c '^codex ' "$PROVIDER_CALLS" | tr -d ' ')"
: > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"
assert_rc "Codex selection succeeds" 0 behavior_run ok 3 2 2 codex
assert_eq "Codex selected exactly once" "1" "$(grep -c '^codex ' "$PROVIDER_CALLS" | tr -d ' ')"
assert_eq "Claude not selected" "0" "$(grep -c '^claude ' "$PROVIDER_CALLS" | tr -d ' ')"

t_case "the eval fixture's default branch is stated by run_one, not inherited from the host"
# THE FIRST-PARTY REGRESSION NOTHING COVERED. run_one() built its fixture with a bare `git init`,
# which takes its branch name from the HOST's init.defaultBranch. Once bin/firm-new-run started
# refusing to derive an already-reviewed base from a HEAD it cannot place on a default branch, a host
# set to anything but main or master made every behavioural eval fail at its own first instruction --
# `firm-new-run`, which every eval's task.md opens with -- before the eval had done anything at all.
#
# THE HOSTILE SETTING IS ASSERTED, NOT ASSUMED. On a host that already defaults to main this case
# would be a green that proves nothing (and .github/workflows/ci.yml pins init.defaultBranch=main on
# every runner), so the probe below fails loudly if the override did not take on this git. The
# override is passed as GIT_CONFIG_COUNT/KEY/VALUE, which outranks every config FILE, so it is
# hostile even where a global init.defaultBranch is already set.
#
# The rc of firm-run-evals is deliberately NOT the detector here: this eval's assertion is
# `file_exists: seed.txt`, which the fixture satisfies whether or not the firm inside it could ever
# have opened a run, so the pre-fix regression came back rc 0. What is asserted is the branch the
# fixture actually landed on, and then the call that was actually refused.
HOSTILE_PROBE="$W/hostile-default-branch-probe"; mkdir -p "$HOSTILE_PROBE"
( cd "$HOSTILE_PROBE" && env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch \
    GIT_CONFIG_VALUE_0=trunk git init -q ) >/dev/null 2>&1
assert_eq "fixture precondition: this git really honours the hostile init.defaultBranch override" \
  "refs/heads/trunk" "$(git -C "$HOSTILE_PROBE" symbolic-ref HEAD 2>/dev/null)"
: > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"
env PATH="$BEHAVIOR_STUB:/usr/bin:/bin" FIRM_PROVIDER_CALLS="$PROVIDER_CALLS" \
  FIRM_CHECKER_CALLS="$CHECKER_CALLS" FIRM_PROVIDER_STUB_MODE=ok FIRM_CHECKER_STUB_MODE=real \
  FIRM_EVAL_TIMEOUT_SECONDS=3 FIRM_EVAL_MAX_TURNS=2 FIRM_EVAL_MAX_CASES=2 FIRM_EVAL_KILL_GRACE=1 \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=trunk \
  "$BEHAVIOR_RUN" --provider claude bounded-one > "$W/hostile-branch.out" 2>&1
hostile_rc=$?
assert_eq "the behavioral run completes under a hostile host default branch" 0 "$hostile_rc"
HOSTILE_SCRATCH="$(sed -n 's/.*bounded posture) in //p' "$W/hostile-branch.out" | head -1)"
t_track "$HOSTILE_SCRATCH"
assert_ok "the run reported the fixture repository it built" \
  sh -c "[ -n '$HOSTILE_SCRATCH' ] && [ -d '$HOSTILE_SCRATCH/.git' ]"
assert_eq "the fixture is on the branch run_one names, not the one the host would have given it" \
  "refs/heads/main" "$(git -C "$HOSTILE_SCRATCH" symbolic-ref HEAD 2>/dev/null)"
# The consequence, not just the shape. This is the exact call every eval's task.md opens with, and
# the exact call that returned rc 2 for the whole class of hosts before this was stated.
assert_rc "and firm-new-run opens a run in that fixture, which is every eval's first instruction" \
  0 sh -c "cd '$HOSTILE_SCRATCH' && '$BIN/firm-new-run' hostile-default-branch fast_path"

t_case "provider failure and wall timeout permit exactly one attempt and no retry"
: > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"
assert_rc "provider nonzero blocks" 1 behavior_run fail 3 2 2 claude
assert_eq "nonzero provider attempted once" "1" "$(grep -c '^claude ' "$PROVIDER_CALLS" | tr -d ' ')"
assert_eq "checker not reached after provider failure" "0" "$(wc -l < "$CHECKER_CALLS" | tr -d ' ')"
: > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"
assert_rc "wall timeout blocks" 1 behavior_run timeout 1 2 2 codex
assert_eq "timed-out provider attempted once" "1" "$(grep -c '^codex ' "$PROVIDER_CALLS" | tr -d ' ')"
assert_eq "checker not reached after timeout" "0" "$(wc -l < "$CHECKER_CALLS" | tr -d ' ')"

t_case "total-case cap blocks before a second provider attempt"
mk_eval "$BEHAVIOR_ROOT" bounded-two
printf 'assertions:\n  - file_exists: seed.txt\n' > "$BEHAVIOR_ROOT/agent-firm/evals/bounded-two/assertions.yaml"
: > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"
assert_rc "one-case cap blocks a two-case run" 1 env PATH="$BEHAVIOR_STUB:/usr/bin:/bin" \
  FIRM_PROVIDER_CALLS="$PROVIDER_CALLS" FIRM_CHECKER_CALLS="$CHECKER_CALLS" \
  FIRM_PROVIDER_STUB_MODE=ok FIRM_CHECKER_STUB_MODE=real FIRM_EVAL_TIMEOUT_SECONDS=3 \
  FIRM_EVAL_MAX_TURNS=2 FIRM_EVAL_MAX_CASES=1 FIRM_EVAL_KILL_GRACE=1 \
  "$BEHAVIOR_RUN" --provider claude
assert_eq "case cap allows exactly one provider invocation" "1" "$(grep -c '^claude ' "$PROVIDER_CALLS" | tr -d ' ')"

t_case "zero, negative, nonnumeric, and excess bounds all fail before provider work"
for spec in \
  'FIRM_EVAL_TIMEOUT_SECONDS|0' 'FIRM_EVAL_TIMEOUT_SECONDS|-1' 'FIRM_EVAL_TIMEOUT_SECONDS|text' 'FIRM_EVAL_TIMEOUT_SECONDS|901' \
  'FIRM_EVAL_MAX_TURNS|0' 'FIRM_EVAL_MAX_TURNS|-1' 'FIRM_EVAL_MAX_TURNS|text' 'FIRM_EVAL_MAX_TURNS|1001' \
  'FIRM_EVAL_MAX_CASES|0' 'FIRM_EVAL_MAX_CASES|-1' 'FIRM_EVAL_MAX_CASES|text' 'FIRM_EVAL_MAX_CASES|9'; do
  bound_name="${spec%%|*}"; bound_value="${spec#*|}"
  : > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"
  env PATH="$BEHAVIOR_STUB:/usr/bin:/bin" FIRM_PROVIDER_CALLS="$PROVIDER_CALLS" \
    FIRM_CHECKER_CALLS="$CHECKER_CALLS" FIRM_EVAL_TIMEOUT_SECONDS=3 FIRM_EVAL_MAX_TURNS=2 \
    FIRM_EVAL_MAX_CASES=2 "$bound_name=$bound_value" \
    "$BEHAVIOR_RUN" --provider claude bounded-one >/dev/null 2>&1
  bound_rc=$?
  if [ "$bound_rc" -eq 2 ] && [ ! -s "$PROVIDER_CALLS" ] && [ ! -s "$CHECKER_CALLS" ]; then
    _t_ok "$bound_name=$bound_value rejected pre-provider"
  else
    _t_no "$bound_name=$bound_value rejected pre-provider" "rc=$bound_rc provider=$(wc -l < "$PROVIDER_CALLS") checker=$(wc -l < "$CHECKER_CALLS")"
  fi
done

t_case "malformed, empty, and prose provider results fail before assertion dispatch"
for provider in claude codex; do
  for result_kind in malformed empty prose; do
    : > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"
    behavior_run "$result_kind" 3 2 2 "$provider" >/dev/null 2>&1
    result_rc=$?
    if [ "$result_rc" -eq 1 ] && [ "$(grep -c "^$provider " "$PROVIDER_CALLS" | tr -d ' ')" = 1 ] \
      && [ ! -s "$CHECKER_CALLS" ]; then
      _t_ok "$provider $result_kind result propagated as failure"
    else
      _t_no "$provider $result_kind result propagated as failure" "rc=$result_rc calls=$(_t_ctx "$(cat "$PROVIDER_CALLS")")"
    fi
  done
done

t_case "missing, failing, malformed, and crashed checkers classify without retry"
MISSING_ROOT="$W/missing-checker-root"; mk_root "$MISSING_ROOT"; mk_eval "$MISSING_ROOT" bounded-one
printf 'assertions:\n  - file_exists: seed.txt\n' > "$MISSING_ROOT/agent-firm/evals/bounded-one/assertions.yaml"
rm "$MISSING_ROOT/bin/firm-check-assertions"
: > "$PROVIDER_CALLS"
assert_rc "missing checker blocks" 1 env PATH="$BEHAVIOR_STUB:/usr/bin:/bin" \
  FIRM_PROVIDER_CALLS="$PROVIDER_CALLS" FIRM_EVAL_TIMEOUT_SECONDS=3 FIRM_EVAL_MAX_TURNS=2 \
  FIRM_EVAL_MAX_CASES=2 "$MISSING_ROOT/bin/firm-run-evals" --provider claude bounded-one
assert_eq "missing checker blocks pre-provider" "0" "$(wc -l < "$PROVIDER_CALLS" | tr -d ' ')"
for checker_case in 'assertions-failed|one or more assertions failed' \
                    'malformed|malformed or unevaluable assertions' \
                    'crash|crashed or returned unsupported rc=7'; do
  checker_mode="${checker_case%%|*}"; checker_message="${checker_case#*|}"
  : > "$PROVIDER_CALLS"; : > "$CHECKER_CALLS"
  FIRM_CHECKER_TEST_MODE="$checker_mode" behavior_run ok 3 2 2 claude > "$W/checker-$checker_mode.out" 2>&1
  checker_run_rc=$?
  if [ "$checker_run_rc" -eq 1 ] \
    && grep -q "$checker_message" "$W/checker-$checker_mode.out" \
    && [ "$(grep -c '^claude ' "$PROVIDER_CALLS" | tr -d ' ')" = 1 ] \
    && [ "$(wc -l < "$CHECKER_CALLS" | tr -d ' ')" = 1 ]; then
    _t_ok "$checker_mode checker rc classified after one provider attempt"
  else
    _t_no "$checker_mode checker rc classified after one provider attempt" "rc=$checker_run_rc output=$(_t_ctx "$(cat "$W/checker-$checker_mode.out")")"
  fi
done

t_summary
