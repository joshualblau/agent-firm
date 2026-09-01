#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEAL="$BIN/firm-seal-qa-evidence"

make_sealable_run() {
  _primary="${1:-claude}"
  _repo="$(mk_repo)"
  _sha="$(sha_of "$_repo" main)"
  _relative="$(cd "$_repo" && "$BIN/firm-new-run" --primary "$_primary" seal-fixture full_track)"
  _run="$_repo/$_relative"
  printf '%s\n' 'task_slug: seal-fixture' 'track: full_track' 'criteria: []' > "$_run/01-acceptance-criteria.yaml"
  printf '%s\n' 'schema_version: 2' 'task_slug: seal-fixture' 'candidate: {}' 'matrix: []' 'two_voice: {}' 'two_voice_diff: []' > "$_run/traceability.yaml"
  printf '%s\n' '{"artifacts":[],"commands_run":[],"verdict":"APPROVE"}' > "$_run/08-qa-verdict.json"
  printf '%s\n' '# 10 · Handoff' '<!-- BEGIN COMPLETE LOCAL PR BODY -->' 'Title: sealed fixture' '' 'Body bytes remain exact.' '<!-- END COMPLETE LOCAL PR BODY -->' > "$_run/10-handoff.md"
  _common="$(git -C "$_repo" rev-parse --git-common-dir)"; case $_common in /*) ;; *) _common="$_repo/$_common";; esac
  printf '{"schema_version":2,"run_id":"%s","repository_root":"%s","git_common_dir":"%s","checkout_path":"%s","source_ref":"refs/heads/integration/seal","source_ref_sha":"%s","base_sha":"%s","candidate_sha":"%s","generation":1}\n' \
    "$(basename "$_run")" "$_repo" "$_common" "$_repo" "$_sha" "$_sha" "$_sha" > "$_run/09-test-evidence/qa-candidate.json"
  chmod 600 "$_run/09-test-evidence/qa-candidate.json"
  mkdir -p "$_run/role-contracts"
  printf '%s\n' '# fixture qa' > "$_run/role-contracts/Q-01-qa-tester.md"
  printf '%s\n' '# fixture packager' > "$_run/role-contracts/P-01-packager.md"
  _run_event="$(t_python -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["event_id"])' "$_run/run.jsonl")"
  _authority="$(t_python -c 'import json,sys; rid=sys.argv[1]; print(json.dumps([{"source_run":".agent-firm/runs/"+rid,"event_id":sys.argv[2],"expect":{"event":"run_started","run_id":rid,"fields":{"base_sha":sys.argv[3]}}}],separators=(",",":")))' "$(basename "$_run")" "$_run_event" "$_sha")"
  _qa_activation="$("$BIN/firm-model-resolve" --provider codex --role qa-tester --format activation)"
  _pack_activation="$("$BIN/firm-model-resolve" --provider codex --role packager --format activation)"
  _qa_start="$("$BIN/firm-ledger-log" --run "$_run" --strict --role-start --stage test/Q-01 --role qa-tester \
    --contract role-contracts/Q-01-qa-tester.md --event qa_started --authority-json "$_authority" \
    --agent /root/seal_fixture_qa --activation-json "$_qa_activation" | t_python -c 'import json,sys; print(json.load(sys.stdin)["event_id"])')" || return 1
  for _path in 08-qa-verdict.json traceability.yaml; do
    _digest="$(shasum -a 256 "$_run/$_path" | awk '{print $1}')"
    _bytes="$(wc -c < "$_run/$_path" | tr -d ' ')"
    "$BIN/firm-ledger-log" --run "$_run" --strict evidence_produced \
      "sha=$_sha" generation=1 "path=$_path" "sha256=$_digest" "bytes=$_bytes" \
      stage=test/Q-01 role=qa-tester "role_start_event_id=$_qa_start" >/dev/null || return 1
  done
  "$BIN/firm-ledger-log" --run "$_run" --strict qa_completed stage=test/Q-01 role=qa-tester \
    "role_start_event_id=$_qa_start" >/dev/null || return 1
  _pack_start="$("$BIN/firm-ledger-log" --run "$_run" --strict --role-start --stage package/P-01 --role packager \
    --contract role-contracts/P-01-packager.md --event packaging_started --authority-json "$_authority" \
    --agent /root/seal_fixture_packager --activation-json "$_pack_activation" | t_python -c 'import json,sys; print(json.load(sys.stdin)["event_id"])')" || return 1
  _path=10-handoff.md
  _digest="$(shasum -a 256 "$_run/$_path" | awk '{print $1}')"
  _bytes="$(wc -c < "$_run/$_path" | tr -d ' ')"
  "$BIN/firm-ledger-log" --run "$_run" --strict evidence_produced "sha=$_sha" generation=1 \
    "path=$_path" "sha256=$_digest" "bytes=$_bytes" stage=package/P-01 role=packager \
    "role_start_event_id=$_pack_start" >/dev/null || return 1
  "$BIN/firm-ledger-log" --run "$_run" --strict packaging_completed stage=package/P-01 role=packager \
    "role_start_event_id=$_pack_start" >/dev/null || return 1
  printf '%s\n' "$_repo" "$_run" "$_sha"
}

t_case "AF-CJSON-1 and exact PR marker vectors"
assert_ok "shared Python module compiles" env PYTHONPYCACHEPREFIX=/tmp/firm-seal-test-pyc \
  "$BIN/firm-python" -m py_compile "$FIRM_ROOT/agent-firm/lib/evidence_seal.py"
vector="$(mktemp "${TMPDIR:-/tmp}/firm-pr-vector.XXXXXX")"; t_track "$vector"
printf '%s\n' 'before' '<!-- BEGIN COMPLETE LOCAL PR BODY -->' 'exact body' '<!-- END COMPLETE LOCAL PR BODY -->' > "$vector"
out="${vector}.out"; t_track "$out"
assert_ok "canonical extractor accepts one exact pair" "$SEAL" --extract-pr-body --input "$vector" --output "$out"
assert_eq "extractor preserves exact body LF" "$(printf 'exact body')" "$(cat "$out")"
bad="${vector}.bad"; t_track "$bad"
printf '%s\r\n' '<!-- BEGIN COMPLETE LOCAL PR BODY -->' 'bad' '<!-- END COMPLETE LOCAL PR BODY -->' > "$bad"
assert_fail "extractor rejects CRLF markers" "$SEAL" --extract-pr-body --input "$bad" --output "${bad}.out"

t_case "end-to-end create, publish, and independent verify"
fixture="$(make_sealable_run)"; fixture_rc=$?
repo="$(printf '%s\n' "$fixture" | sed -n '1p')"
run="$(printf '%s\n' "$fixture" | sed -n '2p')"
if [ "$fixture_rc" -ne 0 ] || [ -z "$run" ]; then
  _t_no "sealable fixture created" "rc=$fixture_rc"
elif ! t_p2_row_supported; then
  t_skip "end-to-end publication" "requires a supported P2 ledger write host"
else
  _t_ok "sealable fixture created"
  create_out="$($SEAL --run "$run" 2>&1)"; create_rc=$?
  if [ "$create_rc" -eq 0 ]; then _t_ok "finalizer creates and publishes one seal"; else _t_no "finalizer creates and publishes one seal" "rc=$create_rc $(_t_ctx "$create_out")"; fi
  assert_ok "independent publication verifier accepts exact bytes" "$SEAL" --verify --run "$run" --phase publication
  assert_ok "reviewer manifest v4 derives exact sealed set/counts and narrow future verdict" \
    t_python - "$FIRM_ROOT" "$run" <<'PY'
import os,sys
root,run=sys.argv[1:]
sys.path.insert(0,os.path.join(root,"agent-firm","lib"))
from evidence_seal import SealError,manifest_v4_fields,verify_seal
r=verify_seal(run,os.path.join(root,"agent-firm","policy","evidence-privacy.yaml"),"publication")
seen=set(r["ordinary_paths"])-{"run.jsonl#prefix"}
fields=manifest_v4_fields(r,seen,"gpt")
assert fields["sealed_declared_count"]==fields["sealed_resolved_count"]==len(r["ordinary_paths"])
assert fields["sealed_total_count"]==fields["sealed_declared_count"]+1
assert fields["sealed_self_count"]==1
assert fields["not_yet_produced"]==[{"origin_path":"08-qa-verdict.gpt.json","reason":"current_secondary_verdict_is_structurally_future"}]
try:
    manifest_v4_fields(r,seen-{next(iter(seen))},"gpt")
except SealError as exc:
    assert exc.category=="MANIFEST_OMISSION"
else:
    raise AssertionError("known manifest omission was accepted")
PY
  assert_file "seal is generation-specific" "$run/09-test-evidence/final-evidence/g1/seal.json"
  assert_output "ledger has one typed publication" '"event":"evidence_seal_published"' cat "$run/run.jsonl"
  receipt="$($SEAL --verify --run "$run" --phase publication)"
  publication_id="$(printf '%s' "$receipt" | t_python -c 'import json,sys; print(json.load(sys.stdin)["publication_event_id"])')"
  projection="$(printf '%s' "$receipt" | t_python -c 'import json,sys; print(json.load(sys.stdin)["projection_sha256"])')"
  attempt_rel=09-test-evidence/reviewer-attempts/gpt-c1-a9000/attempt.json
  mkdir -p "$run/$(dirname "$attempt_rel")"
  t_python - "$run/$attempt_rel" "$(basename "$run")" "$(printf '%s\n' "$fixture" | sed -n '3p')" <<'PY'
import json,sys
path,run_id,sha=sys.argv[1:]
value={"schema_version":1,"attempt_id":"gpt-c1-a9000","provider":"gpt","run_id":run_id,
       "candidate_sha":sha,"generation":1,"status":"started","exit_code":None,
       "started_event_id":"evt-reviewer-open-gpt","outcome_event_id":None}
with open(path,"w") as handle: json.dump(value,handle,separators=(",",":")); handle.write("\n")
PY
  chmod 600 "$run/$attempt_rel"
  "$BIN/firm-ledger-log" --run "$run" --strict --event-id evt-reviewer-open-gpt reviewer_attempt_started \
    provider=gpt generation=1 "sha=$(printf '%s\n' "$fixture" | sed -n '3p')" \
    "attempt=$attempt_rel" attempt_id=gpt-c1-a9000 \
    "seal_event_id=$publication_id" "seal_projection_sha256=$projection" >/dev/null
  assert_ok "wrapper preflight recognizes one recoverable open START" \
    "$SEAL" --verify --run "$run" --phase wrapper-preflight
  assert_fail "ordinary publication phase rejects an unmatched START" \
    "$SEAL" --verify --run "$run" --phase publication
  "$BIN/firm-ledger-log" --run "$run" --strict reviewer_attempt_abandoned \
    provider=gpt generation=1 "sha=$(printf '%s\n' "$fixture" | sed -n '3p')" \
    "attempt=$attempt_rel" attempt_id=gpt-c1-a9000 \
    started_event_id=evt-reviewer-open-gpt reason=wrapper_death_before_terminal \
    "seal_event_id=$publication_id" "seal_projection_sha256=$projection" >/dev/null
  assert_ok "typed ABANDONED closes the suffix for retry" "$SEAL" --verify --run "$run" --phase publication
  assert_fail "exclusive generation refuses a second seal" "$SEAL" --run "$run"
  printf '\nmutation\n' >> "$run/10-handoff.md"
  assert_fail "post-seal handoff mutation is stale" "$SEAL" --verify --run "$run" --phase publication
fi

t_case "both primary-provider orientations publish the same sealed path set"
if t_p2_row_supported; then
  claude_fixture="$(make_sealable_run claude)"; claude_run="$(printf '%s\n' "$claude_fixture" | sed -n '2p')"
  codex_fixture="$(make_sealable_run codex)"; codex_run="$(printf '%s\n' "$codex_fixture" | sed -n '2p')"
  assert_ok "Claude-primary seal publishes" "$SEAL" --run "$claude_run"
  assert_ok "Codex-primary seal publishes" "$SEAL" --run "$codex_run"
  claude_paths="$($SEAL --verify --run "$claude_run" | t_python -c 'import json,sys; print("\n".join(json.load(sys.stdin)["ordinary_paths"]))')"
  codex_paths="$($SEAL --verify --run "$codex_run" | t_python -c 'import json,sys; print("\n".join(json.load(sys.stdin)["ordinary_paths"]))')"
  assert_eq "both orientations derive the identical sealed set" "$claude_paths" "$codex_paths"
else
  t_skip "both sealed orientations" "requires a supported P2 ledger write host"
fi

t_case "seven-finding command, producer, privacy, schema, and TOCTOU mutations fail closed"
assert_ok "direct mutation matrix rejects every cited class" t_python - "$FIRM_ROOT" <<'PY'
import copy, hashlib, json, os, pathlib, tempfile
root=pathlib.Path(__import__('sys').argv[1]); __import__('sys').path.insert(0,str(root/'agent-firm/lib'))
import evidence_seal as e
tmp=pathlib.Path(tempfile.mkdtemp()); (tmp/'in').write_bytes(b'in'); (tmp/'out').write_bytes(b'out')
for p in (tmp/'in',tmp/'out'): os.chmod(p,0o600)
ident=lambda p:{"path":p.name,"bytes":p.stat().st_size,"sha256":hashlib.sha256(p.read_bytes()).hexdigest(),"mode":"0600","sanitizer":"identity"}
valid={"schema_version":1,"argv":["tool","--check"],"cwd":os.path.realpath(tmp),"started_at":"2026-08-31T00:00:00.000Z","finished_at":"2026-08-31T00:00:01.000Z","duration_ms":1000,"exit_code":0,"result":"pass","inputs":[ident(tmp/'in')],"outputs":[ident(tmp/'out')],"stdout":{"kind":"not_applicable","reason":"stream_not_emitted"},"stderr":{"kind":"not_applicable","reason":"stream_not_emitted"}}
e._validate_command_result(valid,'command.json',tmp)
mutations=[]
for key,value in (("argv",["tool","<placeholder>"]),("cwd",str(tmp/'..')),("started_at","not-time"),("finished_at","2026-08-30T00:00:00Z"),("duration_ms",999),("exit_code",1),("result","timeout")):
 d=copy.deepcopy(valid); d[key]=value; mutations.append(d)
d=copy.deepcopy(valid); d["inputs"][0]["bytes"]+=1; mutations.append(d)
d=copy.deepcopy(valid); d["extra"]=1; mutations.append(d)
d=copy.deepcopy(valid); d["inputs"]*=2; mutations.append(d)
d=copy.deepcopy(valid); d["outputs"]=[]; mutations.append(d)
for d in mutations:
 try:e._validate_command_result(d,'command.json',tmp)
 except e.SealError:pass
 else:raise AssertionError(('command mutation accepted',d))
sha='a'*40; raw=b'x'; digest=hashlib.sha256(raw).hexdigest(); sid='evt-start'; base=[{"ts":"2026-08-31T00:00:00Z","event":"qa_started","event_id":sid,"stage":"test/Q","role":"qa-tester","contract":{},"authority":[],"activation":{}},{"ts":"2026-08-31T00:00:01Z","event":"evidence_produced","event_id":"evt-proof","path":"x","sha256":digest,"bytes":"1","sha":sha,"generation":"1","stage":"test/Q","role":"qa-tester","role_start_event_id":sid},{"ts":"2026-08-31T00:00:02Z","event":"qa_completed","event_id":"evt-done","stage":"test/Q","role":"qa-tester","role_start_event_id":sid}]
e._producer(base,'x',raw,sha,1,True)
for mutate in ('missing','duplicate','ordinary','backstamp'):
 rows=copy.deepcopy(base)
 if mutate=='missing': rows[1].pop('role_start_event_id')
 elif mutate=='duplicate': rows.insert(2,copy.deepcopy(rows[1])); rows[2]['event_id']='evt-proof2'
 elif mutate=='ordinary': rows[0]={k:v for k,v in rows[0].items() if k not in ('contract','authority','activation')}
 else: rows[1]['ts']='2026-08-31T00:00:03Z'
 try:e._producer(rows,'x',raw,sha,1,True)
 except e.SealError:pass
 else:raise AssertionError(('producer mutation accepted',mutate))
policy=e.parse_json_unique((root/'agent-firm/policy/evidence-privacy.yaml').read_bytes()); privacy=e._privacy_patterns(policy)
jira=b'https://heightslabs.atlassian.'+b'net/browse/BLOC-51'; connection=b'mongo'+b'db://user:pass@db.internal/prod'
secret=b'pass'+b'word=supersecret'; endpoint=b'https://10.'+b'0.0.1:443'
e._scan(jira,'10-handoff.md',privacy)
for text,path in ((jira,'06-implementation-summary.md'),(connection,'10-handoff.md'),(secret,'traceability.yaml'),(endpoint,'10-handoff.md')):
 try:e._scan(text,path,privacy)
 except e.SealError:pass
 else:raise AssertionError(('privacy mutation accepted',text,path))
# Deterministic final-lstat substitution is detected as TOCTOU.
target=tmp/'race'; target.write_bytes(b'old'); os.chmod(target,0o600); original=e.os.lstat; calls={'n':0}
def raced(path):
 calls['n']+=1
 if pathlib.Path(path)==target and calls['n']>=3: target.write_bytes(b'new')
 return original(path)
e.os.lstat=raced
try:
 try:e._safe_read(tmp,'race')
 except e.SealError as exc: assert exc.category=='ARTIFACT_MOVED'
 else:raise AssertionError('TOCTOU accepted')
finally:e.os.lstat=original
PY

t_case "proven no-append publication failure removes the complete unpublished bundle"
cleanup_fixture="$(make_sealable_run)"; cleanup_run="$(printf '%s\n' "$cleanup_fixture" | sed -n '2p')"
if t_p2_row_supported; then
  assert_rc "negative-only P2 seam blocks publication" 17 env FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=linux "$SEAL" --run "$cleanup_run"
  assert_no_file "proven no-append cleanup removes canonical generation" "$cleanup_run/09-test-evidence/final-evidence/g1"
else
  t_skip "proven no-append publication cleanup" "requires a supported P2 ledger write host"
fi

t_case "pre-publication failure leaves no canonical or staging generation"
atomic_fixture="$(make_sealable_run)"; atomic_rc=$?
atomic_run="$(printf '%s\n' "$atomic_fixture" | sed -n '2p')"
if [ "$atomic_rc" -ne 0 ] || [ -z "$atomic_run" ]; then
  _t_no "atomic fixture created" "rc=$atomic_rc"
else
  _t_ok "atomic fixture created"
  printf '\n<!-- malformed marker -->\n' >> "$atomic_run/10-handoff.md"
  assert_fail "pre-publication validation fails closed" "$SEAL" --run "$atomic_run"
  assert_no_file "failed creation leaves no canonical generation" "$atomic_run/09-test-evidence/final-evidence/g1"
  staging_count="$(find "$atomic_run/09-test-evidence/final-evidence" -maxdepth 1 -name 'g1.staging-*' -print 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "failed creation leaves no staging generation" 0 "$staging_count"
fi

t_summary
