#!/usr/bin/env bash
# tests/test-ledger-compatibility.sh — independently derived four-family grammar and transaction.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$BIN/firm-ledger-log"
RESOLVER="$BIN/firm-model-resolve"
CODEX_ACTIVATION="$($RESOLVER --provider codex --role implementer --format activation)"
CLAUDE_ACTIVATION="$($RESOLVER --provider claude --role implementer --format activation)"
INTAKE_ACTIVATION="$($RESOLVER --provider codex --role intake-analyst --format activation)"
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
  invoke_native_contract "$repo" "$target" "$stage" implementer \
    role-contracts/R-01-implementer.md "$authority" "$activation" build_started /root/compat_implementer
}

invoke_native_contract() {
  local repo="$1" target="$2" stage="$3" role="$4" contract="$5" authority="$6"
  local activation="$7" event="$8" agent="$9"
  "$LOG" --run "$repo/.agent-firm/runs/$target" --strict --role-start \
    --stage "$stage" --role "$role" --contract "$contract" \
    --event "$event" --authority-json "$authority" --agent "$agent" \
    --activation-json "$activation"
}

make_contract() {
  local repo="$1" run="$2" relative="$3" path
  path="$repo/.agent-firm/runs/$run/$relative"
  mkdir -p "$(dirname "$path")"
  printf 'synthetic sealed compatibility contract\n' > "$path"
  chmod 644 "$path"
}

contract_path_for_length() {
  local repo="$1" run="$2" target="$3"
  python3 - "$repo/.agent-firm/runs/$run" "$target" <<'PY'
import os,sys
root,target=sys.argv[1],int(sys.argv[2])
prefix="role-contracts/"
remaining=target-len(prefix.encode("utf-8"))
parts=[]
while remaining > 128:
    parts.append("a"*128)
    remaining-=129
assert 4 <= remaining <= 128
parts.append("f"+"z"*(remaining-4)+".md")
relative=prefix+"/".join(parts)
assert len(relative.encode("utf-8"))==target
path=os.path.join(root,*relative.split("/"))
os.makedirs(os.path.dirname(path),exist_ok=True)
with open(path,"wb") as fh: fh.write(b"synthetic bounded path contract\n")
os.chmod(path,0o644)
print(relative)
PY
}

write_shell_case() {
  local path="$1" kind="$2"
  python3 - "$path" "$kind" <<'PY'
import json,sys
path,kind=sys.argv[1:]
values={
    "empty":"", "unicode":"synthetic-\u2603-\U0001f642", "newline":"synthetic\nline",
    "carriage":"synthetic\rreturn", "tab":"synthetic\ttab", "control":"synthetic\u000bvertical",
    "bytes4096":"x"*4096, "over4096":"y"*4097,
}
row={"ts":"2026-08-12T00:00:00Z","event":"bash","cmd":values.get(kind,"")}
if kind in ("line_below","line_at"):
    target=1048575 if kind=="line_below" else 1048576
    encoded=json.dumps(row,separators=(",",":"),ensure_ascii=False).encode("utf-8")
    row["cmd"]="p"*(target-len(encoded))
encoded=json.dumps(row,separators=(",",":"),ensure_ascii=False).encode("utf-8")
if kind=="line_below": assert len(encoded)==1048575
if kind=="line_at": assert len(encoded)==1048576
with open(path,"wb") as fh: fh.write(encoded+b"\n")
PY
}

write_invalid_shell_case() {
  local path="$1" kind="$2"
  python3 - "$path" "$kind" <<'PY'
import json,sys
path,kind=sys.argv[1:]
base={"ts":"2026-08-12T00:00:00Z","event":"bash","cmd":"synthetic"}
if kind.startswith("typed_"):
    base["cmd"]={"typed_null":None,"typed_bool":True,"typed_number":7,
                 "typed_list":[],"typed_object":{}}[kind]
elif kind=="missing_ts": del base["ts"]
elif kind=="missing_event": del base["event"]
elif kind=="missing_cmd": del base["cmd"]
elif kind=="extra_key": base["extra"]="x"
elif kind=="renamed_key": base["command"]=base.pop("cmd")
elif kind=="different_event": base["event"]="zsh"
elif kind=="invalid_timestamp": base["ts"]="not-a-time"
elif kind=="naive_timestamp": base["ts"]="2026-08-12T00:00:00"
if kind=="duplicate_key":
    raw=b'{"ts":"2026-08-12T00:00:00Z","event":"bash","cmd":"one","cmd":"two"}'
elif kind=="invalid_utf8":
    raw=b'{"ts":"2026-08-12T00:00:00Z","event":"bash","cmd":"'+bytes([255])+b'"}'
else:
    raw=json.dumps(base,separators=(",",":"),ensure_ascii=False).encode("utf-8")
if kind=="oversized":
    empty=json.dumps(base,separators=(",",":"),ensure_ascii=False).encode("utf-8")
    base["cmd"]="q"*(1048577-len(empty)+len(base["cmd"]))
    raw=json.dumps(base,separators=(",",":"),ensure_ascii=False).encode("utf-8")
    assert len(raw)==1048577
ending=b"" if kind=="incomplete" else b"\n"
with open(path,"wb") as fh: fh.write(raw+ending)
PY
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

assert_prewrite_support_rejection() {
  local label="$1" rejection="$2" mode="$3" repo run ledger before sentinel out rc
  repo="$(mk_repo)"; mk_run "$repo" target
  run="$repo/.agent-firm/runs/target"; ledger="$run/run.jsonl"
  printf '%s\n' \
    '{"ts":"2026-08-13T00:00:00Z","event":"p2_predecessor","event_id":"evt-p2-predecessor","run_id":"target","class":"synthetic"}' \
    > "$ledger"
  chmod 600 "$ledger"
  before="$(sha_or_absent "$ledger")"
  sentinel="$repo/p2-sentinel-$label"; printf 'outside sentinel\n' > "$sentinel"
  if [ "$mode" = strict ]; then
    out="$(FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT="$rejection" \
      "$LOG" --run "$run" --strict --print-event-id --event-id "evt-p2-$label" \
      p2_rejected class=synthetic 2> "$repo/p2.err")"; rc=$?
  else
    out="$(FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT="$rejection" \
      "$LOG" --run "$run" --print-event-id --event-id "evt-p2-$label" \
      p2_rejected class=synthetic 2> "$repo/p2.err")"; rc=$?
  fi
  assert_eq "$label $mode rejection is stable WRITE_CONFIGURATION_UNSUPPORTED" 17 "$rc"
  assert_eq "$label $mode rejection emits no success-shaped stdout" "" "$out"
  assert_output "$label $mode rejection diagnostic is sanitized" \
    "WRITE_CONFIGURATION_UNSUPPORTED: p2" cat "$repo/p2.err"
  assert_eq "$label $mode rejection leaves the ledger byte-identical" \
    "$before" "$(sha_or_absent "$ledger")"
  assert_eq "$label $mode rejection creates no transaction temp" 0 \
    "$(find "$run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
  assert_eq "$label $mode rejection does not create the coordination lock" 0 \
    "$(find "$run" -maxdepth 1 -name 'run.jsonl.lock' | wc -l | tr -d ' ')"
  assert_eq "$label $mode rejection leaves unrelated sentinels unchanged" \
    "outside sentinel" "$(cat "$sentinel")"
}

assert_descriptor_probe_pass() {
  local label="$1" behavior="$2" expected_bytes="$3" repo run state out rc
  repo="$(mk_repo)"; mk_run "$repo" target
  run="$repo/.agent-firm/runs/target"; state="$repo/descriptor-$label.json"
  out="$(FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_DESCRIPTOR_TEST_BEHAVIOR="$behavior" \
    FIRM_LEDGER_DESCRIPTOR_TEST_STATE="$state" "$LOG" --run "$run" --strict \
    --print-event-id --event-id "evt-descriptor-$label" descriptor_probe class=synthetic \
    2> "$repo/descriptor.err")"; rc=$?
  assert_eq "$label descriptor response permits the exact supported fact" 0 "$rc"
  assert_eq "$label descriptor response retains the ordinary receipt" "evt-descriptor-$label" "$out"
  assert_eq "$label descriptor response emits no diagnostic" "" "$(cat "$repo/descriptor.err")"
  assert_ok "$label descriptor helper is exact, reaped, and bounded" python3 - \
    "$state" "$expected_bytes" <<'PY'
import json,os,sys
state=json.load(open(sys.argv[1],encoding="utf-8")); expected=int(sys.argv[2])
assert state["status"]=="success" and state["eventual_reaped"] is True
assert state["second_wait_unavailable"] is True
assert oct(os.stat(sys.argv[1]).st_mode & 0o777)=="0o600"
assert isinstance(state["pid"],int) and state["pid"]>0
assert state["process_deadline_ns"]-state["started_ns"]==5_000_000_000
assert state["cleanup_deadline_ns"]-state["started_ns"]==6_000_000_000
assert state["retained_stdout_bytes"]<=256
if expected >= 0: assert state["retained_stdout_bytes"]==expected
try: os.kill(state["pid"],0)
except ProcessLookupError: pass
else: raise AssertionError("descriptor helper PID survived")
try: os.waitpid(state["pid"],os.WNOHANG)
except ChildProcessError: pass
else: raise AssertionError("descriptor helper remained waitable")
PY
}

assert_descriptor_probe_rejection() {
  local label="$1" behavior="$2" mode="$3" timing="$4" repo run ledger before state sentinel out rc elapsed_ns
  repo="$(mk_repo)"; mk_run "$repo" target
  run="$repo/.agent-firm/runs/target"; ledger="$run/run.jsonl"
  printf '%s\n' \
    '{"ts":"2026-08-13T00:00:00Z","event":"descriptor_predecessor","event_id":"evt-descriptor-predecessor","run_id":"target","class":"synthetic"}' \
    > "$ledger"; chmod 600 "$ledger"; before="$(sha_or_absent "$ledger")"
  state="$repo/descriptor-$label.json"
  sentinel="$repo/descriptor-sentinel-$label"; printf 'outside sentinel\n' > "$sentinel"
  if [ "$timing" = real ]; then
    assert_ok "$label production child is measured by one monotonic clock process" python3 - \
      "$LOG" "$run" "$state" "$repo/descriptor.out" "$repo/descriptor.err" \
      "$repo/descriptor.rc" "$repo/descriptor.elapsed-ns" "$label" <<'PY'
import os,subprocess,sys,time
log,run,state,out_path,err_path,rc_path,elapsed_path,label=sys.argv[1:]
env=os.environ.copy()
env.update(FIRM_LEDGER_TEST_GUARD="1",FIRM_LEDGER_DESCRIPTOR_TEST_BEHAVIOR="timeout",
           FIRM_LEDGER_DESCRIPTOR_TEST_STATE=state)
args=[log,"--run",run,"--strict","--print-event-id","--event-id",
      "evt-descriptor-"+label,"descriptor_probe","class=synthetic"]
started=time.monotonic_ns()
with open(out_path,"wb") as out,open(err_path,"wb") as err:
    result=subprocess.run(args,env=env,stdin=subprocess.DEVNULL,stdout=out,stderr=err,check=False)
elapsed=time.monotonic_ns()-started
open(rc_path,"w",encoding="ascii").write(str(result.returncode))
open(elapsed_path,"w",encoding="ascii").write(str(elapsed))
PY
    out="$(cat "$repo/descriptor.out")"; rc="$(cat "$repo/descriptor.rc")"
    elapsed_ns="$(cat "$repo/descriptor.elapsed-ns")"
  elif [ "$mode" = strict ]; then
    out="$(FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_DESCRIPTOR_TEST_BEHAVIOR="$behavior" \
      FIRM_LEDGER_DESCRIPTOR_TEST_STATE="$state" "$LOG" --run "$run" --strict \
      --print-event-id --event-id "evt-descriptor-$label" descriptor_probe class=synthetic \
      2> "$repo/descriptor.err")"; rc=$?
  else
    out="$(FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_DESCRIPTOR_TEST_BEHAVIOR="$behavior" \
      FIRM_LEDGER_DESCRIPTOR_TEST_STATE="$state" "$LOG" --run "$run" \
      --print-event-id --event-id "evt-descriptor-$label" descriptor_probe class=synthetic \
      2> "$repo/descriptor.err")"; rc=$?
  fi
  if [ "$timing" != real ]; then elapsed_ns=0; fi
  assert_eq "$label $mode descriptor rejection is stable WRITE_CONFIGURATION_UNSUPPORTED" 17 "$rc"
  assert_eq "$label $mode descriptor rejection emits no success" "" "$out"
  assert_output "$label $mode descriptor diagnostic is sanitized" \
    "WRITE_CONFIGURATION_UNSUPPORTED: p2" cat "$repo/descriptor.err"
  assert_eq "$label $mode descriptor rejection leaves the ledger byte-identical" \
    "$before" "$(sha_or_absent "$ledger")"
  assert_no_file "$label $mode descriptor rejection creates no coordination lock" "$run/run.jsonl.lock"
  assert_eq "$label $mode descriptor rejection creates no transaction temp" 0 \
    "$(find "$run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
  assert_eq "$label $mode descriptor rejection leaves unrelated sentinels unchanged" \
    "outside sentinel" "$(cat "$sentinel")"
  assert_ok "$label $mode descriptor state proves exact deadlines, bounded retention, and PID absence" \
    python3 - "$state" "$behavior" "$elapsed_ns" "$timing" <<'PY'
import json,os,sys
path,behavior,elapsed,timing=sys.argv[1:]; elapsed=int(elapsed)
state=json.load(open(path,encoding="utf-8"))
assert state["status"]=="failed"
assert state["process_deadline_ns"]-state["started_ns"]==5_000_000_000
assert state["cleanup_deadline_ns"]-state["started_ns"]==6_000_000_000
assert state["retained_stdout_bytes"]<=256
if timing=="real": assert 5_000_000_000 <= elapsed <= 6_500_000_000, elapsed
if behavior in {"ignore_term","terminate_error","wait_error","clock_deadlines"}:
    points=state["controlled_clock_observations_ns"]
    assert points[1]-points[0]==5_000_000_000
    assert points[2]-points[0]==6_000_000_000
if behavior=="ignore_term":
    assert state["cleanup_operations"]==[
        "terminate:success","wait_after_terminate:timeout","kill:success","final_wait:success"]
    assert state["cleanup_uncertain"] is False
if behavior=="terminate_error":
    assert state["cleanup_operations"]==["terminate:error","kill:success","final_wait:success"]
    assert state["cleanup_uncertain"] is True
if behavior=="wait_error":
    assert state["cleanup_operations"][0:2]==["terminate:success","wait_after_terminate:error"]
    assert state["cleanup_operations"][-1]=="final_wait:success"
    assert state["cleanup_uncertain"] is True
if behavior in {"timeout","ignore_term","terminate_error","wait_error","clock_deadlines","pipe_error"}:
    assert state["eventual_reaped"] is True
if state["eventual_reaped"]: assert state["second_wait_unavailable"] is True
if state["pid"] is not None:
    try: os.kill(state["pid"],0)
    except ProcessLookupError: pass
    else: raise AssertionError("descriptor helper PID survived")
    try: os.waitpid(state["pid"],os.WNOHANG)
    except ChildProcessError: pass
    else: raise AssertionError("descriptor helper remained waitable")
PY
}

assert_binding_namespace_control() {
  local mode="$1" repo run out rc expected
  repo="$(mk_repo)"; mk_run "$repo" target; run="$repo/.agent-firm/runs/target"
  if [ "$mode" = strict ]; then
    out="$(FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=bind_enoent \
      "$LOG" --run "$run" --strict --print-event-id namespace_control 2> "$repo/bind.err")"; rc=$?
    expected=1
  else
    out="$(FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=bind_enoent \
      "$LOG" --run "$run" --print-event-id namespace_control 2> "$repo/bind.err")"; rc=$?
    expected=0
  fi
  assert_eq "$mode namespace-family binding error retains ordinary invalid-run behavior" "$expected" "$rc"
  assert_eq "$mode namespace-family binding error emits no success" "" "$out"
  if [ "$mode" = strict ]; then
    assert_output "$mode namespace-family binding error retains the invalid-run diagnostic" \
      "cannot bind run namespace" cat "$repo/bind.err"
  else
    assert_eq "$mode namespace-family binding error retains silent fallback" "" \
      "$(cat "$repo/bind.err")"
  fi
  assert_no_file "$mode namespace-family binding error creates no ledger" "$run/run.jsonl"
  assert_no_file "$mode namespace-family binding error creates no lock" "$run/run.jsonl.lock"
  assert_eq "$mode namespace-family binding error creates no transaction temp" 0 \
    "$(find "$run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
}

wait_ready() {
  local ready="$1" n=0
  while [ ! -f "$ready" ] && [ "$n" -lt 1000 ]; do n=$((n+1)); sleep 0.01; done
  [ -f "$ready" ]
}

t_case "the centralized exact-P2 support gate accepts the local row before ordinary mutation"
repo_p2_positive="$(mk_repo)"; mk_run "$repo_p2_positive" target
run_p2_positive="$repo_p2_positive/.agent-firm/runs/target"
p2_positive_barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-p2-positive.XXXXXX")"
t_track "$p2_positive_barrier"
( FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_BARRIER_PHASE=after_support_gate \
    FIRM_LEDGER_BARRIER_DIR="$p2_positive_barrier" FIRM_LEDGER_BARRIER_TOKEN=writer \
    "$LOG" --run "$run_p2_positive" --strict --print-event-id \
    --event-id evt-p2-positive p2_positive class=synthetic \
    > "$p2_positive_barrier/out" 2> "$p2_positive_barrier/err"; \
    printf '%s' "$?" > "$p2_positive_barrier/rc" ) & p2_positive_pid=$!
assert_ok "ordinary writer reaches the shared support gate on the exact local P2 row" \
  wait_ready "$p2_positive_barrier/writer.ready"
assert_no_file "support-gate boundary precedes ledger creation" "$run_p2_positive/run.jsonl"
assert_no_file "support-gate boundary precedes coordination-lock creation" "$run_p2_positive/run.jsonl.lock"
assert_eq "support-gate boundary precedes transaction-temp creation" 0 \
  "$(find "$run_p2_positive" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
printf 'release\n' > "$p2_positive_barrier/writer.release"; wait "$p2_positive_pid"
assert_eq "exact local P2 row permits the unchanged ordinary receipt" 0 \
  "$(cat "$p2_positive_barrier/rc")"
assert_eq "exact local P2 row returns the requested ordinary id" evt-p2-positive \
  "$(cat "$p2_positive_barrier/out")"

t_case "every unsupported or unverifiable P2 dimension and capability fails before ordinary writes"
for spec in \
  linux:linux unknown:unknown_platform \
  macos_mismatch:macos_version_mismatch macos_unknown:macos_version_unverifiable \
  kernel_mismatch:kernel_version_mismatch kernel_unknown:kernel_version_unverifiable \
  arch_mismatch:architecture_mismatch arch_unknown:architecture_unverifiable \
  python_mismatch:python_version_mismatch python_unknown:python_version_unverifiable \
  fs_type:filesystem_type_mismatch fs_network:filesystem_locality_mismatch \
  fs_unknown:filesystem_unverifiable nofollow_missing:nofollow_missing \
  nofollow_zero:nofollow_invalid directory_missing:directory_missing \
  directory_zero:directory_invalid nonblock_missing:nonblock_missing \
  nonblock_zero:nonblock_invalid open_dir_fd:open_dir_fd_missing \
  stat_dir_fd:stat_dir_fd_missing stat_nofollow:stat_nofollow_missing \
  statvfs_fd:statvfs_fd_missing unlink_dir_fd:unlink_dir_fd_missing \
  replace:replace_missing replace_dir_fd:replace_dir_fd_missing \
  same_filesystem:same_filesystem_mismatch regular_file:regular_file_check_missing \
  file_fsync:file_fsync_missing directory_fsync:directory_fsync_missing flock:flock_missing; do
  p2_label="${spec%%:*}"; p2_rejection="${spec#*:}"
  assert_prewrite_support_rejection "$p2_label" "$p2_rejection" strict
done
assert_prewrite_support_rejection best_effort_linux linux best_effort

t_case "actual pre-bind primitive failures share the narrow support taxonomy in both ordinary modes"
for spec in \
  best_nofollow:nofollow_missing best_directory:directory_missing \
  best_open_dir_fd:open_dir_fd_missing best_type_error:bind_type_error \
  best_not_implemented:bind_not_implemented best_enotsup:bind_enotsup; do
  p2_label="${spec%%:*}"; p2_rejection="${spec#*:}"
  assert_prewrite_support_rejection "$p2_label" "$p2_rejection" best_effort
done
for spec in \
  bind_type_error:bind_type_error bind_not_implemented:bind_not_implemented \
  bind_enotsup:bind_enotsup; do
  p2_label="${spec%%:*}"; p2_rejection="${spec#*:}"
  assert_prewrite_support_rejection "$p2_label" "$p2_rejection" strict
done
assert_binding_namespace_control strict
assert_binding_namespace_control best_effort

t_case "the P2 test seam is negative-only, guarded, and cannot broaden positive support"
repo_p2_seam="$(mk_repo)"; mk_run "$repo_p2_seam" target
run_p2_seam="$repo_p2_seam/.agent-firm/runs/target"
p2_seam_out="$(FIRM_LEDGER_P2_TEST_REJECT=linux \
  "$LOG" --run "$run_p2_seam" --strict p2_seam 2> "$repo_p2_seam/unguarded.err")"
assert_eq "unguarded P2 rejection seam is INPUT_INVALID" 2 "$?"
assert_eq "unguarded P2 rejection seam emits no success" "" "$p2_seam_out"
assert_no_file "unguarded P2 rejection seam creates no ledger" "$run_p2_seam/run.jsonl"
p2_seam_out="$(FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_P2_TEST_REJECT=supported \
  "$LOG" --run "$run_p2_seam" --strict p2_seam 2> "$repo_p2_seam/broaden.err")"
assert_eq "positive-support seam value is outside the closed vocabulary" 2 "$?"
assert_eq "positive-support seam value emits no success" "" "$p2_seam_out"
assert_no_file "positive-support seam value creates no ledger" "$run_p2_seam/run.jsonl"
assert_no_file "negative-only seam creates no coordination lock" "$run_p2_seam/run.jsonl.lock"
assert_eq "negative-only seam creates no transaction temp" 0 \
  "$(find "$run_p2_seam" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
descriptor_seam_out="$(FIRM_LEDGER_DESCRIPTOR_TEST_BEHAVIOR=nonzero \
  "$LOG" --run "$run_p2_seam" --strict descriptor_seam 2> "$repo_p2_seam/descriptor-unguarded.err")"
assert_eq "unguarded descriptor probe seam is INPUT_INVALID" 2 "$?"
assert_eq "unguarded descriptor probe seam emits no success" "" "$descriptor_seam_out"
assert_no_file "unguarded descriptor probe seam creates no ledger" "$run_p2_seam/run.jsonl"

t_case "descriptor helper proves the production ABI/local APFS fact and exact 256-byte response boundary"
assert_descriptor_probe_pass production success -1
assert_descriptor_probe_pass response_256 cap_256 256
assert_descriptor_probe_rejection response_257 cap_257 strict instant

t_case "descriptor helper rejects ABI, syscall, schema, type, encoding, duplicate, trailing, exit, and P2 ambiguity"
for behavior in \
  abi_size abi_flags_offset abi_fstypename_offset symbol syscall \
  schema_missing schema_extra schema_version_type filesystem_type flags_type \
  invalid_utf8 duplicate trailing nonzero filesystem_mismatch locality_mismatch \
  flags_negative flags_overflow popen_error pass_fds_error pipe_error; do
  assert_descriptor_probe_rejection "$behavior" "$behavior" strict instant
done

t_case "one 5+1-second lifetime reaps blocked, TERM-ignored, and cleanup-operation-failure helpers"
assert_descriptor_probe_rejection timeout timeout strict real
assert_descriptor_probe_rejection ignore_term ignore_term strict controlled
assert_descriptor_probe_rejection terminate_error terminate_error best_effort controlled
assert_descriptor_probe_rejection wait_error wait_error strict controlled
assert_descriptor_probe_rejection clock_deadlines clock_deadlines strict controlled

t_case "representative descriptor cap and cleanup failures reject before ordinary best-effort fallback"
assert_descriptor_probe_rejection best_response_257 cap_257 best_effort instant
assert_descriptor_probe_rejection best_terminate_error terminate_error best_effort controlled

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

t_case "shell observation JSON strings span controls, Unicode, field size, and exact row boundaries"
for kind in empty unicode newline carriage tab control bytes4096 over4096 line_below line_at; do
  repo_shell="$(mk_repo)"; mk_run "$repo_shell" target
  ledger_shell="$repo_shell/.agent-firm/runs/target/run.jsonl"
  write_shell_case "$ledger_shell" "$kind"; chmod 600 "$ledger_shell"
  cp "$ledger_shell" "$repo_shell/shell-prefix.bin"
  shell_id="evt-shell-$kind"
  shell_out="$($LOG --run "$repo_shell/.agent-firm/runs/target" --strict --print-event-id \
    --event-id "$shell_id" compatibility_followed "case=$kind")"; shell_rc=$?
  assert_eq "$kind shell predecessor appends successfully" 0 "$shell_rc"
  assert_eq "$kind shell append returns its exact producer id" "$shell_id" "$shell_out"
  assert_ok "$kind shell prefix and non-authoritative identity are exact" python3 - \
    "$repo_shell/shell-prefix.bin" "$ledger_shell" "$kind" "$shell_id" <<'PY'
import json,sys
before_path,after_path,kind,event_id=sys.argv[1:]
before=open(before_path,"rb").read(); after=open(after_path,"rb").read()
assert after.startswith(before)
seed=json.loads(before.decode("utf-8")); rows=[json.loads(x) for x in after.decode("utf-8").splitlines()]
assert len(rows)==2 and rows[0]==seed and rows[1]["event_id"]==event_id
assert not ({"event_id","run_id","activation","authority","stage","role"}&set(seed))
cmd=seed["cmd"]
checks={"empty":cmd=="", "unicode":"\u2603" in cmd and "\U0001f642" in cmd,
        "newline":"\n" in cmd, "carriage":"\r" in cmd, "tab":"\t" in cmd,
        "control":"\u000b" in cmd, "bytes4096":len(cmd.encode())==4096,
        "over4096":len(cmd.encode())>4096, "line_below":len(before)-1==1048575,
        "line_at":len(before)-1==1048576}
assert checks[kind]
PY
done

t_case "closed shell observation negatives fail with stable class and immutable target and authority bytes"
repo_shell_bad="$(mk_repo)"; mk_eligible_run "$repo_shell_bad" source
printf '%s\n' \
  '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"source"}' \
  > "$repo_shell_bad/.agent-firm/runs/source/run.jsonl"
chmod 600 "$repo_shell_bad/.agent-firm/runs/source/run.jsonl"
shell_bad_auth="$(authority_json source "$AUTH_ID" architecture_completed '{"proof":"accepted"}')"
for kind in typed_null typed_bool typed_number typed_list typed_object missing_ts missing_event missing_cmd \
  extra_key renamed_key different_event invalid_timestamp naive_timestamp duplicate_key invalid_utf8 incomplete oversized; do
  target_shell_bad="negative-$kind"; mk_eligible_run "$repo_shell_bad" "$target_shell_bad"
  ledger_shell_bad="$repo_shell_bad/.agent-firm/runs/$target_shell_bad/run.jsonl"
  write_invalid_shell_case "$ledger_shell_bad" "$kind"; chmod 600 "$ledger_shell_bad"
  before_target_bad="$(sha_or_absent "$ledger_shell_bad")"
  before_authority_bad="$(sha_or_absent "$repo_shell_bad/.agent-firm/runs/source/run.jsonl")"
  shell_bad_out="$(invoke_native "$repo_shell_bad" "$target_shell_bad" build/R-01 \
    "$shell_bad_auth" "$CODEX_ACTIVATION" 2> "$repo_shell_bad/$kind.err")"; shell_bad_rc=$?
  assert_eq "$kind shell negative has stable ledger failure" 14 "$shell_bad_rc"
  assert_eq "$kind shell negative has no success-shaped stdout" "" "$shell_bad_out"
  assert_output "$kind shell negative reports only stable sanitized class" \
    "LEDGER_INVALID_OR_LOCK_FAILED" cat "$repo_shell_bad/$kind.err"
  assert_eq "$kind shell negative leaves target byte-identical" "$before_target_bad" \
    "$(sha_or_absent "$ledger_shell_bad")"
  assert_eq "$kind shell negative leaves authority byte-identical" "$before_authority_bad" \
    "$(sha_or_absent "$repo_shell_bad/.agent-firm/runs/source/run.jsonl")"
done

t_case "merge cmd preserves shell-string control whitespace and exact prefix in ordinary and native appends"
repo_merge_ordinary="$(mk_repo)"; mk_run "$repo_merge_ordinary" target
ledger_merge_ordinary="$repo_merge_ordinary/.agent-firm/runs/target/run.jsonl"
python3 - "$ledger_merge_ordinary" <<'PY'
import json,sys
row={"ts":"2026-08-13T17:58:49Z","event":"merge_guard_block",
     "cmd":"git -C /tmp/firm merge --ff-only topic \u2603\nstatus=$?\nprintf 'decision=%s\\n' cannot_evaluate\r\t\v",
     "decision":"cannot_evaluate",
     "reason":"tokenization preserved; repository observation unavailable"}
open(sys.argv[1],"wb").write(json.dumps(row,separators=(",",":"),ensure_ascii=False).encode()+b"\n")
PY
chmod 600 "$ledger_merge_ordinary"; cp "$ledger_merge_ordinary" "$repo_merge_ordinary/prefix.bin"
merge_ordinary_out="$($LOG --run "$repo_merge_ordinary/.agent-firm/runs/target" --strict \
  --print-event-id --event-id evt-merge-multiline-ordinary merge_followed class=synthetic)"
assert_eq "multiline merge cmd permits ordinary append" evt-merge-multiline-ordinary "$merge_ordinary_out"
assert_ok "ordinary append preserves every multiline-merge prefix byte" python3 - \
  "$repo_merge_ordinary/prefix.bin" "$ledger_merge_ordinary" <<'PY'
import json,sys
before=open(sys.argv[1],"rb").read(); after=open(sys.argv[2],"rb").read()
assert after.startswith(before) and len(after)>len(before)
row=json.loads(before)
assert "\n" in row["cmd"] and "\r" in row["cmd"] and "\t" in row["cmd"] and "\v" in row["cmd"]
assert "\u2603" in row["cmd"]
assert row["decision"]=="cannot_evaluate"
PY

repo_merge_native="$(mk_repo)"; mk_eligible_run "$repo_merge_native" target
mkdir -p "$repo_merge_native/.agent-firm/runs/source"
printf '%s\n' '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"source"}' \
  > "$repo_merge_native/.agent-firm/runs/source/run.jsonl"
chmod 600 "$repo_merge_native/.agent-firm/runs/source/run.jsonl"
ledger_merge_native="$repo_merge_native/.agent-firm/runs/target/run.jsonl"
cp "$repo_merge_ordinary/prefix.bin" "$ledger_merge_native"; chmod 600 "$ledger_merge_native"
cp "$ledger_merge_native" "$repo_merge_native/native-prefix.bin"
merge_native_auth="$(authority_json source "$AUTH_ID" architecture_completed '{"proof":"accepted"}')"
merge_native_out="$(invoke_native "$repo_merge_native" target build/R-01 \
  "$merge_native_auth" "$CODEX_ACTIVATION")"
assert_ok "multiline merge cmd permits native append with exact prefix" python3 - \
  "$repo_merge_native/native-prefix.bin" "$ledger_merge_native" "$merge_native_out" <<'PY'
import json,sys
before=open(sys.argv[1],"rb").read(); after=open(sys.argv[2],"rb").read(); result=json.loads(sys.argv[3])
assert after.startswith(before) and len(after)>len(before)
assert json.loads(before)["cmd"].startswith("git -C ")
assert result["event_id"]==json.loads(after[len(before):])["event_id"]
PY

repo_merge_max="$(mk_repo)"; mk_run "$repo_merge_max" target
ledger_merge_max="$repo_merge_max/.agent-firm/runs/target/run.jsonl"
python3 - "$ledger_merge_max" <<'PY'
import json,sys
row={"ts":"2026-08-12T00:00:00Z","event":"merge_guard_block","cmd":"\u2603",
     "decision":"cannot_evaluate","reason":"printable reason"}
base=json.dumps(row,separators=(",",":"),ensure_ascii=False).encode("utf-8")
row["cmd"]="\u2603"+"m"*(1_048_576-len(base))
raw=json.dumps(row,separators=(",",":"),ensure_ascii=False).encode("utf-8")
assert len(raw)==1_048_576 and len(row["cmd"].encode("utf-8"))>4096
open(sys.argv[1],"wb").write(raw+b"\n")
PY
chmod 600 "$ledger_merge_max"; cp "$ledger_merge_max" "$repo_merge_max/prefix.bin"
merge_max_out="$($LOG --run "$repo_merge_max/.agent-firm/runs/target" --strict \
  --print-event-id --event-id evt-merge-cmd-max merge_followed class=synthetic)"
assert_eq "Unicode merge cmd at the exact complete-row ceiling permits append" \
  evt-merge-cmd-max "$merge_max_out"
assert_ok "exact-ceiling merge append preserves all predecessor bytes" python3 - \
  "$repo_merge_max/prefix.bin" "$ledger_merge_max" <<'PY'
import sys
before=open(sys.argv[1],"rb").read(); after=open(sys.argv[2],"rb").read()
assert after.startswith(before) and len(after)>len(before)
PY

t_case "merge cmd widening remains confined to cmd, exact keys, and the complete encoded-row cap"
reject_seed merge_typed_cmd \
  '{"ts":"2026-08-12T00:00:00Z","event":"merge_guard_block","cmd":3,"decision":"block","reason":"protected"}\n'
for merge_negative in decision_control reason_control empty_decision empty_reason typed_decision typed_reason \
  extra missing renamed wrong_event invalid_timestamp duplicate invalid_utf8 incomplete oversized; do
  repo_merge_bad="$(mk_repo)"; mk_run "$repo_merge_bad" target
  ledger_merge_bad="$repo_merge_bad/.agent-firm/runs/target/run.jsonl"
  python3 - "$ledger_merge_bad" "$merge_negative" <<'PY'
import json,sys
path,kind=sys.argv[1:]
row={"ts":"2026-08-12T00:00:00Z","event":"merge_guard_block","cmd":"synthetic\ncmd",
     "decision":"cannot_evaluate","reason":"protected"}
if kind=="decision_control": row["decision"]="cannot\nevaluate"
elif kind=="reason_control": row["reason"]="pro\ttected"
elif kind=="empty_decision": row["decision"]=""
elif kind=="empty_reason": row["reason"]=""
elif kind=="typed_decision": row["decision"]=False
elif kind=="typed_reason": row["reason"]=["protected"]
elif kind=="extra": row["matched"]=False
elif kind=="missing": del row["reason"]
elif kind=="renamed": row["rationale"]=row.pop("reason")
elif kind=="wrong_event": row["event"]="merge_guard_allow"
elif kind=="invalid_timestamp": row["ts"]="not-a-time"
raw=json.dumps(row,separators=(",",":"),ensure_ascii=False).encode()
if kind=="duplicate": raw=raw[:-1]+b',"cmd":"second"}'
elif kind=="invalid_utf8": raw=raw.replace(b"protected",b"pro\xfftected")
elif kind=="oversized":
    row["cmd"]="x"
    base=json.dumps(row,separators=(",",":"),ensure_ascii=False).encode()
    row["cmd"]="m"*(1_048_577-len(base)+1)
    raw=json.dumps(row,separators=(",",":"),ensure_ascii=False).encode()
    assert len(raw)==1_048_577
ending=b"" if kind=="incomplete" else b"\n"
open(path,"wb").write(raw+ending)
PY
  chmod 600 "$ledger_merge_bad"; before_merge_bad="$(sha_or_absent "$ledger_merge_bad")"
  merge_bad_out="$($LOG --run "$repo_merge_bad/.agent-firm/runs/target" --strict \
    --print-event-id compatibility_followed 2>/dev/null)"; merge_bad_rc=$?
  assert_eq "$merge_negative merge negative fails closed" 1 "$merge_bad_rc"
  assert_eq "$merge_negative merge negative emits no id" "" "$merge_bad_out"
  assert_eq "$merge_negative merge negative leaves bytes unchanged" "$before_merge_bad" \
    "$(sha_or_absent "$ledger_merge_bad")"
done
ordinary_long="$(python3 -c 'print("o"*4097,end="")')"
repo_ordinary_bound="$(mk_repo)"; mk_run "$repo_ordinary_bound" target
ordinary_out="$($LOG --run "$repo_ordinary_bound/.agent-firm/runs/target" --strict --print-event-id \
  ordinary_bound "value=$ordinary_long" 2>/dev/null)"; ordinary_rc=$?
assert_eq "over-4096 ordinary extension remains rejected" 1 "$ordinary_rc"
assert_eq "over-4096 ordinary extension emits no id" "" "$ordinary_out"
assert_eq "ordinary bound rejection leaves target absent" absent \
  "$(sha_or_absent "$repo_ordinary_bound/.agent-firm/runs/target/run.jsonl")"

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

t_case "safe non-role-suffix contracts and exact 511/512-byte paths retain exact native projections"
repo_contract="$(mk_repo)"; mk_eligible_run "$repo_contract" source
printf '%s\n' \
  '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"source"}' \
  > "$repo_contract/.agent-firm/runs/source/run.jsonl"
chmod 600 "$repo_contract/.agent-firm/runs/source/run.jsonl"
contract_auth="$(authority_json source "$AUTH_ID" architecture_completed '{"proof":"accepted"}')"
for contract_case in intake nested path511 path512; do
  contract_target="contract-$contract_case"; mk_eligible_run "$repo_contract" "$contract_target"
  case "$contract_case" in
    intake) contract_relative=role-contracts/I-00-intake.md; make_contract "$repo_contract" "$contract_target" "$contract_relative" ;;
    nested) contract_relative=role-contracts/team/v1/sealed-input.md; make_contract "$repo_contract" "$contract_target" "$contract_relative" ;;
    path511) contract_relative="$(contract_path_for_length "$repo_contract" "$contract_target" 511)" ;;
    path512) contract_relative="$(contract_path_for_length "$repo_contract" "$contract_target" 512)" ;;
  esac
  contract_result="$(invoke_native_contract "$repo_contract" "$contract_target" intake/I-00 \
    intake-analyst "$contract_relative" "$contract_auth" "$INTAKE_ACTIVATION" \
    intake_started /root/compat_intake)"; contract_rc=$?
  assert_eq "$contract_case non-role-suffix native append succeeds" 0 "$contract_rc"
  assert_ok "$contract_case native result, retained event, and sealed projection are exact" python3 - \
    "$repo_contract/.agent-firm/runs/$contract_target/run.jsonl" \
    "$repo_contract/.agent-firm/runs/$contract_target/$contract_relative" \
    "$contract_result" "$contract_relative" "$contract_case" <<'PY'
import hashlib,json,os,sys
ledger,contract,result_raw,relative,case=sys.argv[1:]
raw=open(ledger,"rb").read(); assert raw.endswith(b"\n")
rows=[json.loads(x) for x in raw.decode("utf-8").splitlines()]
result=json.loads(result_raw); assert len(rows)==1
event=rows[0]
assert set(result)-{"schema_version"}==set(event)-{"ts"}
assert result["schema_version"]==1
for key in set(event)-{"ts"}: assert result[key]==event[key]
body=open(contract,"rb").read()
assert event["contract"]=={"path":relative,"bytes":len(body),
    "sha256":hashlib.sha256(body).hexdigest(),"mode":"0644"}
assert event["role"]=="intake-analyst" and event["activation"]["selector"]=="intake-analyst"
assert not os.path.basename(relative).endswith("-intake-analyst.md")
if case=="path511": assert len(relative.encode("utf-8"))==511
if case=="path512": assert len(relative.encode("utf-8"))==512
PY
  assert_rc "$contract_case retained native row remains a readable predecessor" 0 "$LOG" \
    --run "$repo_contract/.agent-firm/runs/$contract_target" --strict \
    --event-id "evt-contract-follow-$contract_case" native_followed "case=$contract_case"
done

t_case "unsafe and oversized contract paths, types, modes, and projection overrides remain fail-closed"
for contract_case in path513 over_component unsafe_component foreign_root empty_component dot_component \
  parent_component traversal absolute symlink directory wrong_mode; do
  contract_target="contract-negative-$contract_case"; mk_eligible_run "$repo_contract" "$contract_target"
  contract_run="$repo_contract/.agent-firm/runs/$contract_target"
  case "$contract_case" in
    path513) contract_relative="$(contract_path_for_length "$repo_contract" "$contract_target" 513)" ;;
    over_component) contract_relative="role-contracts/$(python3 -c 'print("a"*129,end="")').md"; make_contract "$repo_contract" "$contract_target" "$contract_relative" ;;
    unsafe_component) contract_relative=role-contracts/_unsafe.md; make_contract "$repo_contract" "$contract_target" "$contract_relative" ;;
    foreign_root) contract_relative=contracts/safe.md; make_contract "$repo_contract" "$contract_target" "$contract_relative" ;;
    empty_component) contract_relative=role-contracts//safe.md; make_contract "$repo_contract" "$contract_target" role-contracts/safe.md ;;
    dot_component) contract_relative=role-contracts/./safe.md; make_contract "$repo_contract" "$contract_target" role-contracts/safe.md ;;
    parent_component) contract_relative=role-contracts/nested/../safe.md; make_contract "$repo_contract" "$contract_target" role-contracts/safe.md ;;
    traversal) contract_relative=role-contracts/../../outside.md; printf 'outside sentinel\n' > "$repo_contract/outside.md" ;;
    absolute) contract_relative="$repo_contract/outside-absolute.md"; printf 'absolute sentinel\n' > "$contract_relative" ;;
    symlink)
      contract_relative=role-contracts/sealed-link.md; printf 'symlink sentinel\n' > "$repo_contract/symlink-target.md"
      ln -s "$repo_contract/symlink-target.md" "$contract_run/$contract_relative"
      ;;
    directory) contract_relative=role-contracts/sealed-dir.md; mkdir -p "$contract_run/$contract_relative" ;;
    wrong_mode) contract_relative=role-contracts/sealed-mode.md; make_contract "$repo_contract" "$contract_target" "$contract_relative"; chmod 600 "$contract_run/$contract_relative" ;;
  esac
  before_contract_target="$(sha_or_absent "$contract_run/run.jsonl")"
  before_contract_authority="$(sha_or_absent "$repo_contract/.agent-firm/runs/source/run.jsonl")"
  contract_bad_out="$(invoke_native_contract "$repo_contract" "$contract_target" intake/I-00 \
    intake-analyst "$contract_relative" "$contract_auth" "$INTAKE_ACTIVATION" \
    intake_started /root/compat_intake 2> "$repo_contract/$contract_case.err")"; contract_bad_rc=$?
  assert_eq "$contract_case contract request has stable failure" 12 "$contract_bad_rc"
  assert_eq "$contract_case contract request emits no success object" "" "$contract_bad_out"
  assert_output "$contract_case contract diagnostic is body-free and classified" CONTRACT_INVALID \
    cat "$repo_contract/$contract_case.err"
  assert_eq "$contract_case contract request leaves target byte-identical" "$before_contract_target" \
    "$(sha_or_absent "$contract_run/run.jsonl")"
  assert_eq "$contract_case contract request leaves authority byte-identical" "$before_contract_authority" \
    "$(sha_or_absent "$repo_contract/.agent-firm/runs/source/run.jsonl")"
  case "$contract_case" in
    traversal) assert_eq "traversal outside sentinel remains unchanged" "outside sentinel" "$(cat "$repo_contract/outside.md")" ;;
    absolute) assert_eq "absolute outside sentinel remains unchanged" "absolute sentinel" "$(cat "$repo_contract/outside-absolute.md")" ;;
    symlink) assert_eq "symlink target sentinel remains unchanged" "symlink sentinel" "$(cat "$repo_contract/symlink-target.md")" ;;
  esac
done

projection_target=contract-negative-projection; mk_eligible_run "$repo_contract" "$projection_target"
make_contract "$repo_contract" "$projection_target" role-contracts/I-00-intake.md
for projection in contract_path=role-contracts/forged.md contract_bytes=1 \
  contract_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa contract_mode=0600; do
  projection_out="$($LOG --run "$repo_contract/.agent-firm/runs/$projection_target" --strict --role-start \
    --stage intake/I-00 --role intake-analyst --contract role-contracts/I-00-intake.md \
    --event intake_started --authority-json "$contract_auth" --agent /root/compat_intake \
    --activation-json "$INTAKE_ACTIVATION" "$projection" 2>/dev/null)"; projection_rc=$?
  assert_eq "$projection caller override remains INPUT_INVALID" 2 "$projection_rc"
  assert_eq "$projection caller override emits no success object" "" "$projection_out"
  assert_eq "$projection caller override leaves target absent" absent \
    "$(sha_or_absent "$repo_contract/.agent-firm/runs/$projection_target/run.jsonl")"
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

t_case "sanitized representative ledger preserves its exact four-family prefix across two append kinds"
repo_rep="$(mk_repo)"; mk_eligible_run "$repo_rep" source; mk_eligible_run "$repo_rep" target
make_contract "$repo_rep" target role-contracts/I-00-intake.md
printf '%s\n' \
  '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"source"}' \
  > "$repo_rep/.agent-firm/runs/source/run.jsonl"
chmod 600 "$repo_rep/.agent-firm/runs/source/run.jsonl"
rep_auth="$(authority_json source "$AUTH_ID" architecture_completed '{"proof":"accepted"}')"
rep_seed_result="$(invoke_native_contract "$repo_rep" target intake/seed intake-analyst \
  role-contracts/I-00-intake.md "$rep_auth" "$INTAKE_ACTIVATION" intake_started /root/compat_intake)"
assert_rc "representative ordinary seed is producer-authored" 0 "$LOG" \
  --run "$repo_rep/.agent-firm/runs/target" --strict --event-id evt-representative-seed \
  representative_seed class=synthetic
python3 - "$repo_rep/.agent-firm/runs/target/run.jsonl" <<'PY'
import json,sys
path=sys.argv[1]
rows=[
 {"ts":"2026-08-12T00:00:00Z","event":"bash","cmd":"synthetic\nline\tsegment"},
 {"ts":"2026-08-12T00:00:01Z","event":"bash","cmd":"s"*5000+"\rterminal"},
 {"ts":"2026-08-12T00:00:02Z","event":"merge_guard_block","cmd":"synthetic merge observation",
  "decision":"block","reason":"protected"},
]
with open(path,"ab") as fh:
    for row in rows:
        fh.write(json.dumps(row,separators=(",",":"),ensure_ascii=False).encode("utf-8")+b"\n")
PY
cp "$repo_rep/.agent-firm/runs/target/run.jsonl" "$repo_rep/representative-prefix.bin"
python3 - "$repo_rep/representative-prefix.bin" "$repo_rep/representative-prefix-manifest.json" <<'PY'
import collections,hashlib,json,sys
raw=open(sys.argv[1],"rb").read(); lines=raw.splitlines(keepends=True)
assert raw.endswith(b"\n") and b"" not in lines
rows=[json.loads(line) for line in lines]
def family(row):
    if "activation" in row: return "native"
    if row.get("event")=="bash" and set(row)=={"ts","event","cmd"}: return "shell"
    if row.get("event")=="merge_guard_block" and "event_id" not in row: return "merge"
    return "ordinary"
counts=collections.Counter(map(family,rows))
assert counts=={"native":1,"ordinary":1,"shell":2,"merge":1}
manifest={"bytes":len(raw),"rows":len(rows),"counts":dict(sorted(counts.items())),
          "family_sha256":{name:hashlib.sha256(b"".join(
              line for line,row in zip(lines,rows) if family(row)==name)).hexdigest()
              for name in sorted(counts)}}
with open(sys.argv[2],"w",encoding="utf-8") as fh: json.dump(manifest,fh,sort_keys=True)
assert "cmd" not in json.dumps(manifest)
PY
rep_terminal_out="$($LOG --run "$repo_rep/.agent-firm/runs/target" --strict --print-event-id \
  --event-id evt-representative-terminal integration_completed status=synthetic)"; rep_terminal_rc=$?
assert_eq "representative terminal ordinary append succeeds" 0 "$rep_terminal_rc"
assert_eq "representative terminal returns exact retained id" evt-representative-terminal "$rep_terminal_out"
assert_ok "terminal append preserves exact prefix, family manifest, and ordered union" python3 - \
  "$repo_rep/representative-prefix.bin" "$repo_rep/.agent-firm/runs/target/run.jsonl" \
  "$repo_rep/representative-prefix-manifest.json" <<'PY'
import collections,hashlib,json,sys
before=open(sys.argv[1],"rb").read(); after=open(sys.argv[2],"rb").read()
manifest=json.load(open(sys.argv[3],encoding="utf-8"))
assert after.startswith(before) and after.endswith(b"\n")
prefix_lines=before.splitlines(keepends=True); prefix_rows=[json.loads(x) for x in prefix_lines]
rows=[json.loads(x) for x in after.splitlines()]
assert rows[:-1]==prefix_rows and len(rows)==manifest["rows"]+1
assert rows[-1]["event"]=="integration_completed" and rows[-1]["event_id"]=="evt-representative-terminal"
assert len(before)==manifest["bytes"]
assert len({r["event_id"] for r in rows if "event_id" in r})==3
PY
cp "$repo_rep/.agent-firm/runs/target/run.jsonl" "$repo_rep/representative-after-terminal.bin"
rep_native_result="$(invoke_native_contract "$repo_rep" target intake/I-01 intake-analyst \
  role-contracts/I-00-intake.md "$rep_auth" "$INTAKE_ACTIVATION" intake_started /root/compat_intake)"; rep_native_rc=$?
assert_eq "representative distinct native append succeeds" 0 "$rep_native_rc"
assert_ok "native append preserves exact prefix and result/event/identity union" python3 - \
  "$repo_rep/representative-prefix.bin" "$repo_rep/representative-after-terminal.bin" \
  "$repo_rep/.agent-firm/runs/target/run.jsonl" "$rep_seed_result" "$rep_native_result" <<'PY'
import json,sys
seed_bytes=open(sys.argv[1],"rb").read(); mid=open(sys.argv[2],"rb").read(); final=open(sys.argv[3],"rb").read()
seed_result=json.loads(sys.argv[4]); result=json.loads(sys.argv[5])
assert mid.startswith(seed_bytes) and final.startswith(mid) and final.endswith(b"\n")
seed_rows=[json.loads(x) for x in seed_bytes.splitlines()]
mid_rows=[json.loads(x) for x in mid.splitlines()]
rows=[json.loads(x) for x in final.splitlines()]
assert mid_rows[:-1]==seed_rows and rows[:-1]==mid_rows and len(rows)==len(seed_rows)+2
assert result["schema_version"]==1
assert set(result)-{"schema_version"}==set(rows[-1])-{"ts"}
for key in set(rows[-1])-{"ts"}: assert result[key]==rows[-1][key]
ids=[r["event_id"] for r in rows if "event_id" in r]
assert len(ids)==len(set(ids))==4
assert set(ids)=={seed_result["event_id"],"evt-representative-seed",
                 "evt-representative-terminal",result["event_id"]}
activations={(r["run_id"],r["stage"],r["role"]) for r in rows if "activation" in r}
assert activations=={("target","intake/seed","intake-analyst"),("target","intake/I-01","intake-analyst")}
assert sum(r.get("event")=="bash" and "event_id" not in r for r in rows)==2
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

t_case "same-inode private-temp mutation fails before replacement with exact cleanup"
for mutation in truncate overwrite same_size valid_injection; do
  repo_temp_content="$(mk_repo)"; mk_run "$repo_temp_content" target
  run_temp_content="$repo_temp_content/.agent-firm/runs/target"
  "$LOG" --run "$run_temp_content" --strict --event-id "evt-temp-seed-$mutation" \
    temp_seed class=synthetic >/dev/null
  temp_content_before="$(sha_or_absent "$run_temp_content/run.jsonl")"
  temp_content_barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-temp-content.XXXXXX")"
  t_track "$temp_content_barrier"
  printf 'outside sentinel\n' > "$temp_content_barrier/outside-sentinel"
  ( FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_BARRIER_PHASE=after_temp_fsync \
      FIRM_LEDGER_BARRIER_DIR="$temp_content_barrier" FIRM_LEDGER_BARRIER_TOKEN=writer \
      "$LOG" --run "$run_temp_content" --strict --print-event-id \
      --event-id "evt-temp-writer-$mutation" temp_writer class=synthetic \
      > "$temp_content_barrier/out" 2> "$temp_content_barrier/err"; \
      printf '%s' "$?" > "$temp_content_barrier/rc" ) & temp_content_pid=$!
  assert_ok "$mutation reaches the after_temp_fsync barrier" \
    wait_ready "$temp_content_barrier/writer.ready"
  temp_content_name="$(sed 's/^[^:]*://' "$temp_content_barrier/writer.ready" | tr -d '\n')"
  temp_content_path="$run_temp_content/$temp_content_name"
  temp_content_inode_before="$(stat -f '%d:%i' "$temp_content_path" 2>/dev/null || stat -c '%d:%i' "$temp_content_path")"
  assert_ok "$mutation mutates the held private-temp inode in place" \
    python3 - "$temp_content_path" "$mutation" <<'PY'
import json, os, sys

path, mutation = sys.argv[1:]
size = os.stat(path).st_size
if mutation == "truncate":
    with open(path, "r+b", buffering=0) as handle:
        handle.truncate(0)
elif mutation == "overwrite":
    with open(path, "r+b", buffering=0) as handle:
        handle.truncate(0)
        handle.write(b"synthetic overwrite\n")
elif mutation == "same_size":
    assert size > 1
    with open(path, "r+b", buffering=0) as handle:
        first = handle.read(1)
        handle.seek(0)
        handle.write(b"[" if first != b"[" else b"{")
    assert os.stat(path).st_size == size
elif mutation == "valid_injection":
    row = {
        "ts": "2026-08-13T00:00:00Z", "event": "synthetic_injection",
        "event_id": "evt-temp-injected", "run_id": "target", "class": "synthetic",
    }
    with open(path, "ab", buffering=0) as handle:
        handle.write((json.dumps(row, separators=(",", ":")) + "\n").encode("utf-8"))
else:
    raise AssertionError(mutation)
PY
  temp_content_inode_after="$(stat -f '%d:%i' "$temp_content_path" 2>/dev/null || stat -c '%d:%i' "$temp_content_path")"
  assert_eq "$mutation preserves the attacked temp device and inode" \
    "$temp_content_inode_before" "$temp_content_inode_after"
  printf 'release\n' > "$temp_content_barrier/writer.release"
  wait "$temp_content_pid"
  assert_eq "$mutation fails the strict append before replacement" 1 \
    "$(cat "$temp_content_barrier/rc")"
  assert_eq "$mutation emits no success-shaped stdout" "" \
    "$(cat "$temp_content_barrier/out")"
  assert_eq "$mutation leaves the old ledger byte-identical" "$temp_content_before" \
    "$(sha_or_absent "$run_temp_content/run.jsonl")"
  assert_no_file "$mutation cleans only its exact owned private temp" "$temp_content_path"
  assert_eq "$mutation leaves unrelated sentinels unchanged" "outside sentinel" \
    "$(cat "$temp_content_barrier/outside-sentinel")"
done

t_case "retained writable temp descriptor mutation during the final exact proof remains fail closed"
repo_retained_temp="$(mk_repo)"; mk_run "$repo_retained_temp" target
run_retained_temp="$repo_retained_temp/.agent-firm/runs/target"
"$LOG" --run "$run_retained_temp" --strict --event-id evt-retained-seed \
  retained_seed class=synthetic >/dev/null
retained_barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-retained-temp.XXXXXX")"
t_track "$retained_barrier"
printf 'outside sentinel\n' > "$retained_barrier/outside-sentinel"
( FIRM_LEDGER_TEST_GUARD=1 \
    FIRM_LEDGER_BARRIER_PHASE=after_temp_fsync,after_result_scan \
    FIRM_LEDGER_BARRIER_DIR="$retained_barrier" FIRM_LEDGER_BARRIER_TOKEN=writer \
    "$LOG" --run "$run_retained_temp" --strict --print-event-id \
    --event-id evt-retained-writer retained_writer class=synthetic \
    > "$retained_barrier/out" 2> "$retained_barrier/err"; \
    printf '%s' "$?" > "$retained_barrier/rc" ) & retained_writer_pid=$!
assert_ok "retained-descriptor writer reaches the populated-temp boundary" \
  wait_ready "$retained_barrier/writer.after_temp_fsync.ready"
retained_temp_name="$(sed 's/^[^:]*://' \
  "$retained_barrier/writer.after_temp_fsync.ready" | tr -d '\n')"
retained_temp_path="$run_retained_temp/$retained_temp_name"
python3 - "$retained_temp_path" "$retained_barrier" <<'PY' &
import json, os, sys, time

path, barrier = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_APPEND)
try:
    st = os.fstat(fd)
    with open(os.path.join(barrier, "holder.identity"), "w", encoding="ascii") as handle:
        handle.write(f"{st.st_dev}:{st.st_ino}\n")
    with open(os.path.join(barrier, "holder.open"), "w", encoding="ascii") as handle:
        handle.write("open\n")
    deadline = time.monotonic() + 20
    while not os.path.exists(os.path.join(barrier, "holder.inject")):
        if time.monotonic() >= deadline:
            raise TimeoutError("inject signal")
        time.sleep(0.01)
    row = {
        "ts": "2026-08-13T00:00:00Z", "event": "synthetic_injection",
        "event_id": "evt-retained-injected", "run_id": "target", "class": "synthetic",
    }
    payload = (json.dumps(row, separators=(",", ":")) + "\n").encode("utf-8")
    os.write(fd, payload)
    os.fsync(fd)
    with open(os.path.join(barrier, "holder.injected"), "w", encoding="ascii") as handle:
        handle.write("injected\n")
finally:
    os.close(fd)
PY
retained_holder_pid=$!
assert_ok "the harness retains the writable populated-temp descriptor without mutation" \
  wait_ready "$retained_barrier/holder.open"
printf 'release\n' > "$retained_barrier/writer.after_temp_fsync.release"
assert_ok "writer reaches the deterministic boundary between scan and the final exact proof" \
  wait_ready "$retained_barrier/writer.after_result_scan.ready"
retained_committed_identity="$(stat -f '%d:%i' "$run_retained_temp/run.jsonl" 2>/dev/null || \
  stat -c '%d:%i' "$run_retained_temp/run.jsonl")"
assert_eq "the retained descriptor names the inode that crossed replacement" \
  "$(tr -d '\n' < "$retained_barrier/holder.identity")" "$retained_committed_identity"
printf 'inject\n' > "$retained_barrier/holder.inject"
assert_ok "retained descriptor injects only at the controlled post-scan boundary" \
  wait_ready "$retained_barrier/holder.injected"
wait "$retained_holder_pid"
printf 'release\n' > "$retained_barrier/writer.after_result_scan.release"
wait "$retained_writer_pid"
assert_eq "during-proof retained-descriptor mutation fails before success" 1 \
  "$(cat "$retained_barrier/rc")"
assert_eq "during-proof retained-descriptor mutation emits no success stdout" "" \
  "$(cat "$retained_barrier/out")"
assert_output "during-proof retained-descriptor mutation reports only the stable failure" \
  "could not append target ledger" cat "$retained_barrier/err"
assert_ok "postcommit external mutation leaves one explicit complete allowed state" \
  python3 - "$run_retained_temp/run.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], "rb") as handle:
    raw = handle.read()
assert raw.endswith(b"\n") and raw.count(b"\n") == 3
rows = [json.loads(line) for line in raw.splitlines()]
assert [row["event_id"] for row in rows] == [
    "evt-retained-seed", "evt-retained-writer", "evt-retained-injected",
]
PY
assert_eq "retained-descriptor schedule leaves unrelated sentinels unchanged" \
  "outside sentinel" "$(cat "$retained_barrier/outside-sentinel")"

t_case "distinct owned inode replacement during final proof fails without redirected mutation"
repo_live_replace="$(mk_repo)"; mk_run "$repo_live_replace" target
run_live_replace="$repo_live_replace/.agent-firm/runs/target"
"$LOG" --run "$run_live_replace" --strict --event-id evt-live-seed \
  live_seed class=synthetic >/dev/null
live_replace_barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-live-replace.XXXXXX")"
t_track "$live_replace_barrier"
printf 'outside sentinel\n' > "$live_replace_barrier/outside-sentinel"
( FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_BARRIER_PHASE=after_result_scan \
    FIRM_LEDGER_BARRIER_DIR="$live_replace_barrier" FIRM_LEDGER_BARRIER_TOKEN=writer \
    "$LOG" --run "$run_live_replace" --strict --print-event-id \
    --event-id evt-live-writer live_writer class=synthetic \
    > "$live_replace_barrier/out" 2> "$live_replace_barrier/err"; \
    printf '%s' "$?" > "$live_replace_barrier/rc" ) & live_replace_pid=$!
assert_ok "ordinary writer reaches the during-P path replacement boundary" \
  wait_ready "$live_replace_barrier/writer.ready"
mv "$run_live_replace/run.jsonl" "$live_replace_barrier/proved-original.jsonl"
cp "$live_replace_barrier/proved-original.jsonl" "$run_live_replace/run.jsonl"
chmod 600 "$run_live_replace/run.jsonl"
live_original_identity="$(stat -f '%d:%i' "$live_replace_barrier/proved-original.jsonl" 2>/dev/null || \
  stat -c '%d:%i' "$live_replace_barrier/proved-original.jsonl")"
live_replacement_identity="$(stat -f '%d:%i' "$run_live_replace/run.jsonl" 2>/dev/null || \
  stat -c '%d:%i' "$run_live_replace/run.jsonl")"
assert_ne "during-P replacement installs a distinct owned inode" \
  "$live_original_identity" "$live_replacement_identity"
live_original_before="$(sha_or_absent "$live_replace_barrier/proved-original.jsonl")"
live_replacement_before="$(sha_or_absent "$run_live_replace/run.jsonl")"
printf 'release\n' > "$live_replace_barrier/writer.release"; wait "$live_replace_pid"
assert_eq "distinct-inode during-P replacement fails strict ordinary success" 1 \
  "$(cat "$live_replace_barrier/rc")"
assert_eq "distinct-inode during-P replacement emits no success stdout" "" \
  "$(cat "$live_replace_barrier/out")"
assert_output "distinct-inode during-P replacement reports only the stable failure" \
  "could not append target ledger" cat "$live_replace_barrier/err"
assert_eq "failed proof does not mutate the moved proved inode" "$live_original_before" \
  "$(sha_or_absent "$live_replace_barrier/proved-original.jsonl")"
assert_eq "failed proof does not mutate the live replacement inode" "$live_replacement_before" \
  "$(sha_or_absent "$run_live_replace/run.jsonl")"
assert_eq "failed proof preserves moved-original identity" "$live_original_identity" \
  "$(stat -f '%d:%i' "$live_replace_barrier/proved-original.jsonl" 2>/dev/null || \
    stat -c '%d:%i' "$live_replace_barrier/proved-original.jsonl")"
assert_eq "failed proof preserves replacement identity" "$live_replacement_identity" \
  "$(stat -f '%d:%i' "$run_live_replace/run.jsonl" 2>/dev/null || \
    stat -c '%d:%i' "$run_live_replace/run.jsonl")"
assert_eq "distinct-inode schedule leaves unrelated sentinels unchanged" \
  "outside sentinel" "$(cat "$live_replace_barrier/outside-sentinel")"

run_ordinary_admitted_post_proof_case() {
  local phase="$1" interval="$2" repo run barrier seed_path temp_name temp_path
  local writer_pid holder_pid committed_identity output_before
  repo="$(mk_repo)"; mk_run "$repo" target
  run="$repo/.agent-firm/runs/target"
  "$LOG" --run "$run" --strict --event-id "evt-admitted-seed-$interval" \
    admitted_seed class=synthetic >/dev/null
  barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-admitted-$interval.XXXXXX")"
  t_track "$barrier"
  seed_path="$barrier/seed.bytes"
  cp "$run/run.jsonl" "$seed_path"
  printf 'outside sentinel\n' > "$barrier/outside-sentinel"
  ( FIRM_LEDGER_TEST_GUARD=1 \
      FIRM_LEDGER_BARRIER_PHASE="after_temp_fsync,after_final_proof,$phase" \
      FIRM_LEDGER_BARRIER_DIR="$barrier" FIRM_LEDGER_BARRIER_TOKEN=writer \
      "$LOG" --run "$run" --strict --print-event-id \
      --event-id "evt-admitted-writer-$interval" admitted_writer class=synthetic \
      > "$barrier/out" 2> "$barrier/err"; \
      printf '%s' "$?" > "$barrier/rc" ) & writer_pid=$!
  assert_ok "$interval counterexample reaches the populated-temp custody boundary" \
    wait_ready "$barrier/writer.after_temp_fsync.ready"
  temp_name="$(sed 's/^[^:]*://' \
    "$barrier/writer.after_temp_fsync.ready" | tr -d '\n')"
  temp_path="$run/$temp_name"
  python3 - "$temp_path" "$barrier" "$interval" <<'PY' &
import json, os, sys, time

path, barrier, interval = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_APPEND)
try:
    st = os.fstat(fd)
    with open(os.path.join(barrier, "holder.identity"), "w", encoding="ascii") as handle:
        handle.write(f"{st.st_dev}:{st.st_ino}\n")
    with open(os.path.join(barrier, "holder.open"), "w", encoding="ascii") as handle:
        handle.write("open\n")
    deadline = time.monotonic() + 20
    while not os.path.exists(os.path.join(barrier, "holder.inject")):
        if time.monotonic() >= deadline:
            raise TimeoutError("inject signal")
        time.sleep(0.01)
    row = {
        "ts": "2026-08-13T00:00:00Z", "event": "admitted_injection",
        "event_id": f"evt-admitted-injected-{interval}", "run_id": "target",
        "class": "synthetic",
    }
    payload = (json.dumps(row, separators=(",", ":")) + "\n").encode("utf-8")
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        assert written > 0
        view = view[written:]
    os.fsync(fd)
    with open(os.path.join(barrier, "holder.injected"), "w", encoding="ascii") as handle:
        handle.write("injected\n")
finally:
    os.close(fd)
PY
  holder_pid=$!
  assert_ok "$interval helper retains the writable populated-temp descriptor without mutation" \
    wait_ready "$barrier/holder.open"
  printf 'release\n' > "$barrier/writer.after_temp_fsync.release"
  assert_ok "$interval schedule reaches completion of final same-inode exact-byte proof P" \
    wait_ready "$barrier/writer.after_final_proof.ready"
  assert_ok "$interval schedule proves exact old-plus-one bytes at P" python3 - \
    "$seed_path" "$run/run.jsonl" "$barrier/proof-at-p.bytes" \
    "evt-admitted-writer-$interval" <<'PY'
import json, sys
seed_path, ledger_path, proof_path, event_id = sys.argv[1:]
seed = open(seed_path, "rb").read()
raw = open(ledger_path, "rb").read()
assert raw.startswith(seed)
appended = raw[len(seed):]
assert appended.endswith(b"\n") and appended.count(b"\n") == 1
row = json.loads(appended)
assert row["event_id"] == event_id and row["event"] == "admitted_writer"
assert row["run_id"] == "target" and row["class"] == "synthetic"
open(proof_path, "wb").write(raw)
PY
  printf 'release\n' > "$barrier/writer.after_final_proof.release"
  assert_ok "$interval schedule reaches the selected admitted post-proof interval" \
    wait_ready "$barrier/writer.$phase.ready"
  committed_identity="$(stat -f '%d:%i' "$run/run.jsonl" 2>/dev/null || \
    stat -c '%d:%i' "$run/run.jsonl")"
  assert_eq "$interval retained descriptor still names the installed inode after P" \
    "$(tr -d '\n' < "$barrier/holder.identity")" "$committed_identity"
  assert_ok "$interval bytes remain the proved old-plus-one receipt before mutation" \
    cmp "$barrier/proof-at-p.bytes" "$run/run.jsonl"
  if [ "$phase" = after_result_construction ]; then
    output_before="$(cat "$barrier/out")"
    assert_eq "$interval result-construction interval precedes success output" "" "$output_before"
  else
    output_before="$(cat "$barrier/out")"
    assert_eq "$interval success output is already flushed before mutation" \
      "evt-admitted-writer-$interval" "$output_before"
  fi
  assert_eq "$interval exact producer temp entry is already installed, not leaked" 0 \
    "$(find "$run" -maxdepth 1 -name '.run.jsonl.tmp.*' | wc -l | tr -d ' ')"
  printf 'inject\n' > "$barrier/holder.inject"
  assert_ok "$interval retained descriptor performs admitted_post_proof_mutation" \
    wait_ready "$barrier/holder.injected"
  wait "$holder_pid"
  assert_ok "$interval admitted mutation changes only the same inode after the proved bytes" \
    python3 - "$barrier/proof-at-p.bytes" "$run/run.jsonl" "$interval" <<'PY'
import json, os, sys
proof_path, ledger_path, interval = sys.argv[1:]
proof = open(proof_path, "rb").read()
raw = open(ledger_path, "rb").read()
assert raw.startswith(proof)
appended = raw[len(proof):]
assert appended.endswith(b"\n") and appended.count(b"\n") == 1
row = json.loads(appended)
assert row["event_id"] == f"evt-admitted-injected-{interval}"
assert row["event"] == "admitted_injection" and row["run_id"] == "target"
PY
  printf 'release\n' > "$barrier/writer.$phase.release"
  wait "$writer_pid"
  assert_eq "$interval proof-instant receipt returns zero under the authority-bound concession" \
    0 "$(cat "$barrier/rc")"
  assert_eq "$interval ordinary event-id receipt retains its exact public bytes" \
    "evt-admitted-writer-$interval" "$(cat "$barrier/out")"
  assert_eq "$interval admitted window emits no misleading producer diagnostic" \
    "" "$(cat "$barrier/err")"
  assert_eq "$interval return stability is waived_by_evt-20260813T140309-96805-1cf299b00bb3a1df" \
    "outside sentinel" "$(cat "$barrier/outside-sentinel")"
}

t_case "ordinary receipt matrix demonstrates admitted_post_proof_mutation under the exact human waiver"
run_ordinary_admitted_post_proof_case after_result_construction result_construction
run_ordinary_admitted_post_proof_case after_success_output success_output
run_ordinary_admitted_post_proof_case before_return observed_return

t_case "contract ancestor replacement cannot borrow the originally held leaf"
for replacement in role_root_safe nested_unsafe; do
  repo_contract_chain="$(mk_repo)"; mk_eligible_run "$repo_contract_chain" source
  mk_eligible_run "$repo_contract_chain" target
  contract_chain_run="$repo_contract_chain/.agent-firm/runs/target"
  contract_chain_relative=role-contracts/nested/sealed-input.md
  make_contract "$repo_contract_chain" target "$contract_chain_relative"
  printf '%s\n' \
    '{"proof":"accepted","event":"architecture_completed","event_id":"evt-compat-authority-0001","ts":"2020-01-01T00:00:00Z","run_id":"source"}' \
    > "$repo_contract_chain/.agent-firm/runs/source/run.jsonl"
  chmod 600 "$repo_contract_chain/.agent-firm/runs/source/run.jsonl"
  contract_chain_auth="$(authority_json source "$AUTH_ID" architecture_completed '{"proof":"accepted"}')"
  contract_chain_target_before="$(sha_or_absent "$contract_chain_run/run.jsonl")"
  contract_chain_authority_before="$(sha_or_absent "$repo_contract_chain/.agent-firm/runs/source/run.jsonl")"
  contract_chain_barrier="$(mktemp -d "${TMPDIR:-/tmp}/firm-ledger-contract-chain.XXXXXX")"
  t_track "$contract_chain_barrier"
  printf 'outside sentinel\n' > "$contract_chain_barrier/outside-sentinel"
  ( FIRM_LEDGER_TEST_GUARD=1 FIRM_LEDGER_BARRIER_PHASE=after_contract_open \
      FIRM_LEDGER_BARRIER_DIR="$contract_chain_barrier" FIRM_LEDGER_BARRIER_TOKEN=writer \
      invoke_native_contract "$repo_contract_chain" target intake/I-00 intake-analyst \
      "$contract_chain_relative" "$contract_chain_auth" "$INTAKE_ACTIVATION" \
      intake_started /root/compat_intake \
      > "$contract_chain_barrier/out" 2> "$contract_chain_barrier/err"; \
      printf '%s' "$?" > "$contract_chain_barrier/rc" ) & contract_chain_pid=$!
  assert_ok "$replacement reaches the deterministic post-contract-open barrier" \
    wait_ready "$contract_chain_barrier/writer.ready"
  case "$replacement" in
    role_root_safe)
      mv "$contract_chain_run/role-contracts" "$contract_chain_barrier/original-role-contracts"
      mkdir "$contract_chain_run/role-contracts"
      mkdir "$contract_chain_run/role-contracts/nested"
      chmod 755 "$contract_chain_run/role-contracts" "$contract_chain_run/role-contracts/nested"
      ln "$contract_chain_barrier/original-role-contracts/nested/sealed-input.md" \
        "$contract_chain_run/$contract_chain_relative"
      ;;
    nested_unsafe)
      mv "$contract_chain_run/role-contracts/nested" "$contract_chain_barrier/original-nested"
      mkdir "$contract_chain_run/role-contracts/nested"
      chmod 777 "$contract_chain_run/role-contracts/nested"
      ln "$contract_chain_barrier/original-nested/sealed-input.md" \
        "$contract_chain_run/$contract_chain_relative"
      ;;
  esac
  printf 'release\n' > "$contract_chain_barrier/writer.release"
  wait "$contract_chain_pid"
  assert_eq "$replacement hard-linked ancestor replacement is CONTRACT_INVALID" 12 \
    "$(cat "$contract_chain_barrier/rc")"
  assert_eq "$replacement emits no success-shaped stdout" "" \
    "$(cat "$contract_chain_barrier/out")"
  assert_output "$replacement reports only the stable contract class" CONTRACT_INVALID \
    cat "$contract_chain_barrier/err"
  assert_eq "$replacement leaves the target ledger byte-identical" "$contract_chain_target_before" \
    "$(sha_or_absent "$contract_chain_run/run.jsonl")"
  assert_eq "$replacement leaves the authority ledger byte-identical" "$contract_chain_authority_before" \
    "$(sha_or_absent "$repo_contract_chain/.agent-firm/runs/source/run.jsonl")"
  assert_eq "$replacement leaves unrelated sentinels unchanged" "outside sentinel" \
    "$(cat "$contract_chain_barrier/outside-sentinel")"
done

t_summary
