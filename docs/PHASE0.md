# Phase 0 — Minimal Safe Operating System

Goal: a working, bounded, evidence-producing firm with the core roles — **before** any dynamic staffing
(Phase 2) or the GPT teammate (Phase 3), so blast radius is small while the lifecycle is proven.

## What's built
- **Core roles** (`.claude/agents/`): intake-analyst, architect, implementer, integrator, reviewer,
  qa-tester, packager — each with scoped tools, a model, a mandate, a durable-artifact contract, and
  role-specific never-rules. The **Lead** is the main session, driven by `CLAUDE.md`.
- **Run ledger** (`firm-new-run`, `firm-ledger-log`, `ledger-hook`): per-run directory with numbered
  artifacts + an append-only `run.jsonl`. This is the source of truth.
- **Policies** (`agent-firm/policy/`): layered action-scopes, the gate matrix + approval-payload format,
  never-rules, definition-of-done, failure-taxonomy, and execution-budget caps.
- **Schemas** (`agent-firm/schemas/`): acceptance-criteria, job-spec, qa-verdict (Codex-ready),
  staffing-plan — with `firm-validate-verdict` enforcing the QA verdict.
- **Permissions** (`.claude/settings.json`): allow/ask/deny implementing the action scopes, plus the
  PreToolUse logging hook.
- **Sandbox** (`.devcontainer/`): project-only mount, non-root, pinned base; egress firewall stubbed
  for Phase 5.

## How to run the lifecycle (manually, today)
From a work project that has the firm config:
```bash
firm-new-run my-feature full_track          # opens the ledger
claude                                      # Lead runs intake → … → package, delegating to subagents
firm-validate-verdict .agent-firm/runs/<run>/08-qa-verdict.json
```
The Lead pauses only at the gates and presents a well-formed approval payload; nothing merges/ships
without your final sign-off.

## Definition of done for Phase 0
- A real small task runs end to end, producing a complete ledger.
- QA emits a schema-valid APPROVE/BLOCK; `validate-verdict` passes.
- Gates fire correctly; caps are respected; the run never merges/deploys autonomously.

## Not yet (by design)
- Dynamic staffing / bench (Phase 2), Codex GPT QA (Phase 3), multi-profile secrets + plugin
  install + second-machine bootstrap (Phase 4), egress firewall + visual regression + golden evals (Phase 5).
