# Phase 2 — Dynamic staffing (hire per engagement, stay general)

Goal: let the firm bring in whatever expertise a project needs **without** carrying permanent domain
experts. The firm keeps a small set of core roles and **hires specialists on demand**, then retires them.

## The principle
A general-purpose firm should not have a standing "crypto investigator" (or finance, or medical, or
framework-X guru) — that expertise is dead weight on the many projects that don't need it. So:
- The **bench starts empty** of domain specialists (`bench/registry.yaml`).
- Expertise is **minted per engagement** and **retired** at the end.
- A specialist earns a durable spot only after proving **broadly reusable** (≥3 successful uses or human
  approval, and genuinely cross-project) — reviewed one at a time, guarded by a golden eval.

## What's added
- **`recruiter`** (agent, Opus) — given the Architect's expertise-required list, designs the team:
  core-first, then mints specialists with a written **job spec** (justification, least-privilege
  tools/MCP, budget, retirement). Produces `04-staffing-plan.yaml`.
- **`specialist`** (agent, Sonnet) — a domain-agnostic base. The Lead dispatches it with a job spec and
  it becomes that expert for one task, honoring its scope and `domain_guardrails`, then is retired.
- **`firm-hire <role>`** — scaffolds a job-spec skeleton (schema-shaped) into the run ledger for the
  Recruiter to fill; logs the hire.
- **`bench/registry.yaml`** — the durable bench (empty by design) + governance (promotion/retirement/
  scoping) + an illustrative (inactive) example of an entry's shape.

## Two hiring modes
- **Ephemeral (default):** `firm-hire` → fill the spec → dispatch the `specialist` agent with it →
  retire at end. No permanent footprint.
- **Hard-scoped:** when tool/MCP scope must be *enforced* (not just requested), persist a durable agent
  (via `/agents`) with explicit `tools`/`mcpServers`, use it, record it.

## Verified
- 9 agents load in the plugin (7 core + `recruiter` + `specialist`).
- `firm-hire` scaffolds a valid job spec and logs `hire_scaffolded` to `run.jsonl`.
- Plugin manifest validates; version bumped to 0.3.0.

## Not yet
- Phase 3 (Codex/GPT QA judge), rest of Phase 4 (multi-profile secrets), Phase 5 (egress firewall,
  visual regression, full golden-eval execution).
