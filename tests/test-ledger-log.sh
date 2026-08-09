#!/usr/bin/env bash
# tests/test-ledger-log.sh — firm-ledger-log is explicitly best-effort: it must never fail the caller,
# whether or not `jq` is on PATH, and must silently no-op with no active run.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$BIN/firm-ledger-log"

# is_valid_json <text> — feeds via STDIN rather than embedding into a python source string, so JSON
# containing quotes/backslashes can never break out of a quoted literal.
is_valid_json() { printf '%s' "$1" | python3 -c "import json,sys; json.load(sys.stdin)"; }

# a PATH with no jq on it, so the no-jq fallback branch is genuinely exercised regardless of whether
# this machine has jq installed.
NOJQ_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-nojq.XXXXXX")"; t_track "$NOJQ_DIR"
for tool in bash sh cat mkdir date printf basename dirname readlink python3 git; do
  real="$(command -v "$tool" 2>/dev/null)"; [ -n "$real" ] && ln -sf "$real" "$NOJQ_DIR/$tool"
done
without_jq() { ( PATH="$NOJQ_DIR" "$@" ); }

# ---------------------------------------------------------------------------
t_case "no active run is a silent, successful no-op"
repo="$(mk_repo)"
assert_rc "exit 0 with no CURRENT_RUN" 0 sh -c "cd '$repo' && '$LOG' some_event k=v"
assert_output "prints nothing" "" sh -c "cd '$repo' && '$LOG' some_event k=v"

t_case "CURRENT_RUN points at a nonexistent dir -> still a silent no-op, never a failure"
repo1b="$(mk_repo)"
mkdir -p "$repo1b/.agent-firm"
printf '%s\n' ".agent-firm/runs/does-not-exist" > "$repo1b/.agent-firm/CURRENT_RUN"
assert_rc "exit 0" 0 sh -c "cd '$repo1b' && '$LOG' some_event"

# ---------------------------------------------------------------------------
t_case "with jq on PATH: writes a well-formed JSON line with the given key=value pairs"
assert_ok "jq really is on PATH for this case" sh -c "command -v jq"
repo2="$(mk_repo)"
mk_run "$repo2" run1
( cd "$repo2" && "$LOG" widget_built role=implementer work_order=wo1 port=1234 )
line="$(tail -1 "$repo2/.agent-firm/runs/run1/run.jsonl")"
assert_ok "line is valid JSON" is_valid_json "$line"
assert_output "event field correct"  '"event":"widget_built"' printf '%s' "$line"
assert_output "role field correct"   '"role":"implementer"'   printf '%s' "$line"
assert_output "work_order correct"   '"work_order":"wo1"'     printf '%s' "$line"
assert_output "ts field present"     '"ts":"'                 printf '%s' "$line"

t_case "with jq: a value containing a double quote doesn't break the JSON (jq escapes it)"
repo2b="$(mk_repo)"; mk_run "$repo2b" run1b
( cd "$repo2b" && "$LOG" tricky_event msg='he said "hi"' )
line2b="$(tail -1 "$repo2b/.agent-firm/runs/run1b/run.jsonl")"
assert_ok "still valid JSON with an embedded quote" is_valid_json "$line2b"

# ---------------------------------------------------------------------------
t_case "without jq: falls back to a minimal manual encode, never fails"
repo3="$(mk_repo)"; mk_run "$repo3" run2
assert_rc "exit 0 even without jq" 0 without_jq sh -c "cd '$repo3' && '$LOG' fallback_event k=v"
line3="$(tail -1 "$repo3/.agent-firm/runs/run2/run.jsonl")"
assert_ok "fallback line is still valid JSON" is_valid_json "$line3"
assert_output "fallback line has the event" '"event":"fallback_event"' printf '%s' "$line3"

t_case "without jq: the shared JSON encoder preserves the same structured fields"
assert_output "key=value survives without jq" '"k":"v"' printf '%s' "$line3"

# ---------------------------------------------------------------------------
t_case "never returns non-zero, even on a garbled/no active run + missing args"
repo4="$(mk_repo)"
assert_rc "no event arg at all -> still exit 0" 0 sh -c "cd '$repo4' && '$LOG'"

t_case "an explicit target owns every outcome and never consults ambient CURRENT_RUN"
repo5="$(mk_repo)"
mk_run "$repo5" ambient
mkdir -p "$repo5/.agent-firm/runs/target"
printf '{"event":"ambient_seed"}\n' > "$repo5/.agent-firm/runs/ambient/run.jsonl"
ambient_before="$(shasum -a 256 "$repo5/.agent-firm/runs/ambient/run.jsonl" | awk '{print $1}')"
for outcome in approve block invalid timeout unavailable; do
  assert_rc "explicit $outcome event succeeds" 0 sh -c "cd '$repo5' && '$LOG' --run '$repo5/.agent-firm/runs/target' --strict reviewer_$outcome provider=gpt generation=4 sha=0123456789012345678901234567890123456789"
done
ambient_after="$(shasum -a 256 "$repo5/.agent-firm/runs/ambient/run.jsonl" | awk '{print $1}')"
assert_eq "ambient ledger is byte-identical" "$ambient_before" "$ambient_after"
assert_eq "all five outcomes landed only in target" 5 "$(wc -l < "$repo5/.agent-firm/runs/target/run.jsonl" | tr -d ' ')"
assert_eq "target ledger mode is 600" 600 "$(stat -f '%Lp' "$repo5/.agent-firm/runs/target/run.jsonl" 2>/dev/null || stat -c '%a' "$repo5/.agent-firm/runs/target/run.jsonl")"

t_case "strict explicit targets reject outside, symlinked, and redirected writes"
outside="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-outside.XXXXXX")"; t_track "$outside"
assert_rc "outside target is rejected" 1 "$LOG" --run "$outside" --strict reviewer_block
repo6="$(mk_repo)"
mkdir -p "$repo6/.agent-firm/runs/safe"
assert_rc "lexical traversal is rejected even when it normalizes inside runs" 1 \
  sh -c "cd '$repo6' && '$LOG' --run '$repo6/.agent-firm/runs/../runs/safe' --strict reviewer_block"
printf 'keep\n' > "$outside/ledger"
ln -s "$outside/ledger" "$repo6/.agent-firm/runs/safe/run.jsonl"
assert_rc "symlinked run.jsonl is rejected" 1 sh -c "cd '$repo6' && '$LOG' --run '$repo6/.agent-firm/runs/safe' --strict reviewer_block"
assert_eq "redirect target remains byte-identical" keep "$(cat "$outside/ledger")"
mv "$repo6/.agent-firm/runs/safe" "$repo6/.agent-firm/runs/real"
ln -s "$repo6/.agent-firm/runs/real" "$repo6/.agent-firm/runs/safe"
assert_rc "symlinked run component is rejected" 1 sh -c "cd '$repo6' && '$LOG' --run '$repo6/.agent-firm/runs/safe' --strict reviewer_block"

t_summary
