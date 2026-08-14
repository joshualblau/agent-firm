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
assert_eq "target ledger mode is 600" 600 "$(t_file_mode "$repo5/.agent-firm/runs/target/run.jsonl")"

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

t_case "strict events carry one immutable event id and can print the generated producer id"
repo7="$(mk_repo)"; mk_run "$repo7" producer
printed_id="$(cd "$repo7" && "$LOG" --run "$repo7/.agent-firm/runs/producer" --strict --print-event-id evidence_captured sha=0123456789012345678901234567890123456789 path=09-test-evidence/proof.log)"
assert_output "generated producer id has the required prefix" "evt-" printf '%s' "$printed_id"
assert_ok "printed id names the exact retained event" python3 - "$repo7/.agent-firm/runs/producer/run.jsonl" "$printed_id" <<'PY'
import json,sys
records=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert len(records)==1, records
record=records[0]
assert record["event_id"]==sys.argv[2]
assert record["event"]=="evidence_captured"
assert record["run_id"]=="producer"
assert record["sha"]=="0123456789012345678901234567890123456789"
assert record["path"]=="09-test-evidence/proof.log"
PY

t_case "requested producer ids are unique and a duplicate cannot append or mutate the ledger"
repo8="$(mk_repo)"; mk_run "$repo8" unique
event_id="evt-explicit-producer-0001"
assert_rc "first explicit producer event succeeds" 0 \
  "$LOG" --run "$repo8/.agent-firm/runs/unique" --strict --event-id "$event_id" evidence_captured path=09-test-evidence/a.log
unique_before="$(shasum -a 256 "$repo8/.agent-firm/runs/unique/run.jsonl" | awk '{print $1}')"
assert_rc "duplicate producer event id is rejected" 1 \
  "$LOG" --run "$repo8/.agent-firm/runs/unique" --strict --event-id "$event_id" evidence_captured path=09-test-evidence/b.log
assert_eq "duplicate rejection leaves the ledger byte-identical" "$unique_before" \
  "$(shasum -a 256 "$repo8/.agent-firm/runs/unique/run.jsonl" | awk '{print $1}')"
assert_eq "only one event owns the explicit producer id" 1 \
  "$(python3 -c 'import json,sys; print(sum(json.loads(x).get("event_id")==sys.argv[2] for x in open(sys.argv[1]) if x.strip()))' "$repo8/.agent-firm/runs/unique/run.jsonl" "$event_id")"

t_case "strict producer fields are closed and malformed prior ledger bytes fail without append"
for reserved in ts event event_id run_id; do
  assert_rc "reserved field $reserved cannot override ledger identity" 1 \
    "$LOG" --run "$repo8/.agent-firm/runs/unique" --strict evidence_captured "$reserved=forged"
done
assert_eq "reserved-field attempts leave the ledger byte-identical" "$unique_before" \
  "$(shasum -a 256 "$repo8/.agent-firm/runs/unique/run.jsonl" | awk '{print $1}')"
repo9="$(mk_repo)"; mk_run "$repo9" malformed
printf 'not-json\n' > "$repo9/.agent-firm/runs/malformed/run.jsonl"
malformed_before="$(shasum -a 256 "$repo9/.agent-firm/runs/malformed/run.jsonl" | awk '{print $1}')"
assert_rc "malformed existing target ledger is rejected" 1 \
  "$LOG" --run "$repo9/.agent-firm/runs/malformed" --strict evidence_captured
assert_eq "malformed target remains byte-identical" "$malformed_before" \
  "$(shasum -a 256 "$repo9/.agent-firm/runs/malformed/run.jsonl" | awk '{print $1}')"

t_case "ordinary writers share the stable lock and atomic replace without partial or lost JSONL records"
repo10="$(mk_repo)"; mk_run "$repo10" concurrent
ordinary_race="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-race.XXXXXX")"; t_track "$ordinary_race"
for n in 1 2 3 4 5 6 7 8 9 10; do
  ( "$LOG" --run "$repo10/.agent-firm/runs/concurrent" --strict \
      --event-id "evt-ordinary-concurrent-$n" ordinary_event "sequence=$n" \
      > "$ordinary_race/$n.out" 2> "$ordinary_race/$n.err"; printf '%s' "$?" > "$ordinary_race/$n.rc" ) &
done
wait
ordinary_successes=0
for n in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(cat "$ordinary_race/$n.rc")" -eq 0 ] && ordinary_successes=$((ordinary_successes+1))
done
assert_eq "all non-conflicting ordinary writers succeed" 10 "$ordinary_successes"
assert_ok "every ordinary race record is complete, unique JSON" python3 - \
  "$repo10/.agent-firm/runs/concurrent/run.jsonl" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1],encoding="utf-8") if line.strip()]
assert len(rows)==10, rows
assert len({row["event_id"] for row in rows})==10
assert {row["sequence"] for row in rows}=={str(n) for n in range(1,11)}
PY
assert_eq "ordinary sidecar lock mode is 600" 600 \
  "$(t_file_mode "$repo10/.agent-firm/runs/concurrent/run.jsonl.lock")"
assert_eq "ordinary transaction leaves no private temp" 0 \
  "$(find "$repo10/.agent-firm/runs/concurrent" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"

t_case "ordinary extensions stay string-only and native-only names cannot enter the ordinary family"
repo11="$(mk_repo)"; mk_run "$repo11" closed
for field in contract authority activation activation_justification; do
  assert_rc "native-only $field is rejected at the ordinary CLI boundary" 1 \
    "$LOG" --run "$repo11/.agent-firm/runs/closed" --strict ordinary_event "$field=forged"
done
assert_rc "duplicate extension names are rejected rather than overwritten" 1 \
  "$LOG" --run "$repo11/.agent-firm/runs/closed" --strict ordinary_event note=first note=second
assert_rc "empty ordinary extension values remain accepted" 0 \
  "$LOG" --run "$repo11/.agent-firm/runs/closed" --strict --event-id evt-empty-extension ordinary_event note=
assert_ok "empty extension is retained as a string" python3 - "$repo11/.agent-firm/runs/closed/run.jsonl" <<'PY'
import json,sys
row=json.loads(open(sys.argv[1],encoding="utf-8").read())
assert row["event_id"]=="evt-empty-extension" and row["note"]==""
PY

t_summary
