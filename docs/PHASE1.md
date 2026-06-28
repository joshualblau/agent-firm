# Phase 1 — Deterministic lifecycle and evidence

Goal: make the lifecycle **deterministic and evidence-driven** — parallel build with real isolation,
a true integration step, clean-checkout QA, acceptance traceability, and the loop by which the firm
improves itself under review.

## What's added on top of Phase 0
- **Worktree + integration tooling** (`bin/`):
  - `new-worktree <role> <wo>` — one isolated git worktree per work-order (base = local HEAD, named
    `<run_id>-<role>-<wo>`, with a deterministic port + db name; copies only `.env.example`, never secrets).
  - `integrate [branch]` — merges this run's worktree branches into an integration branch; conflicts are
    reported for the Integrator to resolve, never silently dropped.
  - `qa-checkout [branch]` — a fresh clean checkout at the integration HEAD so QA runs from known-clean state.
- **Traceability gate**: `firm-traceability-check` cross-references `01-acceptance-criteria.yaml` against
  the verdict's `acceptance_criteria_coverage` and fails if any criterion is uncovered without justification.
  Template: `agent-firm/templates/traceability.yaml`.
- **Fan-out workflow**: `agent-firm/workflows/build-review-test.js` — a Workflow-tool script that runs
  Build (parallel implementers in worktrees) → Integrate → Review panel → QA, keeping orchestration out
  of the Lead's context.
- **Continuous improvement loop**: `firm-propose-system-change <slug>` scaffolds a reviewed change to the
  firm itself (template `agent-firm/templates/system-change-pr.md`), guarded by **golden evals** under
  `agent-firm/evals/` (validate with `firm-run-evals`; full execution is Phase 5).

## Verified (smoke tests)
- Parallel worktrees with independent changes integrate cleanly; same-line edits conflict and are
  reported (exit non-zero), not dropped. Clean QA checkout reflects the integrated result.
- Traceability check fails on an uncovered criterion, passes when covered or explicitly justified.
- The workflow script parses under the runtime's async wrapping; all four stages + subagent types present.
- `run-evals` validates the golden-eval structure; `propose-system-change` scaffolds a PR.

## Not yet (by design)
- Recruiter + bench (Phase 2), Codex GPT QA judge (Phase 3), multi-profile secrets + plugin install +
  second-machine bootstrap (Phase 4), egress firewall + visual regression + full golden-eval execution (Phase 5).
