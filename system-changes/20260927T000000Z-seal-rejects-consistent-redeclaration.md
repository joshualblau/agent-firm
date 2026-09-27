# System Change PR: the evidence seal rejects a path that the verdict and traceability contracts require to appear twice

A change to the **firm itself** (not a project deliverable).

- **Proposed by run:** `20260925T053346Z-pr12-merge-guard-two-voice-closeout` (wedged at the seal step)
- **Date (UTC):** 2026-09-27
- **Status:** proposed — awaiting human merge
- **Files:** `agent-firm/lib/evidence_seal.py` (`_discover_references`),
  `tests/test-evidence-seal.sh`, `agent-firm/evals/final-evidence-seal/task.md`

## Motivation

The closeout run for PR #12 had a correct, primary-QA-approved candidate (`acc2b15`) and could not
get past `firm-seal-qa-evidence`, the step that must run before the cross-provider judge. Its ledger
records `seal_wedged_by_sequencing_error` and an escalation to the human. The seal refused both
primary artifacts with `DUPLICATE_DECLARATION`:

1. `08-qa-verdict.json` listed nine captured logs in both `artifacts` and `commands_run[].artifact`.
   `commands_run[].artifact` is required, and `artifacts` holds "paths to logs/reports", so a
   captured log belongs in both places.
2. `traceability.yaml` cited three shared logs from more than one row (6, 4 and 3 rows). Each matrix
   row's `evidence` is an array of `evidenceRef` objects that require all five keys and set
   `additionalProperties: false`, so a row cannot point at a shared log by bare path.

`_discover_references` raised on *any* second declaration of a path within one artifact, so two
shapes the schemas require became fatal. Because the ledger is append-only and has no supersede
event, fixing the files after their `evidence_produced` records were published makes those records
`PRODUCER_STALE`, and republishing them makes them `PRODUCER_DUPLICATE`. The run cannot move forward.
This is the latest case of one internal contract rejecting what another requires (compare
`20260823T000000Z-primary-verdict-declaring-secondary-verdict-is-circular.md`).

## Proposed change

Within one artifact:

- **Now accepted:** the same path declared consistently from several places (a primary artifact
  that is also a `commands_run` artifact, the same `evidence://run/` token repeated in prose, or
  identical `evidenceRef`s in several traceability rows). These are deduplicated and the path is
  sealed once.
- **Still rejected with `DUPLICATE_DECLARATION`:**
  - two structured references to one path that disagree on `candidate_sha`, `sha256`, `bytes` or
    `producer`
  - one list that names the same path twice (the existing structured-list rule, plus a new check on
    the verdict's `artifacts`)
  - the existing integration-history index duplicate family (AC-007 `ac007_integration_index_duplicate`
    still observes `DUPLICATE_DECLARATION`)

## Generalizability check

- Applies beyond this project? Yes. Any run whose QA follows the verdict schema's intent, or reuses
  one log across criteria, hits this. It does not depend on the merge-guard work.
- Overfitting risk: low. The rule is about declaration consistency, not about this run's paths.

## Risk & rollback

- Risk: a real integrity signal could be lost if the rejected duplicate meant something. The only
  signal a repeated declaration can carry is a disagreement about identity, and that is still fatal.
- Rollback: revert this PR.

## Golden eval to guard it

- Deterministic guard: `tests/test-evidence-seal.sh`, in the case "one artifact may re-declare a path
  consistently; conflicting or repeated declarations still fail". It runs an end-to-end seal of a run
  where one log proves two traceability rows, checks the log is sealed exactly once, and includes unit
  cases for each rejection above. Without the fix it fails with the same error the wedged run hit:
  `BLOCK DUPLICATE_DECLARATION: traceability.yaml:structured_reference:…`.
- Golden eval: `agent-firm/evals/final-evidence-seal/`. The task now tells the run to shape evidence
  this way, so the existing `artifact_exists: …/seal.json` assertion fails if the regression returns.
  The live eval was **not** re-run for this change.

## Human decision

- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
