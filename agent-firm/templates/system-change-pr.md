# System Change PR: <short title>

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** <run_id>
- **Date (UTC):**
- **Status:** proposed | approved | rejected | merged

## Motivation
<!-- What recurring problem or opportunity did the engagement surface? Cite the retrospective. -->

## Proposed change
<!-- Concrete edits to firm config. List exact files. -->
- Files: `.claude/agents/…`, `agent-firm/policy/…`, `bench/registry.yaml`, `skills/…`, `agent-firm/workflows/…`
- Summary of the change:

## Generalizability check (reviewer)
<!-- Is this a reusable improvement, or a project-specific hack masquerading as one? -->
- Applies beyond this project? yes / no — why:
- Risk of overfitting the firm to one repo:

## Risk & rollback
- Risk:
- Rollback: revert this PR (firm config is versioned in git).

## Golden eval to guard it
<!-- Every accepted change should be protected by a golden task so a future change can't silently
     regress it. Name the eval added/updated under agent-firm/evals/. -->
- Eval: `agent-firm/evals/<name>/`
- What it asserts:

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
