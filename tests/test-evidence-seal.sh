#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEAL="$BIN/firm-seal-qa-evidence"

seal_for_run() {
  local _seal_run="$1" _seal_repo; shift
  _seal_repo="$(cd "$_seal_run/../../.." && pwd -P)"
  (cd "$_seal_repo" && "$SEAL" "$@" --run "$_seal_run")
}

seal_for_run_rejected_p2() {
  (export FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=linux; seal_for_run "$1")
}

make_users_repo() {
  local _home _repo
  _home="$(t_python -c 'import os; print(os.path.realpath(os.path.expanduser("~")))')"
  case "$_home" in /Users/[A-Za-z0-9._-]*) ;; *) return 1 ;; esac
  _repo="$(mktemp -d "$_home/.agent-firm-privacy-e2e.XXXXXX")" || return 1
  (
    cd "$_repo" || exit 1
    : > .owned-privacy-seal-fixture
    git init -q .
    git symbolic-ref HEAD refs/heads/main
    git config user.email test@agent-firm.local
    git config user.name "firm tests"
    git config commit.gpgsign false
    printf '%s\n' '.agent-firm/' '.agent-firm-worktree.env' >> .git/info/exclude
    printf 'seed\n' > seed.txt
    git add -A && git commit -qm seed
  ) >/dev/null 2>&1 || return 1
  printf '%s' "$_repo"
}

cleanup_users_repo() {
  t_python - "$1" <<'PY'
import os,pathlib,re,shutil,stat,sys
target=pathlib.Path(sys.argv[1])
home=pathlib.Path(os.path.realpath(os.path.expanduser("~")))
prefix="/"+"Users"+"/"
info=os.lstat(target)
if (not str(home).startswith(prefix) or target.parent != home
        or not target.name.startswith(".agent-firm-privacy-e2e.")
        or target.is_symlink() or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
        or not (target/".owned-privacy-seal-fixture").is_file()):
    raise SystemExit("refusing unsafe users fixture cleanup")
shutil.rmtree(target)
if target.exists():
    raise SystemExit("users fixture cleanup incomplete")
PY
}

make_sealable_run() {
  _primary="${1:-claude}"
  _repo="${2:-}"
  [ -n "$_repo" ] || _repo="$(mk_repo)"
  _repo="$(cd "$_repo" && pwd -P)"
  _sha="$(sha_of "$_repo" main)"
  _relative="$(cd "$_repo" && "$BIN/firm-new-run" --primary "$_primary" seal-fixture full_track)"
  _run="$_repo/$_relative"
  printf '%s\n' 'task_slug: seal-fixture' 'track: full_track' 'criteria: []' > "$_run/01-acceptance-criteria.yaml"
  printf '%s\n' 'schema_version: 2' 'task_slug: seal-fixture' 'candidate: {}' 'matrix: []' 'two_voice: {}' 'two_voice_diff: []' > "$_run/traceability.yaml"
  printf '%s\n' '{"artifacts":[],"commands_run":[],"verdict":"APPROVE"}' > "$_run/08-qa-verdict.json"
  printf '%s\n' '# 10 · Handoff' '<!-- BEGIN COMPLETE LOCAL PR BODY -->' 'Title: sealed fixture' '' 'Body bytes remain exact.' '<!-- END COMPLETE LOCAL PR BODY -->' > "$_run/10-handoff.md"
  _common="$(git -C "$_repo" rev-parse --git-common-dir)"; case $_common in /*) ;; *) _common="$_repo/$_common";; esac
  _common="$(cd "$_common" && pwd -P)"
  _checkout="$_repo/.agent-firm/qa-checkout/$(basename "$_run")"
  mkdir -p "$(dirname "$_checkout")"
  git -C "$_repo" worktree add -q --detach "$_checkout" "$_sha" || return 1
  printf '{"schema_version":2,"run_id":"%s","repository_root":"%s","git_common_dir":"%s","checkout_path":"%s","source_ref":"refs/heads/integration/seal","source_ref_sha":"%s","base_sha":"%s","candidate_sha":"%s","generation":1}\n' \
    "$(basename "$_run")" "$_repo" "$_common" "$_checkout" "$_sha" "$_sha" "$_sha" > "$_run/09-test-evidence/qa-candidate.json"
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
  create_out="$(seal_for_run "$run" 2>&1)"; create_rc=$?
  if [ "$create_rc" -eq 0 ]; then _t_ok "finalizer creates and publishes one seal"; else _t_no "finalizer creates and publishes one seal" "rc=$create_rc $(_t_ctx "$create_out")"; fi
  assert_ok "independent publication verifier accepts exact bytes" seal_for_run "$run" --verify --phase publication
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
  receipt="$(seal_for_run "$run" --verify --phase publication)"
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
    seal_for_run "$run" --verify --phase wrapper-preflight
  assert_fail "ordinary publication phase rejects an unmatched START" \
    seal_for_run "$run" --verify --phase publication
  "$BIN/firm-ledger-log" --run "$run" --strict reviewer_attempt_abandoned \
    provider=gpt generation=1 "sha=$(printf '%s\n' "$fixture" | sed -n '3p')" \
    "attempt=$attempt_rel" attempt_id=gpt-c1-a9000 \
    started_event_id=evt-reviewer-open-gpt reason=wrapper_death_before_terminal \
    "seal_event_id=$publication_id" "seal_projection_sha256=$projection" >/dev/null
  assert_ok "typed ABANDONED closes the suffix for retry" seal_for_run "$run" --verify --phase publication
  assert_fail "exclusive generation refuses a second seal" seal_for_run "$run"
  printf '\nmutation\n' >> "$run/10-handoff.md"
  assert_fail "post-seal handoff mutation is stale" seal_for_run "$run" --verify --phase publication
fi

t_case "both primary-provider orientations publish the same sealed path set"
if t_p2_row_supported; then
  claude_fixture="$(make_sealable_run claude)"; claude_run="$(printf '%s\n' "$claude_fixture" | sed -n '2p')"
  codex_fixture="$(make_sealable_run codex)"; codex_run="$(printf '%s\n' "$codex_fixture" | sed -n '2p')"
  assert_ok "Claude-primary seal publishes" seal_for_run "$claude_run"
  assert_ok "Codex-primary seal publishes" seal_for_run "$codex_run"
  claude_paths="$(seal_for_run "$claude_run" --verify | t_python -c 'import json,sys; print("\n".join(json.load(sys.stdin)["ordinary_paths"]))')"
  codex_paths="$(seal_for_run "$codex_run" --verify | t_python -c 'import json,sys; print("\n".join(json.load(sys.stdin)["ordinary_paths"]))')"
  assert_eq "both orientations derive the identical sealed set" "$claude_paths" "$codex_paths"
else
  t_skip "both sealed orientations" "requires a supported P2 ledger write host"
fi

t_case "operator-home allowance is exactly five fields on two declared-metadata artifacts"
assert_ok "positive/negative field, surface, value, policy, and category matrices are closed" \
  t_python - "$FIRM_ROOT" <<'PY'
import copy,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); sys.path.insert(0,str(root/'agent-firm/lib'))
import evidence_seal as e
policy=e.parse_json_unique((root/'agent-firm/policy/evidence-privacy.yaml').read_bytes())
privacy=e._privacy_patterns(policy)
users="/"+"Users"
repo=users+"/operator/fixture-repository"
common=repo+"/.git"
checkout=repo+"/.agent-firm/qa-checkout/seal-fixture"
bindings={
 ('run-metadata.json','repository_root'):repo,
 ('run-metadata.json','git_common_dir'):common,
 ('09-test-evidence/qa-candidate.json','repository_root'):repo,
 ('09-test-evidence/qa-candidate.json','git_common_dir'):common,
 ('09-test-evidence/qa-candidate.json','checkout_path'):checkout,
}

def raw(field,value):
 return json.dumps({field:value},ensure_ascii=True,separators=(',',':')).encode()

for (path,field),value in bindings.items():
 scan=e._scan(raw(field,value),path,privacy,bindings)
 assert len(scan['allowances'])==1
 allowance=scan['allowances'][0]
 assert allowance['rule_id']=='declared_operator_home_identity'
 assert allowance['artifact_path']==path and allowance['surface_class']=='declared_metadata'
 assert allowance['json_field']==field and allowance['value_sha256']==e.sha256(value.encode())

negative=[
 (raw('checkout_path',checkout),'run-metadata.json',bindings),
 (raw('unrelated',repo),'run-metadata.json',bindings),
 (raw('repository_root',repo),'run-baseline.json',bindings),
 (raw('repository_root',repo),'09-test-evidence/other.json',bindings),
 (repo.encode(),'10-handoff.md',bindings),
 (repo.encode(),'09-test-evidence/command.stdout',bindings),
 (repo.encode(),'09-test-evidence/reviewer-attempts/gpt-a1/controlled-input.json',bindings),
 (raw('repository_root',common),'run-metadata.json',bindings),
 (raw('repository_root',repo+'/../fixture-repository'),'run-metadata.json',
  {**bindings,('run-metadata.json','repository_root'):repo+'/../fixture-repository'}),
 (raw('repository_root',repo+'/'),'run-metadata.json',
  {**bindings,('run-metadata.json','repository_root'):repo+'/'}),
 (raw('repository_root',users+'/operator/other'),'run-metadata.json',bindings),
]
escaped=raw('repository_root',repo).replace(b'/',b'\\/',1)
negative.append((escaped,'run-metadata.json',bindings))
duplicate=(b'{"repository_root":"'+repo.encode()+b'","repository_root":"'+repo.encode()+b'"}')
negative.append((duplicate,'run-metadata.json',bindings))
nested=json.dumps({'identity':{'repository_root':repo}},separators=(',',':')).encode()
negative.append((nested,'run-metadata.json',bindings))
for content,path,context in negative:
 try:
  e._scan(content,path,privacy,context)
 except e.SealError as exc:
  assert exc.category=='PRIVACY_MATCH',(path,exc.category)
 else:
  raise AssertionError(('operator-home negative accepted',path,content))

category_samples={
 'private_key':b'-----BEGIN PRIVATE KEY-----',
 'auth_or_cookie':b'Authorization: abcdefghijk',
 'secret_assignment':b'password=supersecret',
 'jwt':b'eyJabcdefgh.ijklmnopq.rstuvwxyz',
 'connection_uri':b'postgresql://dbuser:dbpass@database.example/app',
 'uri_userinfo':b'https://dbuser:dbpass@example.com/path',
 'numeric_endpoint':b'https://10.20.30.40:443',
 'internal_host':b'https://service.internal:443',
 'production_namespace':b'prod_namespace=cluster-one',
 'raw_stack_frame':b'Traceback (most recent call last):',
 'operator_email':b'operator@heightslabs.com',
 'generic_uri':b'https://heightslabs.atlassian.net/browse/BLOC-51?view=unsafe',
}
for category,sample in category_samples.items():
 try:
  e._scan(sample,'06-implementation-summary.md',privacy,bindings)
 except e.SealError as exc:
  assert exc.category=='PRIVACY_MATCH',(category,exc.category)
 else:
  raise AssertionError(('sensitive category accepted',category))
safe=e._scan(b'https://heightslabs.atlassian.net/browse/BLOC-51','10-handoff.md',privacy,bindings)
assert safe['allowances'][0]['rule_id']=='safe_heights_jira_issue_url'

for mutate in ('extra_field','broad_operator_rule','wrong_version'):
 bad=copy.deepcopy(policy)
 if mutate=='extra_field': bad['allow_rules'][1]['selectors'][0]['fields'].append('checkout_path')
 elif mutate=='broad_operator_rule':
  bad['allow_rules'].append({'id':'broad','pattern_id':'operator_home','pattern':r'/Users/[A-Za-z0-9._-]+','surfaces':['test_evidence']})
 else: bad['version']=1
 try:e._privacy_patterns(bad)
 except e.SealError as exc: assert exc.category=='PRIVACY_POLICY'
 else: raise AssertionError(('broadened policy accepted',mutate))
PY

t_case "real macOS users hierarchy creates and independently verifies the five-field seal"
if ! t_p2_row_supported; then
  t_skip "real users-hierarchy seal and independent verification" "requires a supported macOS P2 ledger write host"
else
  users_repo="$(make_users_repo)"; users_repo_rc=$?
  if [ "$users_repo_rc" -ne 0 ] || [ -z "$users_repo" ]; then
    _t_no "real users-hierarchy fixture created" "fixture creation failed"
  else
    _t_ok "real users-hierarchy fixture created"
    source_head_before="$(git -C "$FIRM_ROOT" rev-parse HEAD)"
    source_common_before="$(git -C "$FIRM_ROOT" rev-parse --git-common-dir)"
    source_status_before="$(git -C "$FIRM_ROOT" status --porcelain=v1 --untracked-files=all)"
    users_fixture="$(make_sealable_run claude "$users_repo")"; users_fixture_rc=$?
    users_run="$(printf '%s\n' "$users_fixture" | sed -n '2p')"
    if [ "$users_fixture_rc" -ne 0 ] || [ -z "$users_run" ]; then
      _t_no "real users-hierarchy sealable run created" "fixture setup failed"
    else
      _t_ok "real users-hierarchy sealable run created"
      assert_ok "real users-hierarchy finalizer creates and publishes" seal_for_run "$users_run"
      assert_ok "independent verifier accepts real users-hierarchy bytes" \
        seal_for_run "$users_run" --verify --phase publication
      assert_ok "privacy report proves only the five bound metadata allowances" \
        t_python - "$users_run" <<'PY'
import json,os,pathlib,sys
run=pathlib.Path(sys.argv[1]); candidate=json.load(open(run/'09-test-evidence/qa-candidate.json'))
metadata=json.load(open(run/'run-metadata.json'))
prefix="/"+"Users"+"/"
assert all(value.startswith(prefix) and os.path.realpath(value)==value for value in (
 metadata['repository_root'],metadata['git_common_dir'],candidate['repository_root'],
 candidate['git_common_dir'],candidate['checkout_path']))
privacy=json.load(open(run/'09-test-evidence/final-evidence/g1/privacy.json'))
allowances=[item for scan in privacy['inputs'] for item in scan['allowances']]
assert len(allowances)==privacy['allow_count']==5
assert {(item['artifact_path'],item['json_field']) for item in allowances}=={
 ('run-metadata.json','repository_root'),('run-metadata.json','git_common_dir'),
 ('09-test-evidence/qa-candidate.json','repository_root'),
 ('09-test-evidence/qa-candidate.json','git_common_dir'),
 ('09-test-evidence/qa-candidate.json','checkout_path'),
}
assert all(item['surface_class']=='declared_metadata' for item in allowances)
assert privacy['command']['argv'][0]=='firm-seal-qa-evidence'
assert privacy['command']['argv'][-1]=='.agent-firm/runs/'+run.name
assert privacy['command']['argv_projection']=='logical_tool_and_run_relative/v1'
assert privacy['command']['cwd']=='.'
assert privacy['command']['cwd_projection']=='repository_relative/v1'
PY
    fi
    assert_ok "owned users-hierarchy fixture cleanup succeeds" cleanup_users_repo "$users_repo"
    assert_no_file "owned users-hierarchy fixture leaves no residue" "$users_repo"
    assert_eq "real source repository HEAD is unchanged" "$source_head_before" "$(git -C "$FIRM_ROOT" rev-parse HEAD)"
    assert_eq "real source Git common directory is unchanged" "$source_common_before" "$(git -C "$FIRM_ROOT" rev-parse --git-common-dir)"
    assert_eq "real source working state is unchanged" "$source_status_before" "$(git -C "$FIRM_ROOT" status --porcelain=v1 --untracked-files=all)"
  fi
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
  assert_rc "negative-only P2 seam blocks publication" 17 seal_for_run_rejected_p2 "$cleanup_run"
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
  assert_fail "pre-publication validation fails closed" seal_for_run "$atomic_run"
  assert_no_file "failed creation leaves no canonical generation" "$atomic_run/09-test-evidence/final-evidence/g1"
  staging_count="$(find "$atomic_run/09-test-evidence/final-evidence" -maxdepth 1 -name 'g1.staging-*' -print 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "failed creation leaves no staging generation" 0 "$staging_count"
fi

t_summary
