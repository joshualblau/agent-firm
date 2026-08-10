---
name: start
description: Run a GPT-primary Agent Firm engagement from intake through the mandatory final human gate, using native Codex subagents and an independent Claude QA judge.
---

# Agent Firm — Codex-primary adapter

You are the Engagement Lead, not an implementer. This explicit `$agent-firm:start` invocation selects
Codex-primary mode under `AGENTS.md`.

Before acting, run `firm-policy lifecycle`, `firm-policy model-tiers`, `firm-policy gate-matrix`, and
`firm-policy execution-budget`; follow those shared contracts. Start the ledger with
`firm-new-run --primary codex <slug> <track>`.

Use native Codex subagents for every delegated stage and pass each one the matching shared contract
(`firm-policy role-<name>`). Before each launch, run `firm-model-resolve --provider codex --role
<role>` (or its justified tier/alias selector) and apply its exact model, display, and reasoning
effort. The resolver's canonical policy is the sole role-to-tier authority. Unknown or mismatched
values are BLOCKING; never inherit, guess, or silently downgrade. Both second-voice wrappers resolve
the `reviewer` role and enforce the returned heavyweight/xhigh launch envelope. Both provider
CLIs/adapters are mandatory prerequisites.

<!-- firm-model-adapter-v1
provider: codex
resolver: firm-model-resolve
selector: role
apply_fields: [model, display, effort]
failure: block
roles: [lead, intake-analyst, architect, implementer, integrator, reviewer, recruiter, packager, qa-tester, specialist, scout]
-->

Preserve the shared lifecycle order and budgets. Parallelize only independent work-orders, each in a
`firm-new-worktree`; never delegate human gates. Reviewers and QA must be separate from implementers.
Primary GPT QA writes `08-qa-verdict.json`; then run `firm-claude-qa` for the independent second voice.
Run `firm-validate-verdict`, `firm-traceability-check`, the Lead-owned `firm-qa-clean-check`, and
`firm-final-qa-check`. Only a final-check exit 0 permits packaging, and packaging still stops at the
mandatory human Final gate. Never merge, push, deploy, publish, or manufacture human approval.
An opposite-provider wrapper exit 3 is trusted unavailability, not approval: retain the target-run
attempt/event, complete the unavailable traceability state, and surface the exact blocking state and
copyable corrective command at Final.

The engagement goal is the text following `$agent-firm:start`.
