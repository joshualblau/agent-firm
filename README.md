# agent-firm

A reusable **AI engineering firm** for Claude Code: a hierarchical Lead orchestrates a team of
specialized role subagents through a disciplined lifecycle — **intake → plan → build → integrate →
review → test → package** — pausing for you only at critical decision points and final approval, and
**testing its own work** (with schema-validated evidence) before it asks you to sign off.

It is built as an **operating system, not a chatty org chart**: every role emits a durable artifact,
every gate carries evidence, every run is bounded, and the firm improves only through changes you review.

## Why it's shaped this way
- **Runtime:** Claude Code **CLI** (subscription-auth, subagents, worktrees, hooks, plan-mode gates,
  plugins). The Claude Agent SDK is reserved for explicitly API-billed automation.
- **GPT teammate (Phase 3):** an independent, read-only QA judge via `codex exec --output-schema` on
  your ChatGPT subscription — no API key.
- **Source of truth:** a per-run **ledger** on disk (`.agent-firm/runs/<ts>-<slug>/`), not chat context.

## Use it on a work project
1. Make the firm config available in the project — either copy `.claude/`, `CLAUDE.md`, `bin/`, and
   `agent-firm/` into the repo, or (Phase 4) install the packaged plugin.
2. Open the project in the hardened dev container (`.devcontainer/`).
3. Start `claude`. The Lead reads `CLAUDE.md` and runs the lifecycle:
   - `firm-new-run <slug> <fast_path|full_track>` opens a run ledger.
   - Each stage is delegated to its subagent (`.claude/agents/`), producing its artifact.
   - You're paused only at the gates in `agent-firm/policy/gate-matrix.md`, with a well-formed
     approval payload each time.
   - `firm-validate-verdict 08-qa-verdict.json` gates on schema-valid QA evidence before the final gate.

## Layout
```
CLAUDE.md                     # the Lead's operating manual (loaded every session)
.claude/agents/*.md           # core roles: intake, architect, implementer, integrator, reviewer, qa, packager
.claude/settings.json         # permissions (action scopes) + the ledger logging hook
agent-firm/policy/*           # action-scopes, gate-matrix, never-rules, definition-of-done, failure-taxonomy, execution-budget
agent-firm/schemas/*.json     # acceptance-criteria, job-spec, qa-verdict, staffing-plan
agent-firm/templates/*        # run-ledger artifact templates
agent-firm/workflows/*.js     # deterministic fan-out (build-review-test) for the Workflow tool
agent-firm/evals/*            # golden-task evals that guard firm changes
bin/                          # new-run, ledger-log, validate-verdict, new-worktree, integrate,
                              #   qa-checkout, traceability-check, propose-system-change, run-evals
.devcontainer/                # hardened sandbox (project-only mount, non-root, pinned base)
.claude-plugin/               # plugin + marketplace scaffold (Phase 4 packaging)
docs/PHASE0.md                # what's built now and the roadmap
```

## Roadmap (see the plan)
- **Phase 0 (done):** core roles, ledger, permissions, sandbox, gates, QA schema, caps, handoff.
- **Phase 1 (done):** worktree/integration/clean-QA tooling, traceability gate, the build-review-test workflow, retro → System-Change-PR + golden-eval loop.
- **Phase 2:** Recruiter + hireable specialist **bench** (incl. a `heightslabs`-scoped crypto-crime specialist) with job specs, budgets, and evals.
- **Phase 3:** Codex/GPT read-only QA judge via `codex exec --output-schema`.
- **Phase 4:** multi-profile secrets/auth (`op` + direnv, `CLAUDE_CONFIG_DIR` + `CODEX_HOME`), plugin packaging, second-machine bootstrap.
- **Phase 5:** egress firewall, visual-regression suite, Slack/phone approvals, golden evals, optional durable runners.
