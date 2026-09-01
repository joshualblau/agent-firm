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

t_case "clean exact candidate gets one-use execution and P2-consumption receipts"
if [ -n "$(git -C "$FIRM_ROOT" status --porcelain --untracked-files=all)" ]; then
  t_skip "live capsule dynamic" "candidate checkout is dirty; prepare correctly refuses an ambiguous candidate"
else
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/firm-eval-capsule.XXXXXX")"; t_track "$scratch"
  chmod 700 "$scratch"
  git -C "$scratch" init -q
  git -C "$scratch" symbolic-ref HEAD refs/heads/main
  printf 'seed\n' > "$scratch/seed"
  git -C "$scratch" add seed
  git -C "$scratch" -c commit.gpgsign=false -c user.email=test@firm -c user.name=test commit -qm seed
  mkdir -p "$scratch/.agent-firm/runs/probe"
  chmod 700 "$scratch/.agent-firm" "$scratch/.agent-firm/runs" "$scratch/.agent-firm/runs/probe"
  mkdir -p "$scratch/.eval-out"
  control="$(mktemp -d "${TMPDIR:-/tmp}/firm-eval-control.XXXXXX")"; t_track "$control"; chmod 700 "$control"
  prepared="$($AUTH prepare --root "$FIRM_ROOT" --eval final-evidence-seal --provider codex \
    --scratch "$scratch" --manifest "$control/manifest.json" --shims "$control/shims" \
    --request-root "$scratch/.eval-out/authority-requests" --response-root "$control/responses")"
  digest="$(printf '%s\n' "$prepared" | t_python -c 'import json,sys; print(json.load(sys.stdin)["manifest_digest"])')"
  invocation="$(printf '%s\n' "$prepared" | t_python -c 'import json,sys; print(json.load(sys.stdin)["invocation"])')"
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
    output="$(PATH="$capsule_path" ZDOTDIR="$shell_env" BASH_ENV="$shell_env/.bash-env" ENV="$shell_env/.sh-env" FIRM_EVAL_AUTHORITY_BIN="$AUTH" \
      FIRM_EVAL_AUTHORITY_REQUEST_ROOT="$scratch/.eval-out/authority-requests" FIRM_EVAL_AUTHORITY_RESPONSE_ROOT="$control/responses" FIRM_EVAL_AUTHORITY_MANIFEST="$control/manifest.json" \
      FIRM_EVAL_AUTHORITY_DIGEST="$digest" FIRM_EVAL_INVOCATION="$invocation" firm-ledger-log \
      --run "$scratch/.agent-firm/runs/probe" --strict --print-event-id --event-id evt-capsule-pass probe kind=modeled)"
    assert_eq "attested candidate writer succeeds" evt-capsule-pass "$output"
    kill "$broker" 2>/dev/null; wait "$broker" 2>/dev/null || true
    summary="$($AUTH verify --manifest "$control/manifest.json" --digest "$digest" --receipts "$control/receipts.jsonl")"
    assert_ok "summary binds exact patch and one consumed P2 token" t_python -c \
      'import json,sys; d=json.loads(sys.argv[1]); assert d["patch_bytes"]==144413 and d["patch_sha256"]=="7e79d4dc34a7fdcf540781fee5a35c006b6dc4aefabfbac1636c5b855c502829" and d["execution_receipts"]>=1 and d["p2_receipts"]>=1' "$summary"
    assert_file "attested writer publishes exactly one ledger" "$scratch/.agent-firm/runs/probe/run.jsonl"
  else
    kill "$broker" 2>/dev/null || true; wait "$broker" 2>/dev/null || true
    _t_no "private authority broker starts" "socket unavailable"
  fi
fi

t_summary
