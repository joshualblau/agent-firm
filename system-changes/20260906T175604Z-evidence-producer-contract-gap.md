# System Change PR: document the `evidence_produced` producer contract

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** 20260902T180106Z-evidence-seal-review-blockers-repair
- **Date (UTC):** 2026-09-06
- **Status:** approved
- **Closed by run:** 20260907T063536Z-close-retro-loose-ends (item 2, AC-013..AC-019)

## Motivation
This run's `bin/firm-ledger-log` now requires a closed 12-key shape for current-protocol
`evidence_produced` records, including three new fields — `stage`, `role`, and `role_start_event_id` —
that identify which role-start window produced the evidence. This requirement exists nowhere a producer
would read it: `rg` for `stage`, `role`, and `role_start_event_id` together against
`agent-firm/contracts/`, `commands/`, and `codex-skills/` returns nothing (confirmed independently by
this run's `security_privacy` and `acceptance_fit` reviewers and by primary QA at both rounds). Every
documented producer path — every role contract's instructions for how to publish evidence — still
describes only the older, now-legacy nine-key shape. The implementer who fixed the two review blockers
this gap surfaced (`WO-REVIEW-FIX-01`) explicitly declined to close it as out of scope for a code-repair
work order and flagged it in the clearest terms available: "Integrator ask / Lead ask: this needs an
owner before any role tries to publish evidence through a documented path. It is the single largest
thing a reasonable reader would expect to find here and does not." Left unaddressed, every role that
follows the documented path for a genuinely new run will keep emitting the nine-key shape, which the
current-protocol classifier now refuses (silently exit-0-refuses for ordinary best-effort logging calls,
per the same work order's fix) — a defect this run's own contracts and skills would walk a future agent
straight into.

## Proposed change
<!-- Concrete edits to firm config. List exact files. -->
- Files: `agent-firm/contracts/roles/*.md` (wherever a role is instructed to call
  `firm-ledger-log ... evidence_produced`), `agent-firm/contracts/lifecycle.md`, `commands/*.md`,
  `codex-skills/*/SKILL.md` — the exact surfaces this run's reviewers named as silent on the current
  shape.
- Summary of the change: add the current 12-key `evidence_produced` shape (canonical run-relative path,
  nonempty `sha`/`generation`/lowercase `sha256`/nonnegative `bytes`, target-run binding, and the
  current-protocol `stage`/`role`/`role_start_event_id` role-window fields) to every producer-facing
  contract and skill surface that currently documents only the legacy nine-key shape, so a role
  following its own contract emits a shape the ledger accepts rather than one it silently refuses.

## Generalizability check (reviewer)
<!-- Is this a reusable improvement, or a project-specific hack masquerading as one? -->
- Applies beyond this project? yes — this is a documentation/contract-completeness gap in the firm's
  own core evidence-publication mechanism, used by every role in every run, not anything specific to
  this run's four defect repairs.
- Risk of overfitting the firm to one repo: none — the fields in question (`stage`, `role`,
  `role_start_event_id`) are already part of `bin/firm-ledger-log`'s own accepted schema for every run;
  this proposal only makes the existing requirement discoverable where producers actually read
  instructions.

## Risk & rollback
- Risk: low for the documentation edits themselves; the risk is in scope creep if this is expanded into
  a code change (e.g., changing what the classifier accepts) rather than staying a
  contracts/commands/skills documentation change matching already-shipped code behavior.
- Rollback: revert this PR (firm config is versioned in git).

## Golden eval to guard it
<!-- Every accepted change should be protected by a golden task so a future change can't silently
     regress it. Name the eval added/updated under agent-firm/evals/. -->
- Eval: `agent-firm/evals/evidence-producer-contract-sync/` — added by the closing run.
- What it asserts: the field set documented in `agent-firm/contracts/evidence-producer-contract.md`
  is identical to `bin/firm-ledger-log`'s live `EVIDENCE_CURRENT_FIELDS`, which the checker parses
  out of the writer's own source rather than keeping a second copy of (AC-019); the writer's
  accept/refuse decision for a table of evidence shapes is unchanged (AC-017); and a run that
  published under the previous rules stays readable and appendable, bytes intact (AC-018). Its
  failure output names the divergent field(s), and it fails closed rather than passing vacuously.
- [x] Golden evals pass (`firm-run-evals --structural`) — parse/shape only, and NOT a behavioural
      claim. The three fixture properties were additionally run directly against the delivered
      checkout and mutation-verified in five directions (see the closing run's WO-D3 report).
- [ ] Behavioural `firm-run-evals evidence-producer-contract-sync` — not yet run; needs a provider
      login and budget.

## Human decision
- [x] approved by the human operator of run `20260907T063536Z-close-retro-loose-ends` on 2026-09-07
      (UTC)   |   [ ] rejected — reason:
      Recorded as ledger event `evt-20260907T063611-58861-681cdba4207e8b89`
      (`event: human_scope_decision`, `decision: approved`) in that run's `run.jsonl`, whose
      `drafts` field names this file. The ledger record carries no approver identity, so none is
      claimed here; the citation is the evidence.

## Disposition (recorded by the closing run)

Delivered as documentation only — no `bin/firm-ledger-log` code path changed, which the closing run
verified rather than assumed (repository-wide search at intake, recheck at Architecture, and the
eval's own unchanged accept/refuse table).

Two corrections to this proposal's own premise, found by the closing run and recorded so the file
does not stand as a false record:

1. The motivation says every documented producer path "still describes only the older, now-legacy
   nine-key shape." In fact **no producer-facing surface documented any field set at all.** The only
   producer instruction that existed was `agent-firm/contracts/roles/qa-tester.md`'s single sentence,
   which named neither the event nor any field. The work was therefore *writing* a producer contract,
   not amending a stale one.
2. The proposed file list names `commands/*.md` and `codex-skills/*/SKILL.md`. Each of those
   directories holds exactly one file (`commands/start.md`, `codex-skills/start/SKILL.md`) and both
   are role-start surfaces, not evidence-producer surfaces. Neither was edited.

Delivered surfaces: `agent-firm/contracts/evidence-producer-contract.md` (new, role-agnostic: field
set, one executable invocation, and the full precondition set — including the `0664`/`umask 002`
refusal and the duplicate-publication retry hazard) and `agent-firm/contracts/roles/qa-tester.md`
(points at it, and states in its own words that a non-`--strict` publication exits 0 and writes no
ledger row).
