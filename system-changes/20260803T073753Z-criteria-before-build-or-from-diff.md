# System Change PR: acceptance criteria before Build — or reconstructed from the diff

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260802T192726Z-remediate-wave2`, reaffirmed by `20260803T051454Z-remediate-wave4`
- **Date (UTC):** 2026-08-03
- **Status:** proposed

## Motivation

Two runs in this engagement began at Build, chartered directly from an evidence-backed findings
artifact rather than passing through a Requirements gate. Their acceptance criteria were written
**after** Build and QA, by the Packager.

**In one of those two runs (`remediate-wave2`) the retrospective criteria contradicted the
implementation, in two places.** The other (`remediate-wave4`) reconciled cleanly — because QA supplied
the criterion ids to the Packager before it wrote them, which is the ordering proposal 2 below makes
mandatory. Both failures were caught by the firm's own mandated second-voice gate (`firm-gpt-qa`), not
by an outside party — a correction to this PR's first draft, which described that gate as external.

The two contradictions:

- **AC-001** (`remediate-wave2`) claimed the test harness "deletes only the real fixture" on the legacy
  channel. The shipped code deliberately **leaks** there, and documents why at `tests/lib.sh:263`:
  *"a leaked temp dir is loud and cheap, a fragment delete is silent and destructive."* The code was
  right; the criterion was wrong.
- **AC-002** (same run) named `set -f` as the control under test. That control had been **removed**
  along with the legacy split it guarded; protection now comes from the absolute-path and identity
  guards. The criterion described a mechanism that no longer existed.

Both were found by the cross-provider judge, which put it precisely: *"the acceptance criteria were
recorded retrospectively after implementation and QA; the mismatches in AC-001 and AC-002 show that
this was not merely administrative."*

The root cause is specific and worth naming: the criteria were reconstructed **from the narrative of
what the work-orders set out to do**, not from the diff of what they actually shipped. That is why they
drifted in the same direction twice.

A second, compounding defect: in `remediate-wave2` the QA verdict's `acceptance_criteria_coverage` used
descriptive strings as ids while the criteria used `AC-001..AC-011`, so nothing reconciled,
`traceability.yaml` stayed a template, and `firm-traceability-check` failed against the run's own
ledger — after the Lead had already presented a final gate.

**That paragraph is history, and a reader who checks it today will not reproduce it. Stated plainly so
nobody concludes the document is wrong.** Re-run against the real ledger:

```
$ bin/firm-traceability-check .agent-firm/runs/20260802T192726Z-remediate-wave2
  acceptance criteria: 11  verdict coverage entries: 11
  coverage: 9 full (yes) | 2 partial | 0 waived | 0 problem(s) | 0 unverifiable | 0 phantom
  TRACEABILITY: INCOMPLETE -- 9/11 criteria fully covered, 2 justified gap(s) above.
  exit 0
```

The ids reconcile, `traceability.yaml` is filled, and the two remaining gaps (AC-002, AC-011) carry
justifications. The repair happened **inside wave 2's own run window**, after the handoff was written:
`10-handoff.md` was last written at 04:20Z, `01-acceptance-criteria.yaml` at 05:05Z, `traceability.yaml`
at 05:06Z, and the ledger's final event is 05:14Z. So the sequence the motivation describes — final gate
presented, *then* the gate run, *then* the ledger fixed — is exactly what the file mtimes show. What the
paragraph should not be read as is a live defect: it was closed, in the same run, by the ordering
proposal 2 below makes mandatory.

Two things worth noticing about how it was closed, because both bear on proposals in this batch:

- `traceability.yaml` carries its own provenance in-document: *"Filled 2026-08-03, after the second-voice
  judge correctly found it was still an unfilled template while `10-handoff.md` claimed all eleven
  criteria were covered."* `01-acceptance-criteria.yaml` and `08-qa-verdict.json` likewise carry
  correction language. Three decision artifacts were rewritten post-handoff and **all three disclosed
  it**. That is the append-with-a-visible-note discipline the commit-the-ledger PR proposes to make a
  rule — practised voluntarily here, and it is the only reason this correction is checkable at all.
- Neither partial was rounded up to `yes` to clear the gate, including AC-011, which records a criterion
  the run **violated**. Relevant to the stop-rule PR, whose condition (1) turns on exactly that.

Cited: `20260802T192726Z-remediate-wave2/11-retrospective.md` (SC-8),
`20260803T051454Z-remediate-wave4/11-retrospective.md`.

## Proposed change

- Files: `CLAUDE.md`, `commands/start.md`, `agent-firm/policy/definition-of-done.yaml`,
  `agents/packager.md`
  <!-- NB: agent definitions live at agents/, NOT .claude/agents/ — the first draft of this PR cited a
       path that does not exist. -->

**Prerequisite: this PR needs a mechanism, or it restates `CLAUDE.md:79`.** SC-3 (artifact validation at
write time) is that mechanism. It is proposed separately, as
`system-changes/20260803T095255Z-validate-run-artifacts-at-write-time.md` (committed at `b1868eb`,
`Status: proposed` — the *document* is in git; the tool it proposes, `bin/firm-validate-ledger`, does not
exist). Without it, items 1 and 3 below are obligations with nothing checking them — the same shape as
the wall-clock stop condition that existed and was never obeyed (see the wall-clock PR). The declared
dependency is one-directional but *acknowledged* in both files, which is the pattern the review held up
as correct; it is named here explicitly so a reader is not left inferring it from a bare "SC-3".

1. **Name the legitimate case and constrain it.** A run may start at Build when the work is fully
   specified by a prior findings artifact — that is proportionate and was correct here. But then
   `01-acceptance-criteria.yaml` is **RETROSPECTIVE**, must be labelled so in-file, and must be written
   **by reading `git diff <base>..<tip>`**, not by summarising the work-orders' intent.
2. **Make the ids reconcile, mechanically.** The QA verdict's `acceptance_criteria_coverage[].id` must
   use the same ids as `01-acceptance-criteria.yaml`. Whichever artifact is written second reads the
   first. (In `remediate-wave4` QA supplied the ids to the Packager and it reconciled cleanly — that
   ordering worked and should be the documented pattern.)
3. **Gate on it.** The Lead must run `firm-traceability-check` — using the binary from the branch under
   test — **before** presenting a final gate, not after. This overlaps SC-9 and should merge with it.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes. Any multi-run engagement where a later run is chartered from an
  earlier run's findings hits this, which is the firm's own documented multi-run doctrine.
- **Risk of overfitting the firm to one repo:** low. The change adds an obligation on *how* criteria
  are written, not on what they contain.
- **What has already generalised, and what has not** *(added on third review, since the guard section
  below now reports a shipped change and this section grades it)*: the *mechanical* half — a coverage
  entry naming no criterion is now a non-passing outcome — shipped at `76814ad` and applies to every run
  the firm will ever do, in any project. The *behavioural* half — criteria written from the diff rather
  than from work-order narrative — did not ship and cannot: no test can distinguish the two sources. So
  this PR's generalizability is asymmetric, and a reader should not take the shipped guard as evidence
  the thesis is enforced. It is evidence the thesis was worth stating.

## Risk & rollback

- **Risk:** requiring criteria up front for every Build-first run could reintroduce the overhead
  proportionality is meant to avoid. Mitigated by permitting the retrospective path explicitly rather
  than banning it — the fix is "write them from the diff", not "always hold a Requirements gate".
- **Risk the shipped guard introduces, measured** *(added on third review)*: `76814ad` made a phantom
  coverage id **exit 2 (cannot evaluate)**, not exit 1. Any ledger whose verdict was written against a
  renumbered or stale criteria set now fails the acceptance-coverage gate outright rather than reporting
  partial coverage. Executed against all eight existing run dirs, none is in that state, so nothing
  historical breaks. The residual is forward-looking: renumbering criteria mid-run — which proposal 1's
  retrospective path makes *more* likely, since the criteria are written last — now blocks the Final gate
  until the verdict is reconciled. That is the intended behaviour and it is also a new way for a run to
  stall late. Naming it because proposal 1 and the shipped guard push in opposite directions.
- **Rollback:** revert this PR (firm config is versioned in git). Note that the guard at `76814ad` is
  *already merged and is not part of this PR* — reverting this document does not revert that behaviour,
  and should not.

## Golden eval to guard it

**The first draft's eval was rejected on review**: the id-mismatch half is already covered twice
(`tests/test-traceability-check.sh:111`, and `traceability_passes: true` in the `greet-fast-path` and
`todo-full-track` evals), and its novel half — "the Lead does not reach the final gate" — has no
assertion verb behind it.

- Test, not eval: extend `tests/test-traceability-check.sh`
- **Status: this half SHIPPED and is closed. Stated past-tense (closes T-03 and T-02).** The reciprocal
  direction — coverage entries naming ids that exist in no criterion — was a **live fail-open at HEAD**
  when this section was written, found by *executing* the gate during review of this PR set rather than
  by reading it. It was closed on `main` at **`76814ad`** *("fix(traceability): a coverage entry naming
  no criterion is cannot-evaluate")* — `bin/firm-traceability-check` **+132/-10**,
  `tests/test-traceability-check.sh` +382 (**16** new `t_case` blocks, **110** new `assert_*` call sites;
  that file now holds 75 cases and executes 442 assertions, up from 59 / 317), and one line of
  `docs/ENFORCEMENT.md` — 515 insertions / 11 deletions across the three files. Nothing here remains to
  build. It is kept in the document, not deleted, because the *provenance* is the point: the guard this
  PR argued for found a real defect in the firm's own coverage gate within an hour of being proposed.
- **The fixture to pin is the SUPERSET, not wave 2's disjoint ledger — and this correction is why the
  shipped test is not a third redundant guard.** Two drafts of this section named the wave-2 shape.
  Executed at the time of review, a fully disjoint ledger **already exited 1** through the
  uncovered-criteria path that `tests/test-traceability-check.sh:111` (`t_case "an uncovered criterion
  FAILs"`) has pinned all along. Fixturing wave 2 would have passed without any code change and pinned
  nothing. The genuinely unpinned case was the superset: **every criterion covered `yes` PLUS coverage
  entries naming unknown ids**, which reported `TRACEABILITY: PASS` at exit 0 while printing the
  discrepancy it ignored. Wave 2 is the motivating story; the superset is the regression test.
- **Both cases re-executed against the gate as shipped** (binary taken from the tree under test,
  `bin/firm-traceability-check` @ `76814ad`; two criteria `AC-001`/`AC-002`):

  ```
  PROBE A -- superset: both criteria covered=yes, plus ids
             'deletes only the real fixture' and 'NOT-A-CRITERION'
    acceptance criteria: 2  verdict coverage entries: 4  -- MISMATCH: 2 of these entries name NO criterion
    coverage: 2 full (yes) | 0 partial | 0 waived | 0 problem(s) | 0 unverifiable | 2 phantom
    TRACEABILITY: CANNOT VERIFY -- coverage could not be evaluated, so this run has no
      traceability verdict in either direction:
      - coverage entry names id 'deletes only the real fixture' (covered='yes') -- NO criterion declares this id
      - coverage entry names id 'NOT-A-CRITERION' (covered='yes') -- NO criterion declares this id
    rc=2                                   <-- was rc=0, "TRACEABILITY: PASS", before 76814ad

  PROBE B -- wave-2 shape: coverage names ONLY descriptive strings (fully disjoint)
    TRACEABILITY: CANNOT VERIFY ... "the two id sets do not overlap AT ALL."
      ...and these criterion-level coverage failures were found as well:
      - AC-001: NOT in verdict coverage
      - AC-002: NOT in verdict coverage
    rc=2                                   <-- was rc=1 before 76814ad

  PROBE C -- control, exact 1:1 coverage
    TRACEABILITY: PASS -- all 2 criteria marked fully covered (covered=yes).
    rc=0
  ```

- **Where the shipped fix diverges from the reviewer's recommendation, recorded rather than smoothed
  over.** The review recommended exit **1** for this case ("the gate CAN evaluate it and the answer is
  no"). The shipped fix chose exit **2**, and its commit message gives the reasoning: a phantom id is a
  fact about the verdict's *provenance*, correspondence between the two documents is a precondition for
  comparing them, and once it is broken the entries whose ids *do* match are untrustworthy too. Exit 2 is
  also the only classification that fails closed for both caller polarities, since
  `firm-check-assertions` rejects anything outside {0,1} for `traceability_passes` **true and false
  alike**. A consequence worth flagging for a future reader: probe B's exit code **changed from 1 to 2**,
  so the reviewer's own stated ground for calling wave 2 redundant ("it already exits 1") is itself now
  out of date — the case is still caught, by a different code and a better message.
- **Honest limitation:** even the reciprocal check is bookkeeping. A verdict whose ids match the criteria
  perfectly can still describe work that was never done. Proposals 1 and 2 above — write criteria from
  the diff, reconcile ids across artifacts — remain guarded by review, not by this test.
- **Honest limitation:** whether the Packager *writes criteria from the diff* rather than from the
  work-order narrative is agent behaviour and is not assertable from a test. That is the substance of
  this PR and it is guarded by review, not by machinery. Stated rather than papered over.
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

**Blocking edit closed: T-03** — the fixture named is now the **superset** (every criterion covered plus
coverage entries naming unknown ids), not wave 2's disjoint ledger, which already failed through the
uncovered-criteria path. **T-02** (non-blocking) closed in the same pass: the claim is upgraded from
"untested direction" to "live fail-open, verified by execution", and then to past tense, because it was
**closed on main at `76814ad`**. Both probes were re-run against the gate as shipped and the raw output is
in the guard section.

**AC-005 cross-section propagation — performed.** After the guard section changed:
- *Motivation* was re-read and now records that its central example **no longer reproduces** —
  `firm-traceability-check` on wave 2's real ledger exits 0 today. Output pasted. Without this a reader
  checking the citation would conclude the document was wrong.
- *Generalizability* gained the asymmetry the shipped guard creates: the mechanical half generalises, the
  behavioural half cannot be tested at all.
- *Risk* gained the risk the shipped guard introduces (exit 2 on a renumbered criteria set, which
  proposal 1's retrospective path makes more likely) and the note that reverting this document does not
  revert `76814ad`.
- Batch grep: `76814ad` (this file and the never-rule PR, consistent in both); "all nine known instances"
  (the never-rule PR — corrected there to ten); the tier list in the footer (six files, corrected).

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
