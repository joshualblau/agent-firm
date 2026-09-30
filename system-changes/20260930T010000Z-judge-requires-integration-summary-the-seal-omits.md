# System Change PR: the judge wrapper requires an integration summary that a sealed closeout run correctly does not have

A change to the **firm itself** (not a project deliverable).

- **Proposed by run:** `20260928T213510Z-pr12-merge-guard-closeout-3` (first real run to seal; judge
  attempt `gpt-c1-a0001` stopped at input assembly and closed `reviewer_invalid`)
- **Date (UTC):** 2026-09-30
- **Status:** proposed — the human chose this option; awaiting merge
- **Files:** `bin/firm-reviewer-common`, `agent-firm/contracts/qa-judge.md`, `AGENTS.md`,
  `tests/test-evidence-seal.sh`

## Motivation

The seal treats the integration summary as optional: it adds `integration-summaries/index.json` or
`integration-summary.md` as a fixed root **only if one exists**. The judge wrapper treats it as
mandatory: with neither present, it stops before any provider phase with `required judge input is
missing: integration-summary.md`. A closeout run of an already-integrated candidate has no integration
stage. Its seal therefore correctly holds no summary, and its judge could never run. Adding a summary
after the seal would hand the judge an input outside the seal. Adding one before would mean inventing
an integration stage that never happened.

No test caught this, because every wrapper test runs on a pre-seal (manifest v3) run. No test drove
the wrapper on a sealed run.

## Proposed change

For a **sealed** run where no summary exists on disk **and** the seal holds none, the wrapper
records the absence as an entry in the manifest's `excluded_references` (origin
`integration-summary.md`, reason
`no_integration_stage_in_this_run_and_the_seal_holds_no_integration_summary`) instead of stopping.
The judge sees a declared, seal-consistent absence, not an omission. In every other case the rules are
unchanged: indexed history is still required when present, a summary the seal holds is still required,
and unsealed runs still require one. The judge contract (`qa-judge.md`) and its repository fallback
(`AGENTS.md`) describe the exclusion.

## Generalizability check

- Applies beyond this project? Yes. It covers every closeout or re-verification run of a candidate
  integrated elsewhere.
- Overfitting risk: low. The seal already defines what the judge must see; this makes the wrapper
  agree with it.

## Risk & rollback

- Risk: a sealed run that *should* have had an integration stage but skipped it would now reach the
  judge, not stop early. The judge sees the declared exclusion alongside the run's intake and ledger,
  and its contract tells it to weigh that.
- Rollback: revert this PR.

## Golden eval to guard it

- `tests/test-evidence-seal.sh`, case "the judge wrapper follows the seal on a run with no
  integration stage". It uses the **real** `firm-gpt-qa` on sealed runs built with the real
  `firm-qa-checkout`. With no summary, the wrapper gets past input assembly (and manifest v4 schema
  validation) to provider discovery, and reports the absent CLI as unavailable (exit 3). With a sealed
  summary that is then removed, it still blocks (exit 1, `ARTIFACT_MISSING: integration-summary.md`).
  Without the fix, the first half fails.

## Human decision

- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
