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

provider_harness() {
  t_python - "$AUTH" "$@" <<'PY'
import json,os,resource,sys,time,types
from pathlib import Path
authority=sys.argv[1]; action=sys.argv[2]; args=sys.argv[3:]
raw=Path(authority).read_text(encoding="utf-8")
source=raw.split("<<'PY'\n",1)[1].rsplit("\nPY\n",1)[0]
saved_argv=list(sys.argv); sys.argv=["-",authority]
scope={"__name__":"firm_eval_authority_provider_test"}
exec(compile(source,authority,"exec"),scope)
sys.argv=saved_argv

def emit(value): print(scope["canonical"](value))
def record(provider,path,barrier=None):
    return scope["provider_executable_record"](provider,path,barrier)

if action=="record":
    provider,path=args[:2]
    value=record(provider,path)
    if len(args)>2 and args[2]=="memory":
        maximum=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        value["maximum_rss_bytes"]=maximum if sys.platform=="darwin" else maximum*1024
    emit(value)
elif action=="capsule-build":
    provider,path,control,token,invocation,pid=args[:6]
    emit(scope["build_provider_capsule"](provider,path,Path(control),int(pid),token,invocation,{"enabled":False}))
elif action=="signing-record":
    emit(scope["codesign_record"](Path(args[0])))
elif action=="signing-observation":
    state,mutation=args[:2]; path=Path("/private/tmp/provider-fixture")
    cdhash="1"*40
    if state=="unsigned":
        display_stdout=b""; display_stderr=(str(path)+": code object is not signed at all\n").encode(); display_exit=1
    elif state=="adhoc_signed":
        display_stdout=("# designated => cdhash H\\\"%s\\\"\n"%cdhash).encode()
        display_stderr=("Executable=%s\nIdentifier=fixture-adhoc\nCodeDirectory v=20400 size=259 flags=0x2(adhoc) hashes=2+2 location=embedded\nCDHash=%s\nSignature=adhoc\nTeamIdentifier=not set\n"%(path,cdhash)).encode()
        display_exit=0
    elif state=="team_signed":
        display_stdout=b'designated => identifier "fixture-team" and anchor apple generic\n'
        display_stderr=("Executable=%s\nIdentifier=fixture-team\nCodeDirectory v=20500 size=259 flags=0x10000(runtime) hashes=2+2 location=embedded\nCDHash=%s\nSignature size=4096\nTeamIdentifier=ABC1234XYZ\n"%(path,cdhash)).encode()
        display_exit=0
    else: raise SystemExit("unknown signing state")
    verify_stdout=b""; verify_stderr=(str(path)+": valid on disk\n"+str(path)+": satisfies its Designated Requirement\n").encode(); verify_exit=0
    if mutation=="none": pass
    elif mutation=="missing-identifier": display_stderr=display_stderr.replace(b"Identifier=fixture-adhoc\n",b"").replace(b"Identifier=fixture-team\n",b"")
    elif mutation=="duplicate-team": display_stderr+=b"TeamIdentifier=ABC1234XYZ\n"
    elif mutation=="mixed-team-adhoc": display_stderr=display_stderr.replace(b"TeamIdentifier=not set",b"TeamIdentifier=ABC1234XYZ")
    elif mutation=="bad-hash": display_stderr=display_stderr.replace(cdhash.encode(),b"A"*40)
    elif mutation=="bad-requirement": display_stdout=display_stdout.replace(b"# designated => ",b"designated => ") if state=="adhoc_signed" else display_stdout.replace(b"designated => ",b"# designated => ")
    elif mutation=="missing-adhoc-signature": display_stderr=display_stderr.replace(b"Signature=adhoc\n",b"")
    elif mutation=="signed-no-team-no-adhoc": display_stderr=display_stderr.replace(b"TeamIdentifier=ABC1234XYZ",b"TeamIdentifier=not set")
    elif mutation=="wrong-unsigned-path": display_stderr=b"/private/tmp/other: code object is not signed at all\n"
    elif mutation=="unsigned-extra-output": display_stdout=b"unexpected\n"
    elif mutation=="control-output": display_stderr+=b"bad\x00value\n"
    elif mutation=="unterminated-output": display_stderr=display_stderr.rstrip(b"\n")
    elif mutation=="verify-failure": verify_exit=1
    elif mutation=="verify-identity-output": verify_stderr+=b"Identifier=forbidden\n"
    elif mutation=="verify-order": pass
    elif mutation=="display-digest-drift": pass
    else: raise SystemExit("unknown signing mutation")
    def observation(kind,stdout,stderr,exit_code):
        argv=[str(scope["CODESIGN"])]
        argv+=(['--display','--requirements','-','--verbose=4',str(path)] if kind=="display" else ['--verify','--strict','--verbose=4',str(path)])
        start_ns,end_ns=(1,2) if kind=="display" else (3,4)
        start_utc,end_utc=(("2026-09-02T00:00:00.000000Z","2026-09-02T00:00:00.000001Z") if kind=="display" else
                           ("2026-09-02T00:00:00.000002Z","2026-09-02T00:00:00.000003Z"))
        result={"argv":argv,"cwd":"/","exit_code":exit_code,"start_utc":start_utc,
                "end_utc":end_utc,"start_monotonic_ns":start_ns,"end_monotonic_ns":end_ns,"duration_ns":1,
                "stdout":{"bytes":len(stdout),"sha256":scope["digest_bytes"](stdout)},
                "stderr":{"bytes":len(stderr),"sha256":scope["digest_bytes"](stderr)}}
        return stdout,stderr,result
    display=observation("display",display_stdout,display_stderr,display_exit)
    if mutation=="display-digest-drift": display[2]["stderr"]["sha256"]="0"*64
    verify=None if state=="unsigned" else observation("verify",verify_stdout,verify_stderr,verify_exit)
    if mutation=="verify-order":
        verify[2].update(start_utc="2026-09-02T00:00:00.000000Z",end_utc="2026-09-02T00:00:00.000001Z",
                         start_monotonic_ns=1,end_monotonic_ns=2)
    emit(scope["codesign_record_from_observations"](path,display,verify))
elif action=="signing-reproof":
    expected=json.loads(args[0]); observed=json.loads(args[0]); mutation=args[1]
    if mutation=="identity": observed["identifier"]+="-drift"
    elif mutation=="team-appearance": observed["team_identifier"]="ABC1234XYZ"
    elif mutation=="display-output": observed["display_result"]["stdout"]["sha256"]="0"*64
    elif mutation=="verify-output": observed["strict_verify_result"]["stderr"]["sha256"]="0"*64
    elif mutation=="none": pass
    else: raise SystemExit("unknown signing reproof mutation")
    scope["validate_codesign_reproof"](expected,observed)
elif action=="capsule-schema-mutate":
    capsule=json.loads(args[0]); mutation=args[1]; signing=capsule["signing"]
    if mutation=="state": signing["copy"]["state"]="team_signed"
    elif mutation=="identity": signing["mounted"]["identifier"]+="-drift"
    elif mutation=="team-appearance": signing["copy"]["team_identifier"]="ABC1234XYZ"
    elif mutation=="hash": signing["source"]["cdhash"]="0"*40
    elif mutation=="verify-failure": signing["mounted"]["strict_verify_result"]["exit_code"]=1
    elif mutation=="extra": signing["copy"]["extra"]=True
    else: raise SystemExit("unknown capsule schema mutation")
    scope["provider_capsule_schema"](capsule)
elif action=="external":
    emit(scope["external_file_record"](Path(args[0])))
elif action=="instrument":
    mode,provider,path=args[:3]
    original_read=scope["os"].read
    if mode=="read-size":
        maximum=[0]
        def measured(fd,amount):
            maximum[0]=max(maximum[0],amount); return original_read(fd,amount)
        scope["os"].read=measured
        value=record(provider,path); value["observed_maximum_read"]=maximum[0]; emit(value)
    elif mode=="read-error":
        scope["os"].read=lambda *_: (_ for _ in ()).throw(OSError(5,"injected read error"))
        record(provider,path)
    elif mode=="short-read":
        used=[False]
        def short(fd,amount):
            if not used[0]: used[0]=True; return original_read(fd,max(1,amount-1))
            return original_read(fd,amount)
        scope["os"].read=short; record(provider,path)
    elif mode=="timeout-before-read":
        base=time.monotonic_ns(); values=iter((base,base+scope["PROVIDER_EXECUTABLE_TIMEOUT_NS"]+1))
        scope["time"].monotonic_ns=lambda: next(values,base+scope["PROVIDER_EXECUTABLE_TIMEOUT_NS"]+1)
        record(provider,path)
    elif mode=="nonterminating-read":
        original_timer=scope["signal"].setitimer
        def fast_timer(which,seconds=0,interval=0):
            return original_timer(which,min(seconds,.05) if seconds else 0,interval)
        scope["signal"].setitimer=fast_timer
        scope["os"].read=lambda *_: time.sleep(20)
        record(provider,path)
    else: raise SystemExit("unknown instrumentation")
elif action=="mismatch":
    field,provider,path=args[:3]
    attribute={"dev":"st_dev","ino":"st_ino","uid":"st_uid","mode":"st_mode",
               "nlink":"st_nlink","bytes":"st_size"}[field]
    original_lstat=scope["os"].lstat
    class ChangedStat:
        def __init__(self,value): self.value=value
        def __getattr__(self,name):
            current=getattr(self.value,name)
            return current+1 if name==attribute else current
    def changed_lstat(candidate,*rest,**kwargs):
        value=original_lstat(candidate,*rest,**kwargs)
        return ChangedStat(value) if os.fspath(candidate)==path else value
    scope["os"].lstat=changed_lstat; record(provider,path)
elif action=="sparse-stat":
    provider,path=args[:2]; original_lstat=scope["os"].lstat
    class SparseStat:
        def __init__(self,value): self.value=value
        def __getattr__(self,name): return 0 if name=="st_blocks" else getattr(self.value,name)
    def sparse_lstat(candidate,*rest,**kwargs):
        value=original_lstat(candidate,*rest,**kwargs)
        return SparseStat(value) if os.fspath(candidate)==path else value
    scope["os"].lstat=sparse_lstat; record(provider,path)
elif action=="reprove":
    mutation,provider,path=args[:3]
    expected=record(provider,path)
    if mutation=="missing": expected.pop(args[3])
    elif mutation=="digest": expected["sha256"]="0"*64
    elif mutation=="maximum": expected["maximum_bytes"]+=1
    else: raise SystemExit("unknown reproof mutation")
    scope["reprove_provider_executable"](expected)
elif action=="barrier":
    provider,path,root,token,phase,invocation=args[:6]
    emit(record(provider,path,scope["test_barrier_config"](root,token,phase,invocation)))
elif action=="descriptor-swap":
    provider,path,replacement=args[:3]
    def swap(_config,phase,observed):
        if phase!="provider_preexec": return
        for descriptor in range(3,256):
            try: value=os.fstat(descriptor)
            except OSError: continue
            if value.st_dev==observed["dev"] and value.st_ino==observed["ino"]:
                other=os.open(replacement,os.O_RDONLY|os.O_NOFOLLOW)
                try: os.dup2(other,descriptor)
                finally: os.close(other)
                return
        raise RuntimeError("provider descriptor not found")
    scope["raw_test_barrier"]=swap
    record(provider,path,{"enabled":True,"phase":"provider_preexec"})
elif action=="exec":
    mutation,provider,path,wrapper,profile,marker=args[:7]
    expected=record(provider,path)
    if mutation=="digest": expected["sha256"]="0"*64
    doc={"invocation":"a"*48,"test_barrier":{"enabled":False},
         "provider_capsule":{"source":expected,"mounted":expected},
         "seatbelt":{"provider":expected,"supervisor_argv_prefix":[wrapper,"-D","REAL_COMMON=/private/absent","-f",profile]}}
    manifest_raw=b"authenticated-manifest\n"
    scope["load_manifest"]=lambda _:(doc,manifest_raw)
    def validate(candidate):
        if record(provider,path)!=candidate["provider_capsule"]["mounted"]:
            scope["fail"]("provider capsule mounted executable drift")
    scope["validate_provider_capsule"]=validate
    def execve(executable,argv,environment):
        if mutation=="clean": Path(marker).touch()
        raise SystemExit(0)
    scope["os"].execve=execve
    ns=types.SimpleNamespace(manifest="ignored",digest=scope["digest_bytes"](manifest_raw),invocation=doc["invocation"],terminal=False)
    executable=path if mutation!="argv" else wrapper
    scope["provider_exec"](ns,[wrapper,"-D","REAL_COMMON=/private/absent","-f",profile,
                                    "/usr/bin/env","PROVIDER_MARKER="+marker,executable])
else:
    raise SystemExit("unknown action")
PY
}

t_case "provider executable records have a closed policy and bounded descriptor stream"
provider_root="$(mktemp -d "${TMPDIR:-/tmp}/firm-provider-identity.XXXXXX")"; t_track "$provider_root"; chmod 700 "$provider_root"
provider_root="$(cd "$provider_root" && pwd -P)"
provider_small="$provider_root/provider-small"
printf '#!/bin/sh\nexit 0\n' > "$provider_small"; chmod 700 "$provider_small"
small_record="$(provider_harness record codex "$provider_small")"
assert_ok "Codex record binds the immutable cap, chunk, timeout, canonical identity, and digest" t_python - "$small_record" "$provider_small" <<'PY'
import hashlib,json,os,sys
d=json.loads(sys.argv[1]); raw=open(sys.argv[2],'rb').read(); st=os.stat(sys.argv[2])
assert d["provider"]=="codex" and d["maximum_bytes"]==247464144
assert d["chunk_bytes"]==1048576 and d["timeout_ns"]==10000000000
assert d["path"]==os.path.realpath(sys.argv[2]) and d["bytes"]==len(raw)==st.st_size
assert d["sha256"]==hashlib.sha256(raw).hexdigest() and d["nlink"]==1
PY
assert_ok "provider schema binds exact provider maxima and rejects missing, extra, crossed, and oversize state" \
  t_python - "$SCHEMA" "$small_record" <<'PY'
import copy,json,sys
from jsonschema import Draft202012Validator
schema=json.load(open(sys.argv[1])); validator=Draft202012Validator(schema["$defs"]["providerExecutable"])
valid=json.loads(sys.argv[2]); validator.validate(valid)
for mutate in (
    lambda d:d.pop("sha256"), lambda d:d.update(extra=True),
    lambda d:d.update(maximum_bytes=197220928), lambda d:d.update(provider="unknown"),
    lambda d:d.update(bytes=247464145)):
    candidate=copy.deepcopy(valid); mutate(candidate)
    assert not validator.is_valid(candidate),candidate
claude=copy.deepcopy(valid); claude.update(provider="claude",maximum_bytes=197220928,bytes=197220928)
validator.validate(claude); claude["bytes"]+=1; assert not validator.is_valid(claude)
PY
claude_record="$(provider_harness record claude "$provider_small")"
assert_ok "Claude selects only its exact immutable ceiling" t_python - "$claude_record" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); assert d["provider"]=="claude" and d["maximum_bytes"]==197220928
PY
assert_rc "unknown provider is rejected before path discovery" 2 provider_harness record unknown "$provider_root/does-not-exist"

provider_codex="$provider_root/codex-247464144"
t_python - "$provider_codex" <<'PY'
import os,sys
remaining=247464144; chunk=b'x'*(1024*1024)
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o700)
try:
    while remaining:
        part=chunk[:min(len(chunk),remaining)]; os.write(fd,part); remaining-=len(part)
    os.fsync(fd)
finally: os.close(fd)
PY
memory_record="$(provider_harness record codex "$provider_codex" memory)"
assert_ok "measured 247464144-byte Codex boundary streams below a 192 MiB resident-memory ceiling" \
  t_python - "$memory_record" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); assert d["bytes"]==247464144 and d["maximum_rss_bytes"]<192*1024*1024,d
PY
read_record="$(provider_harness instrument read-size codex "$provider_small")"
assert_ok "every provider read request is at most 1 MiB" t_python - "$read_record" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); assert 0<d["observed_maximum_read"]<=1048576
PY
printf x >> "$provider_codex"
assert_rc "Codex policy rejects its exact maximum plus one before launch" 2 provider_harness record codex "$provider_codex"
t_python -c 'import os,sys; os.truncate(sys.argv[1],247464144)' "$provider_codex"
assert_rc "ordinary external-file identity still rejects a provider-sized file at the unchanged 64 MiB cap" 2 \
  provider_harness external "$provider_codex"

t_case "provider executable shape, path, stream, and manifest disagreements fail closed"
chmod 720 "$provider_small"
assert_rc "group-writable executable is rejected" 2 provider_harness record codex "$provider_small"
chmod 600 "$provider_small"
assert_rc "non-executable provider file is rejected" 2 provider_harness record codex "$provider_small"
chmod 700 "$provider_small"
provider_link="$provider_root/provider-link"; ln "$provider_small" "$provider_link"
assert_rc "hardlinked provider file is rejected" 2 provider_harness record codex "$provider_small"
rm "$provider_link"
provider_alias="$provider_root/provider-alias"; ln -s "$provider_small" "$provider_alias"
assert_rc "provider pathname alias is rejected" 2 provider_harness record codex "$provider_alias"
provider_real_dir="$provider_root/real-dir"; mkdir "$provider_real_dir"; cp "$provider_small" "$provider_real_dir/provider"; chmod 700 "$provider_real_dir/provider"
ln -s "$provider_real_dir" "$provider_root/alias-dir"
assert_rc "symlinked provider path component is rejected" 2 provider_harness record codex "$provider_root/alias-dir/provider"
assert_rc "allocated-size sparse provider state is rejected" 2 provider_harness sparse-stat codex "$provider_small"
for field in uid mode nlink dev ino bytes; do
  assert_rc "path/descriptor $field disagreement is rejected" 2 provider_harness mismatch "$field" codex "$provider_small"
done
for field in provider maximum_bytes chunk_bytes timeout_ns path dev ino uid mode nlink bytes sha256; do
  assert_rc "missing recorded $field is rejected by reproof" 2 provider_harness reprove missing codex "$provider_small" "$field"
done
assert_rc "recorded digest mismatch is rejected by reproof" 2 provider_harness reprove digest codex "$provider_small"
assert_rc "recorded provider maximum mismatch is rejected by reproof" 2 provider_harness reprove maximum codex "$provider_small"
assert_rc "descriptor read error is rejected" 2 provider_harness instrument read-error codex "$provider_small"
assert_rc "descriptor short read is rejected" 2 provider_harness instrument short-read codex "$provider_small"
assert_rc "expired monotonic deadline rejects before another read" 2 provider_harness instrument timeout-before-read codex "$provider_small"
assert_rc "a nonterminating read is interrupted and rejected" 2 provider_harness instrument nonterminating-read codex "$provider_small"

provider_replacement="$provider_root/provider-replacement"
printf '#!/bin/sh\nexit 9\n' > "$provider_replacement"; chmod 700 "$provider_replacement"
assert_rc "descriptor swap after hashing is rejected by the final descriptor proof" 2 \
  provider_harness descriptor-swap codex "$provider_small" "$provider_replacement"

t_case "provider-exec permits only the manifest provider and never launches after identity failure"
provider_marker="$provider_root/provider-marker"; provider_stub="$provider_root/provider-stub"
printf '#!/bin/sh\n: > "$PROVIDER_MARKER"\n' > "$provider_stub"; chmod 700 "$provider_stub"
wrapper_stub="$provider_root/sandbox-stub"; profile_stub="$provider_root/provider.sb"
printf '#!/bin/sh\nshift 4\nexec "$@"\n' > "$wrapper_stub"; chmod 700 "$wrapper_stub"; printf 'profile\n' > "$profile_stub"; chmod 600 "$profile_stub"
assert_ok "provider-exec reproof retains the descriptor through the terminal wrapper exec" \
  provider_harness exec clean codex "$provider_stub" "$wrapper_stub" "$profile_stub" "$provider_marker"
assert_file "the exact local provider stub executes after successful reproof" "$provider_marker"
rm -f "$provider_marker"
assert_rc "digest disagreement blocks before the provider marker" 2 \
  provider_harness exec digest codex "$provider_stub" "$wrapper_stub" "$profile_stub" "$provider_marker"
assert_no_file "digest failure launches no provider stub" "$provider_marker"
assert_rc "alternate executable argv blocks before the provider marker" 2 \
  provider_harness exec argv codex "$provider_stub" "$wrapper_stub" "$profile_stub" "$provider_marker"
assert_no_file "argv failure launches no provider stub" "$provider_marker"

t_case "closed codesign parsing distinguishes unsigned, ad-hoc, and team identities"
for signing_state in unsigned adhoc_signed team_signed; do
  signing_record="$(provider_harness signing-observation "$signing_state" none)"
  assert_ok "$signing_state has only its closed state-applicable fields" t_python - "$signing_record" "$signing_state" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); state=sys.argv[2]
assert d["state"]==state
if state=="unsigned":
    assert set(d)=={"state","display_result"}
    assert d["display_result"]["exit_code"]!=0
else:
    assert set(d)=={"state","identifier","team_identifier","cdhash","designated_requirement","codedirectory_flags","display_result","strict_verify_result"}
    assert len(d["cdhash"])==40 and d["strict_verify_result"]["exit_code"]==0
    assert (d["team_identifier"] is None and d["codedirectory_flags"]&2) if state=="adhoc_signed" else (len(d["team_identifier"])==10 and not d["codedirectory_flags"]&2)
for command in [d["display_result"]]+([] if state=="unsigned" else [d["strict_verify_result"]]):
    assert command["cwd"]=="/" and command["duration_ns"]==command["end_monotonic_ns"]-command["start_monotonic_ns"]
    assert set(command["stdout"])==set(command["stderr"])=={"bytes","sha256"}
PY
done
for signing_case in \
  "adhoc_signed missing-identifier" \
  "adhoc_signed duplicate-team" \
  "adhoc_signed mixed-team-adhoc" \
  "adhoc_signed bad-hash" \
  "adhoc_signed bad-requirement" \
  "adhoc_signed missing-adhoc-signature" \
  "adhoc_signed control-output" \
  "adhoc_signed unterminated-output" \
  "adhoc_signed verify-failure" \
  "adhoc_signed verify-identity-output" \
  "adhoc_signed verify-order" \
  "adhoc_signed display-digest-drift" \
  "team_signed signed-no-team-no-adhoc" \
  "team_signed bad-hash" \
  "team_signed bad-requirement" \
  "unsigned wrong-unsigned-path" \
  "unsigned unsigned-extra-output"; do
  set -- $signing_case
  assert_rc "$1 $2 is rejected before provider launch" 2 provider_harness signing-observation "$1" "$2"
  assert_no_file "$1 $2 leaves the provider marker absent" "$provider_marker"
done

t_case "guardian-owned native Mach-O capsule is byte-exact, kernel-read-only, and exactly detached"
native_source="$provider_root/native-provider.c"
native_provider="$provider_root/native-provider"
cat > "$native_source" <<'C'
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  const char *nonce = getenv("CAPSULE_NONCE");
  if (argc != 2 || nonce == NULL) return 19;
  printf("%s\n%s\n%s\n", argv[0], argv[1], nonce);
  return 0;
}
C
native_arch="$(t_python -c 'import platform; print(platform.machine())')"
assert_ok "local fixture compiles to a native Mach-O" /usr/bin/xcrun cc -arch "$native_arch" -Os -o "$native_provider" "$native_source"
chmod 700 "$native_provider"
assert_ok "local fixture receives an explicit ad-hoc signature without a private identity" \
  /usr/bin/codesign --force --sign - "$native_provider"
/usr/bin/xattr -w com.agentfirm.fixture readonly-capsule "$native_provider"
native_signing="$(provider_harness signing-record "$native_provider")"
assert_ok "native ad-hoc fixture has exact identity and explicit absent TeamIdentifier" \
  t_python - "$native_signing" <<'PY'
import json,re,sys
d=json.loads(sys.argv[1])
assert d["state"]=="adhoc_signed" and d["team_identifier"] is None and d["codedirectory_flags"]&2
assert d["identifier"] and re.fullmatch(r"[0-9a-f]{40}",d["cdhash"]) and d["designated_requirement"]
assert d["strict_verify_result"]["exit_code"]==0
PY
for signing_drift in identity team-appearance display-output verify-output; do
  assert_rc "mounted $signing_drift drift is rejected by dynamic reproof" 2 \
    provider_harness signing-reproof "$native_signing" "$signing_drift"
  assert_no_file "mounted $signing_drift drift leaves no provider marker" "$provider_marker"
done
unsigned_provider="$provider_root/native-provider-unsigned"
cp "$native_provider" "$unsigned_provider"; chmod 700 "$unsigned_provider"
assert_ok "local unsigned fixture has its signature removed without another identity" \
  /usr/bin/codesign --remove-signature "$unsigned_provider"
unsigned_signing="$(provider_harness signing-record "$unsigned_provider")"
assert_ok "native unsigned fixture exposes no signed identity or verify fields" t_python - "$unsigned_signing" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); assert d["state"]=="unsigned" and set(d)=={"state","display_result"}
PY
capsule_guardian="$($AUTH guardian-start --parent /private/tmp --launcher-pid $$)"
capsule_control="$(printf '%s\n' "$capsule_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["control"])')"
capsule_root="$(printf '%s\n' "$capsule_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["root"])')"
capsule_token="$(printf '%s\n' "$capsule_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
capsule_pid="$(printf '%s\n' "$capsule_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["guardian_pid"])')"
capsule_invocation="$(printf '%s\n' "$capsule_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["invocation"])')"
capsule_record="$(provider_harness capsule-build codex "$native_provider" "$capsule_control" "$capsule_token" "$capsule_invocation" "$capsule_pid")"
capsule_mounted="$(printf '%s\n' "$capsule_record" | t_python -c 'import json,sys; print(json.load(sys.stdin)["mounted"]["path"])')"
for signing_manifest_mutation in state identity team-appearance hash verify-failure extra; do
  assert_rc "manifest signing $signing_manifest_mutation mutation fails the closed capsule schema" 2 \
    provider_harness capsule-schema-mutate "$capsule_record" "$signing_manifest_mutation"
  assert_no_file "manifest signing $signing_manifest_mutation mutation leaves no provider marker" "$provider_marker"
done
assert_ok "manifest binds source, descriptor-copy, and mounted bytes plus native slice/xattr/signing" \
  t_python - "$capsule_record" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
assert d["macho"]["native_architecture"] in d["macho"]["architectures"]
assert d["guardian"]["capsule"]["state"]=="RO_ATTACHED"
assert d["guardian"]["capsule"]["attachment"]["readonly"] is True
assert "read-only" in d["guardian"]["capsule"]["attachment"]["options"]
assert "nobrowse" in d["guardian"]["capsule"]["attachment"]["options"]
assert [x["name"] for x in d["xattrs"]]==["com.agentfirm.fixture"]
for key in ("uid","mode","nlink","bytes","sha256"):
    assert d["source"][key]==d["copy"][key]==d["mounted"][key],key
assert set(d["signing"])=={"source","copy","mounted"}
identities=[]
for name in ("source","copy","mounted"):
    signed=d["signing"][name]
    assert signed["state"]=="adhoc_signed" and signed["team_identifier"] is None and signed["codedirectory_flags"]&2
    assert signed["display_result"]["argv"][-1]==d[name]["path"]
    assert signed["strict_verify_result"]["argv"][-1]==d[name]["path"]
    identities.append(tuple(signed[key] for key in ("state","identifier","team_identifier","cdhash","designated_requirement","codedirectory_flags")))
assert identities[0]==identities[1]==identities[2]
PY
assert_ok "mounted native fixture executes only its original nonce" env CAPSULE_NONCE=original-fixture-nonce \
  "$capsule_mounted" unchanged-argument
assert_ok "overwrite/truncate/rename/unlink/create are denied with EROFS" t_python - "$capsule_mounted" <<'PY'
import errno,os,sys
path=sys.argv[1]; root=os.path.dirname(path)
operations=(
    lambda:os.open(path,os.O_WRONLY),
    lambda:os.truncate(path,0),
    lambda:os.rename(path,path+".other"),
    lambda:os.unlink(path),
    lambda:os.open(os.path.join(root,"replacement"),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o700),
)
for operation in operations:
    try: operation()
    except OSError as exc: assert exc.errno==errno.EROFS,(exc.errno,exc)
    else: raise AssertionError("read-only mutation unexpectedly succeeded")
PY
printf 'mutated source after capsule seal\n' > "$native_provider"
assert_output "source-path mutation cannot change mounted output" original-fixture-nonce \
  env CAPSULE_NONCE=original-fixture-nonce "$capsule_mounted" unchanged-argument
assert_ok "guardian exact-detaches and removes the complete provider capsule after quiescence" \
  "$AUTH" guardian-command --control "$capsule_control" --token "$capsule_token" \
    --invocation "$capsule_invocation" --guardian-pid "$capsule_pid" --sequence 3 \
    --expected-roles '' --action cleanup
assert_no_file "guardian cleanup leaves no image, mount, descriptor, or root residue" "$capsule_root"

unsigned_guardian="$($AUTH guardian-start --parent /private/tmp --launcher-pid $$)"
unsigned_control="$(printf '%s\n' "$unsigned_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["control"])')"
unsigned_root="$(printf '%s\n' "$unsigned_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["root"])')"
unsigned_token="$(printf '%s\n' "$unsigned_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
unsigned_pid="$(printf '%s\n' "$unsigned_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["guardian_pid"])')"
unsigned_invocation="$(printf '%s\n' "$unsigned_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["invocation"])')"
unsigned_capsule="$(provider_harness capsule-build codex "$unsigned_provider" "$unsigned_control" "$unsigned_token" "$unsigned_invocation" "$unsigned_pid")"
assert_ok "unsigned state remains identical across source, writable copy, and read-only mount" \
  t_python - "$unsigned_capsule" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); records=d["signing"]
assert [records[name]["state"] for name in ("source","copy","mounted")]==["unsigned"]*3
assert all(set(records[name])=={"state","display_result"} for name in records)
PY
assert_ok "unsigned capsule cleanup removes every image and mount" \
  "$AUTH" guardian-command --control "$unsigned_control" --token "$unsigned_token" \
    --invocation "$unsigned_invocation" --guardian-pid "$unsigned_pid" --sequence 3 \
    --expected-roles '' --action cleanup
assert_no_file "unsigned capsule leaves no reusable residue" "$unsigned_root"

team_fixture=''
team_fixture_index=0
for candidate in \
  '/Applications/Visual Studio Code.app/Contents/MacOS/Code' \
  '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT' \
  '/Applications/Mersive Solstice.app/Contents/MacOS/SolsticeClient' \
  "$HOME/.local/bin/claude"; do
  [ -f "$candidate" ] || continue
  team_fixture_index=$((team_fixture_index+1))
  candidate_copy="$provider_root/team-fixture-$team_fixture_index"
  cp "$candidate" "$candidate_copy"; chmod 700 "$candidate_copy"
  if candidate_record="$(provider_harness signing-record "$candidate_copy" 2>/dev/null)" \
      && printf '%s\n' "$candidate_record" | t_python -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)["state"]=="team_signed" else 1)'; then
    team_fixture="$candidate_copy"; break
  fi
  rm -f "$candidate_copy"
done
if [ -n "$team_fixture" ]; then
  team_guardian="$($AUTH guardian-start --parent /private/tmp --launcher-pid $$)"
  team_control="$(printf '%s\n' "$team_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["control"])')"
  team_root="$(printf '%s\n' "$team_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["root"])')"
  team_token="$(printf '%s\n' "$team_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  team_pid="$(printf '%s\n' "$team_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["guardian_pid"])')"
  team_invocation="$(printf '%s\n' "$team_guardian" | t_python -c 'import json,sys; print(json.load(sys.stdin)["invocation"])')"
  team_capsule="$(provider_harness capsule-build codex "$team_fixture" "$team_control" "$team_token" "$team_invocation" "$team_pid")"
  assert_ok "available installed team signature and TeamIdentifier survive all three surfaces" t_python - "$team_capsule" <<'PY'
import json,re,sys
r=json.loads(sys.argv[1])["signing"]; values=[]
for name in ("source","copy","mounted"):
    d=r[name]; assert d["state"]=="team_signed" and re.fullmatch(r"[A-Z0-9]{10}",d["team_identifier"])
    values.append(tuple(d[k] for k in ("identifier","team_identifier","cdhash","designated_requirement","codedirectory_flags")))
assert values[0]==values[1]==values[2]
PY
  assert_ok "team-signed capsule cleanup removes every image and mount" \
    "$AUTH" guardian-command --control "$team_control" --token "$team_token" \
      --invocation "$team_invocation" --guardian-pid "$team_pid" --sequence 3 \
      --expected-roles '' --action cleanup
  assert_no_file "team-signed capsule leaves no reusable residue" "$team_root"
else
  t_skip "team-signed source/copy/mount fixture" "no installed local team-signed native fixture passes canonical strict verification"
fi

t_case "synchronized provider streaming and pre-exec mutations fail before launch"
for specification in \
  "provider_stream growth" \
  "provider_stream truncation" \
  "provider_stream content" \
  "provider_preexec content" \
  "provider_preexec replacement"; do
  set -- $specification; provider_phase="$1"; provider_mutation="$2"
  race_root="$(mktemp -d "${TMPDIR:-/tmp}/firm-provider-race.XXXXXX")"; t_track "$race_root"; chmod 700 "$race_root"
  race_root="$(cd "$race_root" && pwd -P)"
  race_target="$race_root/provider"; cp "$provider_small" "$race_target"; chmod 700 "$race_target"
  race_token="$(t_python -c 'import secrets; print(secrets.token_hex(32))')"
  race_invocation="$(t_python -c 'import secrets; print(secrets.token_hex(24))')"
  t_python - "$race_root" "$race_token" "$provider_phase" "$race_invocation" "$race_target" "$provider_mutation" <<'PY' &
import json,os,shutil,sys,time
root,token,phase,invocation,target,mutation=sys.argv[1:]
prefix=os.path.join(root,token+"."+phase)
ready,mutated,resume,release=[prefix+suffix for suffix in (".ready",".mutated",".resume",".release")]
deadline=time.monotonic()+10
while time.monotonic()<deadline and not os.path.exists(ready): time.sleep(.002)
if not os.path.exists(ready): raise SystemExit(3)
ready_doc=json.load(open(ready,encoding="ascii")); authority=ready_doc["authority_pid"]; os.kill(authority,0)
changed={"mutation":mutation,"target":target}
if mutation=="growth":
    fd=os.open(target,os.O_WRONLY|os.O_APPEND); os.write(fd,b"x"); os.fsync(fd); os.close(fd)
elif mutation=="truncation":
    os.truncate(target,os.stat(target).st_size-1)
elif mutation=="content":
    fd=os.open(target,os.O_WRONLY); os.write(fd,b"X"); os.fsync(fd); os.close(fd)
elif mutation=="replacement":
    original=target+".original"; os.rename(target,original); shutil.copyfile(original,target); os.chmod(target,0o700)
    changed["original"]=original
else: raise SystemExit(5)
record={"schema_version":1,"phase":phase,"token":token,"invocation":invocation,
        "mutator_pid":os.getpid(),"mutate_monotonic_ns":max(time.monotonic_ns(),ready_doc["enter_monotonic_ns"]+1),
        "changed":changed}
def publish(path,value):
    temporary=path+".publishing"
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    os.write(fd,(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode("ascii")); os.fsync(fd); os.close(fd)
    os.rename(temporary,path)
publish(mutated,record)
while time.monotonic()<deadline and not os.path.exists(resume): time.sleep(.002)
if not os.path.exists(resume): raise SystemExit(4)
release_doc={"schema_version":1,"phase":phase,"token":token,"invocation":invocation,
             "mutator_pid":os.getpid(),"release_monotonic_ns":time.monotonic_ns()}
publish(release,release_doc)
PY
  race_mutator=$!
  provider_harness barrier codex "$race_target" "$race_root" "$race_token" "$provider_phase" "$race_invocation" \
    > "$race_root/authority.out" 2> "$race_root/authority.err"
  race_rc=$?; wait "$race_mutator"; race_mutator_rc=$?
  if [ "$race_rc" -eq 2 ] && [ "$race_mutator_rc" -eq 0 ]; then
    _t_ok "$provider_phase $provider_mutation overlaps descriptor proof and is rejected"
  else
    _t_no "$provider_phase $provider_mutation overlaps descriptor proof and is rejected" \
      "authority_rc=$race_rc mutator_rc=$race_mutator_rc stderr=$(_t_ctx "$(cat "$race_root/authority.err")")"
  fi
  assert_no_file "$provider_phase $provider_mutation leaves the provider launch marker absent" "$provider_marker"
done

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

t_case "all six authenticated barriers overlap an independent mutator and fail closed"
for phase in manifest_read dispatch_commit use_exec cleanup_commit provider_stream provider_preexec; do
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
ready_doc=json.load(open(ready,encoding="ascii")); authority=ready_doc["authority_pid"]
os.kill(authority,0)
original=target+".original"; os.rename(target,original)
fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
os.write(fd,("mutated-%s\n"%phase).encode("ascii")); os.fsync(fd); os.close(fd)
record={"schema_version":1,"phase":phase,"token":token,"invocation":invocation,
        "mutator_pid":os.getpid(),"mutate_monotonic_ns":max(time.monotonic_ns(),ready_doc["enter_monotonic_ns"]+1),
        "changed":{"original":original,"replacement":target}}
def publish(path,value):
    temporary=path+".publishing"
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    os.write(fd,(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode("ascii")); os.fsync(fd); os.close(fd)
    os.rename(temporary,path)
publish(mutated,record)
while time.monotonic()<deadline and not os.path.exists(resume): time.sleep(.002)
if not os.path.exists(resume): raise SystemExit(4)
release_doc={"schema_version":1,"phase":phase,"token":token,"invocation":invocation,
             "mutator_pid":os.getpid(),"release_monotonic_ns":time.monotonic_ns()}
publish(release,release_doc)
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

t_case "guardian cleanup uses authenticated request/ACK while launcher liveness remains open"
g_ready="$($AUTH guardian-start --parent /private/tmp --launcher-pid $$)"
g_control="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["control"])')"
g_root="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["root"])')"
g_token="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
g_invocation="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["invocation"])')"
g_pid="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["guardian_pid"])')"
g_marker="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["failure_marker"])')"
t_track "$g_root"; t_track "$g_marker"
assert_ok "malformed unauthenticated frame receives NACK without advancing state" t_python - "$g_control/guardian.sock" "$g_token" <<'PY'
import hashlib,hmac,json,socket,sys
path,token=sys.argv[1:]
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(path); s.sendall(b'{broken-json\n'); s.shutdown(socket.SHUT_WR)
raw=b''
while True:
    part=s.recv(65536)
    if not part: break
    raw+=part
d=json.loads(raw); auth=d.pop('auth')
canonical=lambda value: json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True)
assert d['status']=='NACK'
assert hmac.compare_digest(auth,hmac.new(bytes.fromhex(token),canonical(d).encode('ascii'),hashlib.sha256).hexdigest())
PY
g_ack="$($AUTH guardian-command --control "$g_control" --token "$g_token" --invocation "$g_invocation" \
  --guardian-pid "$g_pid" --sequence 1 --expected-roles '' --action cleanup)"
assert_ok "terminal receipt is authenticated, bound, absent, and emitted before launcher exit" t_python - "$g_ack" "$g_token" "$$" <<'PY'
import hashlib,hmac,json,os,sys
d=json.loads(sys.argv[1]); auth=d.pop('auth')
canonical=lambda value: json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True)
assert d['status']=='TERMINAL_OK' and d['kind']=='terminal' and d['absent'] is True
assert d['deletion']=={'absent':True,'method':'parent_fd_relative','removed':True}
assert hmac.compare_digest(auth,hmac.new(bytes.fromhex(sys.argv[2]),canonical(d).encode('ascii'),hashlib.sha256).hexdigest())
os.kill(int(sys.argv[3]),0)
PY
assert_no_file "terminal success leaves no reusable guardian root" "$g_root"
assert_no_file "terminal success never emits a BLOCK marker" "$g_marker"

t_case "authenticated skipped sequence is terminal BLOCK and cannot delete twice"
g_ready="$($AUTH guardian-start --parent /private/tmp --launcher-pid $$)"
g_control="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["control"])')"
g_root="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["root"])')"
g_token="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
g_invocation="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["invocation"])')"
g_pid="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["guardian_pid"])')"
g_marker="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["failure_marker"])')"
t_track "$g_root"; t_track "$g_marker"
assert_rc "skipped cleanup sequence is rejected" 2 "$AUTH" guardian-command --control "$g_control" --token "$g_token" \
  --invocation "$g_invocation" --guardian-pid "$g_pid" --sequence 2 --expected-roles '' --action cleanup
count=0; while [ "$count" -lt 200 ] && [ ! -f "$g_marker" ]; do sleep 0.01; count=$((count+1)); done
assert_file "protocol fault emits the single visible BLOCK marker" "$g_marker"
assert_no_file "protocol-fault disposal removes only the pinned root" "$g_root"
assert_rc "retry after terminal uncertainty cannot recreate or delete again" 2 "$AUTH" guardian-command \
  --control "$g_control" --token "$g_token" --invocation "$g_invocation" --guardian-pid "$g_pid" \
  --sequence 1 --expected-roles '' --action cleanup
rm -f "$g_marker"

t_case "duplicate authenticated provider registration is replay-blocking and quiesces its group"
g_ready="$($AUTH guardian-start --parent /private/tmp --launcher-pid $$)"
g_control="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["control"])')"
g_root="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["root"])')"
g_token="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
g_invocation="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["invocation"])')"
g_pid="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["guardian_pid"])')"
g_marker="$(printf '%s\n' "$g_ready" | t_python -c 'import json,sys; print(json.load(sys.stdin)["failure_marker"])')"
g_child="$(mktemp "${TMPDIR:-/tmp}/guardian-provider-pid.XXXXXX")"; t_track "$g_child"; t_track "$g_root"; t_track "$g_marker"
"$BIN/firm-bounded-exec" --phase guardian-replay --provider test --timeout 20 --grace 1 -- \
  "$AUTH" guardian-exec --control "$g_control" --token "$g_token" --invocation "$g_invocation" \
    --guardian-pid "$g_pid" --sequence 1 --role provider -- /bin/sh -c 'printf "%s\n" "$$" > "$1"; sleep 20' sh "$g_child" &
g_bounded=$!
count=0; while [ "$count" -lt 200 ] && [ ! -s "$g_child" ]; do sleep 0.01; count=$((count+1)); done
assert_file "provider starts only after registration ACK" "$g_child"
g_child_pid="$(sed -n '1p' "$g_child")"
assert_rc "duplicate provider role cannot register or advance state" 2 "$AUTH" guardian-command \
  --control "$g_control" --token "$g_token" --invocation "$g_invocation" --guardian-pid "$g_pid" \
  --sequence 2 --action register --role provider --pid "$g_child_pid" --pgid "$g_child_pid"
wait "$g_bounded" 2>/dev/null || true
assert_ok "duplicate-registration BLOCK quiesces the authenticated process group" sh -c "! kill -0 '$g_child_pid' 2>/dev/null"
count=0; while [ "$count" -lt 200 ] && [ ! -f "$g_marker" ]; do sleep 0.01; count=$((count+1)); done
assert_file "replay fault remains visibly blocking" "$g_marker"
if [ -e "$g_root" ]; then
  assert_output "unprovable group absence prevents deletion and is recorded, never treated as success" \
    "cannot prove registered group absent" cat "$g_marker"
  assert_eq "blocking residue remains private and cannot be mistaken for a fresh capsule" 700 "$(stat -f %Lp "$g_root")"
else
  assert_no_file "replay fault disposes the pinned root after proven group absence" "$g_root"
fi
rm -f "$g_marker"

t_case "clean exact candidate gets one-use execution and P2-consumption receipts"
clean_native_provider="$provider_root/clean-native-provider"
assert_ok "clean capsule fixture compiles to the managed runtime's native Mach-O architecture" \
  /usr/bin/xcrun cc -arch "$native_arch" -Os -o "$clean_native_provider" "$native_source"
chmod 700 "$clean_native_provider"
assert_ok "clean capsule fixture receives an explicit ad-hoc signature without a private identity" \
  /usr/bin/codesign --force --sign - "$clean_native_provider"
assert_ok "clean capsule fixture carries a local xattr into the produced manifest" \
  /usr/bin/xattr -w com.agentfirm.schema schema-capsule "$clean_native_provider"
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
    --provider-executable "$clean_native_provider" --guardian-root "$guardian_root" --guardian-pid "$guardian_pid" \
    --guardian-token "$guardian_token" --guardian-failure-marker "$guardian_marker" --invocation "$invocation" \
    --scratch "$scratch" --fixture "$FIRM_ROOT/agent-firm/evals/final-evidence-seal/fixture" \
    --manifest "$control/manifest.json" --shims "$control/shims" \
    --request-root "$scratch/.eval-out/authority-requests" --response-root "$control/responses")"
  assert_ok "the real produced authority manifest satisfies only the closed canonical schema" \
    t_python - "$SCHEMA" "$control/manifest.json" <<'PY'
import copy,json,sys
from jsonschema import Draft202012Validator

schema=json.load(open(sys.argv[1],encoding="utf-8"))
manifest=json.load(open(sys.argv[2],encoding="utf-8"))
validator=Draft202012Validator(schema)
validator.validate(manifest)
assert manifest["guardian"]["protocol_version"]==3
assert manifest["provider_capsule"]["schema_version"]==1
assert manifest["provider_capsule"]["guardian"]["capsule"]["schema_version"]==1
assert manifest["provider_capsule"]["xattrs"]

def value_at(value,path):
    for part in path: value=value[part]
    return value

def object_paths(value,path=()):
    if isinstance(value,dict):
        yield path
        for key,item in value.items(): yield from object_paths(item,path+(key,))
    elif isinstance(value,list):
        for index,item in enumerate(value): yield from object_paths(item,path+(index,))

# Every field emitted anywhere in the new capsule tree is required, and every object boundary is
# closed. These mutations use the real producer output rather than a hand-maintained fixture.
capsule=manifest["provider_capsule"]
paths=list(object_paths(capsule))
field_count=0
for path in paths:
    original=value_at(capsule,path)
    for key in original:
        candidate=copy.deepcopy(manifest)
        value_at(candidate["provider_capsule"],path).pop(key)
        assert not validator.is_valid(candidate),("missing",path,key)
        field_count+=1
    candidate=copy.deepcopy(manifest)
    value_at(candidate["provider_capsule"],path)["unexpected_schema_field"]=True
    assert not validator.is_valid(candidate),("extra",path)
assert field_count>=100 and len(paths)>=25,(field_count,len(paths))

candidate=copy.deepcopy(manifest); candidate.pop("provider_capsule")
assert not validator.is_valid(candidate)
for path in (("schema_version",),("guardian","capsule","schema_version")):
    candidate=copy.deepcopy(manifest)
    target=value_at(candidate["provider_capsule"],path[:-1]); target[path[-1]]+=1
    assert not validator.is_valid(candidate),("version",path)
candidate=copy.deepcopy(manifest); candidate["guardian"]["protocol_version"]=2
assert not validator.is_valid(candidate)

for phase in ("capsule_copy","capsule_preexec"):
    candidate=copy.deepcopy(manifest)
    import hashlib,os
    root=manifest["guardian"]["control"]; st=os.lstat(root)
    root_identity={"dev":st.st_dev,"ino":st.st_ino,"uid":st.st_uid,"mode":st.st_mode&0o7777}
    encoded=json.dumps(root_identity,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode("ascii")
    token="0"*64
    candidate["test_barrier"]={"enabled":True,"protocol_version":2,"root":root,
        "root_identity":root_identity,"root_binding":hashlib.sha256(encoded).hexdigest(),
        "token":token,"token_sha256":hashlib.sha256(bytes.fromhex(token)).hexdigest(),
        "phase":phase,"invocation":manifest["invocation"]}
    validator.validate(candidate)
    candidate["test_barrier"]["phase"]=phase+"_unexpected"
    assert not validator.is_valid(candidate),phase
PY
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
  guardian_sequence=3
  "$AUTH" guardian-exec --control "$control" --token "$guardian_token" --invocation "$invocation" \
    --guardian-pid "$guardian_pid" --sequence "$guardian_sequence" --role broker -- \
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
      --invocation "$invocation" --control "$control" --token "$guardian_token" --guardian-pid "$guardian_pid" \
      --sequence 4 --expected-roles broker
    chmod 700 "$scratch"
    assert_ok "guardian removes complete capsule" "$AUTH" cleanup --manifest "$control/manifest.json" --digest "$digest" \
      --invocation "$invocation" --control "$control" --token "$guardian_token" --guardian-pid "$guardian_pid" \
      --sequence 4 --expected-roles broker
    assert_no_file "capsule leaves no reusable residue" "$guardian_root"
  else
    kill "$broker" 2>/dev/null || true; wait "$broker" 2>/dev/null || true
    _t_no "private authority broker starts" "socket unavailable"
  fi
fi

t_summary
