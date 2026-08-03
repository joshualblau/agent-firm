# System Change PR: a gate that runs the wrong binary is a gate that cannot see

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260803T092058Z-review-system-change-prs` (promoted on independent review;
  originally SC-5 in `20260802T145947Z-remediate-remote-delta/11-retrospective.md`)
- **Date (UTC):** 2026-08-03
- **Status:** proposed

## Motivation

**18 of the 23 `firm-*` scripts** resolve their own symlink to locate the repo:

```
~/.local/bin/firm-traceability-check -> /Users/younglionsolutions/agent-firm/bin/firm-traceability-check
```

So `SELF` always resolves to the **primary checkout's** `bin/`, no matter which worktree, branch, or
integration tip is under test. A gate invoked while testing a branch runs `main`'s copy of that gate.

*(Corrected on third review (S-22a): this said "**Every** `firm-*` script". Measured — 18 of 23 do; the
five that do not are `firm-ledger-hook`, `firm-ledger-log`, `firm-notify`, `firm-visual-baseline` and
**`firm-traceability-check`, the example quoted above**, which has no symlink resolution at all. The
overclaim was in the direction of making the hazard sound tidier than it is. The hazard is in fact
**worse** for `firm-traceability-check`: with no `SELF` at all it depends entirely on how the caller
invokes it, so the same gate can read different code depending on whether the Lead typed a bare command or
an explicit path — which is precisely incident 2 below.)*

This bit **twice** in one engagement, both times on the tool doing the work:

1. **`firm-integrate` was unusable for the wave repairing its own bug.** `bin/firm-integrate` at
   `cd42594` had a branch-escape defect: no `set -e`, `git switch` exit status discarded by
   `>/dev/null 2>&1`, falling through to `git merge` on whatever branch was checked out. The fix was
   sitting on the branch being integrated — but `firm-integrate` on `$PATH` was the broken copy. Every
   integration in four waves used explicit `git merge` instead, working around the firm's own tooling.
   Worse: `bin/firm-run-evals:232` hands **eight gate/integration tools** to the **unsupervised** headless
   eval agent — `firm-integrate`, `firm-traceability-check`, `firm-qa-clean-check`,
   `firm-validate-verdict`, `firm-qa-checkout`, `firm-gpt-qa`, `firm-new-worktree`, `firm-bench-record` —
   while `:233`'s `--disallowedTools` blocks `Bash(git merge:*)`. The laundering path existed inside the
   eval harness. *(Line reference corrected on second review: an earlier draft cited `:64`. Enumeration
   corrected on third review (T-09): the allow-list names **ten** `firm-*` tools in all; the two not
   listed here, `firm-new-run` and `firm-ledger-log`, are ledger plumbing rather than gates, so the
   argument is unaffected — but the sentence previously read as an enumeration of the grant, which it was
   not.)*
2. **The Lead nearly accepted a `PASS` from a fail-open gate.** Checking traceability on a run whose
   ledger contained two `partial` criteria, `firm-traceability-check` reported
   `TRACEABILITY: PASS — every criterion is covered or justified`. That was `main`'s copy, which
   treated `partial` as passing. The **fixed** copy in the worktree reported
   `TRACEABILITY: INCOMPLETE — 9/11 criteria fully covered, 2 justified gaps`. Same ledger, opposite
   verdicts, and only the second is true. The Lead caught it by explicitly invoking the worktree binary
   — a habit, not a control.

This is the fail-open class one level up. A gate can be perfectly written and still report a wrong
verdict because the wrong copy of it ran. Cited:
`20260802T145947Z-remediate-remote-delta/11-retrospective.md` (SC-5);
`20260803T092058Z-review-system-change-prs/07-review-findings.yaml`.

## Proposed change

- Files: `CLAUDE.md`, `commands/start.md`, `docs/ENFORCEMENT.md`, `bin/firm-*` (preamble),
  `bin/firm-doctor`

1. **Have gate and integration steps resolve firm tooling from the tree under test — conditional on
   provenance.** Second review's central criticism of this PR: the first draft's normative text was
   blanket while its Risk section admitted the rule must depend on trust, which inverts the roles by
   leaving the load-bearing condition to a future reviewer. Stated properly:
   - **Trusted branch** (the operator's own work, e.g. a remediation worktree): resolve the gate from
     **that tree's** `bin/`. Otherwise a fix to a gate cannot be exercised by the gate, which is what
     blocked `firm-integrate` for four waves.
   - **Untrusted branch** (an incoming contribution under evaluation): resolve from the **primary
     checkout**, and never execute the branch's own gate scripts. Running a contributor's gate to judge
     that contributor's code is the supply-chain shape this firm evaluates *for*.
   - The Lead classifies provenance at intake — it is already asked at the Requirements gate — and
     records the choice in the run ledger.
2. **Make each script report which copy it is.** A one-line `--version`-ish banner (`resolved from:
   <path>` at `-v`, or on stderr for the gate scripts) turns an invisible hazard into a visible one.
   The two incidents above were both diagnosable in one second *if* the output had said where the script
   came from.
3. **Fix the divergence check `firm-doctor` already has — in three branches, not one.**
   `bin/firm-doctor:248-261` resolves `command -v firm-install`'s symlink chain and warns when it does not
   equal `$SELF/firm-install`. So this proposal, as first drafted, asked for something that exists — the
   same pathology the wall-clock PR was rewritten for, repeated in a new PR. The **real** defect, found on
   second review: `$SELF` is derived from *firm-doctor's own* resolved location. Run via `$PATH` from
   inside a worktree, both sides resolve to the primary checkout, so the check compares the primary
   checkout against itself and **passes precisely in the situation it exists to catch**.

   **The previous round's prescribed fix — "compare against `git rev-parse --show-toplevel`" — was wrong,
   and third review caught it (T-10).** `firm-doctor` is not a firm-repo-only tool: the portability work
   made it the per-project fail-closed preflight for a *work* project's subscription profiles, `op`/direnv
   secrets and `.claude/settings.json` posture. In any work project `--show-toplevel` returns that
   project's root, which has no `bin/firm-install`, so the comparison mismatches **always** and converts a
   correct PASS into a permanent spurious warning everywhere the tool is most used. A warning that is
   always on is a warning nobody reads. And outside a git repo `--show-toplevel` exits non-zero and prints
   nothing, which the previous text simply did not address — while this batch's sibling PR makes
   "cannot evaluate must not pass" a never-rule.

   The correct shape is three branches, and **the middle one is the common case**:

   - `TOP="$(git rev-parse --show-toplevel)"`. **If that fails** — not inside a git repo — report
     **cannot evaluate**, not pass, and do not warn. (`firm-doctor` has no cannot-evaluate code today; see
     the note under Generalizability.)
   - **If `$TOP/bin/firm-doctor` does not exist**, the enclosing tree is a **work project**. The correct
     target is `$SELF` and today's check is already right — keep it, and say so in the code comment so the
     next reader does not "fix" it again.
   - **If it does exist**, the enclosing tree is a **firm checkout** (primary or worktree). Compare
     `$PATH`'s copy against `$TOP/bin/` and warn on divergence. This is the worktree case the PR is about,
     and the only case where the current check self-passes.

   **Executed in all four environments `firm-doctor` actually runs in** — read-only, nothing under `bin/`
   modified; the probe reimplements only the comparison:

   ```
   ENV                                  TODAY   PR5-AS-WRITTEN   THREE-BRANCH
   primary firm checkout                PASS    PASS             PASS            (branch 3)
   firm WORKTREE  <- the hazard         PASS    WARN             WARN            (branch 3, correct)
   synthetic WORK project (git repo)    PASS    WARN  <- SPURIOUS PASS           (branch 2)
   outside any git repo                 PASS    UNSPECIFIED      CANNOT EVALUATE (branch 1)
   ```

   Every environment resolved `command -v firm-install` to
   `/Users/younglionsolutions/agent-firm/bin/firm-install`, and `$SELF` to
   `/Users/younglionsolutions/agent-firm/bin` — which is why today's check passes in all four, including
   the one it exists to catch. In the worktree, `--show-toplevel` returned the worktree path and
   `<worktree>/bin/firm-install` **does** exist, so the divergence is real and detected. In the work
   project the target does **not** exist, which is exactly the spurious warning T-10 predicted.

   Two consequences for whoever implements this:
   - Branch 2 is not a special case to tolerate; it is the majority of invocations. Getting it wrong is
     worse than leaving the bug, because it retrains the operator to ignore `firm-doctor`.
   - Branch 3 fires in the *primary* checkout too, harmlessly (both sides agree). The test therefore needs
     a real worktree fixture to be meaningful — a primary-checkout-only test passes either way and pins
     nothing, which is this batch's redundant-guard trap in a new place.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes — this is a general hazard for any repo whose own tooling is
  under development in that repo, which is exactly the self-hosting case the firm is built for. It is
  arguably *more* dangerous in other projects, where nobody is watching for it.
- **Risk of overfitting the firm to one repo:** low for proposals 1 and 2. **Proposal 3 is where the
  overfitting risk actually lives, and the previous round fell into it** *(rewritten on third review; this
  bullet used to say "proposals 1 and 3 are mechanical", which is what allowed a fix specified only against
  the firm's own checkout to be called mechanical)*. `firm-doctor` runs mostly in **work** projects, not in
  this repo, and a fix reasoned about from inside the firm checkout warned permanently in every one of
  them. Hence the three-branch form and the four-environment execution in proposal 3. The general lesson,
  which does transfer: any check comparing "where I am" against "where the tooling is" must first decide
  *which kind of tree it is standing in*, and must have a cannot-evaluate answer for "neither".
- **Prerequisite this PR does not carry:** branch 1 of proposal 3 requires `firm-doctor` to have a
  cannot-evaluate outcome. It does not have one — its only verdict paths are `exit 1` and `exit 0`
  (`:436`, `:439`; `exit 2` at `:34` is an argument error). That is the gap the sibling never-rule PR
  records at S-20. Proposal 3 therefore depends on that PR, or on inventing the code here; it should not
  be implemented as a `warn` that quietly means "could not tell".

## Risk & rollback

- **Risk — proposal 1 lets a gate execute code from the tree under test.** Scoped by provenance in
  proposal 1 above, so the untrusted case never does: an incoming contribution is judged with the primary
  checkout's gates and the branch's own gate scripts are never executed. **Residual:** the classification
  is the Lead's judgement at intake, recorded in the run ledger but not enforced by any tool, so a
  misclassified branch gets the trusted path. That is a smaller surface than the current silent
  behaviour, in which *every* gate already runs the primary checkout's copy without anyone recording that
  a choice was made — and, as incident 2 above shows, occasionally the wrong verdict with it.
  *(**Corrected on third review** (T-04). This bullet previously said the rule "should therefore be
  conditional on provenance, not blanket — which the first sketch above does not capture and a reviewer
  should tighten." Proposal 1 was rewritten in the previous round and **does** capture it; the Risk
  section was left standing, so the section a human reads to decide told them the load-bearing condition
  was still missing from the security-relevant PR in the batch. This is the identical defect the stop-rule
  PR fixed at its own Generalizability bullet one file away, reproduced here in the same edit round. It is
  the batch's named recurring failure and this is its third occurrence.)*
- **Second residual, which proposal 1 does not remove:** "resolve the gate from the tree under test" is an
  instruction to an agent, not a mechanism. Nothing in `bin/` selects a binary by provenance today, and
  proposal 2's banner makes the choice *visible* rather than *correct*. So proposals 1 and 2 together
  reduce this from an invisible hazard to a visible one and no further. Proposal 3 is the only
  mechanically checkable piece — see the guard section, and see T-10 below for what it took to get
  proposal 3's fix right.
- **Rollback:** revert this PR (firm config is versioned in git).

## Golden eval to guard it

- Test, not eval: extend `tests/test-qa-checkout.sh` or add `tests/test-tool-resolution.sh`
- What it asserts: given two checkouts of the repo whose `bin/firm-<tool>` differ in observable
  behaviour, invoking the gate "for" checkout B does not silently execute checkout A's copy. Directly
  constructible: the engagement already has a real pair (the `partial`-passing and `partial`-reporting
  versions of `firm-traceability-check`) whose outputs differ on identical input.
- **The test must vary the environment, not just the binaries — and this is the axis the previous draft
  named without driving.** Proposal 3's fix has *three* branches, so a test that only builds two
  differing checkouts exercises branch 3 and leaves branches 1 and 2 unasserted — and branch 2 (the work
  project) is the common case and the one the previous prescription broke. Three fixtures are required, all
  constructible under `mktemp -d`:
  1. a firm worktree whose `bin/` differs from the primary checkout → expect **warn** (branch 3);
  2. a `git init` scratch repo with **no** `bin/firm-doctor` → expect **pass** (branch 2), asserting
     specifically that it does *not* warn;
  3. a directory that is **not** a git repo → expect **cannot evaluate** (branch 1), asserting that it is
     neither a pass nor a warn.

  Executed as a hand probe already (see proposal 3): today's check returns PASS in all three, the previous
  draft's fix returns WARN / WARN / unspecified, and the three-branch form returns WARN / PASS /
  cannot-evaluate. Fixture 2 is the one that fails if someone re-introduces the simple comparison, so it is
  the highest-value assertion here — the mirror of the same lesson in the sibling criteria PR, where the
  motivating story and the regression fixture turned out to be different cases.
- **Honest limitation:** whether the *Lead* remembers to invoke the right copy is agent behaviour, not
  assertable from a test. Proposal 3 (`firm-doctor` divergence warning) is the part that is mechanically
  checkable, and is where the guard should sit — **but only for `firm-install`'s resolution, which is a
  proxy.** `firm-doctor` checks one script's symlink chain and infers the rest; it does not check the gate
  script that actually produced a wrong verdict in incident 2. A divergence warning is therefore evidence
  that the *installation* is stale, not that the *gate that just ran* was the right copy. Proposal 2's
  per-script `resolved from:` banner is the only thing that would have made incident 2 self-evident, and it
  is guarded by nothing.
- **One batch-grep result, recorded because this PR proposes to edit the file it is in.** `CLAUDE.md:119`
  states that "every `firm-*` script now resolves its own symlink". That is the S-22a overclaim in the
  operating manual itself, one file away from the PR that corrects it — 18 of 23 do, and
  `firm-traceability-check` does not. `CLAUDE.md` is already in this PR's file list; this line is the
  specific edit. Left for the PR to make rather than corrected out-of-band, since the manual is not this
  document's to change.
- [ ] Golden evals pass (`firm-run-evals`) — attach the run output. If an eval changed, explain why the
      new behavior is correct (not just newly-passing).

## Evidence availability (read this before following a citation)

Every `.agent-firm/runs/...` path cited above lives in the **run ledger, which is not in git**. It is
excluded by **committed policy** — `.gitignore:32` (`.agent-firm/runs/`) — and additionally by a local
`.git/info/exclude:8`. **This PR is committable; its evidence is not.**

*(Corrected on second review: an earlier version of this note claimed the exclusion was machine-local
only and "not a committed `.gitignore`". It is committed. The conclusion is unchanged but the remedy is
different — this is a deliberate project policy to revisit, not an accident to fix.)*

Consequences a reviewer should weigh:
- A future reader (including the author) cannot verify any citation from a fresh clone.
- The firm's first principle is "artifacts are the source of truth", and those artifacts are outside
  version control — so the source of truth is unreviewable by anyone but the machine that wrote it.

Found by independent review (F-22). **No longer an open question.** It is now a specific proposal:
`system-changes/20260803T101922Z-commit-the-decision-bearing-ledger.md`, whose shape was settled at the
Requirements gate of run `20260803T120043Z-cleanup-and-identity-gate` — tier A is the decision artifacts
`00`-`12` **plus `run.jsonl`** (measured 0.44 MB/run over seven closed runs, ~44 MB at 100 runs), and
bulk `09-test-evidence/` stays local but **curated**: the specific artifacts an approved PR cites are
copied into `system-changes/evidence/<pr-slug>/` so the document is checkable from a clone. That PR is
still `Status: proposed` and still needs its own approval; only its shape is settled.

*(Corrected on third review: this footer previously offered three undecided options and named a narrower
tier — `00`, `01`, `03`, `07`, `08`, `10`, `11`, without `run.jsonl`. That enumeration is superseded and was
stale in six files at once. `run.jsonl` in particular belongs in tier A: it is the only durable source for
the agent-active measurement in the wall-clock PR, and the judge-round attribution in the stop-rule PR is
recoverable from nothing else. Fixing it in one file and not the other five is the failure mode this batch
was rejected for three times.)*

## Third-review edit record

**Blocking edits closed: T-04 and T-10.**
- **T-04** — the Risk section still told the reader the provenance rule was blanket and that "a reviewer
  should tighten" it, after proposal 1 had been rewritten to scope it. Rewritten to state the **residual**
  instead of the open question. This was the same defect the stop-rule PR had just fixed one file away, in
  the security-relevant PR of the batch, in the same edit round — recorded in the bullet rather than
  quietly repaired.
- **T-10** — the prescribed fix (compare against `git rev-parse --show-toplevel`) would have turned
  `firm-doctor` into a permanent spurious warning in every work project and had no answer outside a git
  repo. Replaced with the reviewer's **three-branch** form, and executed in all four environments
  `firm-doctor` runs in. The 4x3 matrix is in proposal 3.

**Non-blocking edits also closed:** **T-09** (the eval allow-list names ten `firm-*` tools, not eight —
the sentence now says which eight are gates and why the other two are not) and **S-22a** ("every `firm-*`
script resolves its own symlink" → **18 of 23**, with the quoted example, `firm-traceability-check`, being
one of the five that do not — which makes the hazard worse, not tidier).

**AC-005 cross-section propagation — performed, and it is why this PR is the cautionary one.**
- *Generalizability* said "proposals 1 and 3 are mechanical". That sentence is what allowed a fix specified
  only against the firm's own checkout to be called mechanical. Rewritten: proposal 3 is where the
  overfitting risk actually lives.
- *Risk* rewritten for T-04, plus a second residual — proposals 1 and 2 make the hazard visible, not
  correct; nothing in `bin/` selects a binary by provenance.
- *Golden eval* re-read last, and it changed the specification: the three-branch fix needs **three
  fixtures**, and the previous single-axis test would have left branch 2 — the common case, and the one the
  bad prescription broke — unasserted. Also recorded that `firm-doctor` checks `firm-install`'s chain as a
  *proxy* and would not have caught incident 2 at all.
- *New prerequisite surfaced by the propagation:* branch 1 needs a cannot-evaluate outcome and
  `firm-doctor` has none (`exit 0`/`exit 1` only). Named as a dependency on the never-rule PR (S-20).
- Batch grep: "every `firm-*` script" → found a second live instance at **`CLAUDE.md:119`**, which this PR
  already lists as a file it edits; recorded there as the specific line rather than corrected out-of-band.

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
