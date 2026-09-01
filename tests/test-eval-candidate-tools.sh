#!/usr/bin/env bash
# Candidate capsule, execution receipts, and eval-only P2 authority.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTH="$BIN/firm-eval-authority"
RUNNER="$BIN/firm-run-evals"
LOG="$BIN/firm-ledger-log"
SCHEMA="$FIRM_ROOT/agent-firm/schemas/eval-execution-authority.schema.json"

t_case "the authority protocol is recursively closed and production predicates stay single-source"
assert_ok "authority schema is valid and every object boundary is closed" t_python - "$SCHEMA" <<'PY'
import json,sys
from jsonschema import Draft202012Validator
d=json.load(open(sys.argv[1])); Draft202012Validator.check_schema(d)
def walk(value,path="$"):
    if isinstance(value,dict):
        if value.get("type")=="object": assert value.get("additionalProperties") is False,path
        for key,item in value.items(): walk(item,path+"."+key)
    elif isinstance(value,list):
        for index,item in enumerate(value): walk(item,path+"[%d]"%index)
walk(d)
PY
assert_eq "SUPPORTED_P2_OS_ROWS remains defined exactly once" 1 \
  "$(rg -l '^SUPPORTED_P2_OS_ROWS = ' "$FIRM_ROOT"/bin | wc -l | tr -d ' ')"
assert_eq "firm-python carries no production OS-row copy" 0 \
  "$(rg -c '26\.5\.1|26\.6\.1' "$BIN/firm-python" || printf '0\n')"
assert_output "runner pins the provider PATH to candidate shims plus system roots" \
  'candidate_path="$control/shims:/usr/bin:/bin:/usr/sbin:/sbin"' cat "$RUNNER"
assert_output "the provider executable is resolved before PATH confinement" \
  'provider_executable=' cat "$RUNNER"

t_case "environment-only or brokerless P2 claims fail before ledger residue"
bad_repo="$(mk_repo)"; mk_run "$bad_repo" bad-authority
bad_run="$bad_repo/.agent-firm/runs/bad-authority"
assert_rc "a copied token without a live broker is INPUT_INVALID" 2 env \
  FIRM_EVAL_P2_ATTESTATION='{}' FIRM_EVAL_AUTHORITY_REQUEST_ROOT=/tmp/absent-firm-eval-requests \
  FIRM_EVAL_AUTHORITY_RESPONSE_ROOT=/tmp/absent-firm-eval-responses \
  FIRM_EVAL_AUTHORITY_BIN="$AUTH" FIRM_EVAL_AUTHORITY_MANIFEST=/tmp/absent-firm-eval-manifest \
  FIRM_EVAL_AUTHORITY_DIGEST="$(printf '0%.0s' {1..64})" \
  FIRM_EVAL_INVOCATION="$(printf '0%.0s' {1..48})" \
  "$LOG" --run "$bad_run" --strict --print-event-id --event-id evt-bad-authority probe kind=bad
assert_no_file "brokerless claim creates no ledger" "$bad_run/run.jsonl"
assert_no_file "brokerless claim creates no lock" "$bad_run/run.jsonl.lock"
assert_eq "brokerless claim creates no transaction temp" 0 \
  "$(find "$bad_run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"

t_case "all four authenticated barriers overlap an independent mutator and fail closed"
for phase in manifest_read dispatch_commit use_exec cleanup_commit; do
  barrier_root="$(mktemp -d "${TMPDIR:-/tmp}/firm-eval-barrier.XXXXXX")"; t_track "$barrier_root"; chmod 700 "$barrier_root"
  token="$(t_python -c 'import secrets; print(secrets.token_hex(32))')"
  invocation="$(t_python -c 'import secrets; print(secrets.token_hex(24))')"
  target="$barrier_root/target"; printf 'before-%s\n' "$phase" > "$target"; chmod 600 "$target"
  t_python - "$barrier_root" "$token" "$phase" "$invocation" "$target" <<'PY' &
import json,os,sys,time
root,token,phase,invocation,target=sys.argv[1:]
prefix=os.path.join(root,token+"."+phase)
ready,mutated,resume,release=[prefix+suffix for suffix in (".ready",".mutated",".resume",".release")]
deadline=time.monotonic()+10
while time.monotonic()<deadline and not os.path.exists(ready): time.sleep(.002)
if not os.path.exists(ready): raise SystemExit(3)
authority=json.load(open(ready,encoding="ascii"))["authority_pid"]
os.kill(authority,0)
original=target+".original"; os.rename(target,original)
fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
os.write(fd,("mutated-%s\n"%phase).encode("ascii")); os.fsync(fd); os.close(fd)
record={"schema_version":1,"phase":phase,"token":token,"invocation":invocation,
        "mutator_pid":os.getpid(),"mutate_monotonic_ns":time.monotonic_ns(),
        "changed":{"original":original,"replacement":target}}
fd=os.open(mutated,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
os.write(fd,(json.dumps(record,sort_keys=True,separators=(",",":"))+"\n").encode("ascii")); os.close(fd)
while time.monotonic()<deadline and not os.path.exists(resume): time.sleep(.002)
if not os.path.exists(resume): raise SystemExit(4)
release_doc={"schema_version":1,"phase":phase,"token":token,"invocation":invocation,
             "mutator_pid":os.getpid(),"release_monotonic_ns":time.monotonic_ns()}
fd=os.open(release,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
os.write(fd,(json.dumps(release_doc,sort_keys=True,separators=(",",":"))+"\n").encode("ascii")); os.close(fd)
PY
  mutator=$!
  "$AUTH" test-barrier-probe --root "$barrier_root" --token "$token" --invocation "$invocation" \
    --candidate a57a8d0b4754ed92b74c023c340aab3154845abb --phase "$phase" --target "$target" \
    > "$barrier_root/authority.out" 2> "$barrier_root/authority.err"
  barrier_rc=$?
  wait "$mutator"; mutator_rc=$?
  if [ "$barrier_rc" -eq 2 ] && [ "$mutator_rc" -eq 0 ] \
      && grep -q "concurrent $phase mutation detected" "$barrier_root/authority.err"; then
    _t_ok "$phase overlaps a live authority and is rejected after release"
  else
    _t_no "$phase overlaps a live authority and is rejected after release" "authority_rc=$barrier_rc mutator_rc=$mutator_rc"
  fi
done

t_case "clean exact candidate gets one-use execution and P2-consumption receipts"
if [ -n "$(git -C "$FIRM_ROOT" status --porcelain --untracked-files=all)" ]; then
  t_skip "live capsule dynamic" "candidate checkout is dirty; prepare correctly refuses an ambiguous candidate"
else
  guardian="$($AUTH guardian-start --parent /private/tmp --launcher-pid $$)"
  scratch="$(printf '%s\n' "$guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["capsule"])')"
  control="$(printf '%s\n' "$guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["control"])')"
  guardian_root="$(printf '%s\n' "$guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["root"])')"
  guardian_token="$(printf '%s\n' "$guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  guardian_pid="$(printf '%s\n' "$guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["guardian_pid"])')"
  guardian_marker="$(printf '%s\n' "$guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["failure_marker"])')"
  invocation="$(printf '%s\n' "$guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["invocation"])')"
  mkdir -p "$scratch/.eval-out"
  prepared="$($AUTH prepare --root "$FIRM_ROOT" --eval final-evidence-seal --provider codex \
    --provider-executable /usr/bin/true --guardian-root "$guardian_root" --guardian-pid "$guardian_pid" \
    --guardian-token "$guardian_token" --guardian-failure-marker "$guardian_marker" --invocation "$invocation" \
    --scratch "$scratch" --fixture "$FIRM_ROOT/agent-firm/evals/final-evidence-seal/fixture" \
    --manifest "$control/manifest.json" --shims "$control/shims" \
    --request-root "$scratch/.eval-out/authority-requests" --response-root "$control/responses")"
  digest="$(printf '%s\n' "$prepared" | t_python -c 'import json,sys; print(json.load(sys.stdin)["manifest_digest"])')"
  project="$(printf '%s\n' "$prepared" | t_python -c 'import json,sys; print(json.load(sys.stdin)["project_root"])')"
  authority_bin="$(printf '%s\n' "$prepared" | t_python -c 'import json,sys; print(json.load(sys.stdin)["authority_bin"])')"
  common="$(cd "$scratch/git-common" && pwd -P)"
  mkdir -p "$project/.agent-firm/runs/probe"
  chmod 700 "$project/.agent-firm" "$project/.agent-firm/runs" "$project/.agent-firm/runs/probe"
  assert_no_file "outer capsule is not a repository" "$scratch/.git"
  assert_eq "nested project resolves only to sibling common-dir" "$common" \
    "$(git -C "$project" rev-parse --path-format=absolute --git-common-dir)"
  assert_eq "candidate anchor is immutable payload" a57a8d0b4754ed92b74c023c340aab3154845abb \
    "$(git -C "$project" rev-parse refs/firm-eval/candidate)"
  assert_ok "exact Seatbelt wrapper denies canonical and alias real-common reads/writes" \
    "$AUTH" seatbelt-probe --manifest "$control/manifest.json" --digest "$digest" --invocation "$invocation"
  guardian_sequence=1
  "$AUTH" guardian-exec --control "$control" --token "$guardian_token" --invocation "$invocation" --sequence "$guardian_sequence" -- \
    "$AUTH" serve --manifest "$control/manifest.json" --digest "$digest" --invocation "$invocation" \
    --request-root "$scratch/.eval-out/authority-requests" --response-root "$control/responses" \
    --receipts "$control/receipts.jsonl" &
  broker=$!
  ready=0; count=0
  while [ "$count" -lt 100 ]; do
    [ -f "$control/receipts.jsonl" ] && { ready=1; break; }
    kill -0 "$broker" 2>/dev/null || break
    sleep 0.02; count=$((count+1))
  done
  if [ "$ready" -eq 1 ]; then
    capsule_path="$control/shims:/usr/bin:/bin:/usr/sbin:/sbin"
    shell_env="$(printf '%s\n' "$prepared" | t_python -c 'import json,sys; print(json.load(sys.stdin)["shell_env"])')"
    login_tool="$(PATH="$capsule_path" ZDOTDIR="$shell_env" /bin/zsh -lc 'command -v firm-ledger-log')"
    assert_ok "a login zsh cannot reset the candidate command capsule" t_python -c \
      'import os,sys; assert os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2])' \
      "$control/shims/firm-ledger-log" "$login_tool"
    output="$(PATH="$capsule_path" ZDOTDIR="$shell_env" BASH_ENV="$shell_env/.bash-env" ENV="$shell_env/.sh-env" FIRM_EVAL_AUTHORITY_BIN="$authority_bin" \
      FIRM_EVAL_AUTHORITY_REQUEST_ROOT="$scratch/.eval-out/authority-requests" FIRM_EVAL_AUTHORITY_RESPONSE_ROOT="$control/responses" FIRM_EVAL_AUTHORITY_MANIFEST="$control/manifest.json" \
      FIRM_EVAL_AUTHORITY_DIGEST="$digest" FIRM_EVAL_INVOCATION="$invocation" firm-ledger-log \
      --run "$project/.agent-firm/runs/probe" --strict --print-event-id --event-id evt-capsule-pass probe kind=modeled)"
    assert_eq "attested candidate writer succeeds" evt-capsule-pass "$output"
    kill "$broker" 2>/dev/null; wait "$broker" 2>/dev/null || true
    summary="$($AUTH verify --manifest "$control/manifest.json" --digest "$digest" --receipts "$control/receipts.jsonl")"
    assert_ok "summary binds exact patch and one consumed P2 token" t_python -c \
      'import json,sys; d=json.loads(sys.argv[1]); assert d["patch_bytes"]==144413 and d["patch_sha256"]=="7e79d4dc34a7fdcf540781fee5a35c006b6dc4aefabfbac1636c5b855c502829" and d["execution_receipts"]>=1 and d["p2_receipts"]>=1' "$summary"
    assert_file "attested writer publishes exactly one ledger" "$project/.agent-firm/runs/probe/run.jsonl"

    t_case "protected Git identity, indirection, hook, ref, and environment mutations fail closed"
    verify_capsule() { "$AUTH" verify --manifest "$control/manifest.json" --digest "$digest" --receipts "$control/receipts.jsonl"; }
    config="$common/config"; config_copy="$control/config.original"; cp "$config" "$config_copy"
    chmod 600 "$config"; printf '[remote "escape"]\n\turl = file:///tmp/escape\n' >> "$config"
    assert_rc "remote/config mutation is rejected" 2 verify_capsule
    cp "$config_copy" "$config"; chmod 400 "$config"
    candidate_ref="$common/refs/firm-eval/candidate"; chmod 600 "$candidate_ref"
    printf '%s\n' 369c86b18027281fcfec1288efaa1255df315c35 > "$candidate_ref"
    assert_rc "protected candidate ref mutation is rejected" 2 verify_capsule
    printf '%s\n' a57a8d0b4754ed92b74c023c340aab3154845abb > "$candidate_ref"; chmod 400 "$candidate_ref"
    ln -s "$FIRM_ROOT/.git/objects" "$common/objects/info/alternates"
    assert_rc "symlinked alternate/object escape is rejected" 2 verify_capsule
    rm "$common/objects/info/alternates"
    chmod 700 "$scratch/no-hooks"
    printf '#!/bin/sh\nexit 99\n' > "$scratch/no-hooks/pre-commit"; chmod 700 "$scratch/no-hooks/pre-commit"
    assert_rc "hook appearance is rejected" 2 verify_capsule
    rm "$scratch/no-hooks/pre-commit"; chmod 500 "$scratch/no-hooks"
    pack_file="$(find "$common/objects/pack" -type f -name '*.pack' -print -quit)"
    ln "$pack_file" "$scratch/protected-pack-hardlink"
    assert_rc "hardlinked protected object is rejected" 2 verify_capsule
    rm "$scratch/protected-pack-hardlink"
    gitfile_raw="$(cat "$project/.git")"; chmod 600 "$project/.git"
    printf 'gitdir: %s\n' "$FIRM_ROOT/.git" > "$project/.git"
    assert_rc "gitfile/common-dir escape is rejected" 2 verify_capsule
    printf '%s\n' "$gitfile_raw" > "$project/.git"; chmod 400 "$project/.git"
    assert_rc "unsafe GIT_DIR cannot reach the authority broker" 2 env GIT_DIR="$FIRM_ROOT/.git" \
      PATH="$capsule_path" ZDOTDIR="$shell_env" BASH_ENV="$shell_env/.bash-env" ENV="$shell_env/.sh-env" \
      FIRM_EVAL_AUTHORITY_BIN="$authority_bin" FIRM_EVAL_AUTHORITY_REQUEST_ROOT="$scratch/.eval-out/authority-requests" \
      FIRM_EVAL_AUTHORITY_RESPONSE_ROOT="$control/responses" FIRM_EVAL_AUTHORITY_MANIFEST="$control/manifest.json" \
      FIRM_EVAL_AUTHORITY_DIGEST="$digest" FIRM_EVAL_INVOCATION="$invocation" firm-ledger-log \
      --run "$project/.agent-firm/runs/probe" --strict --print-event-id --event-id evt-must-not-exist probe kind=escape
    assert_output "rejection has no ledger side effect" 'evt-capsule-pass' tail -1 "$project/.agent-firm/runs/probe/run.jsonl"
    linked="$project/.agent-firm/worktrees/contained-probe"
    assert_ok "normal Git linked worktree writes only contained administration" git -C "$project" worktree add -q -b contained-probe "$linked" HEAD
    assert_eq "linked worktree common-dir remains contained" "$common" \
      "$(git -C "$linked" rev-parse --path-format=absolute --git-common-dir)"
    assert_ok "normal Git linked worktree cleanup stays contained" git -C "$project" worktree remove "$linked"
    chmod 755 "$scratch"
    assert_rc "cleanup refuses ambiguous capsule mode" 2 "$AUTH" cleanup --manifest "$control/manifest.json" --digest "$digest" \
      --invocation "$invocation" --control "$control" --token "$guardian_token" --sequence 2
    chmod 700 "$scratch"
    assert_ok "guardian removes complete capsule" "$AUTH" cleanup --manifest "$control/manifest.json" --digest "$digest" \
      --invocation "$invocation" --control "$control" --token "$guardian_token" --sequence 2
    assert_no_file "capsule leaves no reusable residue" "$guardian_root"
  else
    kill "$broker" 2>/dev/null || true; wait "$broker" 2>/dev/null || true
    _t_no "private authority broker starts" "socket unavailable"
  fi
fi

t_summary
