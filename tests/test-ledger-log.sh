#!/usr/bin/env bash
# tests/test-ledger-log.sh — firm-ledger-log is explicitly best-effort: it must never fail the caller,
# whether or not `jq` is on PATH, and must silently no-op with no active run.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$BIN/firm-ledger-log"

sha_or_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then shasum -a 256 "$1" | awk '{print $1}'; else printf absent; fi
}

wait_ready() {
  _ready="$1"; _n=0
  while [ ! -f "$_ready" ] && [ "$_n" -lt 1000 ]; do _n=$((_n+1)); sleep 0.01; done
  [ -f "$_ready" ]
}

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

t_case "closed evidence publication validates current identity and bytes before append"
make_current_evidence_run() {
  _repo="$(mk_repo)"; _sha="$(sha_of "$_repo" main)"
  _relative="$(cd "$_repo" && "$BIN/firm-new-run" --primary codex --base "$_sha" evidence-event full_track)" || return 1
  _run="$_repo/$_relative"; mkdir -p "$_run/09-test-evidence" "$_run/role-contracts"
  _common="$(git -C "$_repo" rev-parse --git-common-dir)"; case $_common in /*) ;; *) _common="$_repo/$_common";; esac
  printf '{"schema_version":2,"run_id":"%s","repository_root":"%s","git_common_dir":"%s","checkout_path":"%s","source_ref":"refs/heads/main","source_ref_sha":"%s","base_sha":"%s","candidate_sha":"%s","generation":1}\n' \
    "$(basename "$_run")" "$_repo" "$_common" "$_repo" "$_sha" "$_sha" "$_sha" \
    > "$_run/09-test-evidence/qa-candidate.json"
  chmod 600 "$_run/09-test-evidence/qa-candidate.json"
  printf '%s\n' '# evidence event fixture' > "$_run/role-contracts/Q-01-qa-tester.md"
  chmod 644 "$_run/role-contracts/Q-01-qa-tester.md"
  _run_event="$(t_python -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["event_id"])' "$_run/run.jsonl")"
  _authority="$(t_python -c 'import json,sys; rid=sys.argv[1]; print(json.dumps([{"source_run":".agent-firm/runs/"+rid,"event_id":sys.argv[2],"expect":{"event":"run_started","run_id":rid,"fields":{"base_sha":sys.argv[3]}}}],separators=(",",":")))' "$(basename "$_run")" "$_run_event" "$_sha")"
  _activation="$("$BIN/firm-model-resolve" --provider codex --role qa-tester --format activation)" || return 1
  _start="$("$LOG" --run "$_run" --strict --role-start --stage test/Q-01 --role qa-tester \
    --contract role-contracts/Q-01-qa-tester.md --event qa_started --authority-json "$_authority" \
    --agent /root/evidence_event_fixture --activation-json "$_activation" | \
    t_python -c 'import json,sys; print(json.load(sys.stdin)["event_id"])')" || return 1
  printf '%s\n' "$_repo" "$_run" "$_sha" "$_start"
}

assert_evidence_reject() {
  _label="$1"; _run="$2"; shift 2
  _ledger="$_run/run.jsonl"; _before="$(sha_or_absent "$_ledger")"
  _lock_before="$(sha_or_absent "$_run/run.jsonl.lock")"
  _out="$($LOG --run "$_run" --strict --print-event-id "$@" 2> "$_run/reject.err")"; _rc=$?
  assert_eq "$_label fails closed" 1 "$_rc"
  assert_eq "$_label emits no success receipt" "" "$_out"
  assert_eq "$_label leaves ledger bytes unchanged" "$_before" "$(sha_or_absent "$_ledger")"
  assert_eq "$_label leaves coordination state unchanged" "$_lock_before" \
    "$(sha_or_absent "$_run/run.jsonl.lock")"
  assert_eq "$_label leaves no transaction residue" 0 \
    "$(find "$_run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
}

if t_p2_row_supported; then
  current_fixture="$(make_current_evidence_run)"; current_fixture_rc=$?
  current_repo="$(printf '%s\n' "$current_fixture" | sed -n '1p')"
  current_run="$(printf '%s\n' "$current_fixture" | sed -n '2p')"
  current_sha="$(printf '%s\n' "$current_fixture" | sed -n '3p')"
  current_start="$(printf '%s\n' "$current_fixture" | sed -n '4p')"
  if [ "$current_fixture_rc" -ne 0 ] || [ -z "$current_start" ]; then
    _t_no "current evidence fixture created" "rc=$current_fixture_rc"
  else
    _t_ok "current evidence fixture created"
    evidence_path=09-test-evidence/proof.log
    printf '%s\n' 'canonical evidence bytes' > "$current_run/$evidence_path"
    chmod 600 "$current_run/$evidence_path"
    evidence_digest="$(shasum -a 256 "$current_run/$evidence_path" | awk '{print $1}')"
    evidence_bytes="$(wc -c < "$current_run/$evidence_path" | tr -d ' ')"
    common_args=(evidence_produced "sha=$current_sha" generation=1 "path=$evidence_path" \
      "sha256=$evidence_digest" "bytes=$evidence_bytes" stage=test/Q-01 role=qa-tester \
      "role_start_event_id=$current_start")
    evidence_id=evt-current-evidence-proof
    evidence_out="$($LOG --run "$current_run" --strict --print-event-id --event-id "$evidence_id" \
      "${common_args[@]}")"; evidence_rc=$?
    assert_eq "valid current publication succeeds" 0 "$evidence_rc"
    assert_eq "valid current publication returns its exact event id" "$evidence_id" "$evidence_out"
    assert_ok "valid current publication appends one exact closed record" t_python - \
      "$current_run/run.jsonl" "$evidence_id" "$evidence_path" "$evidence_digest" "$evidence_bytes" \
      "$current_sha" "$current_start" <<'PY'
import json,sys
ledger,eid,path,digest,count,sha,start=sys.argv[1:]
rows=[json.loads(line) for line in open(ledger,encoding="utf-8")]
matches=[row for row in rows if row.get("event_id")==eid]
assert len(matches)==1
row=matches[0]
assert set(row)=={"ts","event","event_id","run_id","sha","generation","path","sha256","bytes","stage","role","role_start_event_id"}
assert row["event"]=="evidence_produced" and row["path"]==path
assert row["sha256"]==digest and row["bytes"]==count and row["sha"]==sha and row["generation"]=="1"
assert row["stage"]=="test/Q-01" and row["role"]=="qa-tester" and row["role_start_event_id"]==start
PY

    # Shape and shell-boundary negatives use another path so the duplicate-publication rule is not
    # the reason they fail.
    negative_path=09-test-evidence/negative.log
    printf '%s\n' 'negative evidence bytes' > "$current_run/$negative_path"; chmod 600 "$current_run/$negative_path"
    negative_digest="$(shasum -a 256 "$current_run/$negative_path" | awk '{print $1}')"
    negative_bytes="$(wc -c < "$current_run/$negative_path" | tr -d ' ')"
    negative_args=("sha=$current_sha" generation=1 "path=$negative_path" \
      "sha256=$negative_digest" "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester \
      "role_start_event_id=$current_start")
    assert_evidence_reject "shell-split path plus bare event id" "$current_run" \
      evidence_produced "${negative_args[@]}" evt-split-token
    assert_evidence_reject "shell-joined path and event id" "$current_run" \
      evidence_produced "sha=$current_sha" generation=1 "path=$negative_path evt-joined" \
      "sha256=$negative_digest" "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester \
      "role_start_event_id=$current_start"
    assert_evidence_reject "composite path plus event id" "$current_run" \
      evidence_produced "sha=$current_sha" generation=1 "path=$negative_path+evt-composite" \
      "sha256=$negative_digest" "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester \
      "role_start_event_id=$current_start"
    assert_evidence_reject "omitted digest" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$negative_path" "bytes=$negative_bytes" \
      stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    assert_evidence_reject "empty digest" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$negative_path" sha256= "bytes=$negative_bytes" \
      stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    assert_evidence_reject "omitted byte count" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$negative_path" "sha256=$negative_digest" \
      stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    assert_evidence_reject "empty byte count" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$negative_path" "sha256=$negative_digest" bytes= \
      stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    assert_evidence_reject "duplicate path field" "$current_run" evidence_produced \
      "${negative_args[@]}" "path=$negative_path"
    assert_evidence_reject "stale candidate" "$current_run" evidence_produced \
      "sha=0000000000000000000000000000000000000000" generation=1 "path=$negative_path" \
      "sha256=$negative_digest" "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester \
      "role_start_event_id=$current_start"
    assert_evidence_reject "stale generation" "$current_run" evidence_produced \
      "sha=$current_sha" generation=2 "path=$negative_path" "sha256=$negative_digest" \
      "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    for spec in generation=0 generation=01 generation=x bytes=-1 bytes=01 bytes=x; do
      _key="${spec%%=*}"; _value="${spec#*=}"
      _args=("${negative_args[@]}")
      if [ "$_key" = generation ]; then _args[1]="generation=$_value"; else _args[4]="bytes=$_value"; fi
      assert_evidence_reject "malformed $_key $_value" "$current_run" evidence_produced "${_args[@]}"
    done
    assert_evidence_reject "uppercase digest" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$negative_path" \
      "sha256=$(printf '%s' "$negative_digest" | tr 'a-f' 'A-F')" "bytes=$negative_bytes" \
      stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    assert_evidence_reject "missing role start" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$negative_path" "sha256=$negative_digest" \
      "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester
    assert_evidence_reject "stale role start" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$negative_path" "sha256=$negative_digest" \
      "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester role_start_event_id=evt-unknown-start
    assert_evidence_reject "wrong role window stage" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$negative_path" "sha256=$negative_digest" \
      "bytes=$negative_bytes" stage=test/Q-02 role=qa-tester "role_start_event_id=$current_start"
    assert_evidence_reject "changed artifact bytes" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$negative_path" \
      "sha256=0000000000000000000000000000000000000000000000000000000000000000" \
      "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    assert_evidence_reject "missing artifact" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 path=09-test-evidence/missing.log "sha256=$negative_digest" \
      "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    ln -s negative.log "$current_run/09-test-evidence/symlink.log"
    assert_evidence_reject "symlink artifact" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 path=09-test-evidence/symlink.log "sha256=$negative_digest" \
      "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    ln "$current_run/$negative_path" "$current_run/09-test-evidence/hardlink.log"
    assert_evidence_reject "hardlink alias artifact" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 path=09-test-evidence/hardlink.log "sha256=$negative_digest" \
      "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"
    assert_evidence_reject "outside-run artifact" "$current_run" evidence_produced \
      "sha=$current_sha" generation=1 "path=$current_repo/outside.log" "sha256=$negative_digest" \
      "bytes=$negative_bytes" stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start"

    race_path=09-test-evidence/race.log
    printf '%s\n' 'before race' > "$current_run/$race_path"; chmod 600 "$current_run/$race_path"
    race_digest="$(shasum -a 256 "$current_run/$race_path" | awk '{print $1}')"
    race_bytes="$(wc -c < "$current_run/$race_path" | tr -d ' ')"
    race_before="$(sha_or_absent "$current_run/run.jsonl")"
    race_barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-evidence-race.XXXXXX")"; t_track "$race_barrier"
    ( FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_BARRIER_PHASE=after_lock \
      FIRM_LEDGER_BARRIER_DIR="$race_barrier" FIRM_LEDGER_BARRIER_TOKEN=evidence \
      "$LOG" --run "$current_run" --strict --print-event-id evidence_produced \
      "sha=$current_sha" generation=1 "path=$race_path" "sha256=$race_digest" "bytes=$race_bytes" \
      stage=test/Q-01 role=qa-tester "role_start_event_id=$current_start" \
      > "$race_barrier/out" 2> "$race_barrier/err"; printf '%s' "$?" > "$race_barrier/rc" ) & race_pid=$!
    assert_ok "TOCTOU writer reaches the post-validation lock barrier" wait_ready "$race_barrier/evidence.ready"
    printf '%s\n' 'mutated during lock barrier' > "$current_run/$race_path"
    printf '%s\n' release > "$race_barrier/evidence.release"; wait "$race_pid"
    assert_eq "TOCTOU mutation fails closed" 1 "$(cat "$race_barrier/rc")"
    assert_eq "TOCTOU mutation emits no success receipt" "" "$(cat "$race_barrier/out")"
    assert_eq "TOCTOU mutation leaves ledger prefix byte-identical" "$race_before" \
      "$(sha_or_absent "$current_run/run.jsonl")"
    assert_eq "TOCTOU mutation leaves no transaction residue" 0 \
      "$(find "$current_run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
  fi
else
  t_skip "closed current evidence publication matrix" "requires a supported P2 ledger write host"
fi

t_case "current or partial seal state never falls back, while genuine historical evidence remains bounded"
if t_p2_row_supported; then
  partial_repo="$(mk_repo)"; partial_sha="$(sha_of "$partial_repo" main)"
  partial_relative="$(cd "$partial_repo" && "$BIN/firm-new-run" --primary codex --base "$partial_sha" partial-evidence full_track)"
  partial_run="$partial_repo/$partial_relative"; mkdir -p "$partial_run/09-test-evidence"
  printf '%s\n' partial > "$partial_run/09-test-evidence/partial.log"; chmod 600 "$partial_run/09-test-evidence/partial.log"
  partial_digest="$(shasum -a 256 "$partial_run/09-test-evidence/partial.log" | awk '{print $1}')"
  partial_bytes="$(wc -c < "$partial_run/09-test-evidence/partial.log" | tr -d ' ')"
  partial_before="$(sha_or_absent "$partial_run/run.jsonl")"
  partial_out="$($LOG --run "$partial_run" --strict --print-event-id evidence_produced \
    "sha=$partial_sha" generation=1 path=09-test-evidence/partial.log "sha256=$partial_digest" \
    "bytes=$partial_bytes" 2> "$partial_run/partial.err")"; partial_rc=$?
  assert_eq "approval-eligible partial state rejects legacy-shaped fallback" 1 "$partial_rc"
  assert_eq "partial-state rejection emits no receipt" "" "$partial_out"
  assert_eq "partial-state rejection leaves ledger exact" "$partial_before" \
    "$(sha_or_absent "$partial_run/run.jsonl")"
  assert_no_file "partial-state rejection creates no coordination lock" "$partial_run/run.jsonl.lock"

  for no_fallback_state in opted_in present unknown partial_candidate; do
    state_repo="$(mk_repo)"; state_run="$state_repo/.agent-firm/runs/state-$no_fallback_state"
    mkdir -p "$state_run/09-test-evidence"
    printf '%s\n' '{"ts":"2026-08-01T00:00:00Z","event":"run_started","event_id":"evt-state-run-start","run_id":"state-'"$no_fallback_state"'","repo":"fixture","base_sha":"0000000000000000000000000000000000000000","track":"full_track"}' > "$state_run/run.jsonl"
    chmod 600 "$state_run/run.jsonl"
    case $no_fallback_state in
      opted_in)
        printf '%s\n' '{"ts":"2026-08-01T00:00:01Z","event":"evidence_seal_required","event_id":"evt-state-opt-in","run_id":"state-opted_in","protocol":"1"}' >> "$state_run/run.jsonl"
        ;;
      present) mkdir -p "$state_run/09-test-evidence/final-evidence" ;;
      unknown)
        t_python - "$state_run/run.jsonl" <<'PY'
import json,sys
p=sys.argv[1]; row=json.loads(open(p).read()); row["evidence_seal_protocol"]="999"
open(p,"w").write(json.dumps(row,separators=(",",":"))+"\n")
PY
        ;;
      partial_candidate) printf '{bad\n' > "$state_run/09-test-evidence/qa-candidate.json" ;;
    esac
    printf '%s\n' state > "$state_run/09-test-evidence/state.log"; chmod 600 "$state_run/09-test-evidence/state.log"
    state_digest="$(shasum -a 256 "$state_run/09-test-evidence/state.log" | awk '{print $1}')"
    state_bytes="$(wc -c < "$state_run/09-test-evidence/state.log" | tr -d ' ')"
    state_before="$(sha_or_absent "$state_run/run.jsonl")"
    state_out="$($LOG --run "$state_run" --strict --print-event-id evidence_produced \
      sha=0000000000000000000000000000000000000000 generation=1 \
      path=09-test-evidence/state.log "sha256=$state_digest" "bytes=$state_bytes" \
      2> "$state_run/state.err")"; state_rc=$?
    assert_eq "$no_fallback_state state rejects legacy fallback" 1 "$state_rc"
    assert_eq "$no_fallback_state rejection emits no receipt" "" "$state_out"
    assert_eq "$no_fallback_state rejection leaves ledger exact" "$state_before" \
      "$(sha_or_absent "$state_run/run.jsonl")"
    assert_no_file "$no_fallback_state rejection creates no lock" "$state_run/run.jsonl.lock"
    assert_eq "$no_fallback_state rejection creates no temp" 0 \
      "$(find "$state_run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
  done

  legacy_repo="$(mk_repo)"; legacy_run="$legacy_repo/.agent-firm/runs/legacy-evidence"
  mkdir -p "$legacy_run/09-test-evidence"
  printf '%s\n' '{"ts":"2026-08-01T00:00:00Z","event":"run_started","event_id":"evt-legacy-run-start","run_id":"legacy-evidence","repo":"fixture","base_sha":"0000000000000000000000000000000000000000","track":"full_track"}' > "$legacy_run/run.jsonl"
  chmod 600 "$legacy_run/run.jsonl"
  printf '%s\n' legacy > "$legacy_run/09-test-evidence/legacy.log"; chmod 600 "$legacy_run/09-test-evidence/legacy.log"
  legacy_digest="$(shasum -a 256 "$legacy_run/09-test-evidence/legacy.log" | awk '{print $1}')"
  legacy_bytes="$(wc -c < "$legacy_run/09-test-evidence/legacy.log" | tr -d ' ')"
  legacy_out="$($LOG --run "$legacy_run" --strict --print-event-id --event-id evt-legacy-evidence \
    evidence_produced sha=0000000000000000000000000000000000000000 generation=1 \
    path=09-test-evidence/legacy.log "sha256=$legacy_digest" "bytes=$legacy_bytes")"; legacy_rc=$?
  assert_eq "genuine pre-provider legacy publication succeeds" 0 "$legacy_rc"
  assert_eq "genuine legacy publication returns its id" evt-legacy-evidence "$legacy_out"
  assert_ok "genuine legacy record has only the bounded legacy fields" t_python - "$legacy_run/run.jsonl" <<'PY'
import json,sys
row=[json.loads(line) for line in open(sys.argv[1])][-1]
assert set(row)=={"ts","event","event_id","run_id","sha","generation","path","sha256","bytes"}
assert row["event"]=="evidence_produced" and row["event_id"]=="evt-legacy-evidence"
PY
else
  t_skip "current-no-fallback and genuine-legacy evidence cases" "requires a supported P2 ledger write host"
fi

t_case "malformed source-run evidence is rejected without normalization or mutation"
source_common="$(git -C "$FIRM_ROOT" rev-parse --git-common-dir)"
case $source_common in /*) ;; *) source_common="$FIRM_ROOT/$source_common";; esac
source_repo="$(dirname "$source_common")"
source_run="$source_repo/.agent-firm/runs/20260902T163746Z-evidence-seal-review-qa-completion"
if [ -f "$source_run/run.jsonl" ]; then
  source_before="$(sha_or_absent "$source_run/run.jsonl")"
  assert_rc "canonical classifier rejects the ten malformed source records" 1 \
    "$LOG" --classify-ledger-file "$(basename "$source_run")" "$source_run/run.jsonl"
  assert_eq "source-run ledger remains byte-identical" "$source_before" \
    "$(sha_or_absent "$source_run/run.jsonl")"
else
  t_skip "malformed source-run classifier case" "source audit run is unavailable in fixture checkout"
fi

t_case "the evidence writer preserves the interpreter-row/write-host-row distinction"
if "$BIN/firm-python" --status | grep -q 'p2=yes'; then
  divergent_repo="$(mk_repo)"; mk_run "$divergent_repo" divergent
  divergent_run="$divergent_repo/.agent-firm/runs/divergent"
  divergent_out="$(FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=macos_version_mismatch \
    "$LOG" --run "$divergent_run" --strict --print-event-id evidence_produced \
    sha=0000000000000000000000000000000000000000 generation=1 path=x \
    sha256=0000000000000000000000000000000000000000000000000000000000000000 bytes=0 \
    2> "$divergent_repo/divergent.err")"; divergent_rc=$?
  assert_eq "compliant interpreter does not admit an unproven write-host row" 17 "$divergent_rc"
  assert_eq "divergent write-host refusal emits no receipt" "" "$divergent_out"
  assert_no_file "divergent write-host refusal creates no ledger" "$divergent_run/run.jsonl"
  assert_no_file "divergent write-host refusal creates no lock" "$divergent_run/run.jsonl.lock"
else
  t_skip "modeled interpreter/write-host divergence" "resolved interpreter is not itself P2-compliant"
fi

t_summary
