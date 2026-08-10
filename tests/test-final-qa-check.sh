#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FINAL="$BIN/firm-final-qa-check"
NEW="$BIN/firm-new-run"
QAC="$BIN/firm-qa-checkout"

repo="$(mk_repo)"
( cd "$repo" && "$NEW" --primary claude final-foundation fast_path >/dev/null )
run_rel="$(cat "$repo/.agent-firm/CURRENT_RUN")"; run="$repo/$run_rel"; run_id="$(basename "$run")"
( cd "$repo" && git checkout -qb "integration/$run_id" && mkdir -p auth && printf 'safe\n' > result.txt && printf 'token\n' > auth/token.txt && git add -A && git commit -qm candidate && git checkout -q main )
( cd "$repo" && "$QAC" >/dev/null )
printf 'proof\n' > "$run/09-test-evidence/proof.log"
printf 'round\n' > "$run/09-test-evidence/round.log"

reset_case() { # primary provider
  python3 - "$run" "$1" <<'PY'
import hashlib,json,os,secrets,shutil,sys,yaml
run,primary=sys.argv[1:]; c=json.load(open(run+"/09-test-evidence/qa-candidate.json")); sha=c["candidate_sha"]; gen=c["generation"]
def event_ref(path,event="evidence_produced"):
 raw=open(run+"/"+path,"rb").read(); eid="evt-fixture-"+secrets.token_hex(8)
 item={"ts":"2026-08-10T00:00:00Z","event":event,"event_id":eid,"run_id":os.path.basename(run),
       "sha":sha,"generation":str(gen),"path":path,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":str(len(raw))}
 with open(run+"/run.jsonl","a") as fh: fh.write(json.dumps(item,separators=(",",":"))+"\n")
 return {"path":path,"candidate_sha":sha,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw),"producer":{"event_id":eid,"event":event}}
secondary="gpt" if primary=="claude" else "claude"
shutil.rmtree(run+"/09-test-evidence/reviewer-attempts",ignore_errors=True)
metadata=json.load(open(run+"/run-metadata.json")); metadata["primary_provider"]=primary; json.dump(metadata,open(run+"/run-metadata.json","w"),separators=(",",":"))
criteria={"task_slug":"fixture","track":"fast_path","criteria":[{"id":"AC-001","type":"functional","statement":"fixture","verification":"automated_test"}],"explicitly_out_of_scope":[]}
yaml.safe_dump(criteria,open(run+"/01-acceptance-criteria.yaml","w"),sort_keys=False)
proof=event_ref("09-test-evidence/proof.log")
verdict={"verdict":"APPROVE","commit_sha":sha,"run_id":os.path.basename(run),"generation":gen,"provider":"primary","attempt_id":"primary-fixture",
"environment":"fixture","commands_run":[],"unit":{"status":"pass","evidence":"09-test-evidence/proof.log"},
"integration":{"status":"not_applicable","evidence":"none"},"e2e":{"status":"not_applicable","evidence":"none"},"visual":{"status":"not_applicable","evidence":"none"},
"acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"09-test-evidence/proof.log"}],
"untested_risks":[],"blockers":[],"warnings":[],"artifacts":["09-test-evidence/proof.log"],"summary":"fixture"}
json.dump(verdict,open(run+"/08-qa-verdict.json","w"),indent=2)
for provider in ("gpt","claude"):
 for name in (run+f"/08-qa-verdict.{provider}.json",run+f"/09-test-evidence/reviewer-state.{provider}.json"):
  try: os.unlink(name)
  except FileNotFoundError: pass
trace={"schema_version":2,"task_slug":"fixture","candidate":{
"run_id":os.path.basename(run),"repository_root":c["repository_root"],"git_common_dir":c["git_common_dir"],"checkout_path":c["checkout_path"],
"source_ref":c["source_ref"],"source_ref_sha":c["source_ref_sha"],"base_sha":c["base_sha"],"commit_sha":sha,"generation":gen},
"matrix":[{"id":"AC-001","implementation_files":["result.txt"],"tests":["fixture"],"manual_verification":"","evidence":[proof],"status":"covered"}],
"two_voice":{"secondary_provider":secondary,"status":"available","required":True},"two_voice_diff":[]}
yaml.safe_dump(trace,open(run+"/traceability.yaml","w"),sort_keys=False)
PY
}

wrapper_attempt() { # provider APPROVE|BLOCK blocker attempt-id current yes|no
  python3 - "$run" "$1" "$2" "$3" "$4" "$5" <<'PY'
import hashlib,json,os,sys
run,provider,word,blocker,attempt_id,current=sys.argv[1:]; c=json.load(open(run+"/09-test-evidence/qa-candidate.json")); sha=c["candidate_sha"]; gen=c["generation"]
adir=run+"/09-test-evidence/reviewer-attempts/"+attempt_id; os.makedirs(adir,exist_ok=False)
verdict={"verdict":word,"commit_sha":sha,"run_id":os.path.basename(run),"generation":gen,"provider":provider,"attempt_id":attempt_id,
"environment":"fixture","commands_run":[],"unit":{"status":"pass","evidence":"09-test-evidence/proof.log"},
"integration":{"status":"not_applicable","evidence":"none"},"e2e":{"status":"not_applicable","evidence":"none"},"visual":{"status":"not_applicable","evidence":"none"},
"acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"09-test-evidence/proof.log"}],"untested_risks":[],
"blockers":([blocker] if blocker else []),"warnings":[],"artifacts":["09-test-evidence/proof.log"],"summary":"fixture"}
vraw=(json.dumps(verdict,indent=2,sort_keys=True)+"\n").encode(); open(adir+"/verdict.json","wb").write(vraw); os.chmod(adir+"/verdict.json",0o600)
eid="evt-wrapper-"+attempt_id; status="approve" if word=="APPROVE" else "block"; rc=0 if status=="approve" else 1
arel="09-test-evidence/reviewer-attempts/"+attempt_id+"/attempt.json"; vrel="09-test-evidence/reviewer-attempts/"+attempt_id+"/verdict.json"
attempt={"schema_version":1,"attempt_id":attempt_id,"provider":provider,"run_id":os.path.basename(run),"candidate_sha":sha,"generation":gen,
"status":status,"exit_code":rc,"started_at":"2026-08-10T00:00:00Z","finished_at":"2026-08-10T00:00:01Z","trusted_reason":None,"phases":[],
"started_event_id":"evt-start-"+attempt_id,"outcome_event_id":eid,"model":{"provider":provider,"tier":"heavyweight","model":"fixture","display":"fixture","effort":"xhigh"},
"prior_verdict":None,"private_raw":None,"raw_expires_epoch":None,"verdict":vrel,"canonical":f"08-qa-verdict.{provider}.json","canonical_promoted":True,
"verdict_sha256":hashlib.sha256(vraw).hexdigest(),"verdict_bytes":len(vraw),"diagnostic":"fixture"}
araw=(json.dumps(attempt,indent=2,sort_keys=True)+"\n").encode(); open(run+"/"+arel,"wb").write(araw); os.chmod(run+"/"+arel,0o600)
event={"ts":"2026-08-10T00:00:01Z","event":"reviewer_approve" if rc==0 else "reviewer_block","event_id":eid,"run_id":os.path.basename(run),
"provider":provider,"generation":str(gen),"sha":sha,"attempt":arel,"attempt_id":attempt_id,"exit_code":str(rc),"verdict":vrel,"canonical":f"08-qa-verdict.{provider}.json",
"phase":"judge","sha256":hashlib.sha256(araw).hexdigest(),"bytes":str(len(araw)),"verdict_sha256":hashlib.sha256(vraw).hexdigest(),"verdict_bytes":str(len(vraw))}
with open(run+"/run.jsonl","a") as fh: fh.write(json.dumps(event,separators=(",",":"))+"\n")
if current=="yes":
 open(run+f"/08-qa-verdict.{provider}.json","wb").write(vraw); os.chmod(run+f"/08-qa-verdict.{provider}.json",0o600)
 json.dump({"schema_version":1,"provider":provider,"candidate_sha":sha,"generation":gen,"last_attempt":int(attempt_id.rsplit("a",1)[-1]),"attempt_id":attempt_id},open(run+f"/09-test-evidence/reviewer-state.{provider}.json","w"))
PY
}

set_disposition() { # kind low|high blocked-attempt fresh-attempt-or-empty
  python3 - "$run" "$1" "$2" "$3" "${4:-}" <<'PY'
import hashlib,json,os,secrets,sys,yaml
run,kind,risk,blocked_id,fresh_id=sys.argv[1:]; p=run+"/traceability.yaml"; d=yaml.safe_load(open(p)); sha=d["candidate"]["commit_sha"]; gen=d["candidate"]["generation"]
def ref(path,event_id=None,event="evidence_produced",provider=None,attempt_id=None):
 raw=open(run+"/"+path,"rb").read()
 if event_id is None:
  event_id="evt-evidence-"+secrets.token_hex(8)
  record={"ts":"2026-08-10T00:00:00Z","event":event,"event_id":event_id,"run_id":os.path.basename(run),"sha":sha,"generation":str(gen),"path":path,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":str(len(raw))}
  with open(run+"/run.jsonl","a") as fh: fh.write(json.dumps(record,separators=(",",":"))+"\n")
 producer={"event_id":event_id,"event":event}
 if provider: producer.update({"provider":provider,"generation":gen,"attempt_id":attempt_id})
 return {"path":path,"candidate_sha":sha,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw),"producer":producer}
provider=d["two_voice"]["secondary_provider"]
criteria=["AC-001"]; paths=["result.txt"]; reasons=["criterion:AC-001:functional","path:result.txt:benign"]
if risk=="high":
 paths=["auth/token.txt"]; reasons=["criterion:AC-001:functional","path:auth/token.txt:auth_permissions_crypto_pii:**/*auth*","path:auth/token.txt:auth_permissions_crypto_pii:**/auth/**"]
entry={"secondary_blocker":"secondary defect","primary_position":"positive evidence-based contrary reading","positive_dissent":True,
"affected_criteria":criteria,"affected_paths":paths,"risk":risk,"risk_reasons":reasons,
"bounded_resolution":{"attempted":True,"rounds":1,"rerun":"block","evidence":ref("09-test-evidence/round.log")},
"evidence":ref("09-test-evidence/proof.log"),"disposition":kind}
if blocked_id:
 path=f"09-test-evidence/reviewer-attempts/{blocked_id}/verdict.json"; entry["blocked_secondary_verdict"]=ref(path,"evt-wrapper-"+blocked_id,"reviewer_block",provider,blocked_id)
if fresh_id:
 path=f"09-test-evidence/reviewer-attempts/{fresh_id}/verdict.json"; entry["fresh_secondary_verdict"]=ref(path,"evt-wrapper-"+fresh_id,"reviewer_approve",provider,fresh_id)
d["two_voice_diff"]=[entry]; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
}

add_record_ref() { # relative event field-name
  python3 - "$run" "$1" "$2" "$3" <<'PY'
import hashlib,json,os,secrets,sys,yaml
run,rel,event,field=sys.argv[1:]; p=run+"/traceability.yaml"; d=yaml.safe_load(open(p)); raw=open(run+"/"+rel,"rb").read(); eid="evt-record-"+secrets.token_hex(8)
record={"ts":"2026-08-10T00:00:00Z","event":event,"event_id":eid,"run_id":os.path.basename(run),"sha":d["candidate"]["commit_sha"],"generation":str(d["candidate"]["generation"]),"path":rel,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":str(len(raw))}
with open(run+"/run.jsonl","a") as fh: fh.write(json.dumps(record,separators=(",",":"))+"\n")
ref={"path":rel,"candidate_sha":d["candidate"]["commit_sha"],"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw),"producer":{"event_id":eid,"event":event}}
if field=="waiver": d["two_voice"]["unavailable_waiver"]=ref
else: d["two_voice_diff"][0]["record"]=ref
yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
}

t_case "both provider orientations require exact wrapper attempt/event/current projection"
reset_case claude; wrapper_attempt gpt APPROVE '' gpt-c1-a0101 yes
assert_rc "Claude-primary plus GPT current wrapper APPROVE passes" 0 "$FINAL" "$run"
reset_case codex; wrapper_attempt claude APPROVE '' claude-c1-a0101 yes
assert_rc "Codex-primary plus Claude current wrapper APPROVE passes" 0 "$FINAL" "$run"
python3 - "$run/08-qa-verdict.claude.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["attempt_id"]="orphan"; json.dump(d,open(p,"w"),indent=2)
PY
assert_rc "orphan/direct canonical verdict cannot pass" 1 "$FINAL" "$run"

t_case "current BLOCK low-risk dissent is mechanically derived and bounded"
reset_case claude; wrapper_attempt gpt BLOCK 'secondary defect' gpt-c1-a0201 yes
set_disposition proceed_with_primary low '' ''
assert_rc "positive low-risk one-round dissent passes" 0 "$FINAL" "$run"
python3 - "$run/traceability.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d["two_voice_diff"][0]["risk"]="high"; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "caller-supplied high/low mismatch blocks" 1 "$FINAL" "$run"
set_disposition proceed_with_primary high '' ''
assert_rc "path-derived high risk cannot proceed with primary" 1 "$FINAL" "$run"

t_case "archived wrapper BLOCK followed by latest current APPROVE is the only fixed/withdrawn chain"
reset_case claude; wrapper_attempt gpt BLOCK 'secondary defect' gpt-c1-a0301 no
wrapper_attempt gpt APPROVE '' gpt-c1-a0302 yes
set_disposition fixed low gpt-c1-a0301 gpt-c1-a0302
assert_rc "archived BLOCK objections plus current APPROVE pass" 0 "$FINAL" "$run"
python3 - "$run" <<'PY'
import json,sys
run=sys.argv[1]; event=None
for line in open(run+"/run.jsonl"):
 item=json.loads(line)
 if item.get("event_id")=="evt-wrapper-gpt-c1-a0302": event=item
with open(run+"/run.jsonl","a") as fh: fh.write(json.dumps(event,separators=(",",":"))+"\n")
PY
assert_rc "duplicate outcome event blocks" 1 "$FINAL" "$run"

t_case "required unavailable and high-risk human resolution return nonpassing decision_required"
reset_case codex
python3 - "$run" <<'PY'
import hashlib,json,os,sys,yaml
run=sys.argv[1]; c=json.load(open(run+"/09-test-evidence/qa-candidate.json")); sha=c["candidate_sha"]; gen=c["generation"]; provider="claude"; aid="claude-c1-a0401"
adir=run+"/09-test-evidence/reviewer-attempts/"+aid; os.makedirs(adir)
eid="evt-unavailable-"+aid; rel=f"09-test-evidence/reviewer-attempts/{aid}/attempt.json"
attempt={"schema_version":1,"attempt_id":aid,"provider":provider,"run_id":os.path.basename(run),"candidate_sha":sha,"generation":gen,"status":"unavailable","exit_code":3,"trusted_reason":"authentication","phases":[],"started_at":"2026-08-10T00:00:00Z","finished_at":"2026-08-10T00:00:01Z","started_event_id":"evt-start-"+aid,"outcome_event_id":eid}
raw=(json.dumps(attempt,indent=2,sort_keys=True)+"\n").encode(); open(run+"/"+rel,"wb").write(raw)
event={"ts":"2026-08-10T00:00:01Z","event":"reviewer_unavailable","event_id":eid,"run_id":os.path.basename(run),"provider":provider,"generation":str(gen),"sha":sha,"attempt":rel,"attempt_id":aid,"exit_code":"3","reason":"authentication","sha256":hashlib.sha256(raw).hexdigest(),"bytes":str(len(raw))}
with open(run+"/run.jsonl","a") as fh: fh.write(json.dumps(event,separators=(",",":"))+"\n")
json.dump({"schema_version":1,"provider":provider,"candidate_sha":sha,"generation":gen,"last_attempt":401,"attempt_id":aid},open(run+f"/09-test-evidence/reviewer-state.{provider}.json","w"))
d=yaml.safe_load(open(run+"/traceability.yaml")); d["two_voice"]["status"]="unavailable"; d["two_voice"]["attempt"]={"path":rel,"provider":provider,"generation":gen,"attempt_id":aid,"candidate_sha":sha,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw),"producer":{"event_id":eid,"event":"reviewer_unavailable","provider":provider,"generation":gen,"attempt_id":aid}}; yaml.safe_dump(d,open(run+"/traceability.yaml","w"),sort_keys=False)
PY
assert_rc "required unavailable without human record is decision_required, not PASS/BLOCK" 4 "$FINAL" "$run"
decision_file="$(find "$run/09-test-evidence" -name 'final-decision-required.*.json' -type f | tail -1)"
assert_output "decision state is structured" '"status": "decision_required"' cat "$decision_file"
sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidate_sha"])' "$run/09-test-evidence/qa-candidate.json")"
attempt_rel="09-test-evidence/reviewer-attempts/claude-c1-a0401/attempt.json"
cat > "$run/09-test-evidence/waiver.yaml" <<EOF
schema_version: 1
type: required_unavailable
actor: human-fixture
occurred_at: 2026-08-10T00:00:00Z
run_id: $run_id
candidate_sha: $sha
provider: claude
decision: waive_required_secondary
attempt: $attempt_rel
trusted_reason: authentication
objections: [required secondary unavailable]
EOF
add_record_ref 09-test-evidence/waiver.yaml waiver_recorded waiver
assert_rc "exact digest-bound waiver passes" 0 "$FINAL" "$run"

reset_case claude; wrapper_attempt gpt BLOCK 'secondary defect' gpt-c1-a0501 yes
set_disposition human_decision high '' ''
assert_rc "missing high-risk human decision is decision_required" 4 "$FINAL" "$run"
cat > "$run/09-test-evidence/human.yaml" <<EOF
schema_version: 1
type: human_decision
actor: human-fixture
occurred_at: 2026-08-10T00:00:00Z
run_id: $run_id
candidate_sha: $sha
decision: proceed
objections: [secondary defect]
EOF
add_record_ref 09-test-evidence/human.yaml human_decision_recorded record
assert_rc "exact digest-bound human record permits fresh mechanical pass" 0 "$FINAL" "$run"

t_summary
