#!/usr/bin/env bash
# tests/test-ledger-role-start.sh — fail-closed role activation, provenance, races, and faults.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$BIN/firm-ledger-log"
RESOLVER="$BIN/firm-model-resolve"
ACTIVATION="$($RESOLVER --provider codex --role implementer --format activation)"
REAL_AUTHORITY_ID="evt-20260812T034028-89411-f034d7a01fdd7e28"
FORGED_AUTHORITY_ID="evt-20260812T033804-86100-8a12bd0e388c7c32"
ACTUAL_RECRUITER_SHA="2ff14a2c30409aa620a5a7776761ad94c02b387029344d023f37d43fd4cd51e0"
FORGED_RECRUITER_SHA="7ed15992cae1fe62443860bc3f1b939c6ab09ad313209531a59182f0f0e3140b"

mk_role_fixture() {
  local repo="$1" target="${2:-target}" source="${3:-source}"
  mk_run "$repo" "$target"
  mkdir -p "$repo/.agent-firm/runs/$target/role-contracts" "$repo/.agent-firm/runs/$source"
  printf '{"run_id":"%s","historical":false,"approval_eligible":true}\n' "$target" \
    > "$repo/.agent-firm/runs/$target/run-metadata.json"
  printf 'sealed role contract\n' > "$repo/.agent-firm/runs/$target/role-contracts/R-03-implementer.md"
  chmod 644 "$repo/.agent-firm/runs/$target/run-metadata.json" \
    "$repo/.agent-firm/runs/$target/role-contracts/R-03-implementer.md"
  printf '%s\n' \
    "{\"ts\":\"2020-01-01T00:00:00Z\",\"event\":\"human_architecture_decision\",\"event_id\":\"$REAL_AUTHORITY_ID\",\"run_id\":\"$source\",\"decision\":\"option_a\",\"target_run_id\":\"$target\"}" \
    > "$repo/.agent-firm/runs/$source/run.jsonl"
  chmod 600 "$repo/.agent-firm/runs/$source/run.jsonl"
}

authority_for() {
  local target="$1" source="${2:-source}" event_id="${3:-$REAL_AUTHORITY_ID}" decision="${4:-option_a}"
  printf '[{"source_run":".agent-firm/runs/%s","event_id":"%s","expect":{"event":"human_architecture_decision","run_id":"%s","fields":{"decision":"%s","target_run_id":"%s"}}}]' \
    "$source" "$event_id" "$source" "$decision" "$target"
}

invoke_start() {
  local repo="$1" target="$2" stage="$3" authority="$4" activation="${5:-$ACTIVATION}"
  "$LOG" --run "$repo/.agent-firm/runs/$target" --strict --role-start \
    --stage "$stage" --role implementer --contract role-contracts/R-03-implementer.md \
    --event build_started --authority-json "$authority" --agent /root/implementer \
    --activation-json "$activation"
}

invoke_start_fp() {
  local point="$1" repo="$2" target="$3" authority="$4"
  FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_FAILPOINT="$point" \
    invoke_start "$repo" "$target" build/R-03 "$authority"
}

ledger_sha_or_absent() {
  local path="$1"
  if [ -f "$path" ]; then shasum -a 256 "$path" | awk '{print $1}'; else printf absent; fi
}

jsonl_count() {
  python3 - "$1" <<'PY'
import json,os,sys
path=sys.argv[1]
if not os.path.exists(path):
    print(0)
else:
    rows=[]
    with open(path,encoding="utf-8") as fh:
        for line in fh:
            if line.strip(): rows.append(json.loads(line))
    print(len(rows))
PY
}

t_case "valid role start derives one exact contract tuple and emits only the proved closed result"
repo1="$(mk_repo)"; mk_role_fixture "$repo1" target source
auth1="$(authority_for target)"
result1="$(invoke_start "$repo1" target build/R-03 "$auth1")"; rc1=$?
assert_eq "valid request succeeds" 0 "$rc1"
assert_ok "result and retained event are exact structural projections" python3 - \
  "$repo1/.agent-firm/runs/target/run.jsonl" \
  "$repo1/.agent-firm/runs/target/role-contracts/R-03-implementer.md" "$result1" <<'PY'
import hashlib,json,sys
ledger,contract,result_raw=sys.argv[1:]
result=json.loads(result_raw)
rows=[json.loads(line) for line in open(ledger,encoding="utf-8") if line.strip()]
assert len(rows)==1, rows
event=rows[0]
assert set(event)=={"ts","event","event_id","run_id","stage","role","agent","contract","authority","activation"}
assert set(result)=={"schema_version","event_id","run_id","event","stage","role","agent","contract","authority","activation"}
assert result["schema_version"]==1
for key in set(result)-{"schema_version"}: assert result[key]==event[key], key
body=open(contract,"rb").read()
assert event["contract"]=={
  "path":"role-contracts/R-03-implementer.md","bytes":len(body),
  "sha256":hashlib.sha256(body).hexdigest(),"mode":"0644"}
assert event["authority"][0]["event_id"]=="evt-20260812T034028-89411-f034d7a01fdd7e28"
assert event["activation"]["apply"]=={"display":"GPT-5.6 sol","effort":"xhigh","model":"gpt-5.6-sol"}
PY
assert_eq "ledger lock is stable mode 0600" 600 \
  "$(stat -f '%Lp' "$repo1/.agent-firm/runs/target/run.jsonl.lock" 2>/dev/null || stat -c '%a' "$repo1/.agent-firm/runs/target/run.jsonl.lock")"
assert_eq "ledger is mode 0600" 600 \
  "$(stat -f '%Lp' "$repo1/.agent-firm/runs/target/run.jsonl" 2>/dev/null || stat -c '%a' "$repo1/.agent-firm/runs/target/run.jsonl")"
assert_eq "no private transaction file remains" 0 \
  "$(find "$repo1/.agent-firm/runs/target" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"

t_case "the returned producer id is consumed directly by an ordinary downstream lifecycle event"
produced_id="$(printf '%s' "$result1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["event_id"])')"
assert_rc "downstream append succeeds" 0 "$LOG" --run "$repo1/.agent-firm/runs/target" --strict \
  build_completed "started_event=$produced_id"
assert_ok "downstream predecessor is byte-for-byte the returned id" python3 - \
  "$repo1/.agent-firm/runs/target/run.jsonl" "$produced_id" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1]) if x.strip()]
assert rows[-1]["started_event"]==sys.argv[2]==rows[0]["event_id"]
PY

t_case "the historical nonexistent authority id fails while the unique constrained counterpart succeeds"
repo2="$(mk_repo)"; mk_role_fixture "$repo2" target source
bad_auth="$(authority_for target source "$FORGED_AUTHORITY_ID")"
before2="$(ledger_sha_or_absent "$repo2/.agent-firm/runs/target/run.jsonl")"
bad_out="$(invoke_start "$repo2" target build/R-03 "$bad_auth" 2>/dev/null)"; bad_rc=$?
assert_eq "nonexistent historical id is AUTHORITY_INVALID" 11 "$bad_rc"
assert_eq "authority failure emits no activation object" "" "$bad_out"
assert_eq "authority failure leaves target ledger byte-identical" "$before2" \
  "$(ledger_sha_or_absent "$repo2/.agent-firm/runs/target/run.jsonl")"
assert_rc "real constrained authority succeeds" 0 invoke_start "$repo2" target build/R-03 "$(authority_for target)"

t_case "the manual Recruiter tuple cannot be supplied or override derived provenance"
repo3="$(mk_repo)"; mk_role_fixture "$repo3" target source
python3 - "$repo3/.agent-firm/runs/target/role-contracts/R-03-implementer.md" <<'PY'
import sys
with open(sys.argv[1],"wb") as fh: fh.write(b"R"*3686)
PY
chmod 644 "$repo3/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
auth3="$(authority_for target)"
override_out="$($LOG --run "$repo3/.agent-firm/runs/target" --strict --role-start \
  --stage build/R-03 --role implementer --contract role-contracts/R-03-implementer.md \
  --event build_started --authority-json "$auth3" --agent /root/implementer \
  --activation-json "$ACTIVATION" \
  "contract_bytes=4195" "contract_sha256=$FORGED_RECRUITER_SHA" 2>/dev/null)"; override_rc=$?
assert_eq "caller-supplied tuple is INPUT_INVALID" 2 "$override_rc"
assert_eq "tuple forgery has no success output" "" "$override_out"
result3="$(invoke_start "$repo3" target build/R-03 "$auth3")"
assert_ok "the producer retains 3686 derived bytes and never the forged tuple" python3 - \
  "$result3" "$ACTUAL_RECRUITER_SHA" "$FORGED_RECRUITER_SHA" <<'PY'
import json,sys
r=json.loads(sys.argv[1]); c=r["contract"]
assert c["bytes"]==3686
assert c["sha256"]!=sys.argv[3]
assert c["sha256"]==__import__("hashlib").sha256(b"R"*3686).hexdigest()
# The immutable historical actual digest is encoded as regression identity, never trusted as input.
assert len(sys.argv[2])==64 and sys.argv[2]!=sys.argv[3]
PY

t_case "duplicate JSON keys and every producer-reserved/trailing field are rejected before append"
repo4="$(mk_repo)"; mk_role_fixture "$repo4" target source
auth4="$(authority_for target)"; before4="$(ledger_sha_or_absent "$repo4/.agent-firm/runs/target/run.jsonl")"
dup_auth='[{"source_run":".agent-firm/runs/source","source_run":".agent-firm/runs/source","event_id":"evt-20260812T034028-89411-f034d7a01fdd7e28","expect":{"event":"human_architecture_decision","run_id":"source","fields":{"decision":"option_a","target_run_id":"target"}}}]'
assert_rc "duplicate authority key" 2 invoke_start "$repo4" target build/R-03 "$dup_auth"
dup_activation="$(printf '%s' "$ACTIVATION" | sed 's/{/{\"schema_version\":1,/' )"
assert_rc "duplicate activation key" 2 invoke_start "$repo4" target build/R-03 "$auth4" "$dup_activation"
for reserved in ts event event_id run_id stage role agent contract authority activation activation_justification; do
  assert_rc "reserved/trailing $reserved" 2 "$LOG" --run "$repo4/.agent-firm/runs/target" --strict --role-start \
    --stage build/R-03 --role implementer --contract role-contracts/R-03-implementer.md \
    --event build_started --authority-json "$auth4" --agent /root/implementer \
    --activation-json "$ACTIVATION" "$reserved=forged"
done
assert_eq "all closed-input failures leave ledger byte-identical" "$before4" \
  "$(ledger_sha_or_absent "$repo4/.agent-firm/runs/target/run.jsonl")"

t_case "malformed lifecycle identity and unjustified activation mismatches are INPUT_INVALID"
repo5="$(mk_repo)"; mk_role_fixture "$repo5" target source; auth5="$(authority_for target)"
assert_rc "omitted explicit run and required options" 2 "$LOG" --strict --role-start
assert_rc "requested event id is forbidden in role mode" 2 "$LOG" --run "$repo5/.agent-firm/runs/target" \
  --strict --role-start --event-id evt-forged --stage build/R-03 --role implementer \
  --contract role-contracts/R-03-implementer.md --event build_started --authority-json "$auth5" \
  --agent /root/implementer --activation-json "$ACTIVATION"
assert_rc "unsafe stage" 2 invoke_start "$repo5" target ../R-03 "$auth5"
assert_rc "unsafe event" 2 "$LOG" --run "$repo5/.agent-firm/runs/target" --strict --role-start \
  --stage build/R-03 --role implementer --contract role-contracts/R-03-implementer.md \
  --event build_completed --authority-json "$auth5" --agent /root/implementer --activation-json "$ACTIVATION"
bad_activation="$(printf '%s' "$ACTIVATION" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["apply"]["model"]="forged"; print(json.dumps(d,separators=(",",":")))')"
assert_rc "resolver structural mismatch" 2 invoke_start "$repo5" target build/R-03 "$auth5" "$bad_activation"
tier_activation="$($RESOLVER --provider codex --tier heavyweight --format activation)"
assert_rc "tier selection without justification" 2 invoke_start "$repo5" target build/R-03 "$auth5" "$tier_activation"
assert_rc "tier selection with justification succeeds" 0 "$LOG" --run "$repo5/.agent-firm/runs/target" --strict --role-start \
  --stage build/R-03 --role implementer --contract role-contracts/R-03-implementer.md \
  --event build_started --authority-json "$auth5" --agent /root/implementer \
  --activation-json "$tier_activation" --activation-justification explicit_heavyweight_assignment

t_case "run eligibility and identity are explicit and never fall back to ambient state"
repo6="$(mk_repo)"; mk_role_fixture "$repo6" target source
mk_role_fixture "$repo6" ambient source2
printf '%s\n' '.agent-firm/runs/ambient' > "$repo6/.agent-firm/CURRENT_RUN"
printf '{"run_id":"wrong","historical":false,"approval_eligible":true}\n' > "$repo6/.agent-firm/runs/target/run-metadata.json"
assert_rc "metadata identity mismatch" 10 invoke_start "$repo6" target build/R-03 "$(authority_for target)"
printf '{"run_id":"target","historical":true,"approval_eligible":false}\n' > "$repo6/.agent-firm/runs/target/run-metadata.json"
assert_rc "historical/ineligible run" 10 invoke_start "$repo6" target build/R-03 "$(authority_for target)"
assert_eq "ambient run remains untouched" 0 "$(jsonl_count "$repo6/.agent-firm/runs/ambient/run.jsonl")"

t_case "authority must be unique, earlier, correctly sourced, and match decision and target"
for axis in future ambiguous wrong_source wrong_decision wrong_target malformed; do
  repo="$(mk_repo)"; mk_role_fixture "$repo" target source; auth="$(authority_for target)"
  case "$axis" in
    future) sed -i.bak 's/2020-01-01T00:00:00Z/2999-01-01T00:00:00Z/' "$repo/.agent-firm/runs/source/run.jsonl"; rm -f "$repo/.agent-firm/runs/source/run.jsonl.bak" ;;
    ambiguous) cat "$repo/.agent-firm/runs/source/run.jsonl" >> "$repo/.agent-firm/runs/source/run.jsonl.copy"; cat "$repo/.agent-firm/runs/source/run.jsonl.copy" >> "$repo/.agent-firm/runs/source/run.jsonl"; rm -f "$repo/.agent-firm/runs/source/run.jsonl.copy" ;;
    wrong_source) auth="$(authority_for target absent-source)" ;;
    wrong_decision) auth="$(authority_for target source "$REAL_AUTHORITY_ID" option_b)" ;;
    wrong_target) auth="$(authority_for another-target)" ;;
    malformed) printf 'not-json\n' >> "$repo/.agent-firm/runs/source/run.jsonl" ;;
  esac
  chmod 600 "$repo/.agent-firm/runs/source/run.jsonl"
  out="$(invoke_start "$repo" target build/R-03 "$auth" 2>/dev/null)"; got=$?
  case "$axis" in malformed) want=14 ;; *) want=11 ;; esac
  assert_eq "$axis authority has stable failure exit" "$want" "$got"
  assert_eq "$axis authority emits no success" "" "$out"
  assert_eq "$axis authority appends nothing" 0 "$(jsonl_count "$repo/.agent-firm/runs/target/run.jsonl")"
done

t_case "contract and ledger paths reject modes, types, and redirection without touching outside data"
repo7="$(mk_repo)"; mk_role_fixture "$repo7" target source; auth7="$(authority_for target)"
chmod 600 "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
assert_rc "wrong contract mode" 12 invoke_start "$repo7" target build/R-03 "$auth7"
chmod 644 "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
mv "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md" "$repo7/real-contract"
ln -s "$repo7/real-contract" "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
assert_rc "symlink contract" 12 invoke_start "$repo7" target build/R-03 "$auth7"
assert_eq "symlink target body remains unchanged" "sealed role contract" "$(cat "$repo7/real-contract")"
rm "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
mkdir "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
assert_rc "directory contract" 12 invoke_start "$repo7" target build/R-03 "$auth7"
rm -r "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
mkfifo "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
assert_rc "FIFO contract is rejected without blocking" 12 invoke_start "$repo7" target build/R-03 "$auth7"
rm "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
printf 'sealed role contract\n' > "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"; chmod 644 "$repo7/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
printf 'outside\n' > "$repo7/outside-ledger"
ln -s "$repo7/outside-ledger" "$repo7/.agent-firm/runs/target/run.jsonl"
assert_rc "symlink ledger" 14 invoke_start "$repo7" target build/R-03 "$auth7"
assert_eq "redirected ledger target unchanged" outside "$(cat "$repo7/outside-ledger")"
rm "$repo7/.agent-firm/runs/target/run.jsonl"
printf 'not-json\n' > "$repo7/.agent-firm/runs/target/run.jsonl"; chmod 600 "$repo7/.agent-firm/runs/target/run.jsonl"
assert_rc "malformed target ledger" 14 invoke_start "$repo7" target build/R-03 "$auth7"

t_case "every resolved component and sidecar target is no-follow and permission checked"
repo7b="$(mk_repo)"; mk_role_fixture "$repo7b" target source; auth7b="$(authority_for target)"
mv "$repo7b/.agent-firm/runs/target/role-contracts" "$repo7b/.agent-firm/runs/target/real-contracts"
ln -s real-contracts "$repo7b/.agent-firm/runs/target/role-contracts"
assert_rc "symlinked intermediate contract directory" 12 invoke_start "$repo7b" target build/R-03 "$auth7b"
rm "$repo7b/.agent-firm/runs/target/role-contracts"
mv "$repo7b/.agent-firm/runs/target/real-contracts" "$repo7b/.agent-firm/runs/target/role-contracts"
assert_rc "outside-run device path" 12 "$LOG" --run "$repo7b/.agent-firm/runs/target" --strict --role-start \
  --stage build/R-03 --role implementer --contract /dev/null --event build_started \
  --authority-json "$auth7b" --agent /root/implementer --activation-json "$ACTIVATION"
mv "$repo7b/.agent-firm/runs/target/run-metadata.json" "$repo7b/real-metadata.json"
ln -s "$repo7b/real-metadata.json" "$repo7b/.agent-firm/runs/target/run-metadata.json"
assert_rc "symlinked run metadata" 10 invoke_start "$repo7b" target build/R-03 "$auth7b"
rm "$repo7b/.agent-firm/runs/target/run-metadata.json"
mv "$repo7b/real-metadata.json" "$repo7b/.agent-firm/runs/target/run-metadata.json"
printf 'outside-lock\n' > "$repo7b/outside-lock"
ln -s "$repo7b/outside-lock" "$repo7b/.agent-firm/runs/target/run.jsonl.lock"
assert_rc "symlinked stable lock" 14 invoke_start "$repo7b" target build/R-03 "$auth7b"
assert_eq "redirected lock target remains unchanged" outside-lock "$(cat "$repo7b/outside-lock")"
rm "$repo7b/.agent-firm/runs/target/run.jsonl.lock"
printf '{}\n' > "$repo7b/.agent-firm/runs/target/run.jsonl"
assert_rc "wrong ledger mode" 14 invoke_start "$repo7b" target build/R-03 "$auth7b"
chmod 600 "$repo7b/.agent-firm/runs/target/run.jsonl"
chmod 777 "$repo7b/.agent-firm/runs/target/role-contracts"
assert_rc "unsafe contract directory permissions" 12 invoke_start "$repo7b" target build/R-03 "$auth7b"
chmod 755 "$repo7b/.agent-firm/runs/target/role-contracts"
mv "$repo7b/.agent-firm/runs/target" "$repo7b/.agent-firm/runs/real-target"
ln -s real-target "$repo7b/.agent-firm/runs/target"
assert_rc "symlinked run component" 10 invoke_start "$repo7b" target build/R-03 "$auth7b"

t_case "ordinary legacy _started and scalar stage-role-agent rows never occupy native activation identity"
repo7c="$(mk_repo)"; mk_role_fixture "$repo7c" target source; auth7c="$(authority_for target)"
printf '%s\n' \
  '{"ts":"2020-01-02T00:00:00Z","event":"build_started","event_id":"evt-ordinary-scalar-start","run_id":"target","stage":"build/R-03","role":"implementer","agent":"/root/legacy"}' \
  > "$repo7c/.agent-firm/runs/target/run.jsonl"
chmod 600 "$repo7c/.agent-firm/runs/target/run.jsonl"
assert_rc "complete native activation may follow matching ordinary scalar row" 0 \
  invoke_start "$repo7c" target build/R-03 "$auth7c"
assert_eq "ordinary and native rows both remain complete" 2 \
  "$(jsonl_count "$repo7c/.agent-firm/runs/target/run.jsonl")"
assert_ok "only the complete envelope is native" python3 - "$repo7c/.agent-firm/runs/target/run.jsonl" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1],encoding="utf-8")]
assert sum("activation" in row for row in rows)==1
assert sum("activation" not in row and row.get("role")=="implementer" for row in rows)==1
PY

t_case "same activation is exactly-once sequentially and under a concurrent race"
repo8="$(mk_repo)"; mk_role_fixture "$repo8" target source; auth8="$(authority_for target)"
assert_rc "first activation wins" 0 invoke_start "$repo8" target build/R-03 "$auth8"
dup_out="$(invoke_start "$repo8" target build/R-03 "$auth8" 2>/dev/null)"; dup_rc=$?
assert_eq "sequential duplicate is DUPLICATE_ACTIVATION" 13 "$dup_rc"
assert_eq "duplicate has no success object" "" "$dup_out"
repo9="$(mk_repo)"; mk_role_fixture "$repo9" target source; auth9="$(authority_for target)"
race_dir="$(mktemp -d "${TMPDIR:-/tmp}/firm-role-race.XXXXXX")"; t_track "$race_dir"
for n in 1 2 3 4 5 6; do
  ( invoke_start "$repo9" target build/R-03 "$auth9" > "$race_dir/$n.out" 2> "$race_dir/$n.err"; printf '%s' "$?" > "$race_dir/$n.rc" ) &
done
wait
winners=0; losers=0
for n in 1 2 3 4 5 6; do
  got="$(cat "$race_dir/$n.rc")"
  case "$got" in 0) winners=$((winners+1)) ;; 13) losers=$((losers+1)) ;; esac
done
assert_eq "one concurrent activation wins" 1 "$winners"
assert_eq "all concurrent losers are duplicate activation" 5 "$losers"
assert_eq "race retains exactly one complete JSON event" 1 "$(jsonl_count "$repo9/.agent-firm/runs/target/run.jsonl")"

t_case "non-conflicting concurrent lifecycle instances remain complete"
repo10="$(mk_repo)"; mk_role_fixture "$repo10" target source; auth10="$(authority_for target)"
parallel_dir="$(mktemp -d "${TMPDIR:-/tmp}/firm-role-parallel.XXXXXX")"; t_track "$parallel_dir"
( invoke_start "$repo10" target build/R-03 "$auth10" > "$parallel_dir/a.out" 2> "$parallel_dir/a.err"; printf '%s' "$?" > "$parallel_dir/a.rc" ) &
( invoke_start "$repo10" target build/R-04 "$auth10" > "$parallel_dir/b.out" 2> "$parallel_dir/b.err"; printf '%s' "$?" > "$parallel_dir/b.rc" ) &
wait
assert_eq "R-03 succeeds" 0 "$(cat "$parallel_dir/a.rc")"
assert_eq "R-04 succeeds" 0 "$(cat "$parallel_dir/b.rc")"
assert_eq "two complete events survive" 2 "$(jsonl_count "$repo10/.agent-firm/runs/target/run.jsonl")"

t_case "every pre-replace fault leaves the ledger byte-identical and emits no success"
for point in before_contract_read during_drift_validation contract_replace contract_truncate contract_grow contract_mutate contract_mode before_temp_write partial_temp_write temp_fsync pre_rename; do
  repo="$(mk_repo)"; mk_role_fixture "$repo" target source; auth="$(authority_for target)"
  before="$(ledger_sha_or_absent "$repo/.agent-firm/runs/target/run.jsonl")"
  out="$(invoke_start_fp "$point" "$repo" target "$auth" 2>/dev/null)"; got=$?
  case "$point" in before_contract_read|during_drift_validation|contract_*) want=12 ;; *) want=15 ;; esac
  assert_eq "$point returns its stable class" "$want" "$got"
  assert_eq "$point emits no success object" "" "$out"
  assert_eq "$point leaves the old ledger byte-identical" "$before" \
    "$(ledger_sha_or_absent "$repo/.agent-firm/runs/target/run.jsonl")"
  assert_eq "$point cleans the exact private temp" 0 \
    "$(find "$repo/.agent-firm/runs/target" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
done

t_case "post-replace durability/proof faults retain one complete discoverable event without success"
for point in post_rename directory_fsync post_append_pre_proof proof_read proof_compare; do
  repo="$(mk_repo)"; mk_role_fixture "$repo" target source; auth="$(authority_for target)"
  out="$(invoke_start_fp "$point" "$repo" target "$auth" 2>/dev/null)"; got=$?
  case "$point" in post_rename|directory_fsync) want=15 ;; *) want=16 ;; esac
  assert_eq "$point returns its stable class" "$want" "$got"
  assert_eq "$point emits no success object" "" "$out"
  assert_eq "$point leaves exactly one complete event" 1 "$(jsonl_count "$repo/.agent-firm/runs/target/run.jsonl")"
  assert_ok "$point event remains uniquely discoverable" python3 - "$repo/.agent-firm/runs/target/run.jsonl" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1]) if x.strip()]
assert len(rows)==1 and rows[0]["event"]=="build_started" and rows[0]["stage"]=="build/R-03"
PY
done

t_case "failpoints are inert without the explicit temp-fixture guard"
repo10b="$(mk_repo)"; mk_role_fixture "$repo10b" target source; auth10b="$(authority_for target)"
unguarded="$(FIRM_LEDGER_FAILPOINT=pre_rename invoke_start "$repo10b" target build/R-03 "$auth10b" 2>/dev/null)"; unguarded_rc=$?
assert_eq "unguarded failpoint cannot alter production-shaped behavior" 0 "$unguarded_rc"
assert_ok "unguarded call returns the ordinary closed success schema" python3 -c \
  'import json,sys; d=json.loads(sys.argv[1]); assert d["schema_version"]==1 and d["event"]=="build_started"' "$unguarded"

t_case "large contracts are streamed into a small derived result without body retention"
repo10c="$(mk_repo)"; mk_role_fixture "$repo10c" target source; auth10c="$(authority_for target)"
python3 - "$repo10c/.agent-firm/runs/target/role-contracts/R-03-implementer.md" <<'PY'
import sys
with open(sys.argv[1],"wb") as fh:
    block=b"bounded-stream-fixture-"*4096
    remaining=5*1024*1024
    while remaining:
        part=block[:min(len(block),remaining)]
        fh.write(part); remaining-=len(part)
PY
chmod 644 "$repo10c/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
large_result="$(invoke_start "$repo10c" target build/R-03 "$auth10c")"; large_rc=$?
assert_eq "five-megabyte contract succeeds" 0 "$large_rc"
assert_ok "result contains only bounded derived provenance, never contract bytes" python3 - \
  "$large_result" <<'PY'
import json,sys
raw=sys.argv[1]; result=json.loads(raw)
assert result["contract"]["bytes"]==5*1024*1024
assert len(raw)<4096
assert "bounded-stream-fixture" not in raw
PY

t_case "contract contents and process environment never appear in role-start diagnostics"
repo11="$(mk_repo)"; mk_role_fixture "$repo11" target source
printf 'SEALED_BODY_DO_NOT_DISCLOSE\n' > "$repo11/.agent-firm/runs/target/role-contracts/R-03-implementer.md"; chmod 600 "$repo11/.agent-firm/runs/target/role-contracts/R-03-implementer.md"
diag="$(FIRM_TEST_SECRET=ENV_DO_NOT_DISCLOSE invoke_start "$repo11" target build/R-03 "$(authority_for target)" 2>&1 >/dev/null)"; diag_rc=$?
assert_eq "private contract failure is classified" 12 "$diag_rc"
case "$diag" in *SEALED_BODY_DO_NOT_DISCLOSE*|*ENV_DO_NOT_DISCLOSE*) leaked=yes ;; *) leaked=no ;; esac
assert_eq "diagnostic contains neither body nor environment secret" no "$leaked"
case "$diag" in *'"activation"'*|*'"model"'*) shaped=yes ;; *) shaped=no ;; esac
assert_eq "failure is not success-shaped" no "$shaped"

t_summary
