#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEAL="$BIN/firm-seal-qa-evidence"

seal_for_run() {
  local _seal_run="$1" _seal_repo; shift
  _seal_repo="$(cd "$_seal_run/../../.." && pwd -P)"
  (cd "$_seal_repo" && "$SEAL" "$@" --run "$_seal_run")
}

# seal_for_run_from <cwd> <run> [args...] — invoke the sealer from an arbitrary working directory,
# which is how this firm's agents actually invoke it. seal_for_run always cds to the repository
# root, so it could only ever pin the cwd == repo case.
seal_for_run_from() {
  local _seal_cwd="$1" _seal_run="$2"; shift 2
  (cd "$_seal_cwd" && "$SEAL" "$@" --run "$_seal_run")
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
  _trace_writer="${3:-}"
  _real_qa_tools="${4:-}"
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
  if [ -n "$_real_qa_tools" ]; then
    # A fourth argument captures the candidate with the real firm-qa-checkout, which writes its own
    # qa-candidate.json and qa_checkout ledger event, exactly as a live engagement does.
    git -C "$_repo" branch "integration/$(basename "$_run")" "$_sha" || return 1
    (cd "$_repo" && "$BIN/firm-qa-checkout" --run "$_run") >/dev/null 2>&1 || return 1
  else
    mkdir -p "$(dirname "$_checkout")"
    git -C "$_repo" worktree add -q --detach "$_checkout" "$_sha" || return 1
    printf '{"schema_version":2,"run_id":"%s","repository_root":"%s","git_common_dir":"%s","checkout_path":"%s","source_ref":"refs/heads/integration/seal","source_ref_sha":"%s","base_sha":"%s","candidate_sha":"%s","generation":1}\n' \
      "$(basename "$_run")" "$_repo" "$_common" "$_checkout" "$_sha" "$_sha" "$_sha" > "$_run/09-test-evidence/qa-candidate.json"
    chmod 600 "$_run/09-test-evidence/qa-candidate.json"
  fi
  # An optional third argument names a function that rewrites traceability.yaml (and any evidence it
  # cites) before the producer records are published, so the fixture's records match its final bytes.
  if [ -n "$_trace_writer" ]; then "$_trace_writer" "$_run" "$_sha" || return 1; fi
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
  if [ -n "$_real_qa_tools" ]; then
    "$BIN/firm-qa-clean-check" --run "$_run" >/dev/null || return 1
  fi
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

write_checkout_command_evidence() {
  local _wce_run="$1"
  t_python - "$_wce_run" <<'PY'
import hashlib,json,os,pathlib,sys
run=pathlib.Path(sys.argv[1])
out=run/'09-test-evidence/checkout-status.stdout'
out.write_bytes(b'')
os.chmod(out,0o600)
result={"schema_version":1,"argv":["git","status","--porcelain"],
        "cwd":".agent-firm/qa-checkout/"+run.name,
        "started_at":"2026-09-28T00:00:00.000Z","finished_at":"2026-09-28T00:00:01.000Z",
        "duration_ms":1000,"exit_code":0,"result":"pass","inputs":[],"outputs":[],
        "stdout":{"kind":"retained","path":"09-test-evidence/checkout-status.stdout","bytes":0,
                  "sha256":hashlib.sha256(b'').hexdigest(),"mode":"0600","sanitizer":"identity"},
        "stderr":{"kind":"not_applicable","reason":"stream_not_emitted"}}
(run/'09-test-evidence/checkout-status.json').write_text(json.dumps(result,indent=2)+"\n")
verdict={"artifacts":["09-test-evidence/checkout-status.json"],
         "commands_run":[{"cmd":"git status --porcelain","exit_code":0,"duration_s":1,
                          "artifact":"09-test-evidence/checkout-status.json"}],
         "verdict":"APPROVE"}
(run/'08-qa-verdict.json').write_text(json.dumps(verdict)+"\n")
PY
}

t_case "the known-fake fixture allowance covers one exact token on the source diff and nothing else"
assert_ok "the fake password in a test comment is allowed only as that exact token, only in source_diff" \
  t_python - "$FIRM_ROOT" <<'PY'
import os,sys
sys.path.insert(0,os.path.join(sys.argv[1],"agent-firm","lib"))
import evidence_seal as e
policy=e.parse_json_unique(open(os.path.join(sys.argv[1],"agent-firm","policy","evidence-privacy.yaml"),"rb").read())
privacy=e._privacy_patterns(policy)
diff="09-test-evidence/final-evidence/g1/candidate.diff"
# The exact comment line from tests/test-judge-input-integrity.sh on the PR #12 candidate.
line=b"+# THE REGRESSION THIS CASE EXISTS FOR. Textual redaction caught `password: hunter2` because the key\n"
scan=e._scan(line,diff,privacy)
assert [a["rule_id"] for a in scan["allowances"]]==["known_fake_secret_fixture_hunter2"],scan
def blocked(raw,relative):
    try:
        e._scan(raw,relative,privacy)
    except e.SealError as exc:
        assert exc.category=="PRIVACY_MATCH",exc.category
    else:
        raise AssertionError(("allowed",raw,relative))
# Same token on any other surface still blocks.
for relative in ("10-handoff.md","08-qa-verdict.json","traceability.yaml","09-test-evidence/x.log"):
    blocked(line,relative)
# Any other value, key, spacing or a longer value still blocks on the source diff.
for raw in (b"password: hunter3`", b"password: hunter2x`", b"password=hunter2`", b"password: hunter2",
            b"passwd: hunter2`", b"password: hunter2`extra", b"api_key: hunter2`", b"password:  hunter2`"):
    blocked(raw,diff)
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
      # AC-003 on the production shape: the sealer must work from where agents actually stand.
      #
      # `cwd` was the one dimension the operator-home repair did not project. Recorded as the
      # canonical ABSOLUTE path from anywhere but the repository root, it landed in the privacy
      # report -- which is then self-scanned with no identity bindings and classifies as
      # `test_evidence`, a surface the `operator_home` deny category covers. So on any repository
      # under /Users/<operator>/, sealing from a worktree aborted with PRIVACY_MATCH naming the
      # sealer's own report. This firm's default working pattern puts every agent in
      # .agent-firm/worktrees/..., so that was the normal path, not an edge case.
      worktree_fixture="$(make_sealable_run claude "$users_repo")"; worktree_fixture_rc=$?
      worktree_run="$(printf '%s\n' "$worktree_fixture" | sed -n '2p')"
      worktree_cwd="$users_repo/.agent-firm/worktrees/seal-from-worktree"
      mkdir -p "$worktree_cwd"
      if [ "$worktree_fixture_rc" -ne 0 ] || [ -z "$worktree_run" ]; then
        _t_no "second users-hierarchy sealable run created" "fixture setup failed"
      else
        _t_ok "second users-hierarchy sealable run created"
        assert_ok "sealing succeeds when invoked from a worktree, not the repository root" \
          seal_for_run_from "$worktree_cwd" "$worktree_run"
        assert_ok "independent verifier accepts the worktree-invoked seal" \
          seal_for_run_from "$worktree_cwd" "$worktree_run" --verify --phase publication
        assert_ok "the worktree cwd is projected run-relative, not as an operator-home path" \
          t_python - "$worktree_run" <<'PY'
import json,pathlib,sys
run=pathlib.Path(sys.argv[1])
privacy=json.load(open(run/'09-test-evidence/final-evidence/g1/privacy.json'))
prefix="/"+"Users"+"/"
assert privacy['command']['cwd']=='.agent-firm/worktrees/seal-from-worktree', privacy['command']['cwd']
assert privacy['command']['cwd_projection']=='repository_relative/v1'
assert not privacy['command']['cwd'].startswith(prefix)
assert privacy['command']['argv'][0]=='firm-seal-qa-evidence'
assert privacy['command']['argv'][-1]=='.agent-firm/runs/'+run.name
PY
      fi
    fi
      # The live QA path on a /Users repository: the real firm-qa-checkout and firm-qa-clean-check
      # write their own ledger events, and QA's command evidence runs inside the QA checkout. Before
      # the fix both put /Users/<operator>/... into sealed bytes (the ledger prefix and the command
      # result's cwd), so no real run on a macOS operator's repository could ever seal.
      live_fixture="$(make_sealable_run claude "$users_repo" write_checkout_command_evidence real_qa_tools)"; live_rc=$?
      live_run="$(printf '%s\n' "$live_fixture" | sed -n '2p')"
      if [ "$live_rc" -ne 0 ] || [ -z "$live_run" ]; then
        _t_no "live-QA-path users-hierarchy run created" "fixture setup failed"
      else
        _t_ok "live-QA-path users-hierarchy run created"
        assert_output "the real checkout tool records the checkout repository-relative" \
          "\"dir\":\".agent-firm/qa-checkout/$(basename "$live_run")\"" cat "$live_run/run.jsonl"
        assert_ok "the real clean check still binds that relative checkout event" \
          "$BIN/firm-qa-clean-check" --run "$live_run"
        assert_ok "seal publishes with real checkout events and in-checkout command evidence" seal_for_run "$live_run"
        assert_ok "independent verifier accepts it" seal_for_run "$live_run" --verify --phase publication
        assert_ok "no operator-home path reaches the ledger prefix and the allowances stay at five" \
          t_python - "$live_run" <<'PY'
import json,pathlib,sys
run=pathlib.Path(sys.argv[1])
privacy=json.load(open(run/'09-test-evidence/final-evidence/g1/privacy.json'))
assert privacy['allow_count']==5, privacy['allow_count']
ledger=[scan for scan in privacy['inputs'] if scan['path']=='run.jsonl#prefix']
assert len(ledger)==1 and ledger[0]['allowances']==[] and ledger[0]['matches']==[]
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
e._validate_command_result(valid,'command.json',tmp,tmp)
# A repository-relative cwd is canonical when it names a real, non-symlinked directory in the repository.
(tmp/'sub').mkdir(); os.symlink(tmp/'sub',tmp/'link')
for cwd in ('.','sub'):
 e._validate_command_result({**valid,'cwd':cwd},'command.json',tmp,tmp)
mutations=[]
for key,value in (("argv",["tool","<placeholder>"]),("cwd",str(tmp/'..')),("cwd","../x"),("cwd","sub/../sub"),("cwd","./sub"),("cwd","missing"),("cwd","link"),("cwd",""),("started_at","not-time"),("finished_at","2026-08-30T00:00:00Z"),("duration_ms",999),("exit_code",1),("result","timeout")):
 d=copy.deepcopy(valid); d[key]=value; mutations.append(d)
d=copy.deepcopy(valid); d["inputs"][0]["bytes"]+=1; mutations.append(d)
d=copy.deepcopy(valid); d["extra"]=1; mutations.append(d)
d=copy.deepcopy(valid); d["inputs"]*=2; mutations.append(d)
d=copy.deepcopy(valid); d["outputs"]=[]; mutations.append(d)
for d in mutations:
 try:e._validate_command_result(d,'command.json',tmp,tmp)
 except e.SealError:pass
 else:raise AssertionError(('command mutation accepted',d))
sha='a'*40; raw=b'x'; digest=hashlib.sha256(raw).hexdigest(); sid='evt-start'; base=[{"ts":"2026-08-31T00:00:00Z","event":"qa_started","event_id":sid,"stage":"test/Q","role":"qa-tester","contract":{},"authority":[],"activation":{}},{"ts":"2026-08-31T00:00:01Z","event":"evidence_produced","event_id":"evt-proof","run_id":"fixture","path":"x","sha256":digest,"bytes":"1","sha":sha,"generation":"1","stage":"test/Q","role":"qa-tester","role_start_event_id":sid},{"ts":"2026-08-31T00:00:02Z","event":"qa_completed","event_id":"evt-done","stage":"test/Q","role":"qa-tester","role_start_event_id":sid}]
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

mk_legacy_run() {
  # A GENUINE historical legacy run, built the way REAL runs are built.
  #
  # This fixture used to be a bare `mkdir` with a hand-written two-line ledger and no
  # run-metadata.json -- and its own comment said so: "the only shape whose legacy-shaped evidence
  # rows stay valid". No run in this repository has that shape, so the family that discharges
  # AC-011's legacy clause was proven against a run that cannot exist, and could not distinguish a
  # BOUNDED legacy predicate from an UNREACHABLE one. It did not: `legacy` was unreachable for all
  # 25 real runs, and every one of them that had published evidence became unappendable.
  #
  # So it is now made with `firm-new-run`: real schema_version-2 run-metadata.json, real bound
  # 09-test-evidence/qa-candidate.json. The one thing removed is the `evidence_seal_protocol` marker
  # today's firm-new-run stamps on the run_started row -- that is exactly what makes it historical,
  # and it matches the real runs whose evidence predates the closed family.
  local _repo="$1" _sha _relative _run _digest _bytes _id
  _sha="$(sha_of "$_repo" main)" || return 1
  _relative="$(cd "$_repo" && "$BIN/firm-new-run" --primary claude --base "$_sha" legacy-evidence full_track)" || return 1
  _run="$_repo/$_relative"
  _id="$(basename "$_run")"
  mkdir -p "$_run/09-test-evidence"
  t_python - "$_run" <<'PY' || return 1
import json, os, pathlib, sys
run = pathlib.Path(sys.argv[1])
metadata = json.load(open(run / "run-metadata.json"))
candidate = {
    "schema_version": 2, "run_id": run.name,
    "repository_root": metadata["repository_root"], "git_common_dir": metadata["git_common_dir"],
    "checkout_path": metadata["repository_root"], "source_ref": "refs/heads/integration/legacy",
    "source_ref_sha": metadata["accepted_base_sha"], "base_sha": metadata["accepted_base_sha"],
    "candidate_sha": metadata["accepted_base_sha"], "generation": 1,
}
target = run / "09-test-evidence" / "qa-candidate.json"
target.write_text(json.dumps(candidate, sort_keys=True) + "\n")
os.chmod(target, 0o600)
PY
  printf '%s\n' 'legacy evidence artifact' > "$_run/legacy-artifact.txt"
  _digest="$(shasum -a 256 "$_run/legacy-artifact.txt" | awk '{print $1}')"
  _bytes="$(wc -c < "$_run/legacy-artifact.txt" | tr -d ' ')"
  head -n 1 "$_run/run.jsonl" | t_python -c \
    'import json,sys; row=json.loads(sys.stdin.read()); row.pop("evidence_seal_protocol",None); print(json.dumps(row,separators=(",",":")))' \
    > "$_run/.legacy.rows" || return 1
  printf '{"ts":"2024-01-01T00:00:01Z","event":"evidence_produced","event_id":"evt-legacy-evidence","run_id":"%s","sha":"%s","generation":"1","path":"legacy-artifact.txt","sha256":"%s","bytes":"%s"}\n' \
    "$_id" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$_digest" "$_bytes" >> "$_run/.legacy.rows"
  mv "$_run/.legacy.rows" "$_run/run.jsonl"
  chmod 600 "$_run/run.jsonl"
  printf '%s' "$_run"
}

# AC-007/AC-010/AC-011/AC-012. Everything below is local-fixture-only: no provider is launched, no
# credential is read, and both primary orientations are exercised through ordinary sealable runs.
t_case "every AC-007 mutation family executes fail-closed and is proven by the closed golden manifest"
if ! t_p2_row_supported; then
  t_skip "AC-007 mutation matrix and golden manifest" "requires a supported P2 ledger write host"
else
  matrix_run="$(make_sealable_run claude | sed -n '2p')"
  pre_run="$(make_sealable_run claude | sed -n '2p')"
  published_fixture="$(make_sealable_run claude)"
  published_repo="$(printf '%s\n' "$published_fixture" | sed -n '1p')"
  published_run="$(printf '%s\n' "$published_fixture" | sed -n '2p')"
  codex_run="$(make_sealable_run codex | sed -n '2p')"
  legacy_run="$(mk_legacy_run "$published_repo")"
  if [ -z "$matrix_run" ] || [ -z "$pre_run" ] || [ -z "$published_run" ] || [ -z "$codex_run" ]; then
    _t_no "AC-007 matrix fixtures created" "one or more sealable fixtures failed"
  else
    _t_ok "AC-007 matrix fixtures created"
    assert_ok "claude-primary fixture publishes one seal" seal_for_run "$published_run"
    assert_ok "codex-primary fixture publishes one seal" seal_for_run "$codex_run"
    matrix_authority="$(t_python -c 'import json,sys; rid=sys.argv[1]; print(json.dumps([{"source_run":".agent-firm/runs/"+rid,"event_id":sys.argv[2],"expect":{"event":"run_started","run_id":rid,"fields":{"base_sha":sys.argv[3]}}}],separators=(",",":")))' \
      "$(basename "$matrix_run")" \
      "$(t_python -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["event_id"])' "$matrix_run/run.jsonl")" \
      "$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_sha"])' "$matrix_run/09-test-evidence/qa-candidate.json")")"
    matrix_activation="$("$BIN/firm-model-resolve" --provider codex --role qa-tester --format activation)"
    matrix_start="$("$BIN/firm-ledger-log" --run "$matrix_run" --strict --role-start --stage test/M-01 \
      --role qa-tester --contract role-contracts/Q-01-qa-tester.md --event qa_started \
      --authority-json "$matrix_authority" --agent /root/mutation_matrix \
      --activation-json "$matrix_activation" \
      | t_python -c 'import json,sys; print(json.load(sys.stdin)["event_id"])')"
    if [ -z "$matrix_start" ]; then
      _t_no "mutation-evidence role window opened" "role start produced no event id"
    else
      _t_ok "mutation-evidence role window opened"
      matrix_out="$(t_python "$TESTS_DIR/fixtures/ac007-mutation-matrix.py" "$FIRM_ROOT" "$matrix_run" \
        "$pre_run" "$published_run" "$codex_run" "$legacy_run" test/M-01 qa-tester "$matrix_start" 2>&1)"
      matrix_rc=$?
      if [ "$matrix_rc" -eq 0 ]; then
        _t_ok "every AC-007 family raised its exact expected fail-closed category"
      else
        _t_no "every AC-007 family raised its exact expected fail-closed category" "$(_t_ctx "$matrix_out")"
      fi
      "$BIN/firm-ledger-log" --run "$matrix_run" --strict qa_completed stage=test/M-01 \
        role=qa-tester "role_start_event_id=$matrix_start" >/dev/null
      # Name the families the run actually proved. A count would pass a matrix that dropped one.
      assert_eq "the published matrix names every required family exactly once" \
        "ac007_both_provider_sealed ac007_evidence_tamper ac007_genuine_legacy_reviewable ac007_integration_index_duplicate ac007_integration_index_malformed ac007_opted_in_no_fallback ac007_partial_no_fallback ac007_placeholder_argv ac007_pr_marker_malformed ac007_privacy_category_misuse ac007_privacy_surface_misuse ac007_producer_window_defect ac007_seal_tamper ac007_synchronized_toctou ac007_unexpected_ledger_append" \
        "$(t_python -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(i["family"] for i in d["families"]))' \
           "$matrix_run/09-test-evidence/mutation-evidence/ac007-manifest.json")"
      assert_eq "each family records the exact category it observed" \
        "ac007_both_provider_sealed=SEAL_IDENTITY ac007_evidence_tamper=ARTIFACT_STALE ac007_genuine_legacy_reviewable=NONE ac007_integration_index_duplicate=DUPLICATE_DECLARATION ac007_integration_index_malformed=INTEGRATION_INDEX ac007_opted_in_no_fallback=ARTIFACT_MISSING ac007_partial_no_fallback=MULTIPLE_SEALS ac007_placeholder_argv=COMMAND_EVIDENCE ac007_pr_marker_malformed=PR_MARKERS ac007_privacy_category_misuse=PRIVACY_MATCH ac007_privacy_surface_misuse=PRIVACY_MATCH ac007_producer_window_defect=PRODUCER_WINDOW ac007_seal_tamper=NONCANONICAL_JSON ac007_synchronized_toctou=ARTIFACT_MOVED ac007_unexpected_ledger_append=LEDGER_SUFFIX" \
        "$(t_python -c '
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
manifest=json.load(open(root/"09-test-evidence/mutation-evidence/ac007-manifest.json"))
out=[]
for item in manifest["families"]:
  record=json.load(open(root/item["path"]))
  out.append(item["family"]+"="+record["observed_category"])
print(" ".join(out))' "$matrix_run")"
      assert_eq "only the genuine-legacy family records a success" "ac007_genuine_legacy_reviewable" \
        "$(t_python -c '
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
manifest=json.load(open(root/"09-test-evidence/mutation-evidence/ac007-manifest.json"))
print(" ".join(item["family"] for item in manifest["families"]
               if json.load(open(root/item["path"]))["legacy_success"]))' "$matrix_run")"
      assert_ok "library validator accepts the closed current-candidate manifest" \
        t_python - "$FIRM_ROOT" "$matrix_run" <<'PY'
import json,os,sys
root,run=sys.argv[1:]
sys.path.insert(0,os.path.join(root,"agent-firm","lib"))
from evidence_seal import REQUIRED_MUTATION_FAMILIES,seal_state,validate_mutation_matrix
candidate=json.load(open(os.path.join(run,"09-test-evidence","qa-candidate.json")))
receipt=validate_mutation_matrix(run,candidate["candidate_sha"],candidate["generation"],
                                 seal_state(run)["records"])
assert set(receipt["families"])==set(REQUIRED_MUTATION_FAMILIES),sorted(receipt["families"])
assert receipt["producer"]["event"]=="evidence_produced"
assert {receipt["families"][name]["orientation"] for name in receipt["families"]} >= {"claude","both"}
for name,proven in receipt["families"].items():
  assert proven["cases"],name
  assert proven["producer"]["event_id"].startswith("evt-"),name
PY
      matrix_repo="$(cd "$matrix_run/../../.." && pwd -P)"
      matrix_assertions="$matrix_repo/ac007-golden-assertions.yaml"
      printf 'assertions:\n  - mutation_matrix_proven: true\n' > "$matrix_assertions"
      assert_rc "golden assertion passes on complete mutation evidence" 0 \
        "$BIN/firm-check-assertions" "$matrix_assertions" "$matrix_repo"
      assert_output "golden assertion names the proven candidate and generation" "15 AC-007 families proven" \
        "$BIN/firm-check-assertions" "$matrix_assertions" "$matrix_repo"
      matrix_inverted="$matrix_repo/ac007-golden-assertions-false.yaml"
      printf 'assertions:\n  - mutation_matrix_proven: false\n' > "$matrix_inverted"
      assert_rc "golden assertion refuses to be inverted into a negative" 1 \
        "$BIN/firm-check-assertions" "$matrix_inverted" "$matrix_repo"
      # Every evidence dimension, removed / duplicated / staled / mutated / mismatched / left
      # unproduced / changed after publication. The semantic ones are re-published CONSISTENTLY, so
      # the only defect is the claim itself -- a digest mismatch would prove nothing about them.
      matrix_backup="$(mktemp -d "${TMPDIR:-/tmp}/firm-matrix-backup.XXXXXX")"; t_track "$matrix_backup"
      cp -R "$matrix_run/09-test-evidence/mutation-evidence" "$matrix_backup/mutation-evidence"
      cp "$matrix_run/run.jsonl" "$matrix_backup/run.jsonl"
      for tamper in removed_family_evidence dropped_manifest_family extra_manifest_family \
                    duplicated_manifest_family duplicated_producer_event \
                    unproduced_family_evidence unproduced_manifest stale_manifest_digest \
                    stale_manifest_bytes changed_after_publication producer_event_id_mismatch \
                    mutable_family_evidence symlinked_family_evidence \
                    noncanonical_family_evidence mismatched_candidate mismatched_generation \
                    mismatched_record_candidate observed_category_drift seal_published \
                    reusable_partial_generation ledger_prefix_drift provider_call_drift \
                    nonlegacy_success legacy_family_not_reviewable single_orientation \
                    empty_case_list extra_record_field; do
        rm -rf "$matrix_run/09-test-evidence/mutation-evidence"
        cp -R "$matrix_backup/mutation-evidence" "$matrix_run/09-test-evidence/mutation-evidence"
        cp "$matrix_backup/run.jsonl" "$matrix_run/run.jsonl"
        chmod 600 "$matrix_run/run.jsonl"
        if ! t_python "$TESTS_DIR/fixtures/ac007-mutation-tamper.py" "$FIRM_ROOT" "$matrix_run" \
             "$tamper" >/dev/null 2>&1; then
          _t_no "$tamper is applied" "the tamper script failed"
          continue
        fi
        t_python - "$FIRM_ROOT" "$matrix_run" >/dev/null 2>&1 <<'PY'
import json,os,sys
root,run=sys.argv[1:]
sys.path.insert(0,os.path.join(root,"agent-firm","lib"))
from evidence_seal import seal_state,validate_mutation_matrix
candidate=json.load(open(os.path.join(run,"09-test-evidence","qa-candidate.json")))
validate_mutation_matrix(run,candidate["candidate_sha"],candidate["generation"],
                         seal_state(run)["records"])
PY
        library_rc=$?
        "$BIN/firm-check-assertions" "$matrix_assertions" "$matrix_repo" >/dev/null 2>&1
        golden_rc=$?
        if [ "$library_rc" -ne 0 ] && [ "$golden_rc" -eq 1 ]; then
          _t_ok "$tamper is refused by both the library and the golden assertion"
        else
          _t_no "$tamper is refused by both the library and the golden assertion" \
            "library rc=$library_rc golden rc=$golden_rc"
        fi
      done
      rm -rf "$matrix_run/09-test-evidence/mutation-evidence"
      cp -R "$matrix_backup/mutation-evidence" "$matrix_run/09-test-evidence/mutation-evidence"
      cp "$matrix_backup/run.jsonl" "$matrix_run/run.jsonl"
      chmod 600 "$matrix_run/run.jsonl"
      assert_rc "restored evidence passes the golden assertion again" 0 \
        "$BIN/firm-check-assertions" "$matrix_assertions" "$matrix_repo"
    fi
  fi
fi

t_case "one artifact may re-declare a path consistently; conflicting or repeated declarations still fail"
assert_ok "discovery collapses consistent re-declarations and rejects conflicts and repeats" \
  t_python - "$FIRM_ROOT" <<'PY'
import json,os,sys
sys.path.insert(0,os.path.join(sys.argv[1],"agent-firm","lib"))
from evidence_seal import SealError,_discover_references as discover
def refs(relative,value):
    return discover(relative,json.dumps(value).encode(),value)
def rejected(relative,value):
    try:
        refs(relative,value)
    except SealError as exc:
        assert exc.category=="DUPLICATE_DECLARATION",exc.category
    else:
        raise AssertionError(f"accepted: {value}")
log="09-test-evidence/shared.log"
# A captured log is both a primary artifact and the required commands_run artifact.
assert refs("08-qa-verdict.json",{"artifacts":[log],"commands_run":[{"artifact":log}]})==[log]
# Prose may name the same evidence token more than once.
assert discover("10-handoff.md",f"evidence://run/{log} and again evidence://run/{log}".encode(),None)==[log]
ref={"path":log,"candidate_sha":"a"*40,"sha256":"b"*64,"bytes":3,"producer":{"event_id":"evt-x","event":"evidence_produced"}}
# One shared log proves two traceability rows, each with a complete evidenceRef.
assert refs("traceability.yaml",{"matrix":[{"evidence":[ref]},{"evidence":[dict(ref)]}]})==[log]
# Still fatal: two references to one path that disagree about its identity.
rejected("traceability.yaml",{"matrix":[{"evidence":[ref]},{"evidence":[{**ref,"sha256":"c"*64}]}]})
# Still fatal: one list naming the same path twice.
rejected("traceability.yaml",{"matrix":[{"evidence":[ref,dict(ref)]}]})
rejected("08-qa-verdict.json",{"artifacts":[log,log],"commands_run":[]})
PY

write_shared_log_traceability() {
  local _twr_run="$1" _twr_sha="$2" _twr_log=09-test-evidence/shared-proof.log
  printf 'shared proof\n' > "$_twr_run/$_twr_log"
  t_python - "$_twr_run" "$_twr_sha" "$_twr_log" <<'PY'
import hashlib,sys
run,sha,log=sys.argv[1:]
raw=open(f"{run}/{log}","rb").read()
ref=(f"      - {{path: {log}, candidate_sha: '{sha}', sha256: '{hashlib.sha256(raw).hexdigest()}', "
     f"bytes: {len(raw)}, producer: {{event_id: evt-shared-proof, event: evidence_produced}}}}\n")
with open(f"{run}/traceability.yaml","w") as handle:
    handle.write("schema_version: 2\ntask_slug: seal-fixture\ncandidate: {}\nmatrix:\n"
                 "  - id: AC-001\n    evidence:\n" + ref +
                 "  - id: AC-002\n    evidence:\n" + ref +
                 "two_voice: {}\ntwo_voice_diff: []\n")
PY
}
if t_p2_row_supported; then
  shared_fixture="$(make_sealable_run claude "" write_shared_log_traceability)"; shared_rc=$?
  shared_run="$(printf '%s\n' "$shared_fixture" | sed -n '2p')"
  if [ "$shared_rc" -ne 0 ] || [ -z "$shared_run" ]; then
    _t_no "shared-log fixture created" "rc=$shared_rc"
  else
    assert_ok "seal publishes when one log proves two traceability rows" seal_for_run "$shared_run"
    assert_ok "the shared log is sealed exactly once" t_python - "$shared_run" <<'PY'
import json,sys
seal=json.load(open(f"{sys.argv[1]}/09-test-evidence/final-evidence/g1/seal.json"))
paths=[entry["path"] for entry in seal["entries"]]
assert paths.count("09-test-evidence/shared-proof.log")==1,paths
PY
  fi
else
  t_skip "shared-log seal publication" "requires a supported P2 ledger write host"
fi

t_case "the judge wrapper follows the seal on a run with no integration stage"
# A closeout of an already-integrated candidate has no integration summary, and the seal correctly
# holds none. The wrapper used to stop at input assembly ("required judge input is missing:
# integration-summary.md") before any provider phase, so such a run could never reach its judge.
# Input assembly precedes provider discovery, so with no provider CLI on PATH a wrapper that gets
# past assembly reports the provider unavailable instead.
write_legacy_integration_summary() { printf '# Integration summary\n\nLegacy fixture.\n' > "$1/integration-summary.md"; }
if t_p2_row_supported; then
  judge_fixture="$(make_sealable_run claude "" "" real_qa_tools)"; judge_run="$(printf '%s\n' "$judge_fixture" | sed -n '2p')"
  if [ -z "$judge_run" ]; then
    _t_no "no-integration sealed run created" "fixture setup failed"
  else
    assert_ok "the no-integration run seals" seal_for_run "$judge_run"
    judge_out="$(env PATH=/usr/bin:/bin "$BIN/firm-gpt-qa" --run "$judge_run" 2>&1)"; judge_rc=$?
    assert_no_output_text() { case "$2" in *"$3"*) _t_no "$1" "found: $3";; *) _t_ok "$1";; esac; }
    assert_no_output_text "input assembly no longer demands a summary the seal does not hold" \
      "$judge_out" "required judge input is missing"
    assert_eq "it reaches provider discovery and reports the absent CLI as unavailable" 3 "$judge_rc"
  fi
  held_fixture="$(make_sealable_run claude "" write_legacy_integration_summary real_qa_tools)"
  held_run="$(printf '%s\n' "$held_fixture" | sed -n '2p')"
  if [ -z "$held_run" ]; then
    _t_no "summary-holding sealed run created" "fixture setup failed"
  else
    assert_ok "a run with a summary seals it" seal_for_run "$held_run"
    rm "$held_run/integration-summary.md"
    held_out="$(env PATH=/usr/bin:/bin "$BIN/firm-gpt-qa" --run "$held_run" 2>&1)"; held_rc=$?
    assert_eq "a summary the seal holds is still required" 1 "$held_rc"
    case "$held_out" in
      *"ARTIFACT_MISSING: integration-summary.md"*|*"required judge input is missing: integration-summary.md"*) _t_ok "…and its absence is named";;
      *) _t_no "…and its absence is named" "$(printf '%s' "$held_out" | tail -c 300)";;
    esac
  fi
else
  t_skip "judge wrapper on a sealed no-integration run" "requires a supported P2 ledger write host"
fi

# ledger_writes_supported — t_p2_row_supported, but also false under firm-ledger-log's own guarded
# rejection seam (the tests/test-concurrent-runs-eval.sh pattern), so the post-judge and generation
# cases below are SKIPPED by name on a refused host rather than reported as fixture failures:
#   FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=linux bash tests/test-evidence-seal.sh
ledger_writes_supported() {
  [ "${FIRM_LEDGER_TEST_GUARD:-}" = 1 ] && [ -n "${FIRM_LEDGER_P2_TEST_REJECT:-}" ] && return 1
  t_p2_row_supported
}

# publish_generation_producers <run> <sha> <generation> <qa-stage> <packager-stage> — publish the
# three fixed-root producers for one generation inside fresh QA and packager role windows, the way
# make_sealable_run does for generation 1. Role windows are unique per stage, so a later generation
# names new stages.
publish_generation_producers() {
  local _pg_run="$1" _pg_sha="$2" _pg_gen="$3" _pg_qa="$4" _pg_pack="$5" _pg_event _pg_authority _pg_start _pg_path
  _pg_event="$(t_python -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["event_id"])' "$_pg_run/run.jsonl")"
  _pg_authority="$(t_python -c 'import json,sys; rid=sys.argv[1]; print(json.dumps([{"source_run":".agent-firm/runs/"+rid,"event_id":sys.argv[2],"expect":{"event":"run_started","run_id":rid,"fields":{"base_sha":sys.argv[3]}}}],separators=(",",":")))' \
    "$(basename "$_pg_run")" "$_pg_event" "$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_sha"])' "$_pg_run/09-test-evidence/qa-candidate.json")")"
  _pg_start="$("$BIN/firm-ledger-log" --run "$_pg_run" --strict --role-start --stage "$_pg_qa" --role qa-tester \
    --contract role-contracts/Q-01-qa-tester.md --event qa_started --authority-json "$_pg_authority" \
    --agent /root/seal_fixture_qa --activation-json "$("$BIN/firm-model-resolve" --provider codex --role qa-tester --format activation)" \
    | t_python -c 'import json,sys; print(json.load(sys.stdin)["event_id"])')" || return 1
  for _pg_path in 08-qa-verdict.json traceability.yaml; do
    "$BIN/firm-ledger-log" --run "$_pg_run" --strict evidence_produced "sha=$_pg_sha" "generation=$_pg_gen" \
      "path=$_pg_path" "sha256=$(shasum -a 256 "$_pg_run/$_pg_path" | awk '{print $1}')" \
      "bytes=$(wc -c < "$_pg_run/$_pg_path" | tr -d ' ')" "stage=$_pg_qa" role=qa-tester \
      "role_start_event_id=$_pg_start" >/dev/null || return 1
  done
  "$BIN/firm-ledger-log" --run "$_pg_run" --strict qa_completed "stage=$_pg_qa" role=qa-tester \
    "role_start_event_id=$_pg_start" >/dev/null || return 1
  _pg_start="$("$BIN/firm-ledger-log" --run "$_pg_run" --strict --role-start --stage "$_pg_pack" --role packager \
    --contract role-contracts/P-01-packager.md --event packaging_started --authority-json "$_pg_authority" \
    --agent /root/seal_fixture_packager --activation-json "$("$BIN/firm-model-resolve" --provider codex --role packager --format activation)" \
    | t_python -c 'import json,sys; print(json.load(sys.stdin)["event_id"])')" || return 1
  "$BIN/firm-ledger-log" --run "$_pg_run" --strict evidence_produced "sha=$_pg_sha" "generation=$_pg_gen" \
    path=10-handoff.md "sha256=$(shasum -a 256 "$_pg_run/10-handoff.md" | awk '{print $1}')" \
    "bytes=$(wc -c < "$_pg_run/10-handoff.md" | tr -d ' ')" "stage=$_pg_pack" role=packager \
    "role_start_event_id=$_pg_start" >/dev/null || return 1
  "$BIN/firm-ledger-log" --run "$_pg_run" --strict packaging_completed "stage=$_pg_pack" role=packager \
    "role_start_event_id=$_pg_start" >/dev/null
}

t_case "the seal's producer for a path is the row of the generation being sealed"
assert_ok "producer selection is generation-scoped and still exact inside a generation" \
  t_python - "$FIRM_ROOT" <<'PY'
import copy,hashlib,os,sys
sys.path.insert(0,os.path.join(sys.argv[1],"agent-firm","lib"))
import evidence_seal as e
raw=b'x'; digest=hashlib.sha256(raw).hexdigest(); sha1="a"*40; sha2="b"*40
def window(gen,sha,stage,second):
    sid=f"evt-start-{gen}"
    return [{"ts":f"2026-10-01T00:00:{second:02d}Z","event":"qa_started","event_id":sid,"stage":stage,"role":"qa-tester","contract":{},"authority":[],"activation":{}},
            {"ts":f"2026-10-01T00:00:{second+1:02d}Z","event":"evidence_produced","event_id":f"evt-proof-{gen}","run_id":"fixture","path":"x","sha256":digest,"bytes":"1","sha":sha,"generation":str(gen),"stage":stage,"role":"qa-tester","role_start_event_id":sid},
            {"ts":f"2026-10-01T00:00:{second+2:02d}Z","event":"qa_completed","event_id":f"evt-done-{gen}","stage":stage,"role":"qa-tester","role_start_event_id":sid}]
rows=window(1,sha1,"test/Q-01",0)+window(2,sha2,"test/Q-02",10)
assert e._producer(rows,'x',raw,sha2,2,True)["event_id"]=="evt-proof-2"
assert e._producer(rows,'x',raw,sha1,1,True)["event_id"]=="evt-proof-1"
assert e._producer(rows,'x',raw,"c"*40,3,False) is None
def refused(rows,sha,generation,category):
    try: e._producer(rows,'x',raw,sha,generation,True)
    except e.SealError as exc: assert exc.category==category,(exc.category,category)
    else: raise AssertionError(("accepted",category))
refused(rows,"c"*40,3,"PRODUCER_MISSING")
twice=copy.deepcopy(rows); twice.insert(5,dict(twice[4],event_id="evt-proof-2b"))
refused(twice,sha2,2,"PRODUCER_DUPLICATE")
other=copy.deepcopy(rows); other[4]["sha"]="d"*40
refused(other,sha2,2,"PRODUCER_STALE")
PY

t_case "a sealed and judged generation can be recaptured, republished, and sealed as generation 2"
if ! ledger_writes_supported; then
  t_skip "generation-2 recapture after a sealed judge attempt" "requires a supported P2 ledger write host and no refused-row seam"
else
  g2_fixture="$(make_sealable_run claude "" "" real_qa_tools)"
  g2_repo="$(printf '%s\n' "$g2_fixture" | sed -n '1p')"; g2_run="$(printf '%s\n' "$g2_fixture" | sed -n '2p')"
  g2_sha1="$(printf '%s\n' "$g2_fixture" | sed -n '3p')"
  if [ -z "$g2_run" ]; then
    _t_no "generation-2 fixture created" "fixture setup failed"
  else
    _t_ok "generation-2 fixture created"
    assert_ok "generation 1 seals" seal_for_run "$g2_run"
    g2_judge_rc=0; env PATH=/usr/bin:/bin "$BIN/firm-gpt-qa" --run "$g2_run" >/dev/null 2>&1 || g2_judge_rc=$?
    assert_eq "the generation-1 judge attempt reaches a terminal outcome" 3 "$g2_judge_rc"
    ( cd "$g2_repo" && git checkout -q "integration/$(basename "$g2_run")" && printf 'generation two\n' > gen2.txt \
      && git add gen2.txt && git commit -qm "generation two" && git checkout -q main ) >/dev/null 2>&1
    g2_sha2="$(sha_of "$g2_repo" "integration/$(basename "$g2_run")")"
    g2_out="$(cd "$g2_repo" && "$BIN/firm-qa-checkout" --run "$g2_run" 2>&1)"; g2_rc=$?
    assert_eq "firm-qa-checkout captures generation 2 after a sealed judge attempt" 0 "$g2_rc"
    case "$g2_out" in *unclassifiable*) _t_no "the recapture names no unclassifiable ledger" "$(_t_ctx "$g2_out")";; *) _t_ok "the recapture names no unclassifiable ledger";; esac
    assert_eq "the candidate is now generation 2" 2 \
      "$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["generation"])' "$g2_run/09-test-evidence/qa-candidate.json")"
    assert_rc "the two-generation ledger classifies" 0 \
      "$BIN/firm-ledger-log" --classify-ledger-file "$(basename "$g2_run")" "$g2_run/run.jsonl"
    g2_before="$(shasum -a 256 "$g2_run/run.jsonl" | awk '{print $1}')"
    assert_rc "a new generation-1 era publication is refused once generation 2 exists" 1 \
      "$BIN/firm-ledger-log" --run "$g2_run" --strict evidence_produced "sha=$g2_sha1" generation=1 \
      path=08-qa-verdict.json "sha256=$(shasum -a 256 "$g2_run/08-qa-verdict.json" | awk '{print $1}')" \
      "bytes=$(wc -c < "$g2_run/08-qa-verdict.json" | tr -d ' ')" stage=test/Q-01 role=qa-tester \
      role_start_event_id=evt-not-a-window
    assert_eq "the refused late publication leaves the ledger exact" "$g2_before" \
      "$(shasum -a 256 "$g2_run/run.jsonl" | awk '{print $1}')"
    assert_ok "generation 2 republishes its fixed-root producers" \
      publish_generation_producers "$g2_run" "$g2_sha2" 2 test/Q-02 package/P-02
    assert_ok "generation 2 seals with its own producer rows" seal_for_run "$g2_run"
    assert_file "the generation-2 seal is its own bundle" "$g2_run/09-test-evidence/final-evidence/g2/seal.json"
    assert_ok "the generation-2 seal verifies for publication" seal_for_run "$g2_run" --verify --phase publication
    assert_ok "the generation-2 seal verifies for wrapper preflight" seal_for_run "$g2_run" --verify --phase wrapper-preflight
    assert_ok "every generation-2 fixed-root producer is a generation-2 row" t_python - "$g2_run" "$g2_sha2" <<'PY'
import json,sys
run,sha=sys.argv[1:]
seal=json.load(open(run+"/09-test-evidence/final-evidence/g2/seal.json"))
rows={row.get("event_id"):row for row in map(json.loads,open(run+"/run.jsonl"))}
entries={entry["path"]:entry for entry in seal["entries"]}
for path in ("08-qa-verdict.json","traceability.yaml","10-handoff.md"):
    row=rows[entries[path]["producer"]["event_id"]]
    assert row["generation"]=="2" and row["sha"]==sha,(path,row)
assert seal["identity"]["generation"]==2 and seal["identity"]["candidate_sha"]==sha
PY
    g2_wrapper_out="$(env PATH=/usr/bin:/bin "$BIN/firm-gpt-qa" --run "$g2_run" 2>&1)"; g2_wrapper_rc=$?
    assert_eq "the real wrapper passes generation-2 preflight and reaches provider discovery" 3 "$g2_wrapper_rc"
    assert_output "the generation-2 attempt is numbered for its own generation" "gpt-c2-a0001" \
      cat "$g2_run/09-test-evidence/reviewer-state.gpt.json"
  fi
fi

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
