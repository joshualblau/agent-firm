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

> **Setup, including on a new device, is recorded in [docs/INSTALL.md](docs/INSTALL.md).** Quickest path
> on a machine that has this repo: `~/agent-firm/bin/firm-bootstrap` (registers the marketplace,
> installs the plugin, and links `firm-*` onto your shell PATH), then `firm-install` per project,
> then `/agent-firm:start <goal>`.
>
> **Wiring accounts/secrets/hardening** (1Password, per-project profiles, egress firewall, visual
> baselines, phone approvals, eval calibration) is a one-time runbook in [docs/WIRING.md](docs/WIRING.md).

**Recommended: install as a versioned plugin (shared across all projects, one source of truth).**
```bash
claude plugin marketplace add ~/agent-firm        # register this repo as a local marketplace
claude plugin install agent-firm@local     # installs at user scope (all projects)
~/agent-firm/bin/firm-link                        # symlink firm-* into ~/.local/bin (SHELL PATH)
```
`firm-link` is not optional: a plugin's `bin/` is on `$PATH` only *inside* a `claude` session, and
`firm-install` below is run from your own terminal. `firm-bootstrap` does all three steps for you.

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
`claude plugin marketplace update local && claude plugin update agent-firm@local` (restart to apply).

**Fallback: copy mode** (no plugin). Copy the pieces into the project, mapping agents into `.claude/`:
```bash
mkdir -p <repo>/.claude && cp -R ~/agent-firm/agents <repo>/.claude/agents
cp -R ~/agent-firm/.claude/settings.json ~/agent-firm/bin ~/agent-firm/agent-firm ~/agent-firm/CLAUDE.md <repo>/
<repo>/bin/firm-link --dir ~/.local/bin   # put firm-* on PATH, or call them as <repo>/bin/firm-*
```

## Layout
```
.claude-plugin/plugin.json    # plugin manifest (name, version) — drives the versioned install
.claude-plugin/marketplace.json # local marketplace entry (this repo hosts the plugin)
agents/*.md                   # roles: intake, architect, implementer, integrator, reviewer, qa, packager,
                              #   recruiter, specialist, scout (Opus 5 for lead/intake/architect/build/
                              #   integrate/review; Sonnet 5 workhorse; Haiku scout; Fable escalation)
commands/start.md             # /agent-firm:start — activates the firm and begins an engagement
hooks/hooks.json              # run-ledger logging hook (plugin mode)
AGENTS.md                     # Codex's instructions (independent GPT QA judge)
bin/firm-*                    # firm-new-run, firm-ledger-log, firm-validate-verdict, firm-new-worktree,
                              #   firm-integrate, firm-qa-checkout, firm-traceability-check, firm-policy,
                              #   firm-hire, firm-gpt-qa, firm-propose-system-change, firm-run-evals,
                              #   firm-check-assertions, firm-visual-check, firm-visual-baseline,
                              #   firm-notify, firm-install, firm-link, firm-bootstrap, firm-doctor
.envrc.example / .env.op.example # per-project profile + op:// secret references (direnv loads .envrc)
agent-firm/templates/visual/  # Playwright visual-regression config + specs (firm-visual-check gates on these)
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
- **Phase 2 (done):** Recruiter + generic `specialist` + `firm-hire` — hire expertise per engagement; the bench stays general (no permanent domain experts; promote only via ≥3 uses or approval).
- **Phase 3 (done):** independent Codex/GPT QA judge via `codex exec --output-schema` on the ChatGPT subscription (`firm-gpt-qa`, two-voice QA); needs `codex login` (see docs/PHASE3.md).
- **Phase 4 (done):** versioned plugin distribution; portable secrets + per-project subscription profiles (`op` + direnv, `CLAUDE_CODE_OAUTH_TOKEN` + `CODEX_HOME`), a fail-closed `firm-doctor`, and chezmoi second-machine bootstrap. See [docs/PHASE4.md](docs/PHASE4.md).
- **Phase 5 (done):** hardening — opt-in default-deny **egress firewall**; **visual-regression** suite wired into the QA `visual` verdict (`firm-visual-check`); provider-agnostic **remote approval notifications** (`firm-notify` — phone alerts, notify-only); **full golden-eval execution** (`firm-run-evals` drives the firm headlessly + `firm-check-assertions`); adversarial-panel + durable-runner docs. See [docs/PHASE5.md](docs/PHASE5.md).
