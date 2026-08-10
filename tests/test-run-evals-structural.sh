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

t_summary
