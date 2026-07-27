# System Change PR: Greenfield build track (multi-run planning + right-sized caps)

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** 20260727T080220Z-consulting-ops-system (surfaced Run 1; reaffirmed Runs 2 & 3)
- **Date (UTC):** 2026-07-27
- **Status:** approved

## Motivation
The full-track execution budget (`max_files_changed: 80`, `max_subagents_total: 12`,
`max_wall_clock_minutes: 120`) is sized for a substantial *change to an existing codebase*, not for a
*greenfield multi-module product build*. On the consulting-operations engagement the thin-vertical MVP
could not fit one run; the Lead discovered this mid-flight and re-scoped into three sequential runs
(Foundation+Auth, Catalog+Lifecycle, Intake). That phasing turned out to be *good* engineering (small
reviewable diffs, a human gate between each), but it was reactive rather than planned — the cap was hit
before the phasing decision was made. This should be a decision made at **intake/architecture**, not a
surprise at the file cap. (See `11-retrospective.md` in all three runs.)

## Proposed change
- Files: `agent-firm/policy/execution-budget.yaml`, `.claude/agents/architect.md` (or the architect
  prompt/policy), `agent-firm/policy/gate-matrix.md` (note the intake phasing decision).
- Summary of the change:
  1. Add a **`greenfield_build`** budget profile to `execution-budget.yaml` (a peer of `fast_path` /
     `full_track`) — same per-run caps as `full_track` BUT with an explicit expectation that greenfield
     product builds are decomposed into **multiple bounded runs**, one coherent slice each, with a human
     Final gate per run. Document that caps are per-run and the Lead opens a fresh run per phase.
  2. Add a required **Architect deliverable**: when the work is greenfield/multi-module, `02-architecture-
     options.md` must include a **run-phasing plan** (which slices map to which runs, dependency order,
     est. files/run) so phasing is decided at design time. If the estimated total exceeds one run's caps,
     that is a planned multi-run engagement, not a breach.
  3. Clarify in `gate-matrix.md` that "re-scope with the human" for a greenfield build means "confirm the
     run-phasing plan at the Architecture gate," not an ad-hoc mid-build stop.
- No cap is loosened; this makes phasing a planned, reviewed decision.

## Generalizability check (reviewer)
- Applies beyond this project? **yes** — any greenfield or large multi-module engagement hits the same
  wall (a new product is inherently >80 files). The fix is a planning convention + a profile, not a
  project-specific tweak.
- Risk of overfitting the firm to one repo: **low** — it adds a general track and an architect
  deliverable; it does not encode anything about consulting-ops specifically.

## Risk & rollback
- Risk: teams might over-phase trivial work. Mitigated by keeping `fast_path`/`full_track` as the
  defaults; `greenfield_build` is opt-in when the Architect declares the work greenfield/multi-module.
- Rollback: revert this PR (firm config is versioned in git).

## Golden eval to guard it
- Eval: `agent-firm/evals/greenfield-phasing/`
- What it asserts: given a greenfield multi-module brief whose estimated scope exceeds one run's file
  cap, the Architect output contains a run-phasing plan (>1 run, dependency-ordered) AND the Lead opens
  one run per phase rather than attempting a single over-cap run.
- [x] Golden evals pass (`firm-run-evals`) — structural validation passed for `greenfield-phasing`
      (task.md + assertions.yaml + fixture/ present and well-formed; all assertion types recognized by
      `firm-check-assertions`). Full model-run evals require a Claude login and are deferred.

## Human decision
- [x] approved by josh@heightslabs.com on 2026-07-27 (UTC)   |   [ ] rejected — reason:
