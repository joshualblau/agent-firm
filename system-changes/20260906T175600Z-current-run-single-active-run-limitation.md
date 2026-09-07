# System Change PR: `CURRENT_RUN` breaks under genuinely concurrent runs

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** 20260902T180106Z-evidence-seal-review-blockers-repair
- **Date (UTC):** 2026-09-06
- **Status:** approved
- **Being closed by run:** 20260907T063536Z-close-retro-loose-ends (item 1, AC-001..AC-012)

## Motivation
This run's entire back half (integration, both review passes, both QA rounds) ran concurrently with
a genuinely separate, unrelated, in-progress run (`20260903T185401Z-pr12-fix-merge-guard-defects`) on
the same shared checkout. `bin/firm-qa-checkout` and `bin/firm-integrate --default-branch-glob` both
hard-depend on a single repository-wide `.agent-firm/CURRENT_RUN` pointer, which the other run owned
for its own live session. Every Integrator/QA stage in this run had to hand-construct or route around
the canonical artifacts those tools would otherwise have produced (see `08-qa-verdict.json`'s
`environment` field: "The Lead hand-materialized this checkout and qa-candidate.json because
bin/firm-qa-checkout could not run without touching the shared .agent-firm/CURRENT_RUN, which points
at an unrelated, live, in-progress session"). This is not a one-off: any two runs that overlap in wall
clock time on the same checkout hit the identical wall, and the workaround (an agent or the Lead
hand-building what the tool would have produced) is exactly the kind of ad hoc, unverified path this
firm's own contracts try to eliminate elsewhere. It also creates a subtle trust gap: QA had to
independently re-derive checkout identity from live git state rather than trust `firm-qa-checkout`'s
output, because there was no `firm-qa-checkout` output for this run to trust.

## Proposed change
<!-- Concrete edits to firm config. List exact files. -->
- Files: `bin/firm-qa-checkout`, `bin/firm-integrate`, `.agent-firm/CURRENT_RUN` (or its replacement),
  and any other tool under `bin/` that reads/writes `CURRENT_RUN` as a repository-wide singleton
  (`rg -l CURRENT_RUN bin/` enumerates the exact set — not run as part of this proposal).
- Summary of the change: replace the single repository-wide `CURRENT_RUN` pointer with a per-run scoped
  identity that these tools can resolve without a shared mutable pointer — for example, an explicit
  `--run <run-dir>` argument threaded through `firm-qa-checkout` and `firm-integrate` that is sufficient
  on its own (no `CURRENT_RUN` fallback required when it is supplied), or a lock-file-per-run scheme
  under `.agent-firm/runs/<run-id>/` that these tools consult instead of one global file. Either
  approach must let two runs' Integrator/QA stages execute in the same checkout at overlapping times
  without one clobbering or blocking the other's canonical-artifact production.

## Generalizability check (reviewer)
<!-- Is this a reusable improvement, or a project-specific hack masquerading as one? -->
- Applies beyond this project? yes — any Agent Firm deployment that runs more than one track/run
  concurrently against the same repository checkout (the stated intended usage pattern, not an edge
  case) will hit this exact wall the first time two runs' Integrator or QA stages overlap.
- Risk of overfitting the firm to one repo: low — the fix is about `CURRENT_RUN`'s scoping model, not
  about anything specific to `agent-firm`'s own directory layout beyond what already exists.

## Risk & rollback
- Risk: touches two load-bearing tools (`firm-qa-checkout`, `firm-integrate`) that every run's
  Integrator and QA stages depend on; a scoping change that is subtly wrong could silently point a QA
  checkout at the wrong candidate. Needs careful before/after testing against both a single-run and a
  genuinely concurrent two-run scenario.
- Rollback: revert this PR (firm config is versioned in git).

## Golden eval to guard it
<!-- Every accepted change should be protected by a golden task so a future change can't silently
     regress it. Name the eval added/updated under agent-firm/evals/. -->
- Eval: `agent-firm/evals/<name>/` — a new golden that starts two runs against the same checkout,
  advances both to Integrator/QA concurrently, and asserts each resolves its own canonical
  checkout/integration artifacts without touching or blocking the other's.
- What it asserts: `firm-qa-checkout` and `firm-integrate`, invoked for run A while run B's own
  invocation of the same tools is in flight (or has left its own state in `CURRENT_RUN`), each produce
  artifacts bound to their own run's candidate SHA, and neither invocation fails, blocks, or silently
  operates on the wrong run.
- [ ] Golden evals pass (`firm-run-evals`) — attach the run output. If an eval changed, explain why the
      new behavior is correct (not just newly-passing).

## Human decision
- [x] approved by the human operator of run `20260907T063536Z-close-retro-loose-ends` on 2026-09-07
      (UTC)   |   [ ] rejected — reason:
      Recorded as ledger event `evt-20260907T063611-58861-681cdba4207e8b89`
      (`event: human_scope_decision`, `decision: approved`) in that run's `run.jsonl`, whose
      `drafts` field names this file. The ledger record carries no approver identity, so none is
      claimed here; the citation is the evidence.

**Known error in this proposal, left in place as the historical record but do not act on it:** it
cites `bin/firm-integrate --default-branch-glob`. That flag does not exist anywhere in the
repository. The closing run's intake enumerated the real blast radius, which also includes
`bin/firm-new-worktree`, `bin/firm-hire` and `bin/firm-bench-record`, none of which this file names.
The eval and disposition for item 1 are recorded by that run's own item-1 work orders, not here.
