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
**Recommended: install as a versioned plugin (shared across all projects, one source of truth).**
```bash
claude plugin marketplace add ~/agent-firm        # register this repo as a local marketplace
claude plugin install agent-firm@heights-labs     # installs at user scope (all projects)
```
Then, in any work project (one-time, since a plugin can't ship permissions):
```bash
firm-install                                       # merge the firm's allow/ask/deny into .claude/settings.json
```
Now start an engagement in that project:
```bash
claude                                             # then run:  /agent-firm:start <your goal>
```
The Lead opens a run ledger (`firm-new-run`), delegates each stage to its subagent, pauses only at the
gates (with a well-formed approval payload), and gates on schema-valid QA evidence
(`firm-validate-verdict` + `firm-traceability-check`) before the final sign-off.

To update everywhere after a change: bump `version` in `.claude-plugin/plugin.json`, then
`claude plugin marketplace update heights-labs && claude plugin update agent-firm@heights-labs` (restart to apply).

**Fallback: copy mode** (no plugin). Copy the pieces into the project, mapping agents into `.claude/`:
```bash
mkdir -p <repo>/.claude && cp -R ~/agent-firm/agents <repo>/.claude/agents
cp -R ~/agent-firm/.claude/settings.json ~/agent-firm/bin ~/agent-firm/agent-firm ~/agent-firm/CLAUDE.md <repo>/
# add the firm's bin/ to PATH, or call tools as <repo>/bin/firm-*
```

## Layout
```
.claude-plugin/plugin.json    # plugin manifest (name, version) — drives the versioned install
.claude-plugin/marketplace.json # local marketplace entry (this repo hosts the plugin)
agents/*.md                   # core roles: intake, architect, implementer, integrator, reviewer, qa, packager
commands/start.md             # /agent-firm:start — activates the firm and begins an engagement
hooks/hooks.json              # run-ledger logging hook (plugin mode)
bin/firm-*                    # firm-new-run, firm-ledger-log, firm-validate-verdict, firm-new-worktree,
                              #   firm-integrate, firm-qa-checkout, firm-traceability-check, firm-policy,
                              #   firm-propose-system-change, firm-run-evals, firm-install
agent-firm/policy/*           # action-scopes, gate-matrix, never-rules, definition-of-done, failure-taxonomy, execution-budget
agent-firm/schemas/*.json     # acceptance-criteria, job-spec, qa-verdict, staffing-plan
agent-firm/templates/*        # run-ledger artifact templates
agent-firm/workflows/*.js     # deterministic fan-out (build-review-test) for the Workflow tool
agent-firm/evals/*            # golden-task evals that guard firm changes
.claude/settings.json         # permission rules (copy-mode + the source firm-install merges)
CLAUDE.md                     # operating manual (copy-mode reference; plugin uses /agent-firm:start)
.devcontainer/                # hardened sandbox (project-only mount, non-root, pinned base)
docs/PHASE*.md                # what's built per phase + the roadmap
```

## Roadmap (see the plan)
- **Phase 0 (done):** core roles, ledger, permissions, sandbox, gates, QA schema, caps, handoff.
- **Phase 1 (done):** worktree/integration/clean-QA tooling, traceability gate, the build-review-test workflow, retro → System-Change-PR + golden-eval loop.
- **Phase 2:** Recruiter + hireable specialist **bench** (incl. a `heightslabs`-scoped crypto-crime specialist) with job specs, budgets, and evals.
- **Phase 3:** Codex/GPT read-only QA judge via `codex exec --output-schema`.
- **Phase 4:** multi-profile secrets/auth (`op` + direnv, `CLAUDE_CONFIG_DIR` + `CODEX_HOME`), plugin packaging, second-machine bootstrap.
- **Phase 5:** egress firewall, visual-regression suite, Slack/phone approvals, golden evals, optional durable runners.
