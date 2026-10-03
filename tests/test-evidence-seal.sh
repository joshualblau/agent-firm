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

# FOCUS-HELPERS-BEGIN
# qa_window_open <run> <stage> — open a native primary-QA (qa-tester) role window through the
# writer's role-start mode and print its event id; qa_window_close <run> <stage> <id> closes it.
qa_window_open() {
  local _qw_run="$1" _qw_stage="$2" _qw_authority
  _qw_authority="$(t_python -c 'import json,sys; run=sys.argv[1]; rid=run.rstrip("/").split("/")[-1]; first=json.loads(open(run+"/run.jsonl").readline()); print(json.dumps([{"source_run":".agent-firm/runs/"+rid,"event_id":first["event_id"],"expect":{"event":"run_started","run_id":rid,"fields":{"base_sha":first["base_sha"]}}}],separators=(",",":")))' "$_qw_run")"
  "$BIN/firm-ledger-log" --run "$_qw_run" --strict --role-start --stage "$_qw_stage" --role "${3:-qa-tester}" \
    --contract "${4:-role-contracts/Q-01-qa-tester.md}" --event qa_started --authority-json "$_qw_authority" \
    --agent /root/post_judge_qa \
    --activation-json "$("$BIN/firm-model-resolve" --provider codex --role "${3:-qa-tester}" --format activation)" \
    | t_python -c 'import json,sys; print(json.load(sys.stdin)["event_id"])'
}
qa_window_close() {
  "$BIN/firm-ledger-log" --run "$1" --strict qa_completed "stage=$2" role=qa-tester "role_start_event_id=$3" >/dev/null
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
# FOCUS-HELPERS-END

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

t_case "post_judge_inputs copies only verified, bound, no-follow, privacy-clean artifacts"
assert_ok "the judge-input selector binds, declares, refuses symlinks, and stops on a digest mismatch" \
  t_python - "$FIRM_ROOT" <<'PY'
import hashlib,json,os,sys,tempfile
sys.path.insert(0,os.path.join(sys.argv[1],"agent-firm","lib"))
import evidence_seal as e
privacy=e._privacy_patterns(e.parse_json_unique(open(os.path.join(sys.argv[1],"agent-firm","policy","evidence-privacy.yaml"),"rb").read()))
run=tempfile.mkdtemp(); outside=tempfile.mkdtemp()
os.makedirs(run+"/09-test-evidence/post-judge/g1")
def put(rel,data):
    with open(os.path.join(run,rel),"wb") as h: h.write(data)
    os.chmod(os.path.join(run,rel),0o600); return data
sha="a"*40; seal_id="evt-seal"; projection="b"*64
good=put("09-test-evidence/post-judge/g1/a.md",b"answer\n")
open(outside+"/b.md","wb").write(b"outside the run\n")
os.symlink(outside,run+"/09-test-evidence/post-judge/g1/lnk")
leak=put("09-test-evidence/post-judge/g1/leak.md",b"see /"+b"Users/operator/x\n")
def row(eid,path,data,**extra):
    item={"ts":"2026-10-02T00:00:00Z","event":"post_judge_artifact_published","event_id":eid,"run_id":"r",
          "path":path,"sha256":hashlib.sha256(data).hexdigest(),"bytes":str(len(data)),"sha":sha,"generation":"1",
          "kind":"disposition_evidence","secondary_attempt_id":"gpt-c1-a0001","seal_event_id":seal_id,
          "seal_projection_sha256":projection}
    item.update(extra); return item
rows=[{"ts":"2026-10-02T00:00:00Z","event":"run_started","event_id":"evt-start","run_id":"r"},
      row("evt-pre","09-test-evidence/post-judge/g1/a.md",good),
      {"ts":"2026-10-02T00:00:00Z","event":"evidence_seal_published","event_id":seal_id,"run_id":"r"},
      row("evt-good","09-test-evidence/post-judge/g1/a.md",good),
      row("evt-link","09-test-evidence/post-judge/g1/lnk/b.md",b"outside the run\n"),
      row("evt-leak","09-test-evidence/post-judge/g1/leak.md",leak),
      row("evt-other-gen","09-test-evidence/post-judge/g1/a.md",good,generation="2"),
      row("evt-unbound","09-test-evidence/post-judge/g1/a.md",good,seal_event_id="evt-other-seal"),
      row("evt-outside","09-test-evidence/a.md",good)]
def ledger(items): return b"".join(json.dumps(i,separators=(",",":")).encode()+b"\n" for i in items)
def receipt(raw,count):
    return {"state":"sealed","generation":1,"candidate_sha":sha,"publication_event_id":seal_id,"projection_sha256":projection,
            "ledger_prefix":{"record_count":2},"verified_ledger":{"bytes":len(ledger(rows[:count])),
            "sha256":hashlib.sha256(ledger(rows[:count])).hexdigest(),"record_count":count}}
late=row("evt-late","09-test-evidence/post-judge/g1/a.md",good)
raw=ledger(rows+[late])
inputs,excluded,unresolved=e.post_judge_inputs(run,raw,receipt(raw,len(rows)),privacy)
assert [origin for origin,_,_ in inputs]==["09-test-evidence/post-judge/g1/a.md"],inputs
reasons={item["referenced_by"].split(":",1)[1]:item["reason"] for item in excluded}
assert reasons=={"evt-pre":"row_precedes_this_generations_seal_and_is_never_grammar_checked",
                 "evt-other-gen":"row_belongs_to_another_candidate_or_generation",
                 "evt-unbound":"row_is_not_bound_to_this_generations_seal",
                 "evt-outside":"artifact_is_outside_this_generations_post_judge_root",
                 "evt-late":"row_was_appended_after_the_seal_verification_this_input_is_bound_to"},reasons
unread={item["event_id"]:item["reason"] for item in unresolved}
assert unread["evt-link"]=="unreadable:ARTIFACT_SYMLINK",unread      # R3: a symlinked component is never followed
assert unread["evt-leak"].startswith("privacy:"),unread               # the seal's own scan
assert not any(b"outside the run" in data or b"/"+b"Users/" in data for _,data,_ in inputs)
# R2: a bound artifact whose bytes no longer match its event is tampering, and stops the judge input.
put("09-test-evidence/post-judge/g1/a.md",b"changed after verification\n")
try: e.post_judge_inputs(run,raw,receipt(raw,len(rows)),privacy)
except e.SealError as exc: assert exc.category=="POST_JUDGE_INPUT",exc.category
else: raise AssertionError("a digest mismatch did not stop the judge input")
put("09-test-evidence/post-judge/g1/a.md",good)
# The ledger must still hold exactly the bytes the verification covered.
tampered=raw.replace(b"evt-good",b"evt-gooX")
try: e.post_judge_inputs(run,tampered,receipt(raw,len(rows)),privacy)
except e.SealError as exc: assert exc.category=="POST_JUDGE_INPUT",exc.category
else: raise AssertionError("a ledger that differs from the verified bytes was accepted")
# An unsealed run carries no post-judge input at all.
inputs,excluded,_=e.post_judge_inputs(run,raw,{"state":"legacy_unsealed"},privacy)
assert not inputs and all(item["reason"].startswith("run_is_not_sealed") for item in excluded)
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

# THE CLOSED POST-JUDGE PHASE. After the seal the suffix admitted only reviewer events, so the Final
# check's own final_decision_required, the Lead's final_gate_pending, post-judge dispositions and
# their records, and a recapture all made `--verify --phase publication` fail. Each is now admitted
# only after a terminal reviewer event with no attempt open, bound to the seal's own identity, and
# every other event is still refused. Each case starts from one of two exact ledger snapshots.
PJ_EVENT="$TESTS_DIR/fixtures/post-judge-event.py"
# write_presealed_post_judge <run> <sha> — a make_sealable_run trace writer whose primary verdict
# declares an artifact under 09-test-evidence/post-judge/g1/ BEFORE the seal, so the seal holds a path
# inside the post-judge directory. A post-judge publication must still never name it.
write_presealed_post_judge() {
  mkdir -p "$1/09-test-evidence/post-judge/g1"
  printf 'declared before the seal\n' > "$1/09-test-evidence/post-judge/g1/sealed-before.md"
  chmod 600 "$1/09-test-evidence/post-judge/g1/sealed-before.md"
  printf '%s\n' '{"artifacts":["09-test-evidence/post-judge/g1/sealed-before.md"],"commands_run":[],"verdict":"APPROVE"}' \
    > "$1/08-qa-verdict.json"
}
t_case "the sealed suffix admits a closed post-judge phase and nothing else"
if ! ledger_writes_supported; then
  t_skip "closed post-judge suffix grammar" "requires a supported P2 ledger write host and no refused-row seam"
else
  pj_fixture="$(make_sealable_run claude "" write_presealed_post_judge real_qa_tools)"
  pj_run="$(printf '%s\n' "$pj_fixture" | sed -n '2p')"; pj_sha="$(printf '%s\n' "$pj_fixture" | sed -n '3p')"
  if [ -z "$pj_run" ] || ! seal_for_run "$pj_run" >/dev/null 2>&1; then
    _t_no "sealed post-judge fixture created" "fixture setup or seal failed"
  else
    _t_ok "sealed post-judge fixture created"
    pj_id="$(basename "$pj_run")"
    pj_seal_event="$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["ledger"]["publication"]["event_id"])' "$pj_run/09-test-evidence/final-evidence/g1/seal.json")"
    pj_projection="$(t_python -c 'import json,sys; print(json.load(open(sys.argv[1]))["self"]["projection_sha256"])' "$pj_run/09-test-evidence/final-evidence/g1/seal.json")"
    pj_sealed="$pj_run/.pj-sealed.jsonl"; cp "$pj_run/run.jsonl" "$pj_sealed"
    pj_judge_rc=0; env PATH=/usr/bin:/bin "$BIN/firm-gpt-qa" --run "$pj_run" >/dev/null 2>&1 || pj_judge_rc=$?
    assert_eq "the judge attempt is terminal (trusted unavailable)" 3 "$pj_judge_rc"
    pj_judged="$pj_run/.pj-judged.jsonl"; cp "$pj_run/run.jsonl" "$pj_judged"
    pj_attempt=gpt-c1-a0001
    pj_root=09-test-evidence/post-judge/g1
    pj_other=2222222222222222222222222222222222222222
    pj_zero64="$(printf '%064d' 0)"
    mkdir -p "$pj_run/$pj_root" "$pj_run/09-test-evidence/post-judge/g2"
    for pj_name in "$pj_root/two-voice-dispositions.1.json" "$pj_root/evidence.md" "$pj_root/human.yaml" \
                   "$pj_root/twice.json" 09-test-evidence/stray.json 09-test-evidence/post-judge/g2/x.json; do
      printf '%s\n' "post-judge fixture artifact $pj_name" > "$pj_run/$pj_name"; chmod 600 "$pj_run/$pj_name"
    done
    pj_restore() { cp "$1" "$pj_run/run.jsonl"; chmod 600 "$pj_run/run.jsonl"; }
    pj() { t_python "$PJ_EVENT" "$FIRM_ROOT" "$pj_run" "$@" >/dev/null; }
    pj_publish() { # <name under post-judge/g1> <kind> [override...] — primary QA's kinds in a fresh window
      local _pj_name="$1" _pj_kind="$2" _pj_window=@nowindow; shift 2
      case "$_pj_kind" in two_voice_dispositions|disposition_evidence) _pj_window=@window ;; esac
      pj post_judge_artifact_published "path=$pj_root/$_pj_name" "kind=$_pj_kind" "secondary_attempt_id=$pj_attempt" \
        "$_pj_window" "$@"
    }
    pj_checkout() {
      pj qa_checkout "dir=.agent-firm/qa-checkout/$pj_id" "branch=integration/$pj_id" \
        "source_ref=refs/heads/integration/$pj_id" "base_sha=$pj_sha" candidate=09-test-evidence/qa-candidate.json "$@"
    }
    pj_open() {
      "$BIN/firm-ledger-log" --run "$pj_run" --strict --event-id evt-pj-open reviewer_attempt_started \
        provider=gpt generation=1 "sha=$pj_sha" "attempt=$pj_open_rel" attempt_id=gpt-c1-a0900 \
        "seal_event_id=$pj_seal_event" "seal_projection_sha256=$pj_projection" >/dev/null
    }
    pj_expect() { # <accept|refuse> <label> [phase] [needle] [category] — a refusal must be the grammar's own
      local _pj_out _pj_rc _pj_needle="${4:-BLOCK LEDGER_SUFFIX}" _pj_category="${5:-LEDGER_SUFFIX}"
      _pj_out="$(seal_for_run "$pj_run" --verify --phase "${3:-publication}" 2>&1)"; _pj_rc=$?
      if [ "$1" = accept ]; then
        if [ "$_pj_rc" -eq 0 ]; then _t_ok "$2"; else _t_no "$2" "rc=$_pj_rc $(_t_ctx "$_pj_out")"; fi
      else
        case "$_pj_rc:$_pj_out" in
          0:*) _t_no "$2" "accepted" ;;
          *"BLOCK $_pj_category"*)
            case "$_pj_out" in
              *"$_pj_needle"*) _t_ok "$2"; [ -n "${PJ_TRACE:-}" ] && printf '         %s\n' "$(_t_ctx "$_pj_out")" ;;
              *) _t_no "$2" "refused without naming '$_pj_needle': $(_t_ctx "$_pj_out")" ;;
            esac ;;
          *) _t_no "$2" "refused for another reason: $(_t_ctx "$_pj_out")" ;;
        esac
      fi
    }

    # pj_bad <label> <needle> <category> <fn> [args...] — a bad post-judge row is refused TWICE. The
    # writer refuses it at append time, naming the cause, and the ledger does not change; and the same
    # row appended raw (bypassing the writer) is still refused by the verifier. PJ_PHASE picks the
    # verification phase (default publication). Runs from the current ledger state.
    pj_bad() {
      local _pj_label="$1" _pj_needle="$2" _pj_category="$3" _pj_fn="$4" _pj_snap _pj_out _pj_rc; shift 4
      _pj_snap="$pj_run/.pj-bad.jsonl"; cp "$pj_run/run.jsonl" "$_pj_snap"
      _pj_out="$("$_pj_fn" "$@" event_id=evt-pj-refused 2>&1)"; _pj_rc=$?
      case "$_pj_rc:$_pj_out" in
        0:*) _t_no "$_pj_label: the writer refuses it" "appended" ;;
        *"post-judge event refused, nothing appended"*"$_pj_needle"*)
          if grep -q '"event_id":"evt-pj-refused"' "$pj_run/run.jsonl"; then
            _t_no "$_pj_label: the writer refuses it" "the refused row is in the ledger"
          else _t_ok "$_pj_label: the writer refuses it"; fi ;;
        *) _t_no "$_pj_label: the writer refuses it" "refused for another reason: $(_t_ctx "$_pj_out")" ;;
      esac
      pj_restore "$_pj_snap"
      "$_pj_fn" "$@" @raw event_id=evt-pj-refused >/dev/null 2>&1
      pj_expect refuse "$_pj_label: the verifier refuses the same row appended raw" "${PJ_PHASE:-publication}" \
        "$_pj_needle" "$_pj_category"
    }

    # pj_bad_start <label> <needle> <stage> [role] [contract] — a role-mode start the sealed suffix
    # would refuse is refused by the writer (role mode's INPUT_INVALID, exit 2, nothing appended),
    # and the same native start appended raw is refused by the verifier.
    pj_bad_start() {
      local _pj_label="$1" _pj_needle="$2" _pj_stage="$3" _pj_role="${4:-qa-tester}" _pj_contract="${5:-role-contracts/Q-01-qa-tester.md}"
      local _pj_snap="$pj_run/.pj-bad-start.jsonl" _pj_out _pj_rc
      cp "$pj_run/run.jsonl" "$_pj_snap"
      _pj_out="$(qa_window_open "$pj_run" "$_pj_stage" "$_pj_role" "$_pj_contract" 2>&1)"; _pj_rc=$?
      case "$_pj_out" in
        *"role start refused, nothing appended"*"$_pj_needle"*"INPUT_INVALID: sealed-suffix"*)
          if cmp -s "$_pj_snap" "$pj_run/run.jsonl"; then _t_ok "$_pj_label: the writer refuses the role start"
          else _t_no "$_pj_label: the writer refuses the role start" "the ledger changed"; fi ;;
        *) _t_no "$_pj_label: the writer refuses the role start" "rc=$_pj_rc $(_t_ctx "$_pj_out")" ;;
      esac
      pj_restore "$_pj_snap"
      t_python - "$pj_run" "$pj_sealed" "$_pj_stage" "$_pj_role" \
        "$("$BIN/firm-model-resolve" --provider codex --role "$_pj_role" --format activation)" <<'PY'
import json,sys
run,sealed,stage,role,activation=sys.argv[1:]
native=[r for r in map(json.loads,open(sealed)) if r.get("event")=="qa_started"][0]
row=dict(native,event_id="evt-pj-raw-start",stage=stage,role=role,ts="2026-10-04T00:00:00Z",
         activation=json.loads(activation))
with open(run+"/run.jsonl","a") as fh: fh.write(json.dumps(row,separators=(",",":"))+"\n")
PY
      pj_expect refuse "$_pj_label: the verifier refuses the same native start appended raw" \
        "${PJ_PHASE:-publication}" "$_pj_needle"
    }

    # Accepted after a terminal judge event, one at a time and then all together.
    pj_restore "$pj_judged"; pj final_decision_required
    pj_expect accept "final_decision_required is accepted after the judge"
    pj_restore "$pj_judged"; pj final_gate_pending
    pj_expect accept "final_gate_pending is accepted after the judge"
    for pj_kind in two_voice_dispositions:two-voice-dispositions.1.json disposition_evidence:evidence.md; do
      pj_restore "$pj_judged"; pj_publish "${pj_kind#*:}" "${pj_kind%%:*}"
      pj_expect accept "a ${pj_kind%%:*} post-judge artifact is accepted after the judge"
    done
    # A human decision answers an earlier final_decision_required made for the same attempt.
    pj_restore "$pj_judged"; pj final_decision_required event_id=evt-pj-decision
    pj_publish human.yaml human_decision decision_required_event_id=evt-pj-decision
    pj_expect accept "a human_decision answering an earlier decision for its attempt is accepted after the judge"
    pj_restore "$pj_judged"
    pj_publish two-voice-dispositions.1.json two_voice_dispositions; pj final_decision_required event_id=evt-pj-decision
    pj final_gate_pending; pj_publish human.yaml human_decision decision_required_event_id=evt-pj-decision
    pj_publish evidence.md disposition_evidence
    pj_expect accept "the whole post-judge phase is accepted in sequence"
    pj_expect accept "…and by the wrapper's preflight" wrapper-preflight
    # Interleavable with a further reviewer attempt, and closed while that attempt is open.
    pj_open_rel=09-test-evidence/reviewer-attempts/gpt-c1-a0900/attempt.json
    mkdir -p "$pj_run/$(dirname "$pj_open_rel")"
    t_python - "$pj_run/$pj_open_rel" "$pj_id" "$pj_sha" <<'PY'
import json,os,sys
path,run_id,sha=sys.argv[1:]
json.dump({"schema_version":1,"attempt_id":"gpt-c1-a0900","provider":"gpt","run_id":run_id,"candidate_sha":sha,
           "generation":1,"status":"started","exit_code":None,"started_event_id":"evt-pj-open",
           "outcome_event_id":None},open(path,"w"),separators=(",",":"))
os.chmod(path,0o600)
PY
    pj_open
    pj_expect accept "a further reviewer START after the post-judge phase stays recoverable" wrapper-preflight
    PJ_PHASE=wrapper-preflight pj_bad "a post-judge event while an attempt is open is refused" \
      "needs a terminal reviewer attempt and no open attempt" LEDGER_SUFFIX pj final_gate_pending
    pj_restore "$pj_judged"; pj_open
    pj_expect accept "control: the same open START alone is recoverable" wrapper-preflight

    # No qa_checkout belongs to a suffix that is still being verified. firm-qa-checkout rewrites the
    # candidate before it appends the event, so a real recapture is verified against the NEXT
    # generation's seal, in whose prefix the event lies. Letting one end the suffix meant a single
    # forged event switched off checking of everything after it.
    pj_restore "$pj_judged"; pj_bad "a later-generation qa_checkout inside the verified suffix is refused" \
      "unexpected event qa_checkout" LEDGER_SUFFIX pj_checkout "sha=$pj_sha" generation=2
    pj_restore "$pj_judged"; pj_checkout "sha=$pj_sha" generation=2 @raw; pj lead_note note=anything-after-it @raw
    pj_expect refuse "a forged qa_checkout does not switch off checking of what follows it" publication \
      "unexpected event qa_checkout"
    pj_restore "$pj_judged"; pj_bad "a same-generation qa_checkout inside the verified suffix is refused" \
      "unexpected event qa_checkout" LEDGER_SUFFIX pj_checkout "sha=$pj_sha" generation=1

    # Refused before any terminal judge event.
    pj_restore "$pj_sealed"; pj_bad "final_decision_required before the judge is refused" \
      "needs a terminal reviewer attempt" LEDGER_SUFFIX pj final_decision_required
    pj_restore "$pj_sealed"; pj_bad "final_gate_pending before the judge is refused" \
      "needs a terminal reviewer attempt" LEDGER_SUFFIX pj final_gate_pending
    pj_restore "$pj_sealed"; pj_bad "a post-judge artifact before the judge is refused" \
      "needs a terminal reviewer attempt" LEDGER_SUFFIX \
      pj_publish human.yaml human_decision decision_required_event_id=evt-pj-before-judge

    # Refused with the wrong identity, shape, place, or bytes.
    for pj_spec in "sha=$pj_other:candidate/generation mismatch" "generation=2:candidate/generation mismatch" \
                   "kind=bogus:field set is not closed" "note=extra:field set is not closed" \
                   "path=09-test-evidence/decision-elsewhere.json:does not name its own decision state"; do
      pj_restore "$pj_judged"; pj_bad "final_decision_required with ${pj_spec%%:*} is refused" "${pj_spec#*:}" \
        LEDGER_SUFFIX pj final_decision_required "${pj_spec%%:*}"
    done
    pj_restore "$pj_judged"; pj final_decision_required @tamper
    pj_expect refuse "final_decision_required whose state changed after it was recorded is refused"
    for pj_spec in "sha=$pj_other:candidate/generation mismatch" "generation=2:candidate/generation mismatch" \
                   "note=extra:field set is not closed"; do
      pj_restore "$pj_judged"; pj_bad "final_gate_pending with ${pj_spec%%:*} is refused" "${pj_spec#*:}" \
        LEDGER_SUFFIX pj final_gate_pending "${pj_spec%%:*}"
    done
    for pj_spec in "path=09-test-evidence/stray.json:is outside" "path=09-test-evidence/post-judge/g2/x.json:is outside" \
                   "path=08-qa-verdict.json:is outside" "sha256=$pj_zero64:digest/size mismatch" \
                   "seal_event_id=evt-another-seal:seal identity mismatch" \
                   "seal_projection_sha256=$pj_zero64:seal identity mismatch" \
                   "secondary_attempt_id=gpt-c1-a9999:does not name a terminal attempt" \
                   "secondary_attempt_id=gpt-c1-a0900:does not name a terminal attempt" \
                   "kind=bogus:field set is not closed" "sha=$pj_other:candidate/generation mismatch" \
                   "generation=2:candidate/generation mismatch" "note=extra:field set is not closed" \
                   "-secondary_attempt_id:field set is not closed"; do
      pj_restore "$pj_judged"; pj_bad "a post-judge artifact with ${pj_spec%%:*} is refused" "${pj_spec#*:}" \
        LEDGER_SUFFIX pj_publish evidence.md disposition_evidence "${pj_spec%%:*}"
    done
    pj_restore "$pj_judged"; pj_publish evidence.md disposition_evidence @tamper
    pj_expect refuse "a post-judge artifact changed after it was published is refused"
    pj_restore "$pj_judged"; pj_publish twice.json disposition_evidence
    pj_bad "one post-judge path published twice is refused" "published twice" LEDGER_SUFFIX \
      pj_publish twice.json disposition_evidence
    assert_output "the fixture's seal holds a path inside the post-judge directory" \
      '"path":"09-test-evidence/post-judge/g1/sealed-before.md"' cat "$pj_run/09-test-evidence/final-evidence/g1/seal.json"
    pj_restore "$pj_judged"; pj_bad "a post-judge publication of a sealed path inside the post-judge directory is refused" \
      "post-judge artifact names a sealed path" LEDGER_SUFFIX pj_publish sealed-before.md disposition_evidence

    # PRIMARY QA'S OWN KINDS CARRY A PRODUCER IDENTITY: a native qa-tester window opened after the
    # attempt they answer, with the publication inside it. Without one, anybody who could append to
    # the ledger could dispose of a judge objection.
    for pj_kind in two_voice_dispositions:two-voice-dispositions.1.json disposition_evidence:evidence.md; do
      pj_restore "$pj_judged"; pj_bad "a ${pj_kind%%:*} publication with no primary-QA window is refused" \
        "post_judge_artifact_published field set is not closed" LEDGER_SUFFIX \
        pj_publish "${pj_kind#*:}" "${pj_kind%%:*}" @nowindow
      pj_restore "$pj_judged"; pj_bad "a ${pj_kind%%:*} publication naming a window that does not exist is refused" \
        "is not published inside a qa-tester window" LEDGER_SUFFIX \
        pj_publish "${pj_kind#*:}" "${pj_kind%%:*}" @nowindow stage=test/forged role=qa-tester role_start_event_id=evt-no-such-window
    done
    pj_restore "$pj_judged"; pj_bad "a Lead-published human_decision carries no QA window fields" \
      "post_judge_artifact_published field set is not closed" LEDGER_SUFFIX pj_publish human.yaml human_decision @window
    pj_q01="$(t_python -c 'import json,sys; print([r for r in map(json.loads,open(sys.argv[1])) if r.get("event")=="qa_started"][0]["event_id"])' "$pj_sealed")"
    pj_restore "$pj_judged"; pj_bad "the pre-seal QA window cannot produce a post-judge artifact" \
      "is not published inside a qa-tester window" LEDGER_SUFFIX \
      pj_publish evidence.md disposition_evidence @nowindow stage=test/Q-01 role=qa-tester "role_start_event_id=$pj_q01"
    pj_restore "$pj_judged"; pj_w="$(qa_window_open "$pj_run" test/pj-closed)"; qa_window_close "$pj_run" test/pj-closed "$pj_w"
    pj_bad "a publication after its window closed is refused" "is not published inside a qa-tester window" LEDGER_SUFFIX \
      pj_publish evidence.md disposition_evidence @nowindow stage=test/pj-closed role=qa-tester "role_start_event_id=$pj_w"
    # At append time a window is legitimately still open; it must be closed by the time anything verifies.
    pj_restore "$pj_judged"; pj_w="$(qa_window_open "$pj_run" test/pj-unclosed)"
    assert_ok "the writer accepts a publication inside a window that is still open" \
      pj_publish evidence.md disposition_evidence @nowindow stage=test/pj-unclosed role=qa-tester "role_start_event_id=$pj_w"
    assert_ok "…and a second publication inside the same open window" \
      pj_publish human.yaml disposition_evidence @nowindow stage=test/pj-unclosed role=qa-tester "role_start_event_id=$pj_w"
    pj_expect refuse "a publication in a window that never closes is refused when verified" publication "role window"
    qa_window_close "$pj_run" test/pj-unclosed "$pj_w"
    pj_expect accept "…and verifies once its window closes"
    pj_restore "$pj_judged"; pj_bad "a qa_started that is not a native role start opens no window" \
      "post-judge qa_started is not a native role start" LEDGER_SUFFIX pj qa_started stage=test/pj-forged role=qa-tester
    pj_restore "$pj_judged"; pj_bad_start "a post-judge role window for any role but qa-tester is refused" \
      "post-judge role windows are qa-tester only" test/pj-packager packager role-contracts/P-01-packager.md
    pj_restore "$pj_judged"; pj_bad "a qa_completed that closes no post-judge window is refused" \
      "does not close an open primary-QA window" LEDGER_SUFFIX \
      pj qa_completed stage=test/pj-none role=qa-tester role_start_event_id=evt-no-such-window
    pj_restore "$pj_sealed"; pj_bad_start "a QA window opened before any terminal attempt is refused" \
      "qa_started needs a terminal reviewer attempt" test/pj-early
    # Scenario E: primary QA opens its post-judge window while a further judge attempt is still open.
    # The role start used to land with rc 0 and every later verification and post-judge append failed.
    pj_restore "$pj_judged"; pj_open
    PJ_PHASE=wrapper-preflight pj_bad_start "a QA window opened while a judge attempt is open is refused" \
      "qa_started needs a terminal reviewer attempt and no open attempt" test/pj-during-attempt
    pj_restore "$pj_judged"; pj_open
    qa_window_open "$pj_run" test/pj-during-attempt >/dev/null 2>&1
    pj_expect accept "…and the run it was refused in still verifies" wrapper-preflight

    # EACH RECORD ANSWERS ONE ATTEMPT. A decision state names the attempt it is about, and a human
    # decision names the decision it answers, so neither can be replayed against another attempt.
    for pj_spec in state_attempt=@none state_attempt=gpt-c1-a9999; do
      pj_restore "$pj_judged"; pj_bad "final_decision_required whose state has ${pj_spec} is refused" \
        "final_decision_required state does not name a terminal attempt" LEDGER_SUFFIX \
        pj final_decision_required "$pj_spec"
    done
    pj_restore "$pj_judged"; pj_bad "a human_decision that names no decision is refused" \
      "post_judge_artifact_published field set is not closed" LEDGER_SUFFIX pj_publish human.yaml human_decision
    pj_restore "$pj_judged"; pj_bad "a human_decision naming a decision that does not exist is refused" \
      "does not answer an earlier final_decision_required" LEDGER_SUFFIX \
      pj_publish human.yaml human_decision decision_required_event_id=evt-no-such-decision
    pj_restore "$pj_judged"; pj_bad "a human_decision recorded before its decision is refused" \
      "does not answer an earlier final_decision_required" LEDGER_SUFFIX \
      pj_publish human.yaml human_decision decision_required_event_id=evt-pj-late
    pj_restore "$pj_judged"; pj_publish human.yaml human_decision decision_required_event_id=evt-pj-late @raw
    pj final_decision_required event_id=evt-pj-late @raw
    pj_expect refuse "…and a decision appended after it does not repair it" publication \
      "does not answer an earlier final_decision_required"
    pj_restore "$pj_judged"; pj final_decision_required event_id=evt-pj-unavailable kind=required_secondary_unavailable
    pj_bad "a human_decision cannot answer a required-unavailable decision" \
      "does not answer an earlier final_decision_required" LEDGER_SUFFIX \
      pj_publish human.yaml human_decision decision_required_event_id=evt-pj-unavailable

    # POST-JUDGE BYTES MEET THE SEAL'S PRIVACY POLICY. They are never sealed, so the verifier scans
    # them itself with the same deny categories. The leaks are assembled at run time so this file's own
    # source carries none of them.
    pj_leak_assignment="$(printf '%s%s=%s' pass word Leaked-value-1234)"
    pj_leak_home="$(printf '/%s/operator/.ssh/id_ed25519' Users)"
    printf 'primary QA notes: %s\n' "$pj_leak_assignment" > "$pj_run/$pj_root/leak-secret.md"
    printf 'see %s\n' "$pj_leak_home" > "$pj_run/$pj_root/leak-home.md"
    chmod 600 "$pj_run/$pj_root/leak-secret.md" "$pj_run/$pj_root/leak-home.md"
    pj_restore "$pj_judged"; pj_bad "a post-judge artifact carrying a secret assignment is refused" \
      "secret_assignment" PRIVACY_MATCH pj_publish leak-secret.md disposition_evidence
    pj_restore "$pj_judged"; pj_bad "a post-judge artifact carrying an operator home path is refused" \
      "operator_home" PRIVACY_MATCH pj_publish leak-home.md two_voice_dispositions
    pj_restore "$pj_judged"; pj_bad "a decision state carrying a secret assignment is refused" \
      "secret_assignment" PRIVACY_MATCH pj final_decision_required "state_objection=$pj_leak_assignment"

    # Everything outside the closed set is still refused after the judge.
    pj_restore "$pj_judged"; pj_bad "an ordinary lead_note after the judge is refused" \
      "unexpected event lead_note" LEDGER_SUFFIX pj lead_note note=after-the-judge
    pj_restore "$pj_judged"; pj_bad "an unsealed-style human_decision_recorded event is refused after the seal" \
      "unexpected event human_decision_recorded" LEDGER_SUFFIX \
      pj human_decision_recorded "path=$pj_root/human.yaml" "sha=$pj_sha" generation=1
    pj_restore "$pj_sealed"; pj_bad "an ordinary event right after the seal is refused" \
      "unexpected event lead_note" LEDGER_SUFFIX pj lead_note note=before-the-judge
    # Reviewer events stay with the wrapper: the writer does not judge them, the verifier does.
    pj_restore "$pj_judged"
    assert_ok "the writer leaves reviewer events to the wrapper" "$BIN/firm-ledger-log" --run "$pj_run" --strict \
      reviewer_invalid provider=gpt generation=1 "sha=$pj_sha" note=not-a-wrapper-row
    pj_expect refuse "…and the verifier still refuses a malformed one" publication "reviewer seal identity mismatch"
    pj_restore "$pj_judged"
    pj_expect accept "the judged snapshot itself still verifies"

    # A window answers only attempts that were terminal when it opened. Open one, let a second judge
    # attempt finish (a0002, trusted unavailable), then publish inside the window: answering a0001 is
    # accepted, answering a0002 is not.
    pj_restore "$pj_judged"; pj_w="$(qa_window_open "$pj_run" test/pj-straddle)"
    pj_judge_rc=0; env PATH=/usr/bin:/bin "$BIN/firm-gpt-qa" --run "$pj_run" >/dev/null 2>&1 || pj_judge_rc=$?
    assert_eq "a second judge attempt runs while a QA window is open" 3 "$pj_judge_rc"
    pj_straddle="$pj_run/.pj-straddle.jsonl"; cp "$pj_run/run.jsonl" "$pj_straddle"
    pj_publish evidence.md disposition_evidence @nowindow stage=test/pj-straddle role=qa-tester "role_start_event_id=$pj_w"
    qa_window_close "$pj_run" test/pj-straddle "$pj_w"
    pj_expect accept "control: the window answers the attempt that was terminal when it opened"
    pj_restore "$pj_straddle"; pj_bad "a window opened before the attempt it answers is refused" \
      "window opened after the attempt it answers" LEDGER_SUFFIX \
      pj_publish evidence.md disposition_evidence @nowindow stage=test/pj-straddle role=qa-tester \
      "role_start_event_id=$pj_w" secondary_attempt_id=gpt-c1-a0002
    pj_restore "$pj_straddle"; pj final_decision_required event_id=evt-pj-a0001 state_attempt=gpt-c1-a0001
    pj_bad "a human_decision for one attempt cannot answer a decision made for another" \
      "does not answer an earlier final_decision_required for its attempt" LEDGER_SUFFIX \
      pj_publish human.yaml human_decision decision_required_event_id=evt-pj-a0001 secondary_attempt_id=gpt-c1-a0002
    pj_restore "$pj_straddle"; pj final_decision_required event_id=evt-pj-a0001 state_attempt=gpt-c1-a0001
    pj_publish human.yaml human_decision decision_required_event_id=evt-pj-a0001 secondary_attempt_id=gpt-c1-a0001
    pj_expect accept "control: the same record answering its own attempt's decision is accepted"
  fi
fi

# write_final_ready_run <run> <sha> — a make_sealable_run trace writer whose sealed primary evidence
# satisfies every firm-final-qa-check precondition: one functional criterion, a schema-valid primary
# APPROVE, strict traceability with one digest-bound evidence row, and an available, not-required GPT
# secondary with no dispositions (they cannot exist yet: traceability.yaml is sealed before the judge).
write_final_ready_run() {
  local _fr_run="$1" _fr_sha="$2"
  printf 'final-ready proof\n' > "$_fr_run/09-test-evidence/proof.log"; chmod 600 "$_fr_run/09-test-evidence/proof.log"
  "$BIN/firm-ledger-log" --run "$_fr_run" --strict --event-id evt-final-ready-proof evidence_captured \
    path=09-test-evidence/proof.log "sha=$_fr_sha" generation=1 \
    "sha256=$(shasum -a 256 "$_fr_run/09-test-evidence/proof.log" | awk '{print $1}')" \
    "bytes=$(wc -c < "$_fr_run/09-test-evidence/proof.log" | tr -d ' ')" >/dev/null || return 1
  t_python - "$_fr_run" "$_fr_sha" <<'PY'
import hashlib,json,os,sys,yaml
run,sha=sys.argv[1:]; rid=os.path.basename(run)
c=json.load(open(run+"/09-test-evidence/qa-candidate.json")); gen=c["generation"]
raw=open(run+"/09-test-evidence/proof.log","rb").read()
proof={"path":"09-test-evidence/proof.log","candidate_sha":sha,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw),
       "producer":{"event_id":"evt-final-ready-proof","event":"evidence_captured"}}
yaml.safe_dump({"task_slug":"seal-fixture","track":"full_track","criteria":[{"id":"AC-001","type":"functional",
                "statement":"fixture","verification":"automated_test"}],"explicitly_out_of_scope":[]},
               open(run+"/01-acceptance-criteria.yaml","w"),sort_keys=False)
verdict={"verdict":"APPROVE","commit_sha":sha,"run_id":rid,"generation":gen,"provider":"primary","attempt_id":"primary-fixture",
         "environment":"fixture","commands_run":[],"unit":{"status":"pass","evidence":"09-test-evidence/proof.log"},
         "integration":{"status":"not_applicable","evidence":"none"},"e2e":{"status":"not_applicable","evidence":"none"},
         "visual":{"status":"not_applicable","evidence":"none"},
         "acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"09-test-evidence/proof.log"}],
         "untested_risks":[],"blockers":[],"warnings":[],"artifacts":["09-test-evidence/proof.log"],"summary":"fixture"}
json.dump(verdict,open(run+"/08-qa-verdict.json","w"),indent=2)
rel=lambda path: os.path.relpath(path,c["repository_root"])
trace={"schema_version":2,"task_slug":"seal-fixture",
       "candidate":{"run_id":rid,"repository_root":".","git_common_dir":rel(c["git_common_dir"]),
                    "checkout_path":rel(c["checkout_path"]),"source_ref":c["source_ref"],"source_ref_sha":c["source_ref_sha"],
                    "base_sha":c["base_sha"],"commit_sha":sha,"generation":gen},
       "matrix":[{"id":"AC-001","implementation_files":["seed.txt"],"tests":["fixture"],"manual_verification":"",
                  "evidence":[proof],"status":"covered"}],
       "two_voice":{"secondary_provider":"gpt","status":"available","required":False},"two_voice_diff":[]}
yaml.safe_dump(trace,open(run+"/traceability.yaml","w"),sort_keys=False)
PY
}

# THE POST-JUDGE PATH, END TO END. A sealed run, a real wrapper BLOCK from a stub provider, primary
# QA's post-judge dispositions, a Final check that returns decision_required and records it, the
# Lead's final_gate_pending, a recorded human decision cited from re-published dispositions, and a
# fresh check that passes -- with the seal verifying at every step. Before this change the run was
# terminal at the BLOCK: traceability.yaml is sealed before the judge, so the objection could never
# be disposed, and every post-judge event made the seal verification the Final check runs fail.
t_case "a sealed run proceeds past a judge BLOCK to decision_required and a recorded human decision"
if ! ledger_writes_supported; then
  t_skip "post-judge Final path on a sealed run" "requires a supported P2 ledger write host and no refused-row seam"
else
  fr_fixture="$(make_sealable_run claude "" write_final_ready_run real_qa_tools)"
  fr_run="$(printf '%s\n' "$fr_fixture" | sed -n '2p')"; fr_sha="$(printf '%s\n' "$fr_fixture" | sed -n '3p')"
  if [ -z "$fr_run" ] || ! seal_for_run "$fr_run" >/dev/null 2>&1; then
    _t_no "sealed final-ready fixture created" "fixture setup or seal failed"
  else
    _t_ok "sealed final-ready fixture created"
    fr_id="$(basename "$fr_run")"; fr_root=09-test-evidence/post-judge/g1
    fr_stub="$(mktemp -d "${TMPDIR:-/tmp}/firm-post-judge-stub.XXXXXX")"; t_track "$fr_stub"
    mkdir -p "$fr_stub/bin" "$fr_stub/codex-home"
    fr_text="the post-judge fixture objection is not answered by the sealed evidence"
    t_python - "$fr_stub/block.json" "$fr_id" "$fr_sha" "$fr_text" <<'PY'
import json,sys
path,rid,sha,text=sys.argv[1:]
json.dump({"verdict":"BLOCK","commit_sha":sha,"run_id":rid,"generation":1,"provider":"gpt","attempt_id":"__ATTEMPT__",
           "environment":"stub","commands_run":[],"unit":{"status":"pass","evidence":"09-test-evidence/proof.log"},
           "integration":{"status":"not_applicable","evidence":"none"},"e2e":{"status":"not_applicable","evidence":"none"},
           "visual":{"status":"not_applicable","evidence":"none"},
           "acceptance_criteria_coverage":[{"id":"AC-001","covered":"partial","evidence":"09-test-evidence/proof.log"}],
           "untested_risks":[],"blockers":[text],
           "blocker_objects":[{"id":"obj-post-judge-fixture","text":text,"affected_criteria":["AC-001"],"affected_paths":[]}],
           "warnings":[],"artifacts":[],"summary":"stub judge BLOCK"},open(path,"w"))
PY
    # A provider stub that answers exactly the surfaces the wrapper probes and returns the BLOCK.
    cat > "$fr_stub/bin/codex" <<'SH'
#!/bin/sh
case "$*" in
  "exec --help") echo '  --skip-git-repo-check --ignore-user-config --ignore-rules --strict-config --ephemeral  -s, --sandbox   -m, --model   -c, --config   --output-schema  -o, --output-last-message'; exit 0 ;;
  "doctor --json") printf '{"schemaVersion":1,"overallStatus":"ok","checks":{"auth.credentials":{"id":"auth.credentials","category":"auth","status":"ok","summary":"auth is configured"}}}\n'; exit 0 ;;
  "debug models") printf '{"models":[{"slug":"%s","display_name":"Stub"}]}\n' "$STUB_MODEL"; exit 0 ;;
esac
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && { shift; out="$1"; }; shift; done
# Keep the controlled input manifest this judge was handed, and the whole controlled snapshot, so the
# suite can inspect exactly what crossed into the judge.
if [ -n "${STUB_KEEP:-}" ]; then
  cp "$FIRM_QA_INPUT_MANIFEST" "$STUB_KEEP/manifest-$FIRM_QA_ATTEMPT_ID.json"
  cp -R "$(dirname "$FIRM_QA_INPUT_MANIFEST")" "$STUB_KEEP/snapshot-$FIRM_QA_ATTEMPT_ID"
  chmod -R u+w "$STUB_KEEP/snapshot-$FIRM_QA_ATTEMPT_ID"
fi
sed "s/__ATTEMPT__/$FIRM_QA_ATTEMPT_ID/" "$STUB_VERDICT" > "$out"
SH
    chmod +x "$fr_stub/bin/codex"; mkdir -p "$fr_stub/manifests"
    fr_model="$("$BIN/firm-model-resolve" --provider codex --role reviewer --format json | t_python -c 'import json,sys; print(json.load(sys.stdin)["model"])')"
    fr_judge() {
      env PATH="$fr_stub/bin:/usr/bin:/bin" STUB_MODEL="$fr_model" STUB_VERDICT="$fr_stub/block.json" \
        STUB_KEEP="$fr_stub/manifests" \
        CODEX_HOME="$fr_stub/codex-home" FIRM_GPT_QA_DISCOVERY_TIMEOUT=20 FIRM_GPT_QA_READINESS_TIMEOUT=20 \
        FIRM_GPT_QA_TIMEOUT=60 "$BIN/firm-gpt-qa" --run "$fr_run" >/dev/null 2>&1
    }
    fr_check() { # <expected rc> <label> [needle] — one fresh Final check
      local _fr_out _fr_rc
      _fr_out="$("$BIN/firm-final-qa-check" "$fr_run" 2>&1)"; _fr_rc=$?
      if [ "$_fr_rc" -ne "$1" ]; then _t_no "$2" "expected rc=$1 got rc=$_fr_rc $(_t_ctx "$_fr_out")"
      elif [ -n "${3:-}" ]; then
        case "$_fr_out" in *"$3"*) _t_ok "$2";; *) _t_no "$2" "missing '$3' in: $(_t_ctx "$_fr_out")";; esac
      else _t_ok "$2"; fi
    }
    fr_event() { t_python "$PJ_EVENT" "$FIRM_ROOT" "$fr_run" "$@"; }
    fr_publish() { # <name under post-judge/g1> <kind> <attempt> [override...] — prints the producer event id
      local _fr_name="$1" _fr_kind="$2" _fr_attempt="$3" _fr_window=@nowindow; shift 3
      # Primary QA's own kinds are produced inside a fresh native qa-tester window.
      case "$_fr_kind" in two_voice_dispositions|disposition_evidence) _fr_window=@window ;; esac
      fr_event post_judge_artifact_published "path=$fr_root/$_fr_name" "kind=$_fr_kind" \
        "secondary_attempt_id=$_fr_attempt" "$_fr_window" "$@"
    }
    # fr_dispositions <name> <attempt> [digest=current|wrong|wrong-bytes] [evidence=<event>]
    #   [record=<event>] [disposition=human_decision|proceed_with_primary] [bounded=<event>] [rounds=N]
    # — write one two-voice-dispositions document whose entries have exactly the traceability
    # disposition shape.
    fr_dispositions() {
      t_python - "$fr_run" "$@" <<'PY'
import hashlib,json,os,sys
run,name,attempt=sys.argv[1:4]; options=dict(item.split("=",1) for item in sys.argv[4:])
digest_mode=options.get("digest","current"); evidence_id=options["evidence"]; record_id=options.get("record","")
disposition=options.get("disposition","human_decision")
c=json.load(open(run+"/09-test-evidence/qa-candidate.json")); sha=c["candidate_sha"]; gen=c["generation"]
canonical=json.load(open(run+"/08-qa-verdict.gpt.json"))
local=open(f"{run}/09-test-evidence/reviewer-attempts/{canonical['attempt_id']}/verdict.json","rb").read()
events={row["event_id"]:row for row in map(json.loads,open(run+"/run.jsonl")) if "event_id" in row}
def ref(event_id):
    event=events[event_id]; raw=open(run+"/"+event["path"],"rb").read()
    return {"path":event["path"],"candidate_sha":sha,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw),
            "producer":{"event_id":event_id,"event":event["event"]}}
entries=[]
for objection in canonical["blocker_objects"]:
    entry={"secondary_blocker_id":objection["id"],"secondary_blocker":objection["text"],
           "primary_position":"primary QA reads the sealed evidence differently and asks for a human decision",
           "positive_dissent":True,"affected_criteria":objection["affected_criteria"],
           "affected_paths":objection["affected_paths"],"risk":"low","risk_reasons":["criterion:AC-001:functional"],
           "bounded_resolution":{"attempted":False,"rounds":0,"rerun":"not_run","evidence":None},
           "evidence":ref(evidence_id),"disposition":disposition}
    if "bounded" in options:
        entry["bounded_resolution"]={"attempted":True,"rounds":int(options.get("rounds","1")),"rerun":"block",
                                     "evidence":ref(options["bounded"])}
    if record_id: entry["record"]=ref(record_id)
    entries.append(entry)
doc={"schema_version":1,"run_id":os.path.basename(run),"candidate_sha":sha,"generation":gen,
     "secondary_attempt_id":attempt,
     "secondary_verdict_sha256":hashlib.sha256(local).hexdigest() if digest_mode!="wrong" else "0"*64,
     "secondary_verdict_bytes":len(local)+(1 if digest_mode=="wrong-bytes" else 0),"two_voice_diff":entries}
path=f"{run}/09-test-evidence/post-judge/g{gen}/{name}"
os.makedirs(os.path.dirname(path),exist_ok=True)
open(path,"w").write(json.dumps(doc,indent=2,sort_keys=True)+"\n"); os.chmod(path,0o600)
PY
    }
    fr_decisions() { find "$fr_run/09-test-evidence" -maxdepth 1 -name 'final-decision-required.*.json' | wc -l | tr -d ' '; }
    fr_last_decision() {
      t_python -c 'import json,sys; print([r for r in map(json.loads,open(sys.argv[1])) if r.get("event")=="final_decision_required"][-1]["event_id"])' "$fr_run/run.jsonl"
    }

    # One trusted-unavailable attempt (a0001), then the real wrapper's BLOCK (a0002).
    fr_rc=0; env PATH=/usr/bin:/bin CODEX_HOME="$fr_stub/codex-home" "$BIN/firm-gpt-qa" --run "$fr_run" >/dev/null 2>&1 || fr_rc=$?
    assert_eq "a first judge attempt is trusted unavailable" 3 "$fr_rc"
    fr_rc=0; fr_judge || fr_rc=$?
    assert_eq "the real wrapper returns the stub judge's BLOCK" 1 "$fr_rc"
    assert_output "the BLOCK is the current canonical secondary verdict" '"attempt_id": "gpt-c1-a0002"' \
      cat "$fr_run/09-test-evidence/reviewer-state.gpt.json"
    fr_check 1 "with no dispositions the BLOCK still blocks (silence is not dissent)" \
      "exactly one entry per producer objection id"

    # THE REVIEWER'S EXPLOIT, kept as a regression: one forged qa_checkout(generation=2), with the
    # candidate still at generation 1, followed by a reviewer_approve no wrapper produced (no START,
    # no seal binding) and its forged attempt/verdict files. When a qa_checkout ended the suffix this
    # passed the seal and firm-final-qa-check returned 0.
    fr_snap="$fr_stub/before-exploit"; mkdir -p "$fr_snap"
    cp -p "$fr_run/run.jsonl" "$fr_run/08-qa-verdict.gpt.json" "$fr_run/09-test-evidence/reviewer-state.gpt.json" "$fr_snap/"
    # The writer now refuses the forged qa_checkout outright (the live candidate is still generation 1)...
    assert_fail "the writer refuses a qa_checkout that would land inside the sealed suffix" \
      "$BIN/firm-ledger-log" --run "$fr_run" --strict qa_checkout "dir=.agent-firm/qa-checkout/$fr_id" \
      "branch=integration/$fr_id" "source_ref=refs/heads/integration/$fr_id" "base_sha=$fr_sha" \
      "sha=$fr_sha" generation=2 candidate=09-test-evidence/qa-candidate.json
    # ...so the exploit's row is appended raw, as by any other route, to keep the verifier honest.
    t_python "$PJ_EVENT" "$FIRM_ROOT" "$fr_run" qa_checkout "dir=.agent-firm/qa-checkout/$fr_id" \
      "branch=integration/$fr_id" "source_ref=refs/heads/integration/$fr_id" "base_sha=$fr_sha" \
      "sha=$fr_sha" generation=2 candidate=09-test-evidence/qa-candidate.json @raw >/dev/null
    fr_forged="$(t_python - "$fr_run" "$fr_id" "$fr_sha" <<'PY'
import hashlib,json,os,sys
run,rid,sha=sys.argv[1:]
aid="gpt-c1-a0099"; d=f"{run}/09-test-evidence/reviewer-attempts/{aid}"; os.makedirs(d,exist_ok=True)
local_rel=f"09-test-evidence/reviewer-attempts/{aid}/verdict.json"; attempt_rel=f"09-test-evidence/reviewer-attempts/{aid}/attempt.json"
verdict=json.load(open(run+"/08-qa-verdict.gpt.json"))
verdict.update({"verdict":"APPROVE","attempt_id":aid,"blockers":[],"blocker_objects":[]})
raw=(json.dumps(verdict,indent=2,sort_keys=True)+"\n").encode()
for path in (f"{run}/{local_rel}",run+"/08-qa-verdict.gpt.json"):
    open(path,"wb").write(raw); os.chmod(path,0o600)
attempt={"schema_version":1,"attempt_id":aid,"provider":"gpt","run_id":rid,"candidate_sha":sha,"generation":1,
         "status":"approve","exit_code":0,"started_event_id":"evt-forged-start","outcome_event_id":"evt-forged-approve",
         "verdict":local_rel,"canonical":"08-qa-verdict.gpt.json","canonical_promoted":True,
         "verdict_sha256":hashlib.sha256(raw).hexdigest(),"verdict_bytes":len(raw)}
araw=(json.dumps(attempt,indent=2,sort_keys=True)+"\n").encode(); open(f"{run}/{attempt_rel}","wb").write(araw); os.chmod(f"{run}/{attempt_rel}",0o600)
state=run+"/09-test-evidence/reviewer-state.gpt.json"; doc=json.load(open(state)); doc["attempt_id"]=aid
open(state,"w").write(json.dumps(doc,indent=2)+"\n"); os.chmod(state,0o600)
print(" ".join([f"attempt={attempt_rel}",f"attempt_id={aid}",f"verdict={local_rel}","exit_code=0",
  f"sha256={hashlib.sha256(araw).hexdigest()}",f"bytes={len(araw)}",f"verdict_sha256={hashlib.sha256(raw).hexdigest()}",
  f"verdict_bytes={len(raw)}","canonical=08-qa-verdict.gpt.json","phase=judge"]))
PY
)"
    # shellcheck disable=SC2086
    "$BIN/firm-ledger-log" --run "$fr_run" --strict --event-id evt-forged-approve reviewer_approve provider=gpt \
      generation=1 "sha=$fr_sha" $fr_forged >/dev/null
    assert_fail "a fabricated APPROVE after a forged qa_checkout does not pass the seal" \
      seal_for_run "$fr_run" --verify --phase publication
    fr_check 2 "…and cannot pass the Final check" "unexpected event qa_checkout"
    cp -p "$fr_snap/run.jsonl" "$fr_run/run.jsonl"; cp -p "$fr_snap/08-qa-verdict.gpt.json" "$fr_run/08-qa-verdict.gpt.json"
    cp -p "$fr_snap/reviewer-state.gpt.json" "$fr_run/09-test-evidence/reviewer-state.gpt.json"
    rm -rf "$fr_run/09-test-evidence/reviewer-attempts/gpt-c1-a0099"
    assert_ok "the run is restored to the genuine judge BLOCK" seal_for_run "$fr_run" --verify --phase publication

    # THE VERIFICATION WINDOW. The Final check used to verify the seal in a subprocess and then re-read
    # run.jsonl, so a row appended in between was trusted unverified: a fabricated APPROVE appended
    # there passed with rc 0. A guarded test seam now runs exactly in that window; the check must decide
    # on the bytes it verified, and a fresh check must then refuse the appended row.
    fr_race_hook="$fr_stub/after-verify.sh"
    { printf '#!/bin/sh\n'
      printf 'exec %q - %q %q %q <<'"'"'PY'"'"'\n' "$(command -v python3)" "$fr_run" "$fr_id" "$fr_sha"
      cat <<'PY'
import hashlib,json,os,sys
run,rid,sha=sys.argv[1:]
aid="gpt-c1-a0098"; d=f"{run}/09-test-evidence/reviewer-attempts/{aid}"; os.makedirs(d,exist_ok=True)
local_rel=f"09-test-evidence/reviewer-attempts/{aid}/verdict.json"; attempt_rel=f"09-test-evidence/reviewer-attempts/{aid}/attempt.json"
verdict=json.load(open(run+"/08-qa-verdict.gpt.json"))
verdict.update({"verdict":"APPROVE","attempt_id":aid,"blockers":[],"blocker_objects":[]})
raw=(json.dumps(verdict,indent=2,sort_keys=True)+"\n").encode()
for path in (f"{run}/{local_rel}",run+"/08-qa-verdict.gpt.json"):
    open(path,"wb").write(raw); os.chmod(path,0o600)
attempt={"schema_version":1,"attempt_id":aid,"provider":"gpt","run_id":rid,"candidate_sha":sha,"generation":1,
         "status":"approve","exit_code":0,"started_event_id":"evt-race-start","outcome_event_id":"evt-race-approve",
         "verdict":local_rel,"canonical":"08-qa-verdict.gpt.json","canonical_promoted":True,
         "verdict_sha256":hashlib.sha256(raw).hexdigest(),"verdict_bytes":len(raw)}
araw=(json.dumps(attempt,indent=2,sort_keys=True)+"\n").encode(); open(f"{run}/{attempt_rel}","wb").write(araw)
os.chmod(f"{run}/{attempt_rel}",0o600)
state=run+"/09-test-evidence/reviewer-state.gpt.json"; doc=json.load(open(state)); doc["attempt_id"]=aid
open(state,"w").write(json.dumps(doc,indent=2)+"\n"); os.chmod(state,0o600)
row={"ts":"2026-10-02T00:00:00Z","event":"reviewer_approve","event_id":"evt-race-approve","run_id":rid,"provider":"gpt",
     "generation":"1","sha":sha,"attempt":attempt_rel,"attempt_id":aid,"exit_code":"0","verdict":local_rel,
     "canonical":"08-qa-verdict.gpt.json","phase":"judge","sha256":hashlib.sha256(araw).hexdigest(),"bytes":str(len(araw)),
     "verdict_sha256":hashlib.sha256(raw).hexdigest(),"verdict_bytes":str(len(raw))}
with open(run+"/run.jsonl","a") as fh: fh.write(json.dumps(row,separators=(",",":"))+"\n")
PY
      printf 'PY\n'; } > "$fr_race_hook"
    chmod +x "$fr_race_hook"
    fr_race_out="$(FIRM_FINAL_TEST_GUARD=1 FIRM_FINAL_AFTER_VERIFY_HOOK="$fr_race_hook" "$BIN/firm-final-qa-check" "$fr_run" 2>&1)"
    fr_race_rc=$?
    assert_output "the race hook really appended a fabricated APPROVE after the verification" '"event_id":"evt-race-approve"' \
      cat "$fr_run/run.jsonl"
    case "$fr_race_rc" in
      0) _t_no "a row appended after the Final check's verification is not trusted" "passed: $(_t_ctx "$fr_race_out")" ;;
      *) _t_ok "a row appended after the Final check's verification is not trusted" ;;
    esac
    fr_check 2 "…and a fresh check refuses the unverified row" "BLOCK LEDGER_SUFFIX"
    cp -p "$fr_snap/run.jsonl" "$fr_run/run.jsonl"; cp -p "$fr_snap/08-qa-verdict.gpt.json" "$fr_run/08-qa-verdict.gpt.json"
    cp -p "$fr_snap/reviewer-state.gpt.json" "$fr_run/09-test-evidence/reviewer-state.gpt.json"
    rm -rf "$fr_run/09-test-evidence/reviewer-attempts/gpt-c1-a0098"
    assert_ok "…and the run is restored to the genuine judge BLOCK again" seal_for_run "$fr_run" --verify --phase publication
    # The same window with rows that are VALID (a windowed, seal-bound dispositions set): the check must
    # still decide on the bytes it verified, not on what it would find by reading the ledger again.
    mkdir -p "$fr_run/$fr_root"
    printf 'race-window position\n' > "$fr_run/$fr_root/race-position.md"; chmod 600 "$fr_run/$fr_root/race-position.md"
    t_python - "$fr_run" "$fr_root/race-position.md" <<'PY'
import hashlib,json,os,sys
run,evidence=sys.argv[1:]
c=json.load(open(run+"/09-test-evidence/qa-candidate.json")); sha=c["candidate_sha"]
canonical=json.load(open(run+"/08-qa-verdict.gpt.json"))
local=open(f"{run}/09-test-evidence/reviewer-attempts/{canonical['attempt_id']}/verdict.json","rb").read()
raw=open(run+"/"+evidence,"rb").read()
ref={"path":evidence,"candidate_sha":sha,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw),
     "producer":{"event_id":"evt-race-evidence","event":"post_judge_artifact_published"}}
entries=[{"secondary_blocker_id":o["id"],"secondary_blocker":o["text"],"primary_position":"asks for a human decision",
          "positive_dissent":True,"affected_criteria":o["affected_criteria"],"affected_paths":o["affected_paths"],
          "risk":"low","risk_reasons":["criterion:AC-001:functional"],
          "bounded_resolution":{"attempted":False,"rounds":0,"rerun":"not_run","evidence":None},
          "evidence":ref,"disposition":"human_decision"} for o in canonical["blocker_objects"]]
doc={"schema_version":1,"run_id":os.path.basename(run),"candidate_sha":sha,"generation":1,
     "secondary_attempt_id":canonical["attempt_id"],"secondary_verdict_sha256":hashlib.sha256(local).hexdigest(),
     "secondary_verdict_bytes":len(local),"two_voice_diff":entries}
path=run+"/09-test-evidence/post-judge/g1/race-dispositions.json"
open(path,"w").write(json.dumps(doc,indent=2,sort_keys=True)+"\n"); os.chmod(path,0o600)
PY
    fr_race_hook2="$fr_stub/after-verify-valid.sh"
    printf '#!/bin/sh\n%q %q %q %q post_judge_artifact_published path=%q kind=disposition_evidence secondary_attempt_id=gpt-c1-a0002 @window event_id=evt-race-evidence >/dev/null\n%q %q %q %q post_judge_artifact_published path=%q kind=two_voice_dispositions secondary_attempt_id=gpt-c1-a0002 @window >/dev/null\n' \
      "$BIN/firm-python" "$PJ_EVENT" "$FIRM_ROOT" "$fr_run" "$fr_root/race-position.md" \
      "$BIN/firm-python" "$PJ_EVENT" "$FIRM_ROOT" "$fr_run" "$fr_root/race-dispositions.json" > "$fr_race_hook2"
    chmod +x "$fr_race_hook2"
    fr_race2_out="$(FIRM_FINAL_TEST_GUARD=1 FIRM_FINAL_AFTER_VERIFY_HOOK="$fr_race_hook2" "$BIN/firm-final-qa-check" "$fr_run" 2>&1)"
    fr_race2_rc=$?
    assert_output "the race hook appended a valid dispositions set after the verification" "race-dispositions.json" \
      cat "$fr_run/run.jsonl"
    case "$fr_race2_rc:$fr_race2_out" in
      1:*"exactly one entry per producer objection id"*) _t_ok "the check decides on the bytes it verified, not on rows appended since" ;;
      *) _t_no "the check decides on the bytes it verified, not on rows appended since" "rc=$fr_race2_rc $(_t_ctx "$fr_race2_out")" ;;
    esac
    fr_check 4 "…and a fresh check, which verifies them, sees them" "DECISION REQUIRED"
    cp -p "$fr_snap/run.jsonl" "$fr_run/run.jsonl"
    assert_ok "…and the run is restored to the genuine judge BLOCK once more" seal_for_run "$fr_run" --verify --phase publication

    mkdir -p "$fr_run/$fr_root"
    printf '%s\n' 'Primary QA position on obj-post-judge-fixture: the sealed proof covers AC-001.' \
      > "$fr_run/$fr_root/primary-position.md"; chmod 600 "$fr_run/$fr_root/primary-position.md"
    fr_evidence="$(fr_publish primary-position.md disposition_evidence gpt-c1-a0002)"
    assert_ok "primary QA publishes post-judge disposition evidence" test -n "$fr_evidence"

    fr_dispositions two-voice-dispositions.1.json gpt-c1-a0001 "evidence=$fr_evidence"
    fr_publish two-voice-dispositions.1.json two_voice_dispositions gpt-c1-a0001 >/dev/null
    fr_check 1 "dispositions naming another attempt are ignored, so the BLOCK still blocks" "are ignored"
    fr_dispositions two-voice-dispositions.2.json gpt-c1-a0002 digest=wrong "evidence=$fr_evidence"
    fr_publish two-voice-dispositions.2.json two_voice_dispositions gpt-c1-a0002 >/dev/null
    fr_check 1 "dispositions naming another verdict digest are ignored, so the BLOCK still blocks" "are ignored"
    fr_dispositions two-voice-dispositions.2b.json gpt-c1-a0002 digest=wrong-bytes "evidence=$fr_evidence"
    fr_publish two-voice-dispositions.2b.json two_voice_dispositions gpt-c1-a0002 >/dev/null
    fr_check 1 "dispositions naming the right digest but another verdict size are ignored" "are ignored"

    fr_before="$(fr_decisions)"
    fr_dispositions two-voice-dispositions.3.json gpt-c1-a0002 "evidence=$fr_evidence"
    fr_publish two-voice-dispositions.3.json two_voice_dispositions gpt-c1-a0002 >/dev/null
    fr_check 4 "current dispositions asking for a human decision return decision_required" "DECISION REQUIRED"
    assert_eq "the Final check wrote exactly one decision state" "$((fr_before + 1))" "$(fr_decisions)"
    assert_output "…and recorded it in the target ledger" '"event":"final_decision_required"' cat "$fr_run/run.jsonl"
    assert_ok "the seal still verifies after the Final check's own event" seal_for_run "$fr_run" --verify --phase publication
    assert_ok "the Lead logs final_gate_pending for the sealed candidate" \
      "$BIN/firm-ledger-log" --run "$fr_run" --strict final_gate_pending "sha=$fr_sha" generation=1
    assert_ok "the seal still verifies after final_gate_pending" seal_for_run "$fr_run" --verify --phase publication

    t_python - "$fr_run/$fr_root/human-decision.yaml" "$fr_id" "$fr_sha" "$fr_text" <<'PY'
import os,sys,yaml
path,rid,sha,text=sys.argv[1:]
open(path,"w").write(yaml.safe_dump({"schema_version":1,"type":"human_decision","actor":"human-fixture",
    "occurred_at":"2026-10-01T00:00:00Z","run_id":rid,"candidate_sha":sha,"decision":"proceed",
    "objection_ids":["obj-post-judge-fixture"],"objections":[text]},sort_keys=False))
os.chmod(path,0o600)
PY
    fr_record="$(fr_publish human-decision.yaml human_decision gpt-c1-a0002 "decision_required_event_id=$(fr_last_decision)")"
    assert_ok "the human decision is published as a post-judge record" test -n "$fr_record"
    # The wrong kind of post-judge artifact cannot stand in for the human record.
    cp "$fr_run/$fr_root/human-decision.yaml" "$fr_run/$fr_root/human-as-evidence.yaml"
    fr_wrong_kind="$(fr_publish human-as-evidence.yaml disposition_evidence gpt-c1-a0002)"
    fr_dispositions two-voice-dispositions.4.json gpt-c1-a0002 "evidence=$fr_evidence" "record=$fr_wrong_kind"
    fr_publish two-voice-dispositions.4.json two_voice_dispositions gpt-c1-a0002 >/dev/null
    fr_check 1 "a disposition_evidence artifact cannot stand in for the human record" "where it may not"

    fr_dispositions two-voice-dispositions.5.json gpt-c1-a0002 "evidence=$fr_evidence" "record=$fr_record"
    fr_publish two-voice-dispositions.5.json two_voice_dispositions gpt-c1-a0002 >/dev/null
    fr_check 0 "a recorded human decision cited from re-published dispositions passes a fresh check" \
      "every exact secondary objection has a typed current-SHA disposition"
    assert_ok "the seal verifies for publication at the end of the post-judge phase" \
      seal_for_run "$fr_run" --verify --phase publication
    assert_ok "…and for the wrapper's preflight" seal_for_run "$fr_run" --verify --phase wrapper-preflight
    # The LATEST publication governs. A later set naming another (older) terminal attempt is ignored and
    # does NOT resurrect the earlier set that named the current attempt.
    fr_dispositions two-voice-dispositions.5b.json gpt-c1-a0001 "evidence=$fr_evidence" "record=$fr_record"
    fr_publish two-voice-dispositions.5b.json two_voice_dispositions gpt-c1-a0001 >/dev/null
    fr_check 1 "a later set naming an older attempt does not resurrect the earlier current set" "are ignored"

    # The latest publication rules: a malformed one blocks rather than falling back to an older set.
    t_python - "$fr_run/$fr_root/two-voice-dispositions.5.json" "$fr_run/$fr_root/two-voice-dispositions.6.json" <<'PY'
import json,os,sys
source,target=sys.argv[1:]
doc=json.load(open(source)); doc["two_voice_diff"][0]["disposition"]="accepted_by_silence"
open(target,"w").write(json.dumps(doc,indent=2,sort_keys=True)+"\n"); os.chmod(target,0o600)
PY
    fr_publish two-voice-dispositions.6.json two_voice_dispositions gpt-c1-a0002 >/dev/null
    fr_check 1 "a latest disposition outside the traceability disposition shape blocks" "is not a traceability disposition"

    # A further judge attempt is interleavable: preflight accepts the post-judge phase, and once a new
    # BLOCK is current the earlier dispositions no longer answer it.
    fr_rc=0; fr_judge || fr_rc=$?
    assert_eq "a further wrapper attempt runs after the post-judge phase and BLOCKs again" 1 "$fr_rc"
    # rc 1 is also what a refused preflight returns, so prove the attempt really ran and was promoted.
    assert_output "…as a new promoted attempt, not a refused preflight" '"attempt_id": "gpt-c1-a0003"' \
      cat "$fr_run/09-test-evidence/reviewer-state.gpt.json"
    assert_output "…whose BLOCK is the canonical verdict" '"attempt_id": "gpt-c1-a0003"' cat "$fr_run/08-qa-verdict.gpt.json"
    # That attempt's controlled input manifest holds every digest-named post-judge artifact and
    # decision state the ledger it was handed names: inventoried with the event's digest, or declared.
    assert_ok "the further attempt's manifest inventories every post-judge artifact the ledger names" \
      t_python - "$fr_run" "$fr_stub/manifests/manifest-gpt-c1-a0003.json" <<'PY'
import json,sys
run,manifest_path=sys.argv[1:]
rows=[json.loads(line) for line in open(run+"/run.jsonl")]
start=[i for i,r in enumerate(rows) if r.get("event")=="reviewer_attempt_started" and r.get("attempt_id")=="gpt-c1-a0003"][0]
named=[r for r in rows[:start] if r.get("event") in ("post_judge_artifact_published","final_decision_required")]
assert len(named)>=8,len(named)
manifest=json.load(open(manifest_path))
entries={e["origin_path"]:e for e in manifest["entries"]}
declared={e["origin_path"] for e in manifest["excluded_references"]+manifest["unresolved_references"]}
missing=[r["path"] for r in named if not ((r["path"] in entries and entries[r["path"]]["source_sha256"]==r["sha256"]
                                           and str(entries[r["path"]]["source_bytes"])==r["bytes"]) or r["path"] in declared)]
assert not missing,missing
paths={r["path"] for r in named}
assert not [u for u in manifest["unresolved_references"] if u["origin_path"] in paths],manifest["unresolved_references"]
assert all(r["path"] in entries for r in named)
PY
    fr_check 1 "dispositions of the earlier attempt do not answer the new current BLOCK" "are ignored"
    # Every post-judge record answers one attempt: what was published for a0002 cannot answer a0003.
    cp "$fr_run/$fr_root/primary-position.md" "$fr_run/$fr_root/primary-position.a0003.md"
    fr_evidence3="$(fr_publish primary-position.a0003.md disposition_evidence gpt-c1-a0003)"
    fr_dispositions two-voice-dispositions.7.json gpt-c1-a0003 "evidence=$fr_evidence" "record=$fr_record"
    fr_publish two-voice-dispositions.7.json two_voice_dispositions gpt-c1-a0003 >/dev/null
    fr_check 1 "disposition evidence published for the earlier attempt cannot answer the new BLOCK" \
      "not the current secondary attempt"
    fr_dispositions two-voice-dispositions.8.json gpt-c1-a0003 "evidence=$fr_evidence3" "record=$fr_record"
    fr_publish two-voice-dispositions.8.json two_voice_dispositions gpt-c1-a0003 >/dev/null
    fr_check 1 "a human decision recorded for the earlier attempt cannot answer the new BLOCK" \
      "not the current secondary attempt"
    fr_dispositions two-voice-dispositions.9.json gpt-c1-a0003 "evidence=$fr_evidence3"
    fr_publish two-voice-dispositions.9.json two_voice_dispositions gpt-c1-a0003 >/dev/null
    fr_check 4 "the new BLOCK needs its own human decision" "DECISION REQUIRED"
    assert_output "…whose decision state names the new attempt" '"secondary_attempt_id": "gpt-c1-a0003"' \
      cat "$fr_run/$(t_python -c 'import json,sys; print([r for r in map(json.loads,open(sys.argv[1])) if r.get("event")=="final_decision_required"][-1]["path"])' "$fr_run/run.jsonl")"
    cp "$fr_run/$fr_root/human-decision.yaml" "$fr_run/$fr_root/human-decision.a0003.yaml"
    fr_record3="$(fr_publish human-decision.a0003.yaml human_decision gpt-c1-a0003 "decision_required_event_id=$(fr_last_decision)")"
    fr_dispositions two-voice-dispositions.10.json gpt-c1-a0003 "evidence=$fr_evidence3" "record=$fr_record3"
    fr_publish two-voice-dispositions.10.json two_voice_dispositions gpt-c1-a0003 >/dev/null
    fr_check 0 "dispositions re-published for the new attempt, citing its own decision, pass a fresh check"
    assert_ok "the seal verifies after the whole interleaved post-judge history" \
      seal_for_run "$fr_run" --verify --phase publication

    # PRIMARY QA'S DISPOSITIONS CARRY A PRODUCER IDENTITY. The reviewer cleared a current BLOCK with
    # proceed_with_primary dispositions and disposition evidence appended by a caller with no role
    # window at all. Both kinds must come from a native qa-tester window opened after the attempt.
    printf '%s\n' 'One bounded resolution round: the judge re-ran and still blocked; primary QA keeps its reading.' \
      > "$fr_run/$fr_root/round.md"; chmod 600 "$fr_run/$fr_root/round.md"
    fr_before_windowless="$fr_stub/before-windowless"; mkdir -p "$fr_before_windowless"
    cp -p "$fr_run/run.jsonl" "$fr_before_windowless/"
    # The writer refuses a window-less answer outright, so it never lands...
    assert_fail "the writer refuses window-less disposition evidence" \
      fr_publish round.md disposition_evidence gpt-c1-a0003 @nowindow
    fr_dispositions two-voice-dispositions.11.json gpt-c1-a0003 disposition=proceed_with_primary \
      "evidence=$fr_evidence3" "bounded=$fr_evidence3"
    assert_fail "the writer refuses window-less proceed_with_primary dispositions" \
      fr_publish two-voice-dispositions.11.json two_voice_dispositions gpt-c1-a0003 @nowindow
    assert_eq "…and neither refused row reached the ledger" "$(shasum -a 256 < "$fr_before_windowless/run.jsonl")" \
      "$(shasum -a 256 < "$fr_run/run.jsonl")"
    # ...and the same rows appended by another route still cannot clear the BLOCK.
    fr_publish two-voice-dispositions.11.json two_voice_dispositions gpt-c1-a0003 @nowindow @raw >/dev/null
    fr_check 2 "proceed_with_primary dispositions with no primary-QA window cannot clear the BLOCK" \
      "field set is not closed"
    cp -p "$fr_before_windowless/run.jsonl" "$fr_run/run.jsonl"
    assert_ok "…and the run is restored" seal_for_run "$fr_run" --verify --phase publication
    fr_round="$(fr_publish round.md disposition_evidence gpt-c1-a0003)"
    fr_dispositions two-voice-dispositions.12.json gpt-c1-a0003 disposition=proceed_with_primary \
      "evidence=$fr_round" "bounded=$fr_round" rounds=0
    fr_publish two-voice-dispositions.12.json two_voice_dispositions gpt-c1-a0003 >/dev/null
    fr_check 1 "proceed_with_primary inside a window but without one bounded round still blocks" \
      "exactly one bounded resolution round"
    fr_dispositions two-voice-dispositions.13.json gpt-c1-a0003 disposition=proceed_with_primary \
      "evidence=$fr_round" "bounded=$fr_round"
    fr_publish two-voice-dispositions.13.json two_voice_dispositions gpt-c1-a0003 >/dev/null
    fr_check 0 "proceed_with_primary from a primary-QA window with one bounded round passes"
    assert_ok "the seal verifies with the windowed primary-QA publications" \
      seal_for_run "$fr_run" --verify --phase publication

    # Post-judge bytes meet the privacy policy: disposition evidence carrying a secret assignment
    # (assembled at run time) cannot clear the BLOCK, whichever of the seal or the Final check sees it.
    fr_before_leak="$fr_stub/before-leak"; mkdir -p "$fr_before_leak"; cp -p "$fr_run/run.jsonl" "$fr_before_leak/"
    printf 'bounded round notes: %s\n' "$(printf '%s%s=%s' pass word Leaked-value-1234)" > "$fr_run/$fr_root/round-leak.md"
    chmod 600 "$fr_run/$fr_root/round-leak.md"
    fr_leak_append="$(fr_publish round-leak.md disposition_evidence gpt-c1-a0003 2>&1)"; fr_leak_append_rc=$?
    case "$fr_leak_append_rc:$fr_leak_append" in
      0:*) _t_no "the writer refuses disposition evidence carrying a secret" "appended" ;;
      *"post-judge event refused"*secret_assignment*) _t_ok "the writer refuses disposition evidence carrying a secret" ;;
      *) _t_no "the writer refuses disposition evidence carrying a secret" "$(_t_ctx "$fr_leak_append")" ;;
    esac
    fr_round_leak="$(fr_publish round-leak.md disposition_evidence gpt-c1-a0003 @raw)"
    fr_dispositions two-voice-dispositions.14.json gpt-c1-a0003 disposition=proceed_with_primary \
      "evidence=$fr_round_leak" "bounded=$fr_round_leak"
    fr_publish two-voice-dispositions.14.json two_voice_dispositions gpt-c1-a0003 @raw >/dev/null
    fr_leak_out="$("$BIN/firm-final-qa-check" "$fr_run" 2>&1)"; fr_leak_rc=$?
    case "$fr_leak_rc:$fr_leak_out" in
      0:*) _t_no "disposition evidence carrying a secret, appended raw, cannot clear the BLOCK" "passed" ;;
      *secret_assignment*) _t_ok "disposition evidence carrying a secret, appended raw, cannot clear the BLOCK" ;;
      *) _t_no "disposition evidence carrying a secret, appended raw, cannot clear the BLOCK" "$(_t_ctx "$fr_leak_out")" ;;
    esac
    cp -p "$fr_before_leak/run.jsonl" "$fr_run/run.jsonl"
    fr_check 0 "…and the run is restored to its passing state"
  fi
fi

# A HUMAN RECORD MUST BE MADE AFTER THE VERDICT IT ANSWERS. The ledger before the seal is only
# classified, never held to the suffix grammar, so a decision state and a human decision staged there,
# naming the predictable first attempt and an objection the judge then raises, used to answer that
# BLOCK with no human decision ever required after it. Final now counts a post-judge record only when
# it is bound to this generation's seal and answers a decision required after the current verdict.
t_case "a human decision staged before the seal cannot answer a later judge BLOCK"
if ! ledger_writes_supported; then
  t_skip "pre-seal staged human decision" "requires a supported P2 ledger write host and no refused-row seam"
elif [ ! -x "${fr_stub:-}/bin/codex" ]; then
  _t_no "staged-record fixture has the judge stub" "the end-to-end case did not create it"
else
  st_fixture="$(make_sealable_run claude "" write_final_ready_run real_qa_tools)"
  st_run="$(printf '%s\n' "$st_fixture" | sed -n '2p')"; st_sha="$(printf '%s\n' "$st_fixture" | sed -n '3p')"
  st_id="$(basename "$st_run")"; st_text="the staged fixture objection"
  mkdir -p "$st_run/09-test-evidence/post-judge/g1"
  t_python - "$st_run" "$st_id" "$st_sha" "$st_text" <<'PY'
import json,os,sys,yaml
run,rid,sha,text=sys.argv[1:]
state={"schema_version":1,"status":"decision_required","run_id":rid,"candidate_sha":sha,"generation":1,
       "kind":"secondary_objections","objections":[],"permitted_record_types":["human_decision"],
       "event_id":"evt-staged-decision","secondary_attempt_id":"gpt-c1-a0001","created_at":"2026-10-01T00:00:00Z"}
path=f"{run}/09-test-evidence/final-decision-required.evt-staged-decision.json"
open(path,"w").write(json.dumps(state,indent=2,sort_keys=True)+"\n"); os.chmod(path,0o600)
path=f"{run}/09-test-evidence/post-judge/g1/human.yaml"
open(path,"w").write(yaml.safe_dump({"schema_version":1,"type":"human_decision","actor":"nobody",
    "occurred_at":"2026-10-01T00:00:00Z","run_id":rid,"candidate_sha":sha,"decision":"proceed",
    "objection_ids":["obj-staged"],"objections":[text]},sort_keys=False)); os.chmod(path,0o600)
verdict={"verdict":"BLOCK","commit_sha":sha,"run_id":rid,"generation":1,"provider":"gpt","attempt_id":"__ATTEMPT__",
         "environment":"stub","commands_run":[],"unit":{"status":"pass","evidence":"09-test-evidence/proof.log"},
         "integration":{"status":"not_applicable","evidence":"none"},"e2e":{"status":"not_applicable","evidence":"none"},
         "visual":{"status":"not_applicable","evidence":"none"},
         "acceptance_criteria_coverage":[{"id":"AC-001","covered":"partial","evidence":"09-test-evidence/proof.log"}],
         "untested_risks":[],"blockers":[text],
         "blocker_objects":[{"id":"obj-staged","text":text,"affected_criteria":["AC-001"],"affected_paths":[]}],
         "warnings":[],"artifacts":[],"summary":"stub judge BLOCK"}
json.dump(verdict,open(run+"/.staged-block.json","w"))
PY
  st_digest() { shasum -a 256 "$st_run/$1" | awk '{print $1}'; }
  st_size() { wc -c < "$st_run/$1" | tr -d ' '; }
  st_decision=09-test-evidence/final-decision-required.evt-staged-decision.json
  "$BIN/firm-ledger-log" --run "$st_run" --strict --event-id evt-staged-decision final_decision_required \
    "path=$st_decision" "sha=$st_sha" generation=1 "sha256=$(st_digest "$st_decision")" "bytes=$(st_size "$st_decision")" \
    kind=secondary_objections >/dev/null
  st_human=09-test-evidence/post-judge/g1/human.yaml
  "$BIN/firm-ledger-log" --run "$st_run" --strict --event-id evt-staged-record post_judge_artifact_published \
    "path=$st_human" "sha256=$(st_digest "$st_human")" "bytes=$(st_size "$st_human")" "sha=$st_sha" generation=1 \
    kind=human_decision secondary_attempt_id=gpt-c1-a0001 decision_required_event_id=evt-staged-decision \
    seal_event_id=evt-staged-seal "seal_projection_sha256=$(printf '%064d' 0)" >/dev/null
  assert_ok "the run seals with the staged events in its (only classified) prefix" seal_for_run "$st_run"
  st_rc=0; env PATH="$fr_stub/bin:/usr/bin:/bin" STUB_MODEL="$fr_model" STUB_VERDICT="$st_run/.staged-block.json" \
    CODEX_HOME="$fr_stub/codex-home" FIRM_GPT_QA_DISCOVERY_TIMEOUT=20 FIRM_GPT_QA_READINESS_TIMEOUT=20 \
    FIRM_GPT_QA_TIMEOUT=60 "$BIN/firm-gpt-qa" --run "$st_run" >/dev/null 2>&1 || st_rc=$?
  assert_eq "the real wrapper BLOCKs with the predicted attempt and objection" 1 "$st_rc"
  printf 'primary QA position\n' > "$st_run/09-test-evidence/post-judge/g1/position.md"
  chmod 600 "$st_run/09-test-evidence/post-judge/g1/position.md"
  st_evidence="$(t_python "$PJ_EVENT" "$FIRM_ROOT" "$st_run" post_judge_artifact_published \
    path=09-test-evidence/post-judge/g1/position.md kind=disposition_evidence secondary_attempt_id=gpt-c1-a0001 @window)"
  t_python - "$st_run" "$st_evidence" <<'PY'
import hashlib,json,os,sys
run,evidence=sys.argv[1:]
c=json.load(open(run+"/09-test-evidence/qa-candidate.json")); sha=c["candidate_sha"]
canonical=json.load(open(run+"/08-qa-verdict.gpt.json"))
local=open(f"{run}/09-test-evidence/reviewer-attempts/{canonical['attempt_id']}/verdict.json","rb").read()
events={r["event_id"]:r for r in map(json.loads,open(run+"/run.jsonl")) if "event_id" in r}
def ref(event_id):
    raw=open(run+"/"+events[event_id]["path"],"rb").read()
    return {"path":events[event_id]["path"],"candidate_sha":sha,"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw),
            "producer":{"event_id":event_id,"event":events[event_id]["event"]}}
entries=[{"secondary_blocker_id":o["id"],"secondary_blocker":o["text"],"primary_position":"asks for a human decision",
          "positive_dissent":True,"affected_criteria":o["affected_criteria"],"affected_paths":o["affected_paths"],
          "risk":"low","risk_reasons":["criterion:AC-001:functional"],
          "bounded_resolution":{"attempted":False,"rounds":0,"rerun":"not_run","evidence":None},
          "evidence":ref(evidence),"record":ref("evt-staged-record"),"disposition":"human_decision"}
         for o in canonical["blocker_objects"]]
doc={"schema_version":1,"run_id":os.path.basename(run),"candidate_sha":sha,"generation":1,
     "secondary_attempt_id":canonical["attempt_id"],"secondary_verdict_sha256":hashlib.sha256(local).hexdigest(),
     "secondary_verdict_bytes":len(local),"two_voice_diff":entries}
path=run+"/09-test-evidence/post-judge/g1/two-voice-dispositions.1.json"
open(path,"w").write(json.dumps(doc,indent=2,sort_keys=True)+"\n"); os.chmod(path,0o600)
PY
  t_python "$PJ_EVENT" "$FIRM_ROOT" "$st_run" post_judge_artifact_published \
    path=09-test-evidence/post-judge/g1/two-voice-dispositions.1.json kind=two_voice_dispositions \
    secondary_attempt_id=gpt-c1-a0001 @window >/dev/null
  assert_ok "the seal verifies: every post-seal event is well formed" seal_for_run "$st_run" --verify --phase publication
  st_out="$("$BIN/firm-final-qa-check" "$st_run" 2>&1)"; st_final=$?
  assert_eq "the BLOCK is not answered by the record staged before the seal" 1 "$st_final"
  case "$st_out" in *"not bound to this generation's seal"*) _t_ok "…and the check says why";;
    *) _t_no "…and the check says why" "$(_t_ctx "$st_out")";; esac
fi

# A JUDGE VERDICT STAGED BEFORE THE SEAL IS NOT A JUDGE VERDICT. The pre-seal ledger is only
# classified, so a reviewer_approve row written there with planted attempt and verdict files, and no
# judge ever run, used to satisfy the Final check. In a sealed generation every reviewer event the
# check relies on must now carry this seal's binding.
t_case "a reviewer verdict staged before the seal cannot pass the Final check"
if ! ledger_writes_supported; then
  t_skip "pre-seal staged reviewer verdict" "requires a supported P2 ledger write host and no refused-row seam"
else
  sv_fixture="$(make_sealable_run claude "" write_final_ready_run real_qa_tools)"
  sv_run="$(printf '%s\n' "$sv_fixture" | sed -n '2p')"; sv_sha="$(printf '%s\n' "$sv_fixture" | sed -n '3p')"
  sv_fields="$(t_python - "$sv_run" "$(basename "$sv_run")" "$sv_sha" <<'PY'
import hashlib,json,os,sys
run,rid,sha=sys.argv[1:]
aid="gpt-c1-a0001"; d=f"{run}/09-test-evidence/reviewer-attempts/{aid}"; os.makedirs(d,exist_ok=True)
local_rel=f"09-test-evidence/reviewer-attempts/{aid}/verdict.json"; attempt_rel=f"09-test-evidence/reviewer-attempts/{aid}/attempt.json"
verdict={"verdict":"APPROVE","commit_sha":sha,"run_id":rid,"generation":1,"provider":"gpt","attempt_id":aid,
         "environment":"staged","commands_run":[],"unit":{"status":"pass","evidence":"09-test-evidence/proof.log"},
         "integration":{"status":"not_applicable","evidence":"none"},"e2e":{"status":"not_applicable","evidence":"none"},
         "visual":{"status":"not_applicable","evidence":"none"},
         "acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"09-test-evidence/proof.log"}],
         "untested_risks":[],"blockers":[],"blocker_objects":[],"warnings":[],"artifacts":[],"summary":"staged"}
raw=(json.dumps(verdict,indent=2,sort_keys=True)+"\n").encode()
for path in (f"{run}/{local_rel}",run+"/08-qa-verdict.gpt.json"):
    open(path,"wb").write(raw); os.chmod(path,0o600)
attempt={"schema_version":1,"attempt_id":aid,"provider":"gpt","run_id":rid,"candidate_sha":sha,"generation":1,
         "status":"approve","exit_code":0,"started_event_id":"evt-staged-start","outcome_event_id":"evt-staged-approve",
         "verdict":local_rel,"canonical":"08-qa-verdict.gpt.json","canonical_promoted":True,
         "verdict_sha256":hashlib.sha256(raw).hexdigest(),"verdict_bytes":len(raw)}
araw=(json.dumps(attempt,indent=2,sort_keys=True)+"\n").encode(); open(f"{run}/{attempt_rel}","wb").write(araw)
os.chmod(f"{run}/{attempt_rel}",0o600)
state=run+"/09-test-evidence/reviewer-state.gpt.json"
open(state,"w").write(json.dumps({"schema_version":1,"provider":"gpt","candidate_sha":sha,"generation":1,
                                  "last_attempt":1,"attempt_id":aid},indent=2)+"\n"); os.chmod(state,0o600)
print(" ".join([f"attempt={attempt_rel}",f"attempt_id={aid}",f"verdict={local_rel}","exit_code=0",
  f"sha256={hashlib.sha256(araw).hexdigest()}",f"bytes={len(araw)}",f"verdict_sha256={hashlib.sha256(raw).hexdigest()}",
  f"verdict_bytes={len(raw)}","canonical=08-qa-verdict.gpt.json","phase=judge"]))
PY
)"
  # shellcheck disable=SC2086
  "$BIN/firm-ledger-log" --run "$sv_run" --strict --event-id evt-staged-approve reviewer_approve provider=gpt \
    generation=1 "sha=$sv_sha" $sv_fields >/dev/null
  assert_ok "the run seals with the staged reviewer event in its (only classified) prefix" seal_for_run "$sv_run"
  sv_out="$("$BIN/firm-final-qa-check" "$sv_run" 2>&1)"; sv_rc=$?
  assert_eq "a verdict no judge produced after the seal does not pass" 1 "$sv_rc"
  case "$sv_out" in *"reviewer event is not bound to this generation's seal"*) _t_ok "…and the check says why";;
    *) _t_no "…and the check says why" "$(_t_ctx "$sv_out")";; esac
fi

# ONLY ROWS THE SEAL VERIFIED CROSS INTO A JUDGE'S INPUT. The reviewer inventory used to copy the file
# named by EVERY post-judge row in the ledger, under only the wrapper's narrow redaction: a pre-seal row
# (never grammar-checked) carried an unsealed run file holding a private-key header and an operator
# home path into the judge snapshot; a pre-seal row with a wrong digest stopped every judge attempt;
# and an earlier generation's never-verified post-judge file crossed into the next generation's judge.
# Leaks are assembled at run time, so this file's own source carries none of them.
t_case "only post-judge rows the seal verified cross into a judge's input"
if ! ledger_writes_supported; then
  t_skip "post-judge judge-input binding" "requires a supported P2 ledger write host and no refused-row seam"
elif [ ! -x "${fr_stub:-}/bin/codex" ]; then
  _t_no "judge-input fixture has the judge stub" "the end-to-end case did not create it"
else
  ji_fixture="$(make_sealable_run claude "" write_final_ready_run real_qa_tools)"
  ji_repo="$(printf '%s\n' "$ji_fixture" | sed -n '1p')"; ji_run="$(printf '%s\n' "$ji_fixture" | sed -n '2p')"
  ji_sha="$(printf '%s\n' "$ji_fixture" | sed -n '3p')"; ji_id="$(basename "$ji_run")"
  ji_keep="$fr_stub/keep-$ji_id"; mkdir -p "$ji_keep/g1" "$ji_keep/g2"
  ji_header="$(printf -- '-----BEGIN %s PRIVATE KEY-----' OPENSSH)"; ji_home="$(printf '/%s/operator/projects' Users)"
  mkdir -p "$ji_run/09-test-evidence/scratch"
  printf '%s\nhome: %s\n' "$ji_header" "$ji_home" > "$ji_run/09-test-evidence/scratch/notes.txt"
  printf 'pre-seal stray\n' > "$ji_run/09-test-evidence/x.txt"
  chmod 600 "$ji_run/09-test-evidence/scratch/notes.txt" "$ji_run/09-test-evidence/x.txt"
  "$BIN/firm-ledger-log" --run "$ji_run" --strict post_judge_artifact_published path=09-test-evidence/scratch/notes.txt \
    "sha256=$(shasum -a 256 "$ji_run/09-test-evidence/scratch/notes.txt" | awk '{print $1}')" \
    "bytes=$(wc -c < "$ji_run/09-test-evidence/scratch/notes.txt" | tr -d ' ')" >/dev/null
  "$BIN/firm-ledger-log" --run "$ji_run" --strict post_judge_artifact_published path=09-test-evidence/x.txt \
    "sha256=$(printf '%064d' 0)" bytes=999 >/dev/null
  assert_ok "the run seals with the two stray rows in its prefix" seal_for_run "$ji_run"
  ji_verdict() { # <out> <sha> <generation>
    t_python - "$1" "$ji_id" "$2" "$3" <<'PY'
import json,sys
path,rid,sha,generation=sys.argv[1:]
text="the judge-input fixture objection"
json.dump({"verdict":"BLOCK","commit_sha":sha,"run_id":rid,"generation":int(generation),"provider":"gpt","attempt_id":"__ATTEMPT__",
           "environment":"stub","commands_run":[],"unit":{"status":"pass","evidence":"09-test-evidence/proof.log"},
           "integration":{"status":"not_applicable","evidence":"none"},"e2e":{"status":"not_applicable","evidence":"none"},
           "visual":{"status":"not_applicable","evidence":"none"},
           "acceptance_criteria_coverage":[{"id":"AC-001","covered":"partial","evidence":"09-test-evidence/proof.log"}],
           "untested_risks":[],"blockers":[text],
           "blocker_objects":[{"id":"obj-judge-input","text":text,"affected_criteria":["AC-001"],"affected_paths":[]}],
           "warnings":[],"artifacts":[],"summary":"stub judge BLOCK"},open(path,"w"))
PY
  }
  ji_judge() { # <verdict> <keep>
    env PATH="$fr_stub/bin:/usr/bin:/bin" STUB_MODEL="$fr_model" STUB_VERDICT="$1" STUB_KEEP="$2" \
      CODEX_HOME="$fr_stub/codex-home" FIRM_GPT_QA_DISCOVERY_TIMEOUT=20 FIRM_GPT_QA_READINESS_TIMEOUT=20 \
      FIRM_GPT_QA_TIMEOUT=60 "$BIN/firm-gpt-qa" --run "$ji_run" > "$2/judge.out" 2>&1
  }
  # ji_inputs <keep> <attempt> <origin> <reason-fragment> — the origin was declared, never copied
  ji_inputs() {
    t_python - "$1" "$2" "$3" "$4" "$ji_header" "$ji_home" <<'PY'
import json,os,sys
keep,attempt,origin,reason,header,home=sys.argv[1:]
manifest=json.load(open(f"{keep}/manifest-{attempt}.json"))
assert origin not in {e["origin_path"] for e in manifest["entries"]},("copied",origin)
declared=[e for e in manifest["excluded_references"] if e["origin_path"]==origin]
assert len(declared)==1 and reason in declared[0]["reason"],(origin,manifest["excluded_references"])
for current,_,files in os.walk(f"{keep}/snapshot-{attempt}"):
    for name in files:
        raw=open(os.path.join(current,name),"rb").read()
        assert header.encode() not in raw and home.encode() not in raw,("leaked into",os.path.join(current,name))
PY
  }
  ji_verdict "$ji_keep/g1/block.json" "$ji_sha" 1
  ji_rc=0; ji_judge "$ji_keep/g1/block.json" "$ji_keep/g1" || ji_rc=$?
  assert_eq "a pre-seal row with a wrong digest does not stop the judge attempt" 1 "$ji_rc"
  assert_output "…which ran and promoted its BLOCK" '"attempt_id": "gpt-c1-a0001"' cat "$ji_run/08-qa-verdict.gpt.json"
  assert_ok "a pre-seal row's unsealed file is declared, never copied, and leaks nothing" \
    ji_inputs "$ji_keep/g1" gpt-c1-a0001 09-test-evidence/scratch/notes.txt row_precedes_this_generations_seal
  assert_ok "the wrong-digest pre-seal row is declared, never read" \
    ji_inputs "$ji_keep/g1" gpt-c1-a0001 09-test-evidence/x.txt row_precedes_this_generations_seal

  # Generation 1 gains a leaky post-judge file by a route the writer would refuse, never verifies,
  # and the run is recaptured. The generation-2 judge must not receive generation 1's file.
  mkdir -p "$ji_run/09-test-evidence/post-judge/g1"
  printf 'QA log excerpt from %s\n%s\n' "$ji_home" "$(printf -- '-----BEGIN %s PRIVATE KEY-----' RSA)" \
    > "$ji_run/09-test-evidence/post-judge/g1/log.md"; chmod 600 "$ji_run/09-test-evidence/post-judge/g1/log.md"
  t_python "$PJ_EVENT" "$FIRM_ROOT" "$ji_run" post_judge_artifact_published path=09-test-evidence/post-judge/g1/log.md \
    kind=disposition_evidence secondary_attempt_id=gpt-c1-a0001 @window @raw >/dev/null
  assert_fail "the leaky generation-1 file never verifies" seal_for_run "$ji_run" --verify --phase publication
  ( cd "$ji_repo" && git checkout -q "integration/$ji_id" && printf 'generation two\n' > gen2.txt \
    && git add gen2.txt && git commit -qm "generation two" && git checkout -q main ) >/dev/null 2>&1
  ji_sha2="$(sha_of "$ji_repo" "integration/$ji_id")"
  assert_ok "generation 2 is captured" sh -c "cd '$ji_repo' && '$BIN/firm-qa-checkout' --run '$ji_run' >/dev/null 2>&1"
  # Generation 2's own traceability cites no generation-1 evidence.
  printf '%s\n' 'schema_version: 2' 'task_slug: seal-fixture' 'candidate: {}' 'matrix: []' 'two_voice: {}' \
    'two_voice_diff: []' > "$ji_run/traceability.yaml"
  assert_ok "generation 2 republishes its producers" publish_generation_producers "$ji_run" "$ji_sha2" 2 test/Q-02 package/P-02
  assert_ok "generation 2 seals" seal_for_run "$ji_run"
  ji_verdict "$ji_keep/g2/block.json" "$ji_sha2" 2
  ji_rc=0; ji_judge "$ji_keep/g2/block.json" "$ji_keep/g2" || ji_rc=$?
  assert_eq "the generation-2 judge runs" 1 "$ji_rc"
  assert_output "…and promotes its own BLOCK, so it really assembled its input" '"attempt_id": "gpt-c2-a0001"' \
    cat "$ji_run/08-qa-verdict.gpt.json"
  assert_ok "generation 1's never-verified post-judge file is declared, never copied, and leaks nothing" \
    ji_inputs "$ji_keep/g2" gpt-c2-a0001 09-test-evidence/post-judge/g1/log.md row_precedes_this_generations_seal
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
