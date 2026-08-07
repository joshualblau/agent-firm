# System Change PR: a review verdict carrying unapplied edits must block merge

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260806T143345Z-closeout-record-matches-code`, from lesson 2 of
  `20260803T120043Z-cleanup-and-identity-gate`'s retrospective
- **Date (UTC):** 2026-08-07
- **Status:** proposed

## Motivation

**A reviewer returned a conditional approval. The Lead merged on the condition's headline and skipped
its condition. Documents containing a false number went to `main` — inside System Change PRs whose
subject is claims not matching reality.**

### What the artifact actually said

`07-review-findings-DOC.yaml`, `overall:` block, reproduced verbatim:

```yaml
  is_the_set_committable: >-
    YES — commit the set, with the eight documentation edits below applied first (or, if the Lead
    prefers, applied as a single follow-up commit in the same run, since not one of them changes a
    proposal's meaning).
  blockers: []
  edits_required_before_commit:
    - 'F-DOC-01 · medium · PR2:148 and PR4:76 · +142/-11 -> +132/-10'
    - 'F-DOC-02 · medium · PR4:152-157 · state the no-args precondition or change the input'
    - … six more, low ·
```

Three things are true at once here, and their combination is the defect:

1. **The one structured field a machine would read is `blockers: []` — empty.**
2. **The obligation lives in a differently-named key**, `edits_required_before_commit`, with eight
   entries, two of them `medium`.
3. **The conditional is prose.** `is_the_set_committable` begins with the token `YES`. Any grep, any
   skim, and — as it turned out — the Lead, all resolve that to green. The word "first" is doing all
   the load-bearing work and it is doing it in a sentence.

The per-PR verdicts read `verdict: APPROVE_WITH_EDITS`.

### Why nothing caught it

**`APPROVE_WITH_EDITS` is not a value the firm defines.** `agents/reviewer.md:18` states the
vocabulary as exactly two values:

> an overall `verdict` (approved / changes_requested)

and `agent-firm/templates/07-review-findings.yaml` ends:

```yaml
verdict: changes_requested   # approved | changes_requested
```

The reviewer needed a third state, correctly — "this is right, and eight specific things must change
before it ships" is a real and common review outcome that neither available value expresses. Having no
name for it, the reviewer minted one. Having no schema, the firm accepted it.

That is the mechanical gap, and it is a one-line audit:

| Artifact | Schema | Validator | Gate precondition |
|---|---|---|---|
| `08-qa-verdict.json` | `agent-firm/schemas/qa-verdict.schema.json` | `bin/firm-validate-verdict` | yes — `gate-matrix.md:49`, must exit 0 |
| `01-acceptance-criteria.yaml` | `agent-firm/schemas/acceptance-criteria.schema.json` | via `firm-traceability-check` | yes |
| `04-staffing-plan.yaml` | `agent-firm/schemas/staffing-plan.schema.json` | — | no |
| **`07-review-findings.yaml`** | **none** | **none** | **no** |

`firm-validate-verdict` is documented in its own header as *"the firm's only mechanical evidence
check."* It validates QA's verdict. **It does not look at review findings at all.** The reviewer panel
— the stage whose entire output is a judgement about whether the change is fit to merge — writes into
the one artifact class with no closed vocabulary and no validator.

### What it cost

`main` carried `bin/firm-traceability-check +142/-11` in two System Change PRs where the truth is
`+132/-10`. F-DOC-01 is the *first* item on the list the Lead skipped, and it is `medium`. WO-G later
applied all eight, and while sweeping independently found **two further wrong claims of the same
class** that no reviewer had named — so the skipped list was not merely eight items, it was the thread
that led to ten.

Both numbers are now correct on `main`
(`system-changes/20260803T073753Z-eval-gates-never-pass-unevaluable.md:335` records the correction
explicitly). This PR is about the mechanism, not the residue.

### Why this is worth a firm change rather than a note

The Lead's error was a **reading**, and readings are exactly what this firm does not rely on anywhere
else it matters. The same engagement wrote three PRs on that principle. The gap is not that the Lead
was careless; it is that the review stage is the one place where a role's conclusion reaches the Lead
as *prose to be interpreted* rather than *a value to be checked*, and the interpretation ran in the
permissive direction under merge pressure. A third of the firm's evidence chain is unvalidated, and
it is the third with the most discretion in it.

Note also the shape of the near-miss: the reviewer explicitly offered the escape hatch — *"or, if the
Lead prefers, applied as a single follow-up commit in the same run"*. That is a legitimate option and
the Lead did not take it either. Neither branch of the reviewer's own sentence was executed.

## Proposed change

- Files: `agent-firm/schemas/review-findings.schema.json` (new), `bin/firm-validate-findings` (new),
  `agent-firm/templates/07-review-findings.yaml`, `agents/reviewer.md`,
  `agent-firm/policy/gate-matrix.md`, `CLAUDE.md`, `tests/test-validate-findings.sh` (new)

1. **Name the third state and close the enum.** Add `review-findings.schema.json` with
   `verdict: approved | approved_with_edits | changes_requested`. `approved_with_edits` becomes a
   first-class value **defined as blocking** — it means *not mergeable yet*, and the schema description
   says so in those words. A verdict outside the enum is a validation failure, not a value to be
   interpreted.
2. **Make the edits structured and dispositioned.** Each entry under `edits_required_before_commit`
   carries `id`, `severity`, `location`, `status: open | applied | waived`, and — for `waived` — a
   `waiver_reason` and who waived it. Prose conditions in `is_the_set_committable` are not
   machine-readable and must not be the only place an obligation is recorded.
3. **Add `bin/firm-validate-findings <path>`**, mirroring `firm-validate-verdict`'s existing three-way
   exit contract (`0` valid / `1` invalid / `2` usage / `4` DEGRADED-not-schema-validated). It fails
   when the verdict is `approved_with_edits` **and any edit's `status` is `open`**.
4. **Make it a Final-gate precondition**, listed in `gate-matrix.md` beside `firm-validate-verdict`
   and `firm-traceability-check`. Same posture as those: **exit 4 does not pass.** A gate that cannot
   verify its evidence must not clear.
5. **Update the reviewer's brief** (`agents/reviewer.md:18`) to state all three values and that
   `approved_with_edits` blocks until every edit is dispositioned. The reviewer was not wrong to want
   the state; it should not have had to invent it.

**Deliberately out of scope:** nothing here checks whether an edit was applied *correctly* — only that
someone recorded a disposition. That is honest and stated below under Risk.

### Relationship to the reviewed-SHA PR

`20260806T144301Z-assert-integration-matches-reviewed-sha.md` asserts *the merged bytes are the
reviewed bytes*. This asserts *the review said merge*. They are the two halves of one property and
neither implies the other: in this engagement the reviewed-SHA check passed on the final merge while
this one would have failed at the earlier one. If both are accepted they should be adjacent lines in
`gate-matrix.md`, and the same paragraph should say why there are two.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes. "Approve with comments" / "LGTM with nits" is a universal
  review outcome — GitHub, Gerrit, and every human code review have a name for it. A firm that reviews
  at all needs the state, and any firm whose reviewer output is free-form prose has this exact hole. The
  failure needs only: a reviewer with more nuance than the vocabulary allows, and a Lead under merge
  pressure.
- **Risk of overfitting:** low. It adds a schema and a validator to an artifact class that already has
  a template, using the pattern two other artifacts already follow. No new concept.
- **Would it have caught the actual incident?** Yes, mechanically: verdict `APPROVE_WITH_EDITS` fails
  the enum outright, and under the corrected vocabulary eight `status: open` entries fail the gate.

## Risk & rollback

- **The real risk, and it is not fully mitigable: reviewers may avoid the friction by grading down to
  `approved` and demoting edits to advisory prose.** A mechanism that makes honesty expensive buys
  compliance and loses signal. Partial mitigations: the reviewer brief should state that
  `approved_with_edits` is the *expected* verdict for a good review with findings and carries no
  penalty; and the Lead should treat a panel with zero `approved_with_edits` across a substantial
  change as a smell, not a triumph. Neither is a check, and this PR should not pretend otherwise.
- **Second risk: `status: applied` is self-reported** by whoever applied it. This gate proves an edit
  was *dispositioned*, never that it was *fixed*. In the actual incident WO-G's applications were
  verified by a subsequent reviewer pass, which is the real control; this is the tripwire, not the
  control. Do not let a green `firm-validate-findings` substitute for re-review of the applied edits.
- **Third risk: `waived` becomes the default escape.** Mitigation is visibility rather than
  prohibition — waivers require a named reason and surface in the Final-gate payload, the same posture
  `12-owner-override.md` took for overridden criteria. A waiver the human sees is fine; a silent one
  is the thing being prevented.
- **Rollback:** revert this PR (firm config is versioned in git). The schema and binary are additive;
  nothing depends on them until `gate-matrix.md` lists the precondition. Reverting that one line
  restores current behaviour exactly.

## Golden eval to guard it

- Test: `tests/test-validate-findings.sh` (new) — a shell test, not a model eval, for the same reason
  `20260806T144301Z` gives: file-in / exit-code-out, no model involvement, constructible under
  `mktemp -d`.
- What it asserts, using the real artifact as the load-bearing fixture:
  1. `verdict: approved`, no edits → **exit 0**.
  2. `verdict: approved_with_edits` with every edit `applied` or `waived` → **exit 0**.
  3. `verdict: approved_with_edits` with one edit `open` → **exit 1**, naming the open ids.
  4. **`verdict: APPROVE_WITH_EDITS` (the literal string from the incident) → exit 1, "not in enum".**
     This is the case that distinguishes this control from doing nothing, and the reason to write the
     test at all.
  5. `blockers: []` while `edits_required_before_commit` holds open items → **exit 1**. The incident's
     exact shape: the empty field must not be able to overrule the populated one.
  6. Malformed YAML / missing `verdict` → **exit 1**, never 0.
  7. `jsonschema` absent → **exit 4**, never 0 — mirroring `firm-validate-verdict`'s DEGRADED contract,
     which exists because that binary previously exited 0 in this situation and the Final gate cleared
     on it.
- Feasibility: high. Case 4 can use the run's real `07-review-findings-DOC.yaml` `overall:` block
  copied into `tests/fixtures/`, which also lifts that block out of the ungitted ledger — see below.

## Evidence availability (read this before following a citation)

The `.agent-firm/runs/...` paths cited above live in the **run ledger, which is not in git** —
excluded by `.gitignore:32` (`.agent-firm/runs/`). **This PR is committable; its primary evidence is
not.** That is the same gap
`system-changes/20260803T101922Z-commit-the-decision-bearing-ledger.md` proposes to close, and this PR
is a further argument for it: the artifact that proves the defect is the artifact that isn't kept.

What a reader **can** verify from a clone today, without the ledger:

- The vocabulary is two-valued: `agents/reviewer.md:18` and
  `agent-firm/templates/07-review-findings.yaml` (last line).
- No review-findings schema exists: `ls agent-firm/schemas/` returns four files, none of them it.
- The false number reached `main` and was corrected:
  `system-changes/20260803T073753Z-eval-gates-never-pass-unevaluable.md:335` records
  `+142/-11 → +132/-10` in the document's own edit history.

The `overall:` block is quoted verbatim above precisely so the decisive evidence survives outside the
ledger. Copying it into `tests/fixtures/` under item 4 makes that permanent.

## Author's disclosure

**The Lead who made this error is the author of this PR.** The account of what was read and why is a
self-report and should be weighed as one. The externally checkable parts are the three bullets in the
section above; the claim about the Lead's reasoning at the moment of merge is not among them.

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
