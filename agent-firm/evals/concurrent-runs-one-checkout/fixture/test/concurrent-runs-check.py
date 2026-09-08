#!/usr/bin/env python3
"""Golden check: two runs sharing ONE working tree do not collide (AC-002, AC-004, AC-011, AC-012).

WHY THIS FILE EXISTS, AND WHAT WOULD MAKE IT WORTHLESS
`02-architecture-options.md` F2: `firm-integrate` used to `git switch` the CALLER'S OWN HEAD onto
the integration branch, verify `HEAD == <intb>`, and then merge in a loop. HEAD is one slot per
working tree and the verify-to-last-merge window is unbounded, so the check was TOCTOU across the
whole loop: two invocations in one working tree can interleave so that A's check passes, B moves
HEAD out from under it, and A's remaining merges land somewhere else entirely.

A fixture that runs run A to completion and *then* runs run B cannot observe any of that. It would
pass against the broken tools and against the fixed ones alike, which is the failure AC-012 exists
to prevent, in the exact words of the Plan of record's "Note for WO-7's author". So the properties
below do not merely *overlap* two processes and hope the scheduler is unkind: they PARK one process
at a chosen point inside the operation under test, using a git hook as the rendezvous, drive the
other process start-to-finish while it is demonstrably still parked there, and only then release it.
The overlap is asserted from observed evidence (P*.2 in each property), not assumed.

THE FIVE PROPERTIES

  P1 (AC-002, AC-004, AC-012)  The adversarial interleave, driven through the AMBIENT pointer --
     the zero-argument invocation form, which every generation of these tools accepts. Run A is
     parked between its first and second merge; while it is parked the ambient pointer is moved to
     run B, run B integrates start-to-finish, and the caller's HEAD is moved to a third branch
     (`decoy`). Then A is released. This is the single most important property in the file: because
     the invocation form is identical on the pre-change and post-change tools, a difference in the
     outcome is attributable to the behaviour change and to nothing about the interface.

  P2 (AC-002, AC-004)  The same interleave driven through the EXPLICIT `--run` selector, with the
     ambient pointer parked on a third, decoy run for the whole property. Adds AC-002's other half:
     the explicit selector must drive the merge-source glob AND the ledger the result is recorded
     in, so the decoy run's ledger must stay empty.

  P3 (AC-001, AC-004)  The QA-checkout half of AC-004. Run A's capture is parked INSIDE its
     `git worktree add` (via `post-checkout`), run B's capture runs to completion while it is
     parked, and each run's `09-test-evidence/qa-candidate.json` must be bound to its OWN candidate
     SHA and generation.

  P4 (AC-011)  Rollback, including the residual per-run integration worktree that the delivered
     `firm-integrate` leaves behind: it must be removable by `git worktree remove` / `prune` without
     leaving the shared working tree's registration inconsistent, and a run created under the new
     behaviour must stay resolvable afterwards.

EXIT CODES, AND WHY THERE ARE THREE
  0  every property held.
  1  a property FAILED. The reason is printed and names the assertion and what was observed.
  2  the check could not be evaluated (fail closed). Most importantly: if a rendezvous times out
     while the parked process is STILL RUNNING, the parking mechanism itself is broken and this
     exits 2 rather than degrading to a sequential fixture and reporting a pass. A sequential run of
     these properties proves nothing, so it must never be reachable.

  Note the deliberate asymmetry: a process that EXITS before reaching its rendezvous is a FAILURE
  (exit 1) with its own output quoted, not a "cannot evaluate". That is the shape the pre-change
  tools take when handed `--run` -- they refuse the flag and exit -- and refusing to produce run A's
  artifacts at all is precisely the AC-001/AC-002 defect, not an inconclusive result.

WHICH CHECKOUT IS UNDER TEST
The eval fixture is copied to a scratch directory that contains no copy of the firm, so the firm is
resolved through `firm-integrate` on PATH and can be pinned with FIRM_CONCURRENT_RUNS_ROOT. It
refuses to run at all (exit 2) rather than guess.
"""

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

TOOLS = ("firm-integrate", "firm-qa-checkout", "firm-new-run")

PARK_TIMEOUT = 60.0     # seconds to wait for a rendezvous marker
FINISH_TIMEOUT = 120.0  # seconds to wait for a released process to exit
POLL = 0.02

failures = []


def cannot(message):
    print("CANNOT EVALUATE: " + message, file=sys.stderr)
    raise SystemExit(2)


def prop(name):
    print()
    print("=== %s ===" % name)


def ok(label):
    print("ok  : %s" % label)


def fail(label, *detail):
    failures.append(label)
    print("FAIL: %s" % label)
    for line in detail:
        for physical in str(line).splitlines():
            print("      %s" % physical)


def check(cond, label, *detail):
    if cond:
        ok(label)
    else:
        fail(label, *detail)
    return bool(cond)


def not_evaluated(reason, labels):
    """Record labels that could not be reached. An unrun check must never read as a passing one."""
    for label in labels:
        failures.append(label)
        print("FAIL: %s" % label)
        print("      NOT EVALUATED -- %s, so this assertion was never" % reason)
        print("      run. It is counted as a failure, never as a pass.")


# ------------------------------------------------------------------------------------------------
# Locate the firm under test.
# ------------------------------------------------------------------------------------------------
def firm_root():
    override = os.environ.get("FIRM_CONCURRENT_RUNS_ROOT")
    candidates = []
    if override:
        candidates.append(override)
    tool = shutil.which("firm-integrate")
    if tool:
        candidates.append(os.path.dirname(os.path.dirname(os.path.realpath(tool))))
    for candidate in candidates:
        if all(os.path.isfile(os.path.join(candidate, "bin", t)) for t in TOOLS):
            return os.path.realpath(candidate)
    cannot(
        "cannot locate a firm checkout providing %s.\n"
        "  Tried: %s\n"
        "  Set FIRM_CONCURRENT_RUNS_ROOT=<checkout root>, or put the firm's bin/ on PATH.\n"
        "  Refusing to guess: a check that cannot find its subject must not report a pass."
        % (", ".join(TOOLS), ", ".join(candidates) or "(nothing on PATH, no override)")
    )


# ------------------------------------------------------------------------------------------------
# Small git / process helpers.
# ------------------------------------------------------------------------------------------------
def run(args, cwd=None, env=None, check_rc=False):
    proc = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if check_rc and proc.returncode != 0:
        cannot(
            "fixture setup command failed (rc=%d): %s\n  stdout: %s\n  stderr: %s"
            % (proc.returncode, " ".join(args), proc.stdout.strip(), proc.stderr.strip())
        )
    return proc


def git(repo, *args, **kw):
    return run(["git", "-C", repo] + list(args), **kw)


def rev(repo, ref):
    proc = git(repo, "rev-parse", "--verify", "%s^{commit}" % ref)
    return proc.stdout.strip() if proc.returncode == 0 else None


def has_path(repo, ref, path):
    return git(repo, "cat-file", "-e", "%s:%s" % (ref, path)).returncode == 0


def refs_containing(repo, path):
    """Every local branch whose tip contains <path>. Used to say where a lost merge actually went."""
    listing = git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads")
    found = []
    for name in listing.stdout.split():
        if has_path(repo, name, path):
            found.append(name)
    return found


def head_ref(repo):
    proc = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD")
    return proc.stdout.strip() if proc.returncode == 0 else "(detached)"


def ledger_events(run_dir, event):
    """Rows in <run_dir>/run.jsonl whose `event` field equals <event>. Tolerant of key spacing."""
    path = os.path.join(run_dir, "run.jsonl")
    rows = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get("event") == event:
                    rows.append(row)
    except FileNotFoundError:
        pass
    return rows


def tail(text, limit=6):
    lines = [l for l in (text or "").strip().splitlines() if l.strip()]
    return "\n".join(lines[-limit:]) if lines else "(no output)"


# ------------------------------------------------------------------------------------------------
# Fixture construction.
# ------------------------------------------------------------------------------------------------
class Fixture(object):
    def __init__(self, root, firm):
        self.firm = firm
        self.bin = os.path.join(firm, "bin")
        self.root = root
        self.repo = os.path.realpath(tempfile.mkdtemp(dir=root, prefix="repo-"))
        self.gate = os.path.realpath(tempfile.mkdtemp(dir=root, prefix="gate-"))
        self.out = os.path.realpath(tempfile.mkdtemp(dir=root, prefix="out-"))
        run(["git", "init", "-q", self.repo], check_rc=True)
        git(self.repo, "symbolic-ref", "HEAD", "refs/heads/main", check_rc=True)
        git(self.repo, "config", "user.email", "eval@agent-firm.local", check_rc=True)
        git(self.repo, "config", "user.name", "concurrent-runs eval", check_rc=True)
        git(self.repo, "config", "commit.gpgsign", "false", check_rc=True)
        # Keep the ledger out of every commit, exactly as firm-new-worktree does in production.
        # Without it a work-order branch's `git add -A` swallows .agent-firm/ and switching branches
        # deletes CURRENT_RUN out from under the next command.
        common = git(self.repo, "rev-parse", "--git-common-dir", check_rc=True).stdout.strip()
        if not os.path.isabs(common):
            common = os.path.join(self.repo, common)
        self.gitdir = os.path.realpath(common)
        os.makedirs(os.path.join(self.gitdir, "info"), exist_ok=True)
        with open(os.path.join(self.gitdir, "info", "exclude"), "a", encoding="utf-8") as handle:
            handle.write(".agent-firm/\n.agent-firm-worktree.env\n")
        with open(os.path.join(self.repo, "seed.txt"), "w", encoding="utf-8") as handle:
            handle.write("seed\n")
        git(self.repo, "add", "-A", check_rc=True)
        git(self.repo, "commit", "-qm", "seed", check_rc=True)

    # -- runs ------------------------------------------------------------------------------------
    def new_run(self, slug):
        """Create a run with the firm's own firm-new-run (byte-identical pre- and post-change, so it
        cannot itself be the thing that differs) and return its run id."""
        proc = run([os.path.join(self.bin, "firm-new-run"), slug, "fast_path"], cwd=self.repo)
        if proc.returncode != 0:
            cannot("firm-new-run %s failed (rc=%d): %s" % (slug, proc.returncode, tail(proc.stderr)))
        return os.path.basename(self.current_run())

    def current_run(self):
        with open(os.path.join(self.repo, ".agent-firm", "CURRENT_RUN"), encoding="utf-8") as h:
            return h.read().strip()

    def point_at(self, run_id):
        with open(os.path.join(self.repo, ".agent-firm", "CURRENT_RUN"), "w", encoding="utf-8") as h:
            h.write(".agent-firm/runs/%s\n" % run_id)

    def run_dir(self, run_id):
        return os.path.join(self.repo, ".agent-firm", "runs", run_id)

    def rel_run_dir(self, run_id):
        return ".agent-firm/runs/%s" % run_id

    # -- branches --------------------------------------------------------------------------------
    def work_order_branch(self, run_id, wo, filename):
        branch = "wt/%s-implementer-%s" % (run_id, wo)
        here = head_ref(self.repo)
        git(self.repo, "checkout", "-q", "-b", branch, "main", check_rc=True)
        with open(os.path.join(self.repo, filename), "w", encoding="utf-8") as handle:
            handle.write("%s\n" % wo)
        git(self.repo, "add", "-A", check_rc=True)
        git(self.repo, "commit", "-qm", "work order %s" % wo, check_rc=True)
        git(self.repo, "checkout", "-q", here, check_rc=True)
        return branch

    def integration_branch(self, run_id, filename):
        """An integration/<run_id> branch built with PLAIN GIT, so a property that only exercises
        firm-qa-checkout does not depend on firm-integrate having worked."""
        branch = "integration/%s" % run_id
        here = head_ref(self.repo)
        git(self.repo, "checkout", "-q", "-b", branch, "main", check_rc=True)
        with open(os.path.join(self.repo, filename), "w", encoding="utf-8") as handle:
            handle.write("integrated\n")
        git(self.repo, "add", "-A", check_rc=True)
        git(self.repo, "commit", "-qm", "integrated %s" % run_id, check_rc=True)
        git(self.repo, "checkout", "-q", here, check_rc=True)
        return branch

    # -- the rendezvous --------------------------------------------------------------------------
    def install_hook(self, name, body):
        hooks = os.path.join(self.gitdir, "hooks")
        os.makedirs(hooks, exist_ok=True)
        path = os.path.join(hooks, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.chmod(path, 0o755)

    def arm(self):
        open(os.path.join(self.gate, "arm"), "w").close()

    def release(self):
        open(os.path.join(self.gate, "release"), "w").close()

    def parked(self):
        return os.path.exists(os.path.join(self.gate, "parked"))

    def spawn(self, argv, name):
        """Start a tool in the background with its output captured to a file."""
        path = os.path.join(self.out, "%s.txt" % name)
        handle = open(path, "w", encoding="utf-8")
        proc = subprocess.Popen(argv, cwd=self.repo, stdout=handle, stderr=subprocess.STDOUT)
        proc._firm_out = path       # noqa: SLF001 - test scaffolding, not a public API
        proc._firm_handle = handle  # noqa: SLF001
        return proc

    @staticmethod
    def output_of(proc):
        try:
            with open(proc._firm_out, encoding="utf-8") as handle:  # noqa: SLF001
                return handle.read()
        except OSError:
            return ""


PARK_HOOK = """#!/bin/sh
# Rendezvous for the concurrent-runs golden eval. Parks the FIRST process that reaches the chosen
# point for the armed run, and holds it there until the eval releases it. One-shot: the arm file is
# removed on entry, so a later process (or a later merge in the same loop) runs straight through.
[ -f "%(gate)s/arm" ] || exit 0
%(guard)s
rm -f "%(gate)s/arm"
: > "%(gate)s/parked"
i=0
while [ ! -f "%(gate)s/release" ]; do
  i=$((i+1))
  [ "$i" -gt %(spins)d ] && exit 0
  sleep 0.02
done
exit 0
"""


def merge_park_hook(fixture, run_id):
    """post-merge fires after a merge COMPLETES -- index written, HEAD updated, locks released -- so
    the parked process sits BETWEEN two iterations of firm-integrate's merge loop. That is the exact
    window F2 describes, and it is why this is a post-merge hook and not a merge driver: a driver
    would park inside `git merge` while it holds index.lock, which serialises the two processes
    through git's own locking and so tests something weaker than the race under test.

    The guard is on the branch HEAD is on, which reads `integration/<run_id>` under BOTH tool
    generations -- the caller's checkout pre-change, the run's own integration worktree post-change
    -- so the same hook parks the same operation either way."""
    return PARK_HOOK % {
        "gate": fixture.gate,
        "spins": int(PARK_TIMEOUT / POLL) + 500,
        "guard": (
            'b="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo none)"\n'
            '[ "$b" = "integration/%s" ] || exit 0' % run_id
        ),
    }


def checkout_park_hook(fixture, run_id):
    """post-checkout fires inside `git worktree add`, with the new worktree as the working directory,
    so the parked process sits in the middle of firm-qa-checkout MATERIALISING its checkout."""
    return PARK_HOOK % {
        "gate": fixture.gate,
        "spins": int(PARK_TIMEOUT / POLL) + 500,
        "guard": 'case "$(pwd)" in */qa-checkout/%s) ;; *) exit 0 ;; esac' % run_id,
    }


class Rendezvous(object):
    """Result of waiting for a process to reach its parking point.

    `parked`  - it got there, and was still running when we looked.
    `exited`  - it terminated first. That is a FAILURE with a stated reason (the process's own
                output), not an inconclusive result.
    `stuck`   - neither happened inside the timeout: the mechanism is broken and the caller must
                exit 2 rather than continue into a sequential fixture.
    """

    def __init__(self, state, proc, detail=""):
        self.state = state
        self.proc = proc
        self.detail = detail


def wait_for_park(fixture, proc, timeout=PARK_TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if fixture.parked():
            # The marker alone is not enough. The hook writes it and THEN blocks, so a process that
            # has already exited by the time we look was not parked when the other run started --
            # and the overlap assertion would be claiming something that did not happen. Both
            # conditions, or it is not a park.
            if proc.poll() is None:
                return Rendezvous("parked", proc)
            return Rendezvous("exited", proc, Fixture.output_of(proc))
        if proc.poll() is not None:
            return Rendezvous("exited", proc, Fixture.output_of(proc))
        time.sleep(POLL)
    return Rendezvous("stuck", proc)


def wait_for_exit(proc, timeout=FINISH_TIMEOUT):
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        return False
    finally:
        try:
            proc._firm_handle.close()  # noqa: SLF001
        except Exception:
            pass
    return True


def merged_branches(output):
    """The `merging <branch> ... ok` lines firm-integrate prints, in order."""
    return re.findall(r"^merging\s+(\S+)\s", output or "", re.MULTILINE)


# ------------------------------------------------------------------------------------------------
# P1 -- the adversarial interleave through the AMBIENT pointer.
# ------------------------------------------------------------------------------------------------
def property_one(firm, root):
    prop("P1 (AC-002, AC-004, AC-012) adversarial interleave, ambient pointer, one working tree")
    print("    Run A is parked BETWEEN its first and second merge. While it is parked the ambient")
    print("    pointer is moved to run B, run B integrates start-to-finish, and the caller's HEAD")
    print("    is moved to a third branch. Only then is A released.")
    print("    Both invocations are the ZERO-ARGUMENT form, which every generation of this tool")
    print("    accepts -- so any difference in outcome is the behaviour, not the interface.")

    fx = Fixture(root, firm)
    a = fx.new_run("alpha")
    b = fx.new_run("bravo")
    for wo, name in (("wo1", "alpha1.txt"), ("wo2", "alpha2.txt")):
        fx.work_order_branch(a, wo, name)
    for wo, name in (("wo1", "bravo1.txt"), ("wo2", "bravo2.txt")):
        fx.work_order_branch(b, wo, name)
    fx.install_hook("post-merge", merge_park_hook(fx, a))

    main_before = rev(fx.repo, "main")
    caller_before = head_ref(fx.repo)

    fx.point_at(a)
    fx.arm()
    proc_a = fx.spawn([os.path.join(fx.bin, "firm-integrate")], "p1-a")

    labels = [
        "P1.3 run A's merges all landed on run A's own integration branch",
        "P1.4 run A's integration branch carries none of run B's work",
        "P1.5 run B's integration branch carries none of run A's work",
        "P1.6 run B's merges all landed on run B's own integration branch",
        "P1.7 the caller's own HEAD was not written through while A was in flight",
        "P1.8 the default branch never moved",
        "P1.9 each run's integration event is recorded in that run's own ledger",
        "P1.10 each invocation merged only its own run's work-order branches",
    ]

    try:
        rendezvous = wait_for_park(fx, proc_a)
        if rendezvous.state == "stuck":
            cannot(
                "run A never reached its parking point inside firm-integrate's merge loop, and is\n"
                "  still running after %.0fs. The rendezvous mechanism (a post-merge hook) is broken,\n"
                "  so this property cannot be evaluated. It is NOT reported as a pass and it is NOT\n"
                "  retried sequentially: a sequential fixture proves nothing here (AC-012)."
                % PARK_TIMEOUT
            )
        if rendezvous.state == "exited":
            fail(
                "P1.2 the two runs genuinely overlapped in wall-clock time",
                "run A's firm-integrate exited (rc=%s) before it reached its first merge, so no"
                % proc_a.returncode,
                "interleave was established. Its own output was:",
                tail(rendezvous.detail),
            )
            not_evaluated("the interleave above could not be established", labels)
            return

        t_park = time.monotonic()
        caller_while_parked = head_ref(fx.repo)
        print("      run A is parked inside its merge loop; the caller's checkout is on %r"
              % caller_while_parked)

        # --- run B, start to finish, while A is demonstrably still parked ---------------------
        fx.point_at(b)
        t_b_start = time.monotonic()
        proc_b = subprocess.run(
            [os.path.join(fx.bin, "firm-integrate")],
            cwd=fx.repo, capture_output=True, text=True,
        )
        t_b_end = time.monotonic()
        a_alive_at_b_end = proc_a.poll() is None

        # --- move the caller's HEAD out from under the parked process --------------------------
        git(fx.repo, "checkout", "-q", "-b", "decoy")
        decoy_before = rev(fx.repo, "decoy")

        t_release = time.monotonic()
        fx.release()
        if not wait_for_exit(proc_a):
            cannot("run A did not exit within %.0fs after the gate was released" % FINISH_TIMEOUT)
        out_a = Fixture.output_of(proc_a)

        # -- P1.1 ------------------------------------------------------------------------------
        check(
            proc_a.returncode == 0 and proc_b.returncode == 0,
            "P1.1 neither invocation failed because the other was running",
            "run A rc=%s, run B rc=%s (AC-004 requires both to complete)"
            % (proc_a.returncode, proc_b.returncode),
            "run A output:\n%s" % tail(out_a),
            "run B output:\n%s" % tail(proc_b.stdout + proc_b.stderr),
        )

        # -- P1.2: the overlap, from evidence rather than assumption ---------------------------
        check(
            a_alive_at_b_end and t_park <= t_b_start < t_b_end <= t_release,
            "P1.2 the two runs genuinely overlapped in wall-clock time",
            "run A was observed parked inside firm-integrate at t=%.3fs; run B ran from %.3fs to"
            % (t_park - t_park, t_b_start - t_park),
            "%.3fs; run A's process was%s still alive when run B exited; the gate opened at %.3fs."
            % (t_b_end - t_park, "" if a_alive_at_b_end else " NOT", t_release - t_park),
            "A sequential fixture cannot satisfy this assertion, which is why it is here.",
        )

        # -- P1.3 / P1.4 -----------------------------------------------------------------------
        int_a = "integration/%s" % a
        int_b = "integration/%s" % b
        missing = [f for f in ("alpha1.txt", "alpha2.txt") if not has_path(fx.repo, int_a, f)]
        detail = [
            "expected %s to contain alpha1.txt and alpha2.txt (both of run A's work orders)" % int_a,
            "absent from it: %s" % ", ".join(missing),
        ]
        for name in missing:
            elsewhere = refs_containing(fx.repo, name)
            detail.append("  %s is instead reachable from: %s"
                          % (name, ", ".join(elsewhere) or "no branch at all"))
        claimed = re.search(r"^integration branch: .*$", out_a, re.MULTILINE)
        detail.append("run A's own report claimed: %s"
                      % (claimed.group(0) if claimed else "(it printed no such line)"))
        detail.append(
            "This is F2: the merges that ran after the caller's HEAD moved landed wherever HEAD"
        )
        detail.append(
            "was pointing, while the tool went on reporting the branch it had selected. AC-004"
        )
        detail.append("requires the tool to stop sharing the caller's HEAD at all.")
        check(not missing, labels[0], *detail)

        strays = [f for f in ("bravo1.txt", "bravo2.txt") if has_path(fx.repo, int_a, f)]
        check(not strays, labels[1],
              "%s contains run B's work: %s" % (int_a, ", ".join(strays)))

        # -- P1.5 / P1.6 -----------------------------------------------------------------------
        strays = [f for f in ("alpha1.txt", "alpha2.txt") if has_path(fx.repo, int_b, f)]
        check(not strays, labels[2],
              "%s contains run A's work: %s" % (int_b, ", ".join(strays)),
              "Run B's integration branch was created while run A was parked with the shared HEAD",
              "on its own integration branch, so run B's branch inherited run A's merges.")

        missing = [f for f in ("bravo1.txt", "bravo2.txt") if not has_path(fx.repo, int_b, f)]
        check(not missing, labels[3],
              "expected %s to contain bravo1.txt and bravo2.txt; absent: %s"
              % (int_b, ", ".join(missing)))

        # -- P1.7 ------------------------------------------------------------------------------
        decoy_after = rev(fx.repo, "decoy")
        check(
            head_ref(fx.repo) == "decoy" and decoy_after == decoy_before,
            labels[4],
            "the caller's checkout was on %r at %s when the gate opened;"
            % ("decoy", (decoy_before or "?")[:12]),
            "afterwards it is on %r at %s." % (head_ref(fx.repo), (decoy_after or "?")[:12]),
            "A branch the caller chose, that belongs to neither run, received a run's merges.",
        )

        # -- P1.8 ------------------------------------------------------------------------------
        check(rev(fx.repo, "main") == main_before, labels[5],
              "main was %s before and is %s now (it started on %r)"
              % ((main_before or "?")[:12], (rev(fx.repo, "main") or "?")[:12], caller_before))

        # -- P1.9 ------------------------------------------------------------------------------
        rows_a = ledger_events(fx.run_dir(a), "integrated")
        rows_b = ledger_events(fx.run_dir(b), "integrated")
        branch_a = [r.get("branch") for r in rows_a]
        branch_b = [r.get("branch") for r in rows_b]
        check(
            branch_a == [int_a] and branch_b == [int_b],
            labels[6],
            "run A's ledger holds %d 'integrated' row(s) for branches %s (expected exactly [%r])"
            % (len(rows_a), branch_a, int_a),
            "run B's ledger holds %d 'integrated' row(s) for branches %s (expected exactly [%r])"
            % (len(rows_b), branch_b, int_b),
            "The ambient pointer named run B by the time run A finished, so a tool that re-reads it",
            "at logging time attributes run A's integration to run B: a correct-looking merge with",
            "its evidence attached to the wrong run (F3, AC-002).",
        )

        # -- P1.10 -----------------------------------------------------------------------------
        merged_a = merged_branches(out_a)
        merged_b = merged_branches(proc_b.stdout)
        bad_a = [m for m in merged_a if not m.startswith("wt/%s-" % a)]
        bad_b = [m for m in merged_b if not m.startswith("wt/%s-" % b)]
        check(
            merged_a and merged_b and not bad_a and not bad_b,
            labels[7],
            "run A merged %s (foreign: %s)" % (merged_a, bad_a or "none"),
            "run B merged %s (foreign: %s)" % (merged_b, bad_b or "none"),
        )
    finally:
        if proc_a.poll() is None:
            fx.release()
            wait_for_exit(proc_a, timeout=30)


# ------------------------------------------------------------------------------------------------
# P2 -- the same interleave through the EXPLICIT --run selector, ambient pointer on a decoy run.
# ------------------------------------------------------------------------------------------------
def property_two(firm, root):
    prop("P2 (AC-002, AC-004) the same interleave, driven by the explicit --run selector")
    print("    .agent-firm/CURRENT_RUN names a THIRD run for the whole property and is never moved.")
    print("    The explicit selector must drive both selections firm-integrate makes: which")
    print("    branches are merged, and which run's ledger records that they were.")

    fx = Fixture(root, firm)
    a = fx.new_run("alpha")
    b = fx.new_run("bravo")
    decoy_run = fx.new_run("decoyrun")
    for wo, name in (("wo1", "alpha1.txt"), ("wo2", "alpha2.txt")):
        fx.work_order_branch(a, wo, name)
    for wo, name in (("wo1", "bravo1.txt"), ("wo2", "bravo2.txt")):
        fx.work_order_branch(b, wo, name)
    fx.install_hook("post-merge", merge_park_hook(fx, a))

    fx.point_at(decoy_run)
    main_before = rev(fx.repo, "main")

    labels = [
        "P2.3 run A's merges all landed on run A's own integration branch",
        "P2.4 the two integration branches did not cross-contaminate",
        "P2.5 the caller's own HEAD was not written through while A was in flight",
        "P2.6 the default branch never moved",
        "P2.7 each run's integration event is recorded in that run's own ledger",
        "P2.8 the ambient pointer's run received nothing at all",
        "P2.9 each invocation merged only the work-order branches of the run it was given",
    ]

    fx.arm()
    proc_a = fx.spawn(
        [os.path.join(fx.bin, "firm-integrate"), "--run", fx.rel_run_dir(a)], "p2-a"
    )
    try:
        rendezvous = wait_for_park(fx, proc_a)
        if rendezvous.state == "stuck":
            cannot("run A never parked inside firm-integrate's merge loop under --run; still"
                   " running after %.0fs. Mechanism broken; not reported as a pass." % PARK_TIMEOUT)
        if rendezvous.state == "exited":
            fail(
                "P2.2 the two runs genuinely overlapped in wall-clock time",
                "run A's `firm-integrate --run %s` exited rc=%s before merging anything, so no"
                % (fx.rel_run_dir(a), proc_a.returncode),
                "interleave was established. The tool's own output was:",
                tail(rendezvous.detail),
                "AC-002 requires the explicit selector to be accepted and to be authoritative; a",
                "tool that refuses it cannot integrate run A while the ambient pointer names",
                "another run, which is the whole of the defect this eval guards.",
            )
            not_evaluated("the interleave above could not be established", labels)
            return

        t_park = time.monotonic()
        t_b_start = time.monotonic()
        proc_b = subprocess.run(
            [os.path.join(fx.bin, "firm-integrate"), "--run", fx.rel_run_dir(b)],
            cwd=fx.repo, capture_output=True, text=True,
        )
        t_b_end = time.monotonic()
        a_alive = proc_a.poll() is None

        git(fx.repo, "checkout", "-q", "-b", "decoy")
        decoy_before = rev(fx.repo, "decoy")
        t_release = time.monotonic()
        fx.release()
        if not wait_for_exit(proc_a):
            cannot("run A did not exit within %.0fs after the gate was released" % FINISH_TIMEOUT)
        out_a = Fixture.output_of(proc_a)

        check(proc_a.returncode == 0 and proc_b.returncode == 0,
              "P2.1 neither invocation failed because the other was running",
              "run A rc=%s, run B rc=%s" % (proc_a.returncode, proc_b.returncode),
              "run A output:\n%s" % tail(out_a),
              "run B output:\n%s" % tail(proc_b.stdout + proc_b.stderr))

        check(a_alive and t_park <= t_b_start < t_b_end <= t_release,
              "P2.2 the two runs genuinely overlapped in wall-clock time",
              "A parked, then B ran for %.3fs while A's process was%s still alive."
              % (t_b_end - t_b_start, "" if a_alive else " NOT"))

        int_a, int_b = "integration/%s" % a, "integration/%s" % b
        missing = [f for f in ("alpha1.txt", "alpha2.txt") if not has_path(fx.repo, int_a, f)]
        detail = ["absent from %s: %s" % (int_a, ", ".join(missing))]
        for name in missing:
            detail.append("  %s is instead reachable from: %s"
                          % (name, ", ".join(refs_containing(fx.repo, name)) or "no branch at all"))
        check(not missing, labels[0], *detail)

        cross = ([f for f in ("bravo1.txt", "bravo2.txt") if has_path(fx.repo, int_a, f)]
                 + [f for f in ("alpha1.txt", "alpha2.txt") if has_path(fx.repo, int_b, f)])
        check(not cross, labels[1], "cross-contaminating paths: %s" % ", ".join(cross))

        decoy_after = rev(fx.repo, "decoy")
        check(head_ref(fx.repo) == "decoy" and decoy_after == decoy_before, labels[2],
              "decoy was %s and is now %s; HEAD is on %r"
              % ((decoy_before or "?")[:12], (decoy_after or "?")[:12], head_ref(fx.repo)))

        check(rev(fx.repo, "main") == main_before, labels[3],
              "main moved from %s to %s"
              % ((main_before or "?")[:12], (rev(fx.repo, "main") or "?")[:12]))

        rows_a = [r.get("branch") for r in ledger_events(fx.run_dir(a), "integrated")]
        rows_b = [r.get("branch") for r in ledger_events(fx.run_dir(b), "integrated")]
        check(rows_a == [int_a] and rows_b == [int_b], labels[4],
              "run A's ledger: %s (expected [%r]); run B's ledger: %s (expected [%r])"
              % (rows_a, int_a, rows_b, int_b))

        rows_decoy = ledger_events(fx.run_dir(decoy_run), "integrated")
        check(
            not rows_decoy and not rev(fx.repo, "integration/%s" % decoy_run), labels[5],
            "the ambient pointer named %s throughout; it holds %d 'integrated' row(s) and its"
            % (decoy_run, len(rows_decoy)),
            "integration branch %s exists: %s"
            % ("integration/%s" % decoy_run, bool(rev(fx.repo, "integration/%s" % decoy_run))),
            "An explicit selector that reaches the merge but not the ledger call writes the right",
            "merge into the wrong run's evidence -- the harder half to notice (F3, AC-002).",
        )

        merged_a = merged_branches(out_a)
        merged_b = merged_branches(proc_b.stdout)
        bad = ([m for m in merged_a if not m.startswith("wt/%s-" % a)]
               + [m for m in merged_b if not m.startswith("wt/%s-" % b)])
        check(merged_a and merged_b and not bad, labels[6],
              "run A merged %s; run B merged %s; foreign branches: %s"
              % (merged_a, merged_b, bad or "none"))
    finally:
        if proc_a.poll() is None:
            fx.release()
            wait_for_exit(proc_a, timeout=30)


# ------------------------------------------------------------------------------------------------
# P3 -- the QA-checkout half of AC-004.
# ------------------------------------------------------------------------------------------------
def property_three(firm, root):
    prop("P3 (AC-001, AC-004) two QA captures overlapping in one working tree")
    print("    Run A's capture is parked INSIDE its `git worktree add`, mid-materialisation. Run B's")
    print("    capture then runs start-to-finish. The ambient pointer names a third run throughout,")
    print("    so neither capture can be reached without an explicit selector.")

    fx = Fixture(root, firm)
    a = fx.new_run("alpha")
    b = fx.new_run("bravo")
    decoy_run = fx.new_run("decoyrun")
    # Built with plain git: this property is about firm-qa-checkout, and must not depend on
    # firm-integrate having worked.
    fx.integration_branch(a, "alpha-result.txt")
    fx.integration_branch(b, "bravo-result.txt")
    sha_a = rev(fx.repo, "integration/%s" % a)
    sha_b = rev(fx.repo, "integration/%s" % b)
    fx.install_hook("post-checkout", checkout_park_hook(fx, a))
    fx.point_at(decoy_run)

    labels = [
        "P3.3 each run's candidate metadata is bound to that run's own SHA and generation",
        "P3.4 the two captures really are different candidates",
        "P3.5 each run's QA checkout is detached at that run's own candidate",
        "P3.6 the ambient pointer's run received no checkout and no candidate metadata",
        "P3.7 each run's qa_checkout event is recorded in that run's own ledger",
    ]

    fx.arm()
    proc_a = fx.spawn(
        [os.path.join(fx.bin, "firm-qa-checkout"), "--run", fx.rel_run_dir(a)], "p3-a"
    )
    try:
        rendezvous = wait_for_park(fx, proc_a)
        if rendezvous.state == "stuck":
            cannot("run A's QA capture never reached its checkout materialisation; still running"
                   " after %.0fs. Mechanism broken; not reported as a pass." % PARK_TIMEOUT)
        if rendezvous.state == "exited":
            fail(
                "P3.2 the two captures genuinely overlapped in wall-clock time",
                "run A's `firm-qa-checkout --run %s` exited rc=%s without materialising a checkout."
                % (fx.rel_run_dir(a), proc_a.returncode),
                "The tool's own output was:",
                tail(rendezvous.detail),
                "AC-001: an explicit run selector must be sufficient on its own. A firm-qa-checkout",
                "that reads only the ambient pointer cannot produce run A's canonical QA artifacts",
                "at all while that pointer names another run, so two runs sharing one working tree",
                "cannot both reach QA -- which is the AC-004 collision, in its QA half.",
            )
            not_evaluated("the interleave above could not be established", labels)
            return

        t_park = time.monotonic()
        t_b_start = time.monotonic()
        proc_b = subprocess.run(
            [os.path.join(fx.bin, "firm-qa-checkout"), "--run", fx.rel_run_dir(b)],
            cwd=fx.repo, capture_output=True, text=True,
        )
        t_b_end = time.monotonic()
        a_alive = proc_a.poll() is None
        t_release = time.monotonic()
        fx.release()
        if not wait_for_exit(proc_a):
            cannot("run A's QA capture did not exit within %.0fs after release" % FINISH_TIMEOUT)
        out_a = Fixture.output_of(proc_a)

        check(proc_a.returncode == 0 and proc_b.returncode == 0,
              "P3.1 neither capture failed or blocked on the other",
              "run A rc=%s, run B rc=%s" % (proc_a.returncode, proc_b.returncode),
              "run A output:\n%s" % tail(out_a),
              "run B output:\n%s" % tail(proc_b.stdout + proc_b.stderr))

        check(a_alive and t_park <= t_b_start < t_b_end <= t_release,
              "P3.2 the two captures genuinely overlapped in wall-clock time",
              "run A was parked inside `git worktree add`; run B's whole capture took %.3fs and"
              % (t_b_end - t_b_start),
              "run A's process was%s still alive when it finished." % ("" if a_alive else " NOT"))

        def candidate(run_id):
            path = os.path.join(fx.run_dir(run_id), "09-test-evidence", "qa-candidate.json")
            try:
                with open(path, encoding="utf-8") as handle:
                    return json.load(handle)
            except (OSError, ValueError):
                return None

        cand_a, cand_b = candidate(a), candidate(b)
        problems = []
        for name, doc, run_id, want in (("A", cand_a, a, sha_a), ("B", cand_b, b, sha_b)):
            if doc is None:
                problems.append("run %s: no readable qa-candidate.json in its own run directory"
                                % name)
                continue
            if doc.get("run_id") != run_id:
                problems.append("run %s: candidate run_id is %r, expected %r"
                                % (name, doc.get("run_id"), run_id))
            if doc.get("candidate_sha") != want:
                problems.append("run %s: candidate_sha is %r, expected its own integration tip %r"
                                % (name, doc.get("candidate_sha"), want))
            if doc.get("generation") != 1:
                problems.append("run %s: generation is %r, expected 1 (one capture happened)"
                                % (name, doc.get("generation")))
        check(not problems, labels[0], *problems)

        check(
            cand_a is not None and cand_b is not None
            and cand_a.get("candidate_sha") != cand_b.get("candidate_sha"),
            labels[1],
            "both captures resolved to the same candidate SHA, so P3.3 would hold vacuously",
        )

        problems = []
        for name, run_id, want in (("A", a, sha_a), ("B", b, sha_b)):
            qa_dir = os.path.join(fx.repo, ".agent-firm", "qa-checkout", run_id)
            if not os.path.isdir(qa_dir):
                problems.append("run %s: no QA checkout at %s" % (name, qa_dir))
                continue
            if rev(qa_dir, "HEAD") != want:
                problems.append("run %s: checkout HEAD is %s, expected %s"
                                % (name, (rev(qa_dir, "HEAD") or "?")[:12], (want or "?")[:12]))
            if git(qa_dir, "symbolic-ref", "--quiet", "HEAD").returncode == 0:
                problems.append("run %s: checkout is on a branch; QA candidates are detached"
                                % name)
        check(not problems, labels[2], *problems)

        decoy_qa = os.path.join(fx.repo, ".agent-firm", "qa-checkout", decoy_run)
        decoy_cand = os.path.join(
            fx.run_dir(decoy_run), "09-test-evidence", "qa-candidate.json")
        check(
            not os.path.exists(decoy_qa) and not os.path.exists(decoy_cand), labels[3],
            "the ambient pointer named %s throughout." % decoy_run,
            "checkout %s exists: %s" % (decoy_qa, os.path.exists(decoy_qa)),
            "candidate %s exists: %s" % (decoy_cand, os.path.exists(decoy_cand)),
        )

        problems = []
        for name, run_id in (("A", a), ("B", b)):
            rows = ledger_events(fx.run_dir(run_id), "qa_checkout")
            if len(rows) != 1:
                problems.append("run %s: %d 'qa_checkout' row(s) in its own ledger, expected 1"
                                % (name, len(rows)))
        rows = ledger_events(fx.run_dir(decoy_run), "qa_checkout")
        if rows:
            problems.append("the ambient run %s holds %d 'qa_checkout' row(s), expected 0"
                            % (decoy_run, len(rows)))
        check(not problems, labels[4], *problems)
    finally:
        if proc_a.poll() is None:
            fx.release()
            wait_for_exit(proc_a, timeout=30)


# ------------------------------------------------------------------------------------------------
# P4 -- rollback, including the residual per-run integration worktree.
# ------------------------------------------------------------------------------------------------
REVERTED_TOOL_NOTE = (
    "MODEL, NOT A COPY. The pre-change firm-integrate's first two operations are: read"
    " .agent-firm/CURRENT_RUN, then `git switch integration/<run_id>` in the caller's own checkout."
    " Those two lines are reproduced here deliberately and are labelled as a model of the reverted"
    " tool -- a vendored copy of the old script would rot silently, and this eval must not carry a"
    " second, unmaintained implementation of the thing it is testing."
)


def property_four(firm, root):
    prop("P4 (AC-011) rollback: the residual integration worktree is cleanly removable")
    print("    " + REVERTED_TOOL_NOTE.replace(". ", ".\n    "))

    fx = Fixture(root, firm)
    run_id = fx.new_run("rollback")
    fx.work_order_branch(run_id, "wo1", "work.txt")

    # A CONTROL, so P4.8's "firm-integrate left nothing new in the run directory" is measured rather
    # than asserted. firm-integrate ends by calling firm-ledger-log, which is not part of this change
    # and which the pre-change tool called too; that writer leaves its own artifacts (a lock beside
    # run.jsonl). Rather than name them in an allowlist -- which would be this eval deciding what is
    # permitted -- a second run in the same repo is given the same ledger write and nothing else, and
    # whatever THAT leaves becomes the permitted delta. Anything firm-integrate leaves beyond it is a
    # residual of the behaviour change and fails.
    control = fx.new_run("control")
    fx.point_at(control)
    control_before = set(os.listdir(fx.run_dir(control)))
    run([os.path.join(fx.bin, "firm-ledger-log"), "integrated",
         "branch=integration/%s" % control, "merged=0", "conflicts=0"], cwd=fx.repo)
    writer_leaves = set(os.listdir(fx.run_dir(control))) - control_before

    fx.point_at(run_id)
    inventory_before = sorted(os.listdir(fx.run_dir(run_id)))
    proc = run([os.path.join(fx.bin, "firm-integrate")], cwd=fx.repo)
    inventory_after = sorted(os.listdir(fx.run_dir(run_id)))
    int_dir = os.path.join(fx.repo, ".agent-firm", "integration", run_id)
    intb = "integration/%s" % run_id
    registration = os.path.join(fx.gitdir, "worktrees", run_id)

    if not check(
        proc.returncode == 0 and os.path.isdir(int_dir),
        "P4.1 the delivered firm-integrate leaves a per-run linked worktree to be rolled back",
        "firm-integrate rc=%s; %s exists: %s" % (proc.returncode, int_dir, os.path.isdir(int_dir)),
        "This property tests the residual the delivered change introduces. A tool that creates no",
        "such worktree has not made the change AC-011's rollback clause is written about, so the",
        "clause cannot be satisfied here -- there is nothing to prove removable.",
        "firm-integrate output:\n%s" % tail(proc.stdout + proc.stderr),
    ):
        not_evaluated(
            "the residual this property exists to test was never created",
            [
                "P4.2 while it is registered, a reverted firm-integrate fails CLOSED, not silently",
                "P4.3 `git worktree remove` takes it cleanly and the registration goes with it",
                "P4.4 nothing is left for `git worktree prune` to find",
                "P4.5 the reverted tool's own operation works again once the worktree is released",
                "P4.6 removing the worktree loses none of the merges",
                "P4.7 a directory deleted with rm -rf is recoverable by `git worktree prune`",
                "P4.8 a run created under the new behaviour stays resolvable after rollback",
                "P4.9 the residual is outside every run directory",
            ],
        )
        return

    listing = git(fx.repo, "worktree", "list", "--porcelain").stdout
    check(
        intb in listing and os.path.isdir(registration),
        "P4.1b the worktree is git-registered, not merely a directory on disk",
        "`git worktree list --porcelain` mentions %r: %s" % (intb, intb in listing),
        "%s exists: %s" % (registration, os.path.isdir(registration)),
    )

    # -- P4.2: the residual, demonstrated as the reverted tool would meet it --------------------
    switch = git(fx.repo, "switch", intb)
    check(
        switch.returncode != 0 and "already used by worktree" in switch.stderr,
        "P4.2 while it is registered, a reverted firm-integrate fails CLOSED, not silently",
        "`git switch %s` in the caller's checkout returned rc=%s" % (intb, switch.returncode),
        "stderr: %s" % switch.stderr.strip(),
        "The reverted tool checks that switch's exit code and refuses to merge when it fails, so",
        "the residual is safe but confusing -- which is exactly why AC-011 requires it to be",
        "removable and WO-4's rollback note requires the removal to happen BEFORE the revert.",
    )

    # -- P4.3 / P4.4 ---------------------------------------------------------------------------
    removal = git(fx.repo, "worktree", "remove", int_dir)
    listing = git(fx.repo, "worktree", "list", "--porcelain").stdout
    check(
        removal.returncode == 0 and not os.path.exists(int_dir)
        and intb not in listing and not os.path.isdir(registration),
        "P4.3 `git worktree remove` takes it cleanly and the registration goes with it",
        "rc=%s stderr=%s" % (removal.returncode, removal.stderr.strip()),
        "directory still present: %s; still listed: %s; %s still present: %s"
        % (os.path.exists(int_dir), intb in listing, registration, os.path.isdir(registration)),
    )

    prune = git(fx.repo, "worktree", "prune", "--dry-run", "-v")
    status = git(fx.repo, "status", "--porcelain")
    listing_rc = git(fx.repo, "worktree", "list")
    check(
        prune.returncode == 0 and not prune.stdout.strip()
        and status.returncode == 0 and listing_rc.returncode == 0,
        "P4.4 nothing is left for `git worktree prune` to find",
        "prune --dry-run rc=%s said: %r" % (prune.returncode, prune.stdout.strip()),
        "the shared working tree's `git status` rc=%s, `git worktree list` rc=%s"
        % (status.returncode, listing_rc.returncode),
        "An emptied directory with a stale registration would be an INCONSISTENT registration,",
        "which is the failure AC-011 names.",
    )

    # -- P4.5 / P4.6 ---------------------------------------------------------------------------
    switch = git(fx.repo, "switch", intb)
    check(switch.returncode == 0,
          "P4.5 the reverted tool's own operation works again once the worktree is released",
          "`git switch %s` rc=%s stderr=%s" % (intb, switch.returncode, switch.stderr.strip()),
          REVERTED_TOOL_NOTE)
    git(fx.repo, "switch", "main")

    check(has_path(fx.repo, intb, "work.txt"),
          "P4.6 removing the worktree loses none of the merges",
          "%s no longer contains work.txt; the branch is ordinary and must survive removal" % intb)

    # -- P4.7: the rm -rf path -----------------------------------------------------------------
    run([os.path.join(fx.bin, "firm-integrate")], cwd=fx.repo)
    if os.path.isdir(int_dir):
        shutil.rmtree(int_dir)
    listing = git(fx.repo, "worktree", "list", "--porcelain").stdout
    prunable = "prunable" in git(fx.repo, "worktree", "list").stdout
    prune = git(fx.repo, "worktree", "prune")
    after = git(fx.repo, "worktree", "list", "--porcelain").stdout
    switch = git(fx.repo, "switch", intb)
    git(fx.repo, "switch", "main")
    check(
        intb in listing and prunable and prune.returncode == 0
        and intb not in after and not os.path.isdir(registration) and switch.returncode == 0,
        "P4.7 a directory deleted with rm -rf is recoverable by `git worktree prune`",
        "before prune the registration was still listed: %s (marked prunable: %s)"
        % (intb in listing, prunable),
        "prune rc=%s; still listed after: %s; %s still present: %s; reverted switch rc=%s"
        % (prune.returncode, intb in after, registration, os.path.isdir(registration),
           switch.returncode),
    )

    # -- P4.8: the run itself is still resolvable ----------------------------------------------
    pointer = os.path.join(fx.repo, ".agent-firm", "CURRENT_RUN")
    problems = []
    info = os.lstat(pointer)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        problems.append("CURRENT_RUN is not a regular non-symlink file")
    text = fx.current_run()
    if text != ".agent-firm/runs/%s" % run_id:
        problems.append("CURRENT_RUN reads %r, which a reverted tool would basename to %r"
                        % (text, os.path.basename(text)))
    if not os.path.isdir(os.path.join(fx.repo, text)):
        problems.append("the run directory %r named by CURRENT_RUN does not exist" % text)
    try:
        with open(os.path.join(fx.run_dir(run_id), "run-metadata.json"), encoding="utf-8") as h:
            json.load(h)
    except (OSError, ValueError) as exc:
        problems.append("run-metadata.json is unreadable: %s" % exc)
    added = set(inventory_after) - set(inventory_before)
    removed = set(inventory_before) - set(inventory_after)
    unexplained = added - writer_leaves
    if unexplained or removed:
        problems.append(
            "firm-integrate changed the run directory beyond what its ledger write explains:")
        problems.append("  added: %s" % (sorted(added) or "nothing"))
        problems.append("  removed: %s" % (sorted(removed) or "nothing"))
        problems.append("  the ledger writer alone leaves: %s (measured on a control run)"
                        % (sorted(writer_leaves) or "nothing"))
        problems.append("  unexplained: %s" % sorted(unexplained))
    check(not problems,
          "P4.8 a run created under the new behaviour stays resolvable after rollback",
          *problems)

    # -- P4.9 -----------------------------------------------------------------------------------
    residual_parent = os.path.realpath(os.path.join(fx.repo, ".agent-firm", "integration"))
    runs_parent = os.path.realpath(os.path.join(fx.repo, ".agent-firm", "runs"))
    check(
        not residual_parent.startswith(runs_parent + os.sep),
        "P4.9 the residual is outside every run directory",
        "%s is inside %s, so removing it would disturb the ledger itself"
        % (residual_parent, runs_parent),
    )


# ------------------------------------------------------------------------------------------------
PROPERTIES = (
    ("p1", property_one),
    ("p2", property_two),
    ("p3", property_three),
    ("p4", property_four),
)


def select(argv):
    """`--only p1,p3` runs a subset. It exists for the MUTATION cases in
    tests/test-concurrent-runs-eval.sh, which target one tool each and would otherwise pay for three
    properties they are not about. It is deliberately not a way to run nothing: a selector matching
    no property is exit 2, and the chosen set is echoed so a transcript always says what ran.

    Note what this flag can and cannot do. It narrows which properties run; it cannot narrow which
    assertions inside a property run, and there is no flag that skips an assertion. `sh
    test/run-tests.sh` -- the form the eval and CI use -- passes no arguments and runs all four."""
    only = None
    rest = list(argv)
    while rest:
        arg = rest.pop(0)
        if arg == "--only":
            if not rest:
                cannot("--only needs a comma-separated list of property names (p1,p2,p3,p4)")
            only = [name.strip().lower() for name in rest.pop(0).split(",") if name.strip()]
        elif arg.startswith("--only="):
            only = [name.strip().lower() for name in arg[len("--only="):].split(",") if name.strip()]
        else:
            cannot("unknown argument %r; usage: concurrent-runs-check.py [--only p1,p2,p3,p4]" % arg)
    if only is None:
        return list(PROPERTIES)
    unknown = [name for name in only if name not in dict(PROPERTIES)]
    if unknown:
        cannot("unknown propert%s %s; known: %s"
               % ("y" if len(unknown) == 1 else "ies", ", ".join(unknown),
                  ", ".join(name for name, _ in PROPERTIES)))
    chosen = [(name, fn) for name, fn in PROPERTIES if name in only]
    if not chosen:
        cannot("--only selected no property; refusing to report a pass having checked nothing")
    return chosen


def main():
    chosen = select(sys.argv[1:])
    firm = firm_root()
    if not shutil.which("git"):
        cannot("git is not on PATH")
    print("concurrent-runs-one-checkout: golden check for AC-002, AC-004, AC-011, AC-012")
    print("firm under test: %s" % firm)
    print("properties selected: %s" % ", ".join(name for name, _ in chosen))
    integrate_help = run([os.path.join(firm, "bin", "firm-integrate"), "--help"])
    print("firm-integrate --help exits %d" % integrate_help.returncode)

    root = tempfile.mkdtemp(prefix="firm-concurrent-runs-")
    keep = os.environ.get("FIRM_CONCURRENT_RUNS_KEEP")
    try:
        for _, fn in chosen:
            fn(firm, root)
    finally:
        if keep:
            print("\n(fixtures kept at %s by FIRM_CONCURRENT_RUNS_KEEP)" % root)
        else:
            shutil.rmtree(root, ignore_errors=True)

    print()
    if failures:
        print("CONCURRENT-RUNS CHECK: FAIL -- %d assertion(s):" % len(failures))
        for label in failures:
            print("  - %s" % label)
        return 1
    print("CONCURRENT-RUNS CHECK: PASS -- %s held, each proven under a rendezvous that"
          % ("every property" if len(chosen) == len(PROPERTIES)
             else "the selected propert%s" % ("y" if len(chosen) == 1 else "ies")))
    print("a sequential fixture cannot satisfy (see the P*.2 assertions).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
