#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FINAL="$BIN/firm-final-qa-check"
NEW="$BIN/firm-new-run"
QAC="$BIN/firm-qa-checkout"
LOG="$BIN/firm-ledger-log"

repo="$(mk_repo)"
( cd "$repo" && "$NEW" --primary claude final-matrix fast_path >/dev/null )
run_rel="$(cat "$repo/.agent-firm/CURRENT_RUN")"; run="$repo/$run_rel"; run_id="$(basename "$run")"
( cd "$repo" && git checkout -qb "integration/$run_id" && printf 'safe\n' > result.txt && git add -A && git commit -qm candidate && git checkout -q main )
( cd "$repo" && "$QAC" >/dev/null )
printf 'proof\n' > "$run/09-test-evidence/proof.log"
printf 'round\n' > "$run/09-test-evidence/round.log"

verdict_file() { # path verdict provider blocker [attempt]
  python3 - "$run" "$1" "$2" "$3" "${4:-}" "${5:-fixture-attempt}" <<'PY'
import json,os,sys
run,path,word,provider,blocker,attempt=sys.argv[1:]
c=json.load(open(run+"/09-test-evidence/qa-candidate.json"))
d={"verdict":word,"commit_sha":c["candidate_sha"],"run_id":os.path.basename(run),"generation":c["generation"],
"provider":provider,"attempt_id":attempt,"environment":"fixture","commands_run":[],
"unit":{"status":"pass","evidence":"09-test-evidence/proof.log"},
"integration":{"status":"not_applicable","evidence":"none"},"e2e":{"status":"not_applicable","evidence":"none"},
"visual":{"status":"not_applicable","evidence":"none"},
"acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"09-test-evidence/proof.log"}],
"untested_risks":[],"blockers":([blocker] if blocker else []),"warnings":[],
"artifacts":["09-test-evidence/proof.log"],"summary":"fixture"}
json.dump(d,open(path,"w"),indent=2)
PY
}

reset_case() { # primary orientation, security true|false
  primary="$1"; security="$2"
  rm -f "$run/08-qa-verdict.gpt.json" "$run/08-qa-verdict.claude.json"
  python3 - "$run" "$primary" "$security" <<'PY'
import json,os,sys,yaml
run,primary,security=sys.argv[1:]
c=json.load(open(run+"/09-test-evidence/qa-candidate.json")); sha=c["candidate_sha"]
json.dump({"run_id":os.path.basename(run),"track":"fast_path","primary_provider":primary},open(run+"/run-metadata.json","w"))
criteria={"task_slug":"fixture","track":"fast_path","criteria":[{"id":"AC-001","type":("security_privacy" if security=="true" else "functional"),"statement":"fixture","verification":"automated_test"}],"explicitly_out_of_scope":[]}
yaml.safe_dump(criteria,open(run+"/01-acceptance-criteria.yaml","w"),sort_keys=False)
secondary="gpt" if primary=="claude" else "claude"
trace={"schema_version":1,"task_slug":"fixture","candidate":{"run_id":os.path.basename(run),"commit_sha":sha,"generation":c["generation"],"checkout_path":c["checkout_path"]},
"matrix":[{"id":"AC-001","implementation_files":["result.txt"],"tests":["fixture"],"manual_verification":"",
"evidence":[{"path":"09-test-evidence/proof.log","candidate_sha":sha}],"status":"covered"}],
"two_voice":{"secondary_provider":secondary,"status":"available","required":security=="true"},"two_voice_diff":[]}
yaml.safe_dump(trace,open(run+"/traceability.yaml","w"),sort_keys=False)
PY
  verdict_file "$run/08-qa-verdict.json" APPROVE primary
}

set_voice() { # status required
  python3 - "$run/traceability.yaml" "$1" "$2" <<'PY'
import sys,yaml
p,status,required=sys.argv[1:]; d=yaml.safe_load(open(p)); d["two_voice"]["status"]=status; d["two_voice"]["required"]=required=="true"; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
}

t_case "both full-SHA provider directions approve against one acceptance standard"
reset_case claude false
verdict_file "$run/08-qa-verdict.gpt.json" APPROVE gpt
assert_rc "Claude-primary plus GPT secondary passes" 0 "$FINAL" "$run"
reset_case codex false
verdict_file "$run/08-qa-verdict.claude.json" APPROVE claude
assert_rc "Codex-primary plus Claude secondary passes" 0 "$FINAL" "$run"

t_case "primary or stale secondary verdicts always block"
reset_case claude false
verdict_file "$run/08-qa-verdict.gpt.json" APPROVE gpt
verdict_file "$run/08-qa-verdict.json" BLOCK primary "primary blocker"
assert_rc "primary BLOCK cannot be cleared by secondary" 1 "$FINAL" "$run"
reset_case claude false
verdict_file "$run/08-qa-verdict.gpt.json" APPROVE gpt
python3 - "$run/08-qa-verdict.gpt.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["commit_sha"]="0"*40; json.dump(d,open(p,"w"),indent=2)
PY
assert_rc "wrong-SHA secondary blocks" 1 "$FINAL" "$run"

make_unavailable() { # primary security reason unique
  primary="$1"; security="$2"; reason="$3"; suffix="$4"
  reset_case "$primary" "$security"
  secondary="gpt"; [ "$primary" = codex ] && secondary=claude
  sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidate_sha"])' "$run/09-test-evidence/qa-candidate.json")"
  gen="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["generation"])' "$run/09-test-evidence/qa-candidate.json")"
  rel="09-test-evidence/reviewer-attempts/$secondary-$suffix/attempt.json"
  mkdir -p "$(dirname "$run/$rel")"
  python3 - "$run/$rel" "$run_id" "$secondary" "$sha" "$gen" "$reason" <<'PY'
import json,sys
p,run,provider,sha,gen,reason=sys.argv[1:]
json.dump({"schema_version":1,"attempt_id":"fixture","provider":provider,"run_id":run,"candidate_sha":sha,
"generation":int(gen),"status":"unavailable","exit_code":3,"trusted_reason":reason,"phases":[]},open(p,"w"),indent=2)
PY
  python3 - "$run/traceability.yaml" "$rel" "$secondary" "$sha" "$gen" <<'PY'
import sys,yaml
p,rel,provider,sha,gen=sys.argv[1:]; d=yaml.safe_load(open(p)); d["two_voice"]["status"]="unavailable"
d["two_voice"]["attempt"]={"path":rel,"provider":provider,"generation":int(gen),"candidate_sha":sha}
yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
  "$LOG" --run "$run" --strict reviewer_unavailable provider="$secondary" generation="$gen" sha="$sha" attempt="$rel" exit_code=3 reason="$reason"
}

t_case "optional unavailable still requires a real matching attempt and target event"
make_unavailable claude false authentication optional1
assert_rc "trusted optional unavailable passes with exact attempt/event" 0 "$FINAL" "$run"
python3 - "$run/traceability.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d["two_voice"]["attempt"]["path"]="09-test-evidence/missing.json"; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_fail "fabricated attempt cannot pass" "$FINAL" "$run"
make_unavailable codex false model optional2
python3 - "$run/traceability.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d["two_voice"]["attempt"]["generation"]+=1; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "stale generation blocks unavailable state" 1 "$FINAL" "$run"

t_case "derived high risk cannot be self-declared optional and needs an exact human waiver"
make_unavailable codex true authentication required1
set_voice unavailable false
assert_rc "false required cross-check blocks high-risk run" 1 "$FINAL" "$run"
set_voice unavailable true
assert_fail "required unavailable without waiver blocks" "$FINAL" "$run"
sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidate_sha"])' "$run/09-test-evidence/qa-candidate.json")"
attempt_rel="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["two_voice"]["attempt"]["path"])' "$run/traceability.yaml")"
cat > "$run/09-test-evidence/waiver.yaml" <<EOF
schema_version: 1
type: required_unavailable
actor: human-fixture
occurred_at: 2026-08-09T15:00:00Z
run_id: $run_id
candidate_sha: $sha
provider: claude
decision: waive_required_secondary
attempt: $attempt_rel
trusted_reason: authentication
objections: [required secondary unavailable]
EOF
python3 - "$run/traceability.yaml" "$sha" <<'PY'
import sys,yaml
p,sha=sys.argv[1:]; d=yaml.safe_load(open(p)); d["two_voice"]["unavailable_waiver"]={"path":"09-test-evidence/waiver.yaml","candidate_sha":sha}; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "exact current-SHA waiver passes" 0 "$FINAL" "$run"
python3 - "$run/09-test-evidence/waiver.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d["objections"]=[]; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "waiver without objections blocks" 1 "$FINAL" "$run"

set_block_disposition() { # disposition risk dissent
  disposition="$1"; risk="$2"; dissent="$3"
  secondary="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["two_voice"]["secondary_provider"])' "$run/traceability.yaml")"
  verdict_file "$run/08-qa-verdict.$secondary.json" BLOCK "$secondary" "secondary defect" block-attempt
  python3 - "$run/traceability.yaml" "$disposition" "$risk" "$dissent" <<'PY'
import sys,yaml
p,disposition,risk,dissent=sys.argv[1:]; d=yaml.safe_load(open(p)); sha=d["candidate"]["commit_sha"]; d["two_voice"]["status"]="available"
d["two_voice_diff"]=[{"secondary_blocker":"secondary defect","primary_position":"positive evidence-based contrary reading",
"positive_dissent":dissent=="true","risk":risk,
"bounded_resolution":{"attempted":True,"rounds":1,"rerun":"block","evidence":{"path":"09-test-evidence/round.log","candidate_sha":sha}},
"evidence":{"path":"09-test-evidence/proof.log","candidate_sha":sha},"disposition":disposition}]
yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
}

t_case "proceed-with-primary is exact, positive, low-risk, and one-round only"
reset_case claude false
set_block_disposition proceed_with_primary low true
assert_rc "positive low-risk dissent after one round passes" 0 "$FINAL" "$run"
set_block_disposition proceed_with_primary high true
assert_rc "high-risk disagreement blocks" 1 "$FINAL" "$run"
set_block_disposition proceed_with_primary low false
assert_rc "silence or no dissent blocks" 1 "$FINAL" "$run"
set_block_disposition unresolved low true
assert_rc "unresolved disposition blocks" 1 "$FINAL" "$run"

t_case "fixed and secondary-withdrew require a distinct fresh secondary APPROVE"
reset_case codex false
set_block_disposition fixed low true
assert_fail "free-form fixed does not clear current BLOCK" "$FINAL" "$run"
verdict_file "$run/09-test-evidence/fresh.json" APPROVE claude "" fresh-attempt
python3 - "$run/traceability.yaml" "$sha" <<'PY'
import sys,yaml
p,sha=sys.argv[1:]; d=yaml.safe_load(open(p)); d["two_voice_diff"][0]["fresh_secondary_verdict"]={"path":"09-test-evidence/fresh.json","candidate_sha":sha}; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "fixed plus distinct fresh secondary APPROVE passes" 0 "$FINAL" "$run"
set_block_disposition secondary_withdrew low true
python3 - "$run/traceability.yaml" "$sha" <<'PY'
import sys,yaml
p,sha=sys.argv[1:]; d=yaml.safe_load(open(p)); d["two_voice_diff"][0]["fresh_secondary_verdict"]={"path":"09-test-evidence/fresh.json","candidate_sha":sha}; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "secondary-withdrew also needs and accepts fresh APPROVE" 0 "$FINAL" "$run"

t_case "human decision is run-contained, current-SHA, actor/time, and objection exact"
reset_case claude true
set_block_disposition human_decision high true
cat > "$run/09-test-evidence/human.yaml" <<EOF
schema_version: 1
type: human_decision
actor: human-fixture
occurred_at: 2026-08-09T15:00:00Z
run_id: $run_id
candidate_sha: $sha
decision: proceed
objections: [secondary defect]
EOF
python3 - "$run/traceability.yaml" "$sha" <<'PY'
import sys,yaml
p,sha=sys.argv[1:]; d=yaml.safe_load(open(p)); d["two_voice_diff"][0]["record"]={"path":"09-test-evidence/human.yaml","candidate_sha":sha}; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "exact human decision resolves high-risk objection" 0 "$FINAL" "$run"
python3 - "$run/09-test-evidence/human.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d["objections"]=["different"]; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "record for another objection blocks" 1 "$FINAL" "$run"
python3 - "$run/traceability.yaml" "$sha" <<'PY'
import sys,yaml
p,sha=sys.argv[1:]; d=yaml.safe_load(open(p)); d["two_voice_diff"][0]["record"]={"path":"../outside.yaml","candidate_sha":sha}; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "outside-run record cannot evaluate" 2 "$FINAL" "$run"

t_case "exact secondary objection mapping rejects omission and phantom text"
reset_case codex false
set_block_disposition proceed_with_primary low true
python3 - "$run/traceability.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d["two_voice_diff"][0]["secondary_blocker"]="other"; yaml.safe_dump(d,open(p,"w"),sort_keys=False)
PY
assert_rc "mismatched objection blocks" 1 "$FINAL" "$run"

t_summary
