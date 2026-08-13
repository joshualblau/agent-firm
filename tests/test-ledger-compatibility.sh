#!/usr/bin/env bash
# tests/test-ledger-compatibility.sh — independently derived four-family grammar and transaction.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$BIN/firm-ledger-log"
RESOLVER="$BIN/firm-model-resolve"
CODEX_ACTIVATION="$($RESOLVER --provider codex --role implementer --format activation)"
CLAUDE_ACTIVATION="$($RESOLVER --provider claude --role implementer --format activation)"
AUTH_ID="evt-compat-authority-0001"

sha_or_absent() {
  if [ -f "$1" ]; then shasum -a 256 "$1" | awk '{print $1}'; else printf absent; fi
}

mk_eligible_run() {
  local repo="$1" run="$2"
  mk_run "$repo" "$run"
  mkdir -p "$repo/.agent-firm/runs/$run/role-contracts"
  printf '{"run_id":"%s","historical":false,"approval_eligible":true}\n' "$run" \
    > "$repo/.agent-firm/runs/$run/run-metadata.json"
  printf 'independent compatibility role contract\n' \
    > "$repo/.agent-firm/runs/$run/role-contracts/R-01-implementer.md"
  chmod 644 "$repo/.agent-firm/runs/$run/run-metadata.json" \
    "$repo/.agent-firm/runs/$run/role-contracts/R-01-implementer.md"
}

authority_json() {
  local source="$1" event_id="$2" event="$3" fields="$4"
  python3 - "$source" "$event_id" "$event" "$fields" <<'PY'
import json,sys
source,event_id,event,fields=sys.argv[1:]
print(json.dumps([{"source_run":".agent-firm/runs/"+source,"event_id":event_id,
 "expect":{"event":event,"run_id":source,"fields":json.loads(fields)}}],separators=(",",":")))
PY
}

invoke_native() {
  local repo="$1" target="$2" stage="$3" authority="$4" activation="$5"
  "$LOG" --run "$repo/.agent-firm/runs/$target" --strict --role-start \
    --stage "$stage" --role implementer --contract role-contracts/R-01-implementer.md \
    --event build_started --authority-json "$authority" --agent /root/compat_implementer \
    --activation-json "$activation"
}

seed_and_follow() {
  local label="$1" raw="$2" repo run ledger before
  repo="$(mk_repo)"; run=target; mk_run "$repo" "$run"; ledger="$repo/.agent-firm/runs/$run/run.jsonl"
  printf '%s\n' "$raw" > "$ledger"; chmod 600 "$ledger"
  assert_rc "$label is a readable target predecessor" 0 "$LOG" --run "$repo/.agent-firm/runs/$run" \
    --strict --event-id "evt-follow-$label" compatibility_followed "case=$label"
  assert_ok "$label preserves its predecessor and exact appended id" python3 - "$ledger" "evt-follow-$label" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1],encoding="utf-8")]
assert len(rows)==2 and rows[-1]["event_id"]==sys.argv[2]
PY
}

reject_seed() {
  local label="$1" raw="$2" repo ledger before out rc
  repo="$(mk_repo)"; mk_run "$repo" target; ledger="$repo/.agent-firm/runs/target/run.jsonl"
  printf '%s' "$raw" > "$ledger"; chmod 600 "$ledger"; before="$(sha_or_absent "$ledger")"
  out="$($LOG --run "$repo/.agent-firm/runs/target" --strict compatibility_followed 2>/dev/null)"; rc=$?
  assert_eq "$label fails closed" 1 "$rc"
  assert_eq "$label emits no success-shaped stdout" "" "$out"
  assert_eq "$label leaves target bytes unchanged" "$before" "$(sha_or_absent "$ledger")"
}

wait_ready() {
  local ready="$1" n=0
  while [ ! -f "$ready" ] && [ "$n" -lt 1000 ]; do n=$((n+1)); sleep 0.01; done
  [ -f "$ready" ]
}

t_case "accepted-base catalog: exact observations and ordinary producer shapes are readable predecessors"
seed_and_follow shell_observation \
  '{"cmd":"git status --short","event":"bash","ts":"2026-08-12T00:00:00Z"}'
seed_and_follow merge_observation \
  '{"reason":"protected","decision":"block","cmd":"git merge topic","ts":"2026-08-12T00:00:00Z","event":"merge_guard_block"}'

catalog="$(mktemp "${TMPDIR:-/tmp}/firm-ledger-catalog.XXXXXX")"; t_track "$catalog"
cat > "$catalog" <<'EOF'
run_started|{"track":"full_track","event_id":"evt-catalog-run","ts":"2026-08-12T00:00:00Z","event":"run_started","run_id":"target"}
worktree_created_role|{"role":"implementer","branch":"wt/x","run_id":"target","event":"worktree_created","ts":"2026-08-12T00:00:00Z","event_id":"evt-catalog-worktree"}
intake_started|{"event_id":"evt-catalog-intake","run_id":"target","event":"intake_started","ts":"2026-08-12T00:00:00Z"}
architecture_started|{"stage":"Architecture","event_id":"evt-catalog-architecture","run_id":"target","event":"architecture_started","ts":"2026-08-12T00:00:00Z"}
staffing_started|{"agent":"/root/recruiter","event":"staffing_started","event_id":"evt-catalog-staffing","ts":"2026-08-12T00:00:00Z","run_id":"target"}
build_started_scalar|{"agent":"/root/implementer","role":"implementer","stage":"build/R-01","event":"build_started","event_id":"evt-catalog-build","ts":"2026-08-12T00:00:00Z","run_id":"target"}
integration_started|{"event":"integration_started","event_id":"evt-catalog-integration","ts":"2026-08-12T00:00:00Z","run_id":"target"}
review_started|{"event":"review_started","event_id":"evt-catalog-review","ts":"2026-08-12T00:00:00Z","run_id":"target"}
budget_usage|{"turns":"4","active_minutes":"8","agent":"/root/i","role":"implementer","stage":"build/R-01","event":"role_budget_usage","event_id":"evt-catalog-budget","ts":"2026-08-12T00:00:00Z","run_id":"target"}
integrated|{"branch":"integration/x","event":"integrated","event_id":"evt-catalog-integrated","ts":"2026-08-12T00:00:00Z","run_id":"target"}
bench_record|{"outcome":"pass","role":"implementer","event":"bench_record","event_id":"evt-catalog-bench","ts":"2026-08-12T00:00:00Z","run_id":"target"}
hire_scaffolded|{"file":"agents/i.md","role":"implementer","event":"hire_scaffolded","event_id":"evt-catalog-hire","ts":"2026-08-12T00:00:00Z","run_id":"target"}
qa_checkout|{"generation":"1","sha":"0123456789012345678901234567890123456789","event":"qa_checkout","event_id":"evt-catalog-checkout","ts":"2026-08-12T00:00:00Z","run_id":"target"}
qa_clean_check|{"status":"pass","event":"qa_clean_check","event_id":"evt-catalog-clean","ts":"2026-08-12T00:00:00Z","run_id":"target"}
review_outcome|{"reviewer":"REV-SC","outcome":"approve","event":"reviewer_approve","event_id":"evt-catalog-reviewer","ts":"2026-08-12T00:00:00Z","run_id":"target"}
decision_required|{"path":"09-test-evidence/decision.json","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generation":"1","event":"final_decision_required","event_id":"evt-catalog-decision","ts":"2026-08-12T00:00:00Z","run_id":"target"}
human_decision|{"decision":"approve","reference":"human-final-1","event":"human_decision_recorded","event_id":"evt-catalog-human","ts":"2026-08-12T00:00:00Z","run_id":"target"}
waiver_reference|{"reference":"waiver-1","scope":"final","event":"human_waiver_recorded","event_id":"evt-catalog-waiver","ts":"2026-08-12T00:00:00Z","run_id":"target"}
final_gate_pending|{"gate":"Final","event":"final_gate_pending","event_id":"evt-catalog-gate","ts":"2026-08-12T00:00:00Z","run_id":"target"}
empty_extension|{"note":"","custom":"safe value","event":"arbitrary_safe_event","event_id":"evt-catalog-empty","ts":"2026-08-12T00:00:00Z","run_id":"target"}
EOF
while IFS='|' read label raw; do seed_and_follow "$label" "$raw"; done < "$catalog"

t_case "modern ordinary rows are authority-eligible while exact observations are explicitly ineligible"
repo_auth="$(mk_repo)"; mk_eligible_run "$repo_auth" target; mkdir -p "$repo_auth/.agent-firm/runs/source"
printf '%s\n' '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"source"}' \
  > "$repo_auth/.agent-firm/runs/source/run.jsonl"; chmod 600 "$repo_auth/.agent-firm/runs/source/run.jsonl"
ordinary_auth="$(authority_json source "$AUTH_ID" architecture_completed '{"proof":"accepted"}')"
assert_rc "ordinary catalog row can satisfy exact authority projection" 0 invoke_native "$repo_auth" target build/R-01 "$ordinary_auth" "$CODEX_ACTIVATION"
repo_obs="$(mk_repo)"; mk_eligible_run "$repo_obs" target; mkdir -p "$repo_obs/.agent-firm/runs/source"
printf '%s\n' '{"ts":"2020-01-01T00:00:00Z","event":"bash","cmd":"true"}' > "$repo_obs/.agent-firm/runs/source/run.jsonl"
chmod 600 "$repo_obs/.agent-firm/runs/source/run.jsonl"
obs_auth="$(authority_json source "$AUTH_ID" bash '{"cmd":"true"}')"
assert_rc "observation cannot satisfy event-id authority" 11 invoke_native "$repo_obs" target build/R-01 "$obs_auth" "$CODEX_ACTIVATION"

t_case "native Codex and Claude envelopes are target predecessors and native authority predecessors"
for provider in codex claude; do
  case "$provider" in codex) activation="$CODEX_ACTIVATION" ;; *) activation="$CLAUDE_ACTIVATION" ;; esac
  repo="$(mk_repo)"; mk_eligible_run "$repo" source; mk_eligible_run "$repo" target; mkdir -p "$repo/.agent-firm/runs/origin"
  printf '%s\n' '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"origin"}' \
    > "$repo/.agent-firm/runs/origin/run.jsonl"; chmod 600 "$repo/.agent-firm/runs/origin/run.jsonl"
  origin_auth="$(authority_json origin "$AUTH_ID" architecture_completed '{"proof":"accepted"}')"
  native_result="$(invoke_native "$repo" source build/R-01 "$origin_auth" "$activation")"; native_rc=$?
  assert_eq "$provider native producer succeeds" 0 "$native_rc"
  python3 - "$repo/.agent-firm/runs/source/run.jsonl" <<'PY'
import json,sys
row=json.loads(open(sys.argv[1],encoding="utf-8").read()); row["ts"]="2020-01-02T00:00:00Z"
open(sys.argv[1],"w",encoding="utf-8").write(json.dumps(row,separators=(",",":"))+"\n")
PY
  native_id="$(printf '%s' "$native_result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["event_id"])')"
  native_auth="$(authority_json source "$native_id" build_started '{"role":"implementer","stage":"build/R-01"}')"
  assert_rc "$provider native envelope is an authority predecessor" 0 invoke_native "$repo" target build/R-02 "$native_auth" "$activation"
  assert_rc "$provider native envelope remains a target predecessor" 0 "$LOG" --run "$repo/.agent-firm/runs/source" --strict \
    --event-id "evt-$provider-native-follow" native_followed provider="$provider"
done

t_case "ordinary scalar lifecycle metadata never creates a native activation duplicate"
repo_scalar="$(mk_repo)"; mk_eligible_run "$repo_scalar" target; mkdir -p "$repo_scalar/.agent-firm/runs/source"
printf '%s\n' \
  '{"agent":"/root/old","role":"implementer","stage":"build/R-01","event":"build_started","event_id":"evt-scalar-started","ts":"2020-01-01T00:00:00Z","run_id":"target"}' \
  > "$repo_scalar/.agent-firm/runs/target/run.jsonl"
printf '%s\n' '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"source"}' \
  > "$repo_scalar/.agent-firm/runs/source/run.jsonl"
chmod 600 "$repo_scalar/.agent-firm/runs/target/run.jsonl" "$repo_scalar/.agent-firm/runs/source/run.jsonl"
assert_rc "complete native activation may follow ordinary scalar _started row" 0 invoke_native "$repo_scalar" target build/R-01 \
  "$(authority_json source "$AUTH_ID" architecture_completed '{"proof":"accepted"}')" "$CODEX_ACTIVATION"

t_case "closed grammar rejects common, observation, extension, duplicate-key, incomplete, and oversized mutations"
reject_seed common_missing_id '{"ts":"2026-08-12T00:00:00Z","event":"ordinary","run_id":"target"}\n'
reject_seed common_wrong_type '{"ts":"2026-08-12T00:00:00Z","event":"ordinary","event_id":3,"run_id":"target"}\n'
reject_seed common_foreign_run '{"ts":"2026-08-12T00:00:00Z","event":"ordinary","event_id":"evt-bad-foreign","run_id":"other"}\n'
reject_seed naive_timestamp '{"ts":"2026-08-12T00:00:00","event":"ordinary","event_id":"evt-bad-time","run_id":"target"}\n'
reject_seed nonstring_extension '{"ts":"2026-08-12T00:00:00Z","event":"ordinary","event_id":"evt-bad-typed","run_id":"target","value":false}\n'
reject_seed duplicate_json_key '{"ts":"2026-08-12T00:00:00Z","event":"ordinary","event":"forged","event_id":"evt-bad-dup-key","run_id":"target"}\n'
reject_seed incomplete_line '{"ts":"2026-08-12T00:00:00Z","event":"ordinary","event_id":"evt-bad-incomplete","run_id":"target"}'
reject_seed observation_extra '{"ts":"2026-08-12T00:00:00Z","event":"bash","cmd":"true","extra":"x"}\n'
reject_seed observation_wrong_type '{"ts":"2026-08-12T00:00:00Z","event":"merge_guard_block","cmd":"x","decision":false,"reason":"x"}\n'
oversized="$(python3 -c 'print("x"*(1024*1024+1),end="")')"
reject_seed oversized_line "$oversized\n"

t_case "every native-only discriminator selects complete native validation with no ordinary fallback"
for field in contract authority activation activation_justification; do
  reject_seed "partial_$field" \
    "{\"ts\":\"2026-08-12T00:00:00Z\",\"event\":\"ordinary\",\"event_id\":\"evt-partial-$field\",\"run_id\":\"target\",\"$field\":\"forged\"}\n"
done
reject_seed mixed_native_fields \
  '{"ts":"2026-08-12T00:00:00Z","event":"build_started","event_id":"evt-mixed-native","run_id":"target","stage":"build/R-01","role":"implementer","agent":"/root/i","contract":{},"authority":[],"activation":{},"ordinary":"mixed"}\n'

t_case "stored native nested mutations fail before target append"
repo_native="$(mk_repo)"; mk_eligible_run "$repo_native" source; mkdir -p "$repo_native/.agent-firm/runs/origin"
printf '%s\n' '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"origin"}' \
  > "$repo_native/.agent-firm/runs/origin/run.jsonl"; chmod 600 "$repo_native/.agent-firm/runs/origin/run.jsonl"
invoke_native "$repo_native" source build/R-01 \
  "$(authority_json origin "$AUTH_ID" architecture_completed '{"proof":"accepted"}')" "$CODEX_ACTIVATION" >/dev/null
valid_native="$repo_native/.agent-firm/runs/source/run.jsonl"
for mutation in top_extra contract_digest authority_empty authority_repeat activation_adapter activation_argv activation_apply event_suffix justification; do
  repo_bad="$(mk_repo)"; mk_run "$repo_bad" target; ledger_bad="$repo_bad/.agent-firm/runs/target/run.jsonl"
  python3 - "$valid_native" "$ledger_bad" "$mutation" <<'PY'
import copy,json,sys
row=json.loads(open(sys.argv[1],encoding="utf-8").read()); m=sys.argv[3]; row["run_id"]="target"
if m=="top_extra": row["extra"]="x"
elif m=="contract_digest": row["contract"]["sha256"]="X"*64
elif m=="authority_empty": row["authority"]=[]
elif m=="authority_repeat": row["authority"].append(copy.deepcopy(row["authority"][0]))
elif m=="activation_adapter": row["activation"]["adapter_source"]="commands/start.md"
elif m=="activation_argv": row["activation"]["resolver_argv"][2]="claude"
elif m=="activation_apply": row["activation"]["apply"]["model"]="forged"
elif m=="event_suffix": row["event"]="build_completed"
elif m=="justification": row["activation_justification"]="not-legal-for-role"
open(sys.argv[2],"w",encoding="utf-8").write(json.dumps(row,separators=(",",":"))+"\n")
PY
  chmod 600 "$ledger_bad"; before_bad="$(sha_or_absent "$ledger_bad")"
  out_bad="$($LOG --run "$repo_bad/.agent-firm/runs/target" --strict native_mutation_follow 2>/dev/null)"; rc_bad=$?
  assert_eq "$mutation native mutation fails" 1 "$rc_bad"
  assert_eq "$mutation emits no stdout" "" "$out_bad"
  assert_eq "$mutation remains byte-identical" "$before_bad" "$(sha_or_absent "$ledger_bad")"
done

t_case "barrier-controlled ordinary duplicates and bounded many-writer schedule retain an exact union"
repo_con="$(mk_repo)"; mk_run "$repo_con" target; run_con="$repo_con/.agent-firm/runs/target"
barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-barrier.XXXXXX")"; t_track "$barrier"
( FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_BARRIER_PHASE=after_lock FIRM_LEDGER_BARRIER_DIR="$barrier" \
    FIRM_LEDGER_BARRIER_TOKEN=first "$LOG" --run "$run_con" --strict --event-id evt-many-0 many_writer sequence=0 \
    > "$barrier/first.out" 2> "$barrier/first.err"; printf '%s' "$?" > "$barrier/first.rc" ) & first_pid=$!
assert_ok "first writer reaches named after_lock barrier" wait_ready "$barrier/first.ready"
for n in 1 2 3 4 5 6 7 8; do
  ( "$LOG" --run "$run_con" --strict --event-id "evt-many-$n" many_writer "sequence=$n" \
      > "$barrier/$n.out" 2> "$barrier/$n.err"; printf '%s' "$?" > "$barrier/$n.rc" ) &
done
printf 'release\n' > "$barrier/first.release"; wait "$first_pid"; wait
successes=0
for n in first 1 2 3 4 5 6 7 8; do [ "$(cat "$barrier/$n.rc")" -eq 0 ] && successes=$((successes+1)); done
assert_eq "every deterministically queued distinct writer succeeds" 9 "$successes"
assert_ok "many-writer final id set is the exact complete union" python3 - "$run_con/run.jsonl" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1],encoding="utf-8")]
assert {r["event_id"] for r in rows}=={"evt-many-%d"%n for n in range(9)}
assert all(r["event"]=="many_writer" for r in rows)
PY

repo_dup="$(mk_repo)"; mk_run "$repo_dup" target; run_dup="$repo_dup/.agent-firm/runs/target"
dup_barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-dupbarrier.XXXXXX")"; t_track "$dup_barrier"
( FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_BARRIER_PHASE=after_lock FIRM_LEDGER_BARRIER_DIR="$dup_barrier" \
    FIRM_LEDGER_BARRIER_TOKEN=winner "$LOG" --run "$run_dup" --strict --event-id evt-forced-duplicate ordinary_duplicate \
    > "$dup_barrier/a.out" 2> "$dup_barrier/a.err"; printf '%s' "$?" > "$dup_barrier/a.rc" ) & a_pid=$!
assert_ok "duplicate winner holds the transaction lock" wait_ready "$dup_barrier/winner.ready"
( "$LOG" --run "$run_dup" --strict --event-id evt-forced-duplicate ordinary_duplicate \
    > "$dup_barrier/b.out" 2> "$dup_barrier/b.err"; printf '%s' "$?" > "$dup_barrier/b.rc" ) & b_pid=$!
printf 'release\n' > "$dup_barrier/winner.release"; wait "$a_pid"; wait "$b_pid"
assert_eq "forced first identical id wins" 0 "$(cat "$dup_barrier/a.rc")"
assert_eq "forced duplicate loser is strict failure" 1 "$(cat "$dup_barrier/b.rc")"
assert_eq "duplicate loser stdout is empty" "" "$(cat "$dup_barrier/b.out")"

t_case "all four seeded families and a decision row survive a forced mixed ordinary/native schedule"
repo_mix="$(mk_repo)"; mk_eligible_run "$repo_mix" target; mkdir -p "$repo_mix/.agent-firm/runs/source"
printf '%s\n' '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"source"}' \
  > "$repo_mix/.agent-firm/runs/source/run.jsonl"; chmod 600 "$repo_mix/.agent-firm/runs/source/run.jsonl"
mix_auth="$(authority_json source "$AUTH_ID" architecture_completed '{"proof":"accepted"}')"
invoke_native "$repo_mix" target build/seed "$mix_auth" "$CODEX_ACTIVATION" >/dev/null
printf '%s\n' \
  '{"ts":"2020-01-02T00:00:00Z","event":"bash","cmd":"true"}' \
  '{"ts":"2020-01-02T00:00:01Z","event":"merge_guard_block","cmd":"git merge x","decision":"block","reason":"protected"}' \
  >> "$repo_mix/.agent-firm/runs/target/run.jsonl"
"$LOG" --run "$repo_mix/.agent-firm/runs/target" --strict --event-id evt-mix-decision \
  final_decision_required path=09-test-evidence/decision.json sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null
mix_barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-mixbarrier.XXXXXX")"; t_track "$mix_barrier"
( FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_BARRIER_PHASE=after_lock FIRM_LEDGER_BARRIER_DIR="$mix_barrier" \
    FIRM_LEDGER_BARRIER_TOKEN=ordinary "$LOG" --run "$repo_mix/.agent-firm/runs/target" --strict \
    --event-id evt-mix-ordinary mixed_ordinary role=implementer \
    > "$mix_barrier/ordinary.out" 2> "$mix_barrier/ordinary.err"; printf '%s' "$?" > "$mix_barrier/ordinary.rc" ) & mix_o_pid=$!
assert_ok "ordinary writer holds the mixed transaction domain" wait_ready "$mix_barrier/ordinary.ready"
( invoke_native "$repo_mix" target build/R-02 "$mix_auth" "$CLAUDE_ACTIVATION" \
    > "$mix_barrier/native.out" 2> "$mix_barrier/native.err"; printf '%s' "$?" > "$mix_barrier/native.rc" ) & mix_n_pid=$!
printf 'release\n' > "$mix_barrier/ordinary.release"; wait "$mix_o_pid"; wait "$mix_n_pid"
assert_eq "mixed ordinary writer succeeds" 0 "$(cat "$mix_barrier/ordinary.rc")"
assert_eq "mixed native writer succeeds" 0 "$(cat "$mix_barrier/native.rc")"
assert_ok "all-family seeded mixed final ledger has exact family and success union" python3 - \
  "$repo_mix/.agent-firm/runs/target/run.jsonl" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1],encoding="utf-8")]
ids={r.get("event_id") for r in rows if "event_id" in r}
assert {"evt-mix-decision","evt-mix-ordinary"}.issubset(ids)
assert sum(r.get("event")=="build_started" and "activation" in r for r in rows)==2
assert sum(r.get("event")=="bash" and set(r)=={"ts","event","cmd"} for r in rows)==1
assert sum(r.get("event")=="merge_guard_block" and "event_id" not in r for r in rows)==1
PY

t_case "descriptor barriers detect lock, target-ledger, and private-temp entry substitution"
repo_sub="$(mk_repo)"; mk_run "$repo_sub" target; run_sub="$repo_sub/.agent-firm/runs/target"
"$LOG" --run "$run_sub" --strict --event-id evt-sub-seed substitution_seed >/dev/null
for axis in lock ledger temp; do
  sub_barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-sub-$axis.XXXXXX")"; t_track "$sub_barrier"
  case "$axis" in lock) phase=after_lock ;; ledger) phase=after_source_open ;; temp) phase=after_temp_fsync ;; esac
  before_sub="$(sha_or_absent "$run_sub/run.jsonl")"
  ( FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_BARRIER_PHASE="$phase" FIRM_LEDGER_BARRIER_DIR="$sub_barrier" \
      FIRM_LEDGER_BARRIER_TOKEN=writer "$LOG" --run "$run_sub" --strict \
      --event-id "evt-sub-$axis" substitution_attempt "axis=$axis" \
      > "$sub_barrier/out" 2> "$sub_barrier/err"; printf '%s' "$?" > "$sub_barrier/rc" ) & sub_pid=$!
  assert_ok "$axis substitution reaches its named barrier" wait_ready "$sub_barrier/writer.ready"
  case "$axis" in
    lock)
      mv "$run_sub/run.jsonl.lock" "$sub_barrier/original-lock"; printf 'attacker-lock\n' > "$run_sub/run.jsonl.lock"; chmod 600 "$run_sub/run.jsonl.lock" ;;
    ledger)
      mv "$run_sub/run.jsonl" "$sub_barrier/original-ledger"; cp "$sub_barrier/original-ledger" "$run_sub/run.jsonl"; chmod 600 "$run_sub/run.jsonl" ;;
    temp)
      temp_name="$(sed 's/^[^:]*://' "$sub_barrier/writer.ready" | tr -d '\n')"
      mv "$run_sub/$temp_name" "$sub_barrier/original-temp"; printf 'attacker-temp\n' > "$run_sub/$temp_name"; chmod 600 "$run_sub/$temp_name" ;;
  esac
  printf 'release\n' > "$sub_barrier/writer.release"; wait "$sub_pid"
  assert_eq "$axis substitution fails strict append" 1 "$(cat "$sub_barrier/rc")"
  assert_eq "$axis substitution emits no success stdout" "" "$(cat "$sub_barrier/out")"
  case "$axis" in
    lock) assert_eq "replacement lock sentinel remains byte-identical" attacker-lock "$(cat "$run_sub/run.jsonl.lock")" ;;
    ledger)
      assert_eq "replacement ledger remains the old complete bytes" "$before_sub" "$(sha_or_absent "$run_sub/run.jsonl")"
      mv "$sub_barrier/original-ledger" "$run_sub/run.jsonl" ;;
    temp) assert_eq "cleanup does not unlink substituted temp" attacker-temp "$(cat "$run_sub/$temp_name")" ;;
  esac
  if [ "$axis" = lock ]; then mv "$sub_barrier/original-lock" "$run_sub/run.jsonl.lock"; fi
  if [ "$axis" = temp ]; then mv "$run_sub/$temp_name" "$sub_barrier/attacker-temp"; fi
done

t_summary
