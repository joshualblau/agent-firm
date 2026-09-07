#!/usr/bin/env bash
# tests/test-eval-capsule-attacks.sh — AC-048 post-validation capsule attacks, on the ACTUAL chain.
#
# WHAT THIS PROVES, and why nothing cheaper would. firm-eval-authority validates the provider
# executable and then execs it by PATHNAME. Every check-then-use pair has a window, and a window
# that is only argued about on paper is a window nobody has measured. So this suite opens that exact
# window on purpose — under an authenticated barrier the wrapper itself controls — mutates the
# validated binary from an independent, live process while the wrapper is stopped inside it, and
# then requires the run to end in exactly one of two states: the ORIGINAL binary's output carrying
# this case's nonce, or a terminal BLOCK. Never the replacement's output, and never an ambiguous
# third thing.
#
# WHAT IS NOT EVIDENCE HERE (all four were deliberately rejected):
#   · running the fixture directly — proves nothing about the wrapper;
#   · a standalone barrier probe — exercises the barrier, not the exec path it guards;
#   · mutating before or after the run instead of inside the window — that is not a race;
#   · invoking a real provider — this suite never does, and tests/test-run-evals-structural.sh
#     asserts that it never does.
# The chain each case traverses is the real one, link for link:
#   firm-bounded-exec -> firm-eval-authority guardian-exec -> firm-eval-authority provider-exec
#   -> /usr/bin/sandbox-exec (Seatbelt) -> /usr/bin/env -> terminal provider-exec -> os.execve.
# The only thing standing in for a provider is a locally compiled, ad-hoc-signed Mach-O fixture that
# this suite builds itself in a temporary directory and deletes afterwards.
#
# EVERYTHING IS BOUNDED. There is no unbounded loop, wait, or teardown anywhere below: every wait is
# a deadline loop, the mutation loop is bounded by both a deadline and an iteration cap, every
# subprocess carries a timeout, and disposal is a fixed sequence that verifies its own result.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

t_case "authenticated capsule_preexec attacks traverse the actual local wrapper chain"
if [ "$(uname -s)" != Darwin ] || [ ! -x /usr/bin/sandbox-exec ] || [ ! -x /usr/bin/hdiutil ] \
    || [ ! -x /usr/bin/xcrun ] || [ ! -x /usr/bin/codesign ] || [ ! -x /usr/bin/xattr ]; then
  t_skip "AC-048 actual-chain attack matrix" "requires macOS Seatbelt, disk images, compiler, and local ad-hoc signing"
  t_summary
  exit $?
fi
# `prepare` refuses a dirty candidate on purpose: it binds the harness commit into the manifest, and
# a dirty tree makes "which candidate ran" unanswerable. Announced rather than silently dropped.
if [ -n "$(git -C "$FIRM_ROOT" status --porcelain --untracked-files=all)" ]; then
  t_skip "AC-048 actual-chain attack matrix" "candidate checkout must be clean so authority preparation can bind it"
  t_summary
  exit $?
fi

report="$(mktemp "${TMPDIR:-/tmp}/firm-capsule-attacks.XXXXXX")"; t_track "$report"
errors="$(mktemp "${TMPDIR:-/tmp}/firm-capsule-attacks-errors.XXXXXX")"; t_track "$errors"
t_python - "$FIRM_ROOT" >"$report" 2>"$errors" <<'PY'
import errno
import hashlib
import hmac
import json
import os
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT=Path(sys.argv[1]).resolve()
AUTH=ROOT/"bin/firm-eval-authority"
BOUNDED=ROOT/"bin/firm-bounded-exec"
FIXTURE=ROOT/"agent-firm/evals/final-evidence-seal/fixture"
PHASE="capsule_preexec"
# Bounds. Every one of these is a ceiling, never a poll count without a clock.
PREPARE_TIMEOUT=180
COMMAND_TIMEOUT=60
CHAIN_TIMEOUT=90
CHAIN_WALL_SECONDS=40
BARRIER_WAIT_SECONDS=30
JOIN_SECONDS=45
# The wrapper's own barrier deadline. `late` must exceed it to be late at all.
WRAPPER_BARRIER_TIMEOUT=10
LOOP_DEADLINE_SECONDS=3
LOOP_MAX_ITERATIONS=2000
# Errnos that mean "the kernel refused this mutation". A refusal is a legitimate outcome — it is in
# fact the outcome the read-only capsule is designed to produce. Anything OUTSIDE this set is an
# unclassified failure and is reported as one rather than quietly folded into "blocked".
REFUSAL_ERRNOS={errno.EROFS,errno.EACCES,errno.EPERM,errno.EBUSY,errno.ETXTBSY,errno.ENOENT,
                errno.EINVAL,errno.ENOTSUP}

def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True)

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def signed(token,unsigned):
    value=dict(unsigned)
    value["auth"]=hmac.new(bytes.fromhex(token),canonical(unsigned).encode("ascii"),hashlib.sha256).hexdigest()
    return value

def run(argv,check=True,timeout=COMMAND_TIMEOUT,**kwargs):
    result=subprocess.run([str(item) for item in argv],timeout=timeout,stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE,**kwargs)
    if check and result.returncode:
        raise AssertionError("command failed rc=%d argv=%r stderr=%s"%(
            result.returncode,argv,result.stderr.decode("utf-8","replace")[:1000]))
    return result

def wait_path(path,timeout=BARRIER_WAIT_SECONDS):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if path.exists(): return True
        time.sleep(.005)
    return False

def publish(path,value,raw=None):
    # Create-then-rename so a reader never observes a partial record: the wrapper's own state machine
    # requires each record to be canonical and authenticated, and a torn write would be neither.
    temporary=Path(str(path)+".publishing")
    payload=raw if raw is not None else (canonical(value)+"\n").encode("ascii")
    fd=os.open(str(temporary),os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        view=memoryview(payload)
        while view:
            count=os.write(fd,view)
            if count<=0: raise AssertionError("short barrier write")
            view=view[count:]
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(str(temporary),str(path))

def read_signed(path,token):
    raw=path.read_bytes(); value=json.loads(raw.decode("ascii"))
    assert raw==(canonical(value)+"\n").encode("ascii"),"barrier record is not canonical"
    unsigned=dict(value); auth=unsigned.pop("auth")
    expected=hmac.new(bytes.fromhex(token),canonical(unsigned).encode("ascii"),hashlib.sha256).hexdigest()
    assert hmac.compare_digest(auth,expected),"barrier record failed authentication"
    return value,unsigned,sha(raw)

def repository_identity():
    # Deliberately NOT a content hash of the common directory: git legitimately rewrites its own
    # index and log files, and a check that goes red for that is a check nobody will trust. What must
    # not move is the commit, the cleanliness, the ref set, the worktree set, and the common dir.
    def out(*args):
        return run(["git","-C",str(ROOT)]+list(args)).stdout.decode("utf-8","replace")
    return {"head":out("rev-parse","HEAD").strip(),
            "status":out("status","--porcelain","--untracked-files=all"),
            "common_dir":out("rev-parse","--path-format=absolute","--git-common-dir").strip(),
            "refs_sha256":sha(out("show-ref").encode("utf-8")),
            "worktrees_sha256":sha(out("worktree","list","--porcelain").encode("utf-8"))}

def mount_lines():
    raw=run(["/sbin/mount"],timeout=COMMAND_TIMEOUT).stdout.decode("utf-8","replace")
    return sorted(line for line in raw.splitlines() if "firm-eval-" in line)

def residue_snapshot():
    # The disposal proof, stated as a SET DIFFERENCE rather than an absolute count. /private/tmp is
    # shared: this host already carries capsule roots and BLOCK markers from earlier runs of other
    # suites, and a test that demanded "none exist" would either be red for somebody else's residue
    # or be quietly deleting evidence that is not its to delete. What this suite is answerable for is
    # that it added nothing — every attachment, image, mountpoint, guardian root, failure marker and
    # barrier root it created is gone by the end. (This global view is also why the file is
    # classified `runs_alone` in tests/run-tests.sh.)
    parent=Path("/private/tmp")
    def matching(pattern,kind):
        found=set()
        with os.scandir(parent) as entries:
            for entry in entries:
                if not entry.name.startswith(pattern): continue
                try: st=os.lstat(entry.path)
                except FileNotFoundError: continue
                if kind=="dir" and stat.S_ISDIR(st.st_mode): found.add(entry.name)
                if kind=="file" and stat.S_ISREG(st.st_mode): found.add(entry.name)
        return sorted(found)
    return {"mounts":mount_lines(),
            "guardian_roots":matching("firm-eval-","dir"),
            "failure_markers":matching("firm-eval-block-","file"),
            "barrier_roots":matching("firm-capsule-barrier-","dir"),
            "suite_roots":matching("firm-capsule-attack-suite.","dir")}

def strict_dispose_barrier(root):
    # The barrier root is ours and holds only regular 0600 single-link files this run wrote. Anything
    # else is unexplained residue and must fail loudly rather than be swept away by a recursive
    # delete — which is also why there is no rmtree anywhere in this file.
    root=Path(root); st=os.lstat(root)
    assert stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode) and st.st_uid==os.getuid()
    names=[]
    with os.scandir(root) as entries:
        listing=list(entries)
    for entry in listing:
        child=os.lstat(entry.path)
        assert stat.S_ISREG(child.st_mode) and child.st_uid==os.getuid() and child.st_nlink==1,entry.path
        assert stat.S_IMODE(child.st_mode)==0o600,entry.path
        names.append(entry.name)
        os.unlink(entry.path)
    os.rmdir(root)
    assert not root.exists()
    return sorted(name.rsplit(".",1)[-1] for name in names)

def dispose_tree(root):
    # Bounded, shape-checked disposal of a directory this suite created. Depth-first over a snapshot,
    # refusing symlinks and anything not owned by us.
    root=Path(root)
    if not root.exists(): return
    for current,dirs,files in os.walk(str(root),topdown=False,followlinks=False):
        for name in files:
            path=os.path.join(current,name)
            st=os.lstat(path)
            assert st.st_uid==os.getuid() and not stat.S_ISDIR(st.st_mode),path
            os.unlink(path)
        for name in dirs:
            path=os.path.join(current,name)
            st=os.lstat(path)
            if stat.S_ISLNK(st.st_mode): os.unlink(path)
            else: os.rmdir(path)
    os.rmdir(str(root))
    assert not root.exists()

def pid_absent(pid,timeout=15):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try: os.kill(pid,0)
        except ProcessLookupError: return True
        except PermissionError: return False
        time.sleep(.01)
    return False

repository_before=repository_identity()
residue_before=residue_snapshot()

suite_root=Path(tempfile.mkdtemp(prefix="firm-capsule-attack-suite.",dir="/private/tmp")).resolve()
os.chmod(suite_root,0o700)
original_template=suite_root/"original-provider"
replacement=suite_root/"replacement-provider"
source_c=suite_root/"original.c"; replacement_c=suite_root/"replacement.c"
# The original prints a per-case nonce it can only have received through the real chain, plus the
# argv it was actually given. The replacement prints a string that must never appear anywhere.
source_c.write_text(r'''#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  const char *nonce=getenv("CAPSULE_NONCE");
  if (argc!=2 || nonce==NULL) return 19;
  printf("ORIGINAL:%s\nARGV0:%s\nARG1:%s\n",nonce,argv[0],argv[1]);
  return 0;
}
''',encoding="ascii")
replacement_c.write_text(r'''#include <stdio.h>
int main(void) { puts("REPLACEMENT-EXECUTED"); return 0; }
''',encoding="ascii")
arch=run([ROOT/"bin/firm-python","-c","import platform; print(platform.machine())"]).stdout.decode().strip()
for source,target in ((source_c,original_template),(replacement_c,replacement)):
    run(["/usr/bin/xcrun","cc","-arch",arch,"-Os","-o",target,source])
    os.chmod(target,0o700)
    run(["/usr/bin/codesign","--force","--sign","-",target])

records=[]

def setup_case(name,barrier_enabled=True):
    case_root=Path(tempfile.mkdtemp(prefix="case-%s."%name.replace("_","-"),dir=str(suite_root))).resolve()
    os.chmod(case_root,0o700)
    source=case_root/"provider"
    shutil.copyfile(original_template,source); os.chmod(source,0o700)
    run(["/usr/bin/xattr","-w","com.agentfirm.attack",name,source])
    barrier=Path(tempfile.mkdtemp(prefix="firm-capsule-barrier-",dir="/private/tmp")).resolve()
    os.chmod(barrier,0o700)
    token=os.urandom(32).hex(); invocation=os.urandom(24).hex()
    start=[AUTH,"guardian-start","--parent","/private/tmp","--launcher-pid",str(os.getpid()),
           "--invocation",invocation]
    barrier_args=["--test-barrier-root",barrier,"--test-barrier-token",token,"--test-barrier-phase",PHASE]
    if barrier_enabled: start += barrier_args
    guardian=json.loads(run(start).stdout)
    scratch=Path(guardian["capsule"]); (scratch/".eval-out").mkdir(mode=0o700)
    prepare=[AUTH,"prepare","--root",ROOT,"--eval","final-evidence-seal","--provider","codex",
             "--provider-executable",source,"--guardian-root",guardian["root"],
             "--guardian-pid",str(guardian["guardian_pid"]),"--guardian-token",guardian["token"],
             "--guardian-failure-marker",guardian["failure_marker"],"--invocation",invocation,
             "--scratch",scratch,"--fixture",FIXTURE,"--manifest",Path(guardian["control"])/"manifest.json",
             "--shims",Path(guardian["control"])/"shims","--request-root",scratch/".eval-out/authority-requests",
             "--response-root",Path(guardian["control"])/"responses"]
    if barrier_enabled: prepare += barrier_args
    prepared=json.loads(run(prepare,timeout=PREPARE_TIMEOUT).stdout)
    manifest=json.loads(Path(prepared["manifest"]).read_text("ascii"))
    return {"name":name,"case_root":case_root,"source":source,"barrier":barrier,"token":token,
            "guardian":guardian,"prepared":prepared,"manifest":manifest,"invocation":invocation,
            "wrapper_pid":None,"mutation_error":None,"loop_count":0,"changed":None}

def state_paths(ctx):
    # Filenames carry the DIGEST of the token, never the token: listing the directory must not
    # publish the secret that authenticates its contents.
    token_id=sha(bytes.fromhex(ctx["token"]))
    prefix=ctx["barrier"]/(token_id+"."+PHASE)
    return {name:Path(str(prefix)+"."+name) for name in ("ready","mutated","resume","release","consumed")}

def attempt(operation):
    try:
        return {"outcome":"succeeded","value":operation()}
    except OSError as exc:
        classified=exc.errno in REFUSAL_ERRNOS
        return {"outcome":"refused" if classified else "unclassified",
                "errno":exc.errno,"errno_name":errno.errorcode.get(exc.errno,"?")}

def apply_attack(ctx,mode,ready):
    manifest=ctx["manifest"]; mounted=Path(ready["mounted"]["path"])
    source=Path(manifest["provider_capsule"]["source"]["path"])
    attachment=manifest["provider_capsule"]["guardian"]["capsule"]["attachment"]
    image=manifest["provider_capsule"]["guardian"]["capsule"]["image"]["path"]
    if mode=="success": return {"axis":"success","outcome":"no mutation"}
    if mode=="release_to_exec_loop":
        # This axis deliberately mutates NOTHING here. Its whole point is the interval AFTER the
        # wrapper's authenticated release, so the mutation happens in the bounded loop below rather
        # than at the synchronized mutation point.
        return {"axis":mode,"outcome":"deferred to the post-release loop"}
    if mode=="mounted_overwrite":
        def overwrite():
            fd=os.open(mounted,os.O_WRONLY|os.O_NOFOLLOW)
            try: return os.write(fd,b"X")
            finally: os.close(fd)
        return {"axis":mode,**attempt(overwrite)}
    if mode=="mounted_truncate": return {"axis":mode,**attempt(lambda:os.truncate(mounted,0))}
    if mode=="mounted_rename":
        moved=Path(str(mounted)+".renamed"); result=attempt(lambda:os.rename(mounted,moved))
        if result["outcome"]=="succeeded": ctx["mounted_rename"]=(moved,mounted)
        return {"axis":mode,**result}
    if mode=="mounted_unlink": return {"axis":mode,**attempt(lambda:os.unlink(mounted))}
    if mode=="mounted_replacement":
        unlink=attempt(lambda:os.unlink(mounted))
        create=attempt(lambda:str(shutil.copyfile(replacement,mounted)))
        return {"axis":mode,"unlink":unlink,"create":create}
    if mode=="original_path_mutation":
        # The SOURCE the capsule was built from, replaced wholesale. The mounted copy is the
        # authority after sealing, so this must not change what runs.
        old=Path(str(source)+".original")
        os.rename(source,old); shutil.copyfile(replacement,source); os.chmod(source,0o700)
        return {"axis":mode,"original":str(old),"replacement":str(source)}
    if mode=="original_inode_mutation":
        # Same file, same inode, different bytes — the mutation a rename check would miss.
        raw=replacement.read_bytes(); fd=os.open(source,os.O_WRONLY|os.O_TRUNC|os.O_NOFOLLOW)
        try:
            view=memoryview(raw)
            while view: view=view[os.write(fd,view):]
            os.fsync(fd)
        finally: os.close(fd)
        return {"axis":mode,"bytes":len(raw),"inode":os.lstat(source).st_ino}
    if mode=="sibling_source_fd_close_reuse":
        # A sibling process frees a descriptor number and immediately reuses it for the replacement.
        # Recorded honestly: this happens in the MUTATOR, and its point is that a descriptor NUMBER
        # is not part of the wrapper's authority chain in the first place.
        first=os.open(source,os.O_RDONLY|os.O_NOFOLLOW); os.close(first)
        second=os.open(replacement,os.O_RDONLY|os.O_NOFOLLOW); os.close(second)
        return {"axis":mode,"performed_in":"mutator","closed_fd":first,"reused_fd":second,
                "number_reused":first==second}
    if mode=="detach":
        done=run(["/usr/bin/hdiutil","detach",attachment["device"]],check=False,timeout=COMMAND_TIMEOUT)
        return {"axis":mode,"exit_code":done.returncode,"stderr_sha256":sha(done.stderr)}
    if mode=="remount":
        done=run(["/usr/bin/hdiutil","attach","-kernel","-readonly","-nobrowse","-owners","on",
                  "-mountpoint",attachment["mountpoint"],"-plist",image],check=False,timeout=COMMAND_TIMEOUT)
        extra=[]
        if done.returncode==0:
            value=plistlib.loads(done.stdout)
            extra=[item["dev-entry"] for item in value.get("system-entities",[])
                   if isinstance(item,dict) and item.get("dev-entry")!=attachment["device"]]
            ctx["unexpected_devices"]=extra
        return {"axis":mode,"exit_code":done.returncode,"additional_devices":extra,
                "stderr_sha256":sha(done.stderr)}
    if mode=="shadow":
        mountpoint=Path(attachment["mountpoint"]); moved=Path(str(mountpoint)+".shadowed")
        rename=attempt(lambda:os.rename(mountpoint,moved))
        link={"outcome":"not_attempted"}
        if rename["outcome"]=="succeeded":
            link=attempt(lambda:os.symlink(str(replacement.parent),str(mountpoint)))
            ctx["shadow_restore"]=(mountpoint,moved)
        return {"axis":mode,"rename":rename,"link":link}
    raise AssertionError("unknown attack "+mode)

# Modes that publish a MUTATED record and then stop, because the record itself is the attack.
STOP_AFTER_MUTATED={"malformed","forged","cross_capsule","wrong_process"}
# Modes that never touch the barrier at all.
NO_BARRIER_TRAFFIC={"absent","inherited","early","replay"}
# Modes whose "mutation" is a signal rather than a filesystem change.
SIGNAL_MODES={"wrapper_sigterm":signal.SIGTERM,"wrapper_sigint":signal.SIGINT,
              "wrapper_sigkill":signal.SIGKILL}

def mutate(ctx,mode,stop):
    try:
        paths=state_paths(ctx)
        if mode in NO_BARRIER_TRAFFIC: return
        assert wait_path(paths["ready"]),"wrapper never published READY"
        _,ready,ready_sha=read_signed(paths["ready"],ctx["token"])
        ctx["wrapper_pid"]=ready["wrapper_pid"]
        if mode in SIGNAL_MODES:
            os.kill(ready["wrapper_pid"],SIGNAL_MODES[mode]); return
        if mode=="guardian_sigterm":
            os.kill(ctx["guardian"]["guardian_pid"],signal.SIGTERM); return
        common={key:ready[key] for key in ("schema_version","protocol_version","phase","token_sha256",
            "invocation","barrier_root","barrier_root_binding","wrapper_pid","capsule_digest",
            "mounted","logical_argv")}
        structural={"malformed","forged","cross_capsule","wrong_process","duplicate","late"}
        changed={"axis":mode} if mode in structural else apply_attack(ctx,mode,ready)
        ctx["changed"]=changed
        mutation={**common,"state":"MUTATED","enter_monotonic_ns":ready["enter_monotonic_ns"],
                  "ready_sha256":ready_sha,"mutator_pid":os.getpid(),
                  "mutate_monotonic_ns":max(time.monotonic_ns(),ready["enter_monotonic_ns"]+1),
                  "changed":changed}
        if mode=="malformed": publish(paths["mutated"],{},raw=b"{\n"); return
        if mode=="cross_capsule": mutation["capsule_digest"]="0"*64
        if mode=="wrong_process": mutation["wrapper_pid"]+=1
        value=signed(ctx["token"],mutation)
        if mode=="forged": value["auth"]="0"*64
        publish(paths["mutated"],value)
        if mode in STOP_AFTER_MUTATED: return
        if mode=="duplicate": publish(Path(str(paths["mutated"])+".duplicate"),signed(ctx["token"],mutation))
        assert wait_path(paths["resume"]),"wrapper never published RESUME"
        _,resume,resume_sha=read_signed(paths["resume"],ctx["token"])
        if mode=="late": time.sleep(WRAPPER_BARRIER_TIMEOUT+0.5)
        release={**common,"state":"RELEASE","enter_monotonic_ns":ready["enter_monotonic_ns"],
                 "ready_sha256":ready_sha,"mutator_pid":os.getpid(),
                 "mutation_sha256":sha((canonical(value)+"\n").encode("ascii")),
                 "resume_sha256":resume_sha,"release_monotonic_ns":time.monotonic_ns()}
        publish(paths["release"],signed(ctx["token"],release))
        if mode=="release_to_exec_loop":
            # The one interval revalidation cannot close: from the wrapper's authenticated release
            # through the pathname exec itself. Bounded twice — by a deadline AND by an iteration
            # cap — so a wrapper that dies early can never leave this spinning.
            mounted=Path(ready["mounted"]["path"]); payload=replacement.read_bytes()[:4096]
            deadline=time.monotonic()+LOOP_DEADLINE_SECONDS
            while (not stop.is_set() and time.monotonic()<deadline
                   and ctx["loop_count"]<LOOP_MAX_ITERATIONS):
                try:
                    descriptor=os.open(mounted,os.O_WRONLY|os.O_NOFOLLOW)
                except OSError as exc:
                    assert exc.errno in REFUSAL_ERRNOS,(exc.errno,str(exc))
                else:
                    try: os.write(descriptor,payload); os.fsync(descriptor)
                    finally: os.close(descriptor)
                ctx["loop_count"]+=1
                time.sleep(.0005)
    except BaseException as exc:
        ctx["mutation_error"]="%s: %s"%(type(exc).__name__,exc)

def cleanup_case(ctx,guardian_alive=True,cleanup_fault=False,barrier_env=None):
    guardian=ctx["guardian"]
    # Undo only what an attack actually managed to change, and only in the exact shape it changed it.
    if "shadow_restore" in ctx:
        mountpoint,moved=ctx["shadow_restore"]
        if mountpoint.is_symlink(): os.unlink(mountpoint)
        if moved.exists(): os.rename(moved,mountpoint)
    if "mounted_rename" in ctx:
        moved,mounted=ctx["mounted_rename"]
        if moved.exists() and not mounted.exists(): os.rename(moved,mounted)
    for device in ctx.get("unexpected_devices",[]):
        removed=run(["/usr/bin/hdiutil","detach",device],check=False,timeout=COMMAND_TIMEOUT)
        assert removed.returncode==0,(device,removed.stderr.decode("utf-8","replace"))
    terminal=None
    if guardian_alive:
        cleanup=[AUTH,"cleanup","--manifest",ctx["prepared"]["manifest"],
                 "--digest",ctx["prepared"]["manifest_digest"],"--invocation",ctx["invocation"],
                 "--control",guardian["control"],"--token",guardian["token"],
                 "--guardian-pid",str(guardian["guardian_pid"]),"--sequence","4",
                 "--expected-roles","provider"]
        if cleanup_fault:
            # A capsule whose mode drifted is ambiguous, and ambiguity must BLOCK rather than be
            # cleaned up optimistically. The guardian survives the refusal and cleans up correctly
            # once the ambiguity is gone.
            os.chmod(guardian["capsule"],0o755)
            first=run(cleanup,check=False,timeout=COMMAND_TIMEOUT,env=barrier_env)
            assert first.returncode==2,(first.returncode,first.stderr.decode("utf-8","replace")[:400])
            os.chmod(guardian["capsule"],0o700)
        terminal=json.loads(run(cleanup,timeout=COMMAND_TIMEOUT,env=barrier_env).stdout)
        assert terminal["status"]=="TERMINAL_OK" and terminal["absent"] is True
        assert terminal["capsule_detach"]["absent"] is True and terminal["deletion"]["absent"] is True
        assert terminal["deletion"]["removed"] is True
        disposition="TERMINAL_OK"
    else:
        # The guardian owns lifecycle cleanup even when it dies mid-run: it must quiesce every
        # registered group, dispose the capsule, and leave an authenticated BLOCK marker behind.
        deadline=time.monotonic()+CHAIN_WALL_SECONDS
        while time.monotonic()<deadline and Path(guardian["root"]).exists(): time.sleep(.02)
        assert not Path(guardian["root"]).exists(),"guardian root survived guardian death"
        marker=Path(guardian["failure_marker"])
        assert wait_path(marker),"guardian published no failure marker"
        marker_value=json.loads(marker.read_bytes().decode("ascii"))
        assert marker_value["status"]=="BLOCK"
        marker_unsigned=dict(marker_value); marker_auth=marker_unsigned.pop("auth")
        expected=hmac.new(bytes.fromhex(guardian["token"]),canonical(marker_unsigned).encode("ascii"),
                          hashlib.sha256).hexdigest()
        assert hmac.compare_digest(marker_auth,expected)
        marker.unlink()
        disposition="TERMINAL_BLOCK_DISPOSED"
    assert not Path(guardian["root"]).exists(),"guardian root residue"
    assert not Path(ctx["manifest"]["provider_capsule"]["guardian"]["capsule"]["image"]["path"]).exists()
    assert not Path(ctx["manifest"]["provider_capsule"]["guardian"]["capsule"]["attachment"]["mountpoint"]).exists()
    if ctx["wrapper_pid"] is not None:
        assert pid_absent(ctx["wrapper_pid"]),"wrapper %r still live"%ctx["wrapper_pid"]
    states=strict_dispose_barrier(ctx["barrier"])
    dispose_tree(ctx["case_root"])
    return disposition,states

def execute_case(name,mode=None,cleanup_fault=False,barrier_enabled=True):
    mode=mode or name; ctx=setup_case(name,barrier_enabled)
    paths=state_paths(ctx)
    # `early` and `replay` plant well-formed state BEFORE the wrapper arrives. The wrapper must
    # refuse to start on a root that already holds state rather than adopt it.
    if mode=="early":
        publish(paths["release"],signed(ctx["token"],{"state":"RELEASE","phase":PHASE,
                "invocation":ctx["invocation"],"token_sha256":sha(bytes.fromhex(ctx["token"]))}))
    if mode=="replay":
        publish(paths["consumed"],signed(ctx["token"],{"state":"CONSUMED","phase":PHASE,
                "invocation":ctx["invocation"],"token_sha256":sha(bytes.fromhex(ctx["token"]))}))
    stop=threading.Event(); worker=threading.Thread(target=mutate,args=(ctx,mode,stop),daemon=True)
    # The no-traffic axes are exactly the ones whose attack is the ABSENCE of a live counterparty
    # (or state planted before one could exist), so for those there is deliberately no mutator at all.
    synchronized=mode not in NO_BARRIER_TRAFFIC
    if synchronized: worker.start()
    manifest=ctx["manifest"]; guardian=ctx["guardian"]; prepared=ctx["prepared"]
    # The barrier's four variables are the wrapper's OWN channel and must reach every authority
    # process in the chain that loads the manifest — but never the provider, which provider_exec
    # strips them for. `inherited` deliberately supplies them ONLY through the inner `env`, against a
    # manifest that carries no barrier at all, which is precisely what must be refused.
    assignments=[]
    if barrier_enabled or mode=="inherited":
        assignments=["FIRM_EVAL_TEST_BARRIER_ROOT="+str(ctx["barrier"]),
                     "FIRM_EVAL_TEST_BARRIER_TOKEN="+ctx["token"],
                     "FIRM_EVAL_TEST_BARRIER_INVOCATION="+ctx["invocation"],
                     "FIRM_EVAL_TEST_BARRIER_PHASE="+PHASE]
    assignments += ["CAPSULE_NONCE=nonce-"+name]
    chain_env=dict(os.environ)
    if barrier_enabled:
        chain_env.update({"FIRM_EVAL_TEST_BARRIER_ROOT":str(ctx["barrier"]),
                          "FIRM_EVAL_TEST_BARRIER_TOKEN":ctx["token"],
                          "FIRM_EVAL_TEST_BARRIER_INVOCATION":ctx["invocation"],
                          "FIRM_EVAL_TEST_BARRIER_PHASE":PHASE})
    output=ctx["case_root"]/"stdout"; stderr=ctx["case_root"]/"stderr"; result=ctx["case_root"]/"result.json"
    chain=[BOUNDED,"--phase","capsule-attack","--provider","fixture","--timeout",str(CHAIN_WALL_SECONDS),
           "--grace","1","--max-output","262144","--output",output,"--stderr-output",stderr,
           "--result",result,"--cwd",guardian["capsule"],
           "--",AUTH,"guardian-exec","--control",guardian["control"],"--token",guardian["token"],
           "--invocation",ctx["invocation"],"--guardian-pid",str(guardian["guardian_pid"]),
           "--sequence","3","--role","provider",
           "--",AUTH,"provider-exec","--manifest",prepared["manifest"],
           "--digest",prepared["manifest_digest"],"--invocation",ctx["invocation"],
           "--","/usr/bin/sandbox-exec","-D","REAL_COMMON="+manifest["seatbelt"]["real_common"],
           "-f",manifest["seatbelt"]["profile"]["path"],"/usr/bin/env"]+assignments+[
           manifest["provider_capsule"]["mounted"]["path"],"attack-"+name]
    done=run(chain,check=False,timeout=CHAIN_TIMEOUT,env=chain_env)
    stop.set()
    if synchronized:
        worker.join(JOIN_SECONDS)
        assert not worker.is_alive(),"mutator did not finish within its bound"
    if ctx["mutation_error"]:
        raise AssertionError("%s [%s]; bounded_rc=%s stderr=%s"%(ctx["mutation_error"],name,
            done.returncode,stderr.read_text("utf-8",errors="replace")[:600] if stderr.exists() else ""))
    result_doc=json.loads(result.read_text("ascii")); raw=output.read_text("utf-8",errors="replace")
    wrapper_stderr=stderr.read_text("utf-8",errors="replace") if stderr.exists() else ""
    # THE INVARIANT. Two outcomes are permitted and no third one is.
    assert "REPLACEMENT-EXECUTED" not in raw,"replacement binary executed on axis "+name
    success=(done.returncode==0 and result_doc["status"]=="ok")
    blocked=(done.returncode!=0 and result_doc["status"] in ("exit","timeout","turn_limit"))
    assert success!=blocked,("ambiguous outcome",name,done.returncode,result_doc["status"],raw[:400])
    if success:
        assert "ORIGINAL:nonce-"+name in raw and "ARG1:attack-"+name in raw,(name,raw[:400])
    else:
        assert "ORIGINAL:" not in raw,(name,raw[:400])
    # Every authentication axis must BLOCK. A pass here would mean forged, replayed, cross-capsule or
    # wrong-process state was accepted as this run's own.
    if mode in NO_BARRIER_TRAFFIC or mode in STOP_AFTER_MUTATED or mode in ("duplicate","late"):
        assert blocked,("authentication axis was not blocked",name,raw[:400])
        assert "firm-eval-authority:" in wrapper_stderr,(name,wrapper_stderr[:400])
    guardian_alive=mode!="guardian_sigterm"
    disposition,states=cleanup_case(ctx,guardian_alive=guardian_alive,cleanup_fault=cleanup_fault,
                                    barrier_env=chain_env if barrier_enabled else None)
    records.append({"axis":name,"mode":mode,"outcome":"original" if success else "BLOCK",
                    "wrapper_pid_disposed":ctx["wrapper_pid"] is not None,
                    "loop_iterations":ctx["loop_count"],"barrier_states":states,
                    "changed":ctx["changed"],"guardian_cleanup":disposition,
                    "wrapper_reason":wrapper_stderr.strip().split(": ")[-1][:80] if not success else None})

# The mutation matrix: every axis mutates the validated binary, its backing store, its mount, or its
# source, inside the post-validation window.
MUTATION_AXES=["success","mounted_overwrite","mounted_truncate","mounted_rename","mounted_unlink",
               "mounted_replacement","original_path_mutation","original_inode_mutation",
               "sibling_source_fd_close_reuse","detach","remount","shadow","release_to_exec_loop"]
# The authentication and lifecycle matrix: every way barrier state can be wrong, plus every way the
# run can die while inside the window.
AUTH_AXES=["absent","malformed","forged","replay","cross_capsule","early","late","duplicate",
           "wrong_process","inherited","wrapper_sigterm","wrapper_sigint","wrapper_sigkill",
           "guardian_sigterm"]

for axis in MUTATION_AXES: execute_case(axis,cleanup_fault=(axis=="success"))
for axis in AUTH_AXES: execute_case("auth-"+axis,mode=axis,barrier_enabled=(axis!="inherited"))

loop=next(row for row in records if row["axis"]=="release_to_exec_loop")
assert loop["loop_iterations"]>0,"the release-to-exec loop never ran an iteration"
assert len(records)==len(MUTATION_AXES)+len(AUTH_AXES)
assert all(row["outcome"] in ("original","BLOCK") for row in records)
for row in records:
    if row["mode"] in set(NO_BARRIER_TRAFFIC)|set(STOP_AFTER_MUTATED)|{"duplicate","late"}:
        assert row["outcome"]=="BLOCK",row

dispose_tree(suite_root)
repository_after=repository_identity()
assert repository_after==repository_before,(repository_before,repository_after)
residue_after=residue_snapshot()
added={key:sorted(set(residue_after[key])-set(residue_before[key])) for key in residue_before}
assert not any(added.values()),("residue added by this suite",added)

print(canonical({"schema_version":1,
                 "actual_chain":["firm-bounded-exec","guardian-exec","provider-exec",
                                 "/usr/bin/sandbox-exec","/usr/bin/env","terminal provider-exec",
                                 "os.execve"],
                 "local_fixture":"compiled_ad_hoc_signed_macho",
                 "mutation_axes":len(MUTATION_AXES),"authentication_axes":len(AUTH_AXES),
                 "blocked":sum(1 for row in records if row["outcome"]=="BLOCK"),
                 "original":sum(1 for row in records if row["outcome"]=="original"),
                 "repository_unchanged":True,
                 "residue_added":{key:len(value) for key,value in added.items()},
                 "suite_root_absent":not suite_root.exists(),
                 "cases":records}))
PY
rc=$?
if [ "$rc" -eq 0 ]; then
  _t_ok "every mutation, authentication, death, and cleanup axis yields original output or terminal BLOCK"
else
  _t_no "every mutation, authentication, death, and cleanup axis yields original output or terminal BLOCK" \
    "rc=$rc $(_t_ctx "$(cat "$errors")")"
  sed -n '1,25p' "$errors"
  t_summary
  exit $?
fi

# The report is the evidence, so it is asserted over rather than merely printed.
assert_ok "the real chain was traversed link for link with a local compiled fixture and no provider" \
  t_python - "$report" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1],encoding="ascii"))
assert doc["actual_chain"]==["firm-bounded-exec","guardian-exec","provider-exec","/usr/bin/sandbox-exec",
                             "/usr/bin/env","terminal provider-exec","os.execve"]
assert doc["local_fixture"]=="compiled_ad_hoc_signed_macho"
PY
assert_ok "all thirteen mutation axes ran inside the window and none produced replacement output" \
  t_python - "$report" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1],encoding="ascii"))
axes={row["axis"] for row in doc["cases"]}
for axis in ("mounted_overwrite","mounted_truncate","mounted_rename","mounted_unlink",
             "mounted_replacement","original_path_mutation","original_inode_mutation",
             "sibling_source_fd_close_reuse","detach","remount","shadow","release_to_exec_loop"):
    assert axis in axes,axis
assert doc["mutation_axes"]==13 and doc["authentication_axes"]==14
loop=next(row for row in doc["cases"] if row["axis"]=="release_to_exec_loop")
assert loop["loop_iterations"]>0 and loop["outcome"]=="original"
PY
assert_ok "every absent, malformed, forged, replayed, cross-capsule, early, late, duplicate, inherited, or wrong-process state blocked" \
  t_python - "$report" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1],encoding="ascii"))
by_mode={row["mode"]:row for row in doc["cases"]}
for mode in ("absent","malformed","forged","replay","cross_capsule","early","late","duplicate",
             "wrong_process","inherited"):
    assert by_mode[mode]["outcome"]=="BLOCK",mode
    assert by_mode[mode]["wrapper_reason"],mode
PY
assert_ok "wrapper and guardian death both quiesce the run and dispose the capsule" \
  t_python - "$report" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1],encoding="ascii"))
by_mode={row["mode"]:row for row in doc["cases"]}
for mode in ("wrapper_sigterm","wrapper_sigint","wrapper_sigkill"):
    assert by_mode[mode]["outcome"]=="BLOCK" and by_mode[mode]["guardian_cleanup"]=="TERMINAL_OK",mode
    assert by_mode[mode]["wrapper_pid_disposed"],mode
assert by_mode["guardian_sigterm"]["guardian_cleanup"]=="TERMINAL_BLOCK_DISPOSED"
assert all(row["guardian_cleanup"] in ("TERMINAL_OK","TERMINAL_BLOCK_DISPOSED") for row in doc["cases"])
PY
assert_ok "no mount, image, mountpoint, barrier, or capsule-root residue survives, and the repository is unchanged" \
  t_python - "$report" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1],encoding="ascii"))
assert doc["suite_root_absent"] is True
assert set(doc["residue_added"])=={"mounts","guardian_roots","failure_markers","barrier_roots","suite_roots"}
assert all(count==0 for count in doc["residue_added"].values()),doc["residue_added"]
assert doc["repository_unchanged"] is True
assert doc["blocked"]+doc["original"]==len(doc["cases"])==27
PY
# Print the per-axis outcome, so the log itself records which axes ran and how each one ended
# rather than only that "everything passed".
t_python - "$report" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1],encoding="ascii"))
for row in doc["cases"]:
    print("         %-34s %-8s %s"%(row["axis"],row["outcome"],row["guardian_cleanup"]))
PY

t_summary
