# agent-firm

A reusable **AI engineering firm** for Claude Code: a hierarchical Lead orchestrates a team of
specialized role subagents through a disciplined lifecycle — **intake → plan → build → integrate →
review → test → package** (the full stage/subagent/artifact/gate table lives in
[CLAUDE.md](CLAUDE.md#the-lifecycle-delegate-each-stage-to-its-subagent), the operating manual — this
README doesn't carry a second copy) — pausing for you only at critical decision points and final
approval, and **testing its own work** (with schema-validated evidence) before it asks you to sign off.

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
Either install path — plugin or copy — carries the firm's **runtime** only. Neither brings `tests/` or
`.github/workflows/ci.yml` into your project: those are the firm's own regression suite and CI, and
they test `bin/` inside this repo. So don't expect `tests/run-tests.sh` or a `ci` workflow to appear in
`<repo>`; that's the design, not a broken install. To change the firm's tooling, work in this repo,
where CI runs.

## Layout
```
.claude-plugin/plugin.json    # plugin manifest (name, version) — drives the versioned install
.claude-plugin/marketplace.json # local marketplace entry (this repo hosts the plugin)
agents/*.md                   # roles: intake, architect, implementer, integrator, reviewer, qa, packager,
                              #   recruiter, specialist, scout — model tiers: agent-firm/policy/model-tiers.yaml
commands/start.md             # /agent-firm:start — activates the firm and begins an engagement
hooks/hooks.json              # run-ledger logging hook (plugin mode)
AGENTS.md                     # Codex's instructions (independent GPT QA judge)
bin/firm-*                    # firm-new-run, firm-ledger-log, firm-validate-verdict, firm-new-worktree,
                              #   firm-integrate, firm-qa-checkout, firm-qa-clean-check, firm-traceability-check,
                              #   firm-policy, firm-hire, firm-bench-record, firm-gpt-qa,
                              #   firm-propose-system-change, firm-run-evals, firm-check-assertions,
                              #   firm-visual-check, firm-visual-baseline, firm-notify, firm-install,
                              #   firm-link, firm-bootstrap, firm-doctor
.envrc.example / .env.op.example # per-project profile + op:// secret references (direnv loads .envrc)
agent-firm/templates/visual/  # Playwright visual-regression config + specs (firm-visual-check gates on these)
agent-firm/policy/*           # action-scopes, gate-matrix, never-rules, definition-of-done, failure-taxonomy,
                              #   execution-budget, model-tiers, retired-permissions
agent-firm/schemas/*.json     # acceptance-criteria, job-spec, qa-verdict, staffing-plan
agent-firm/templates/*        # run-ledger artifact templates
agent-firm/workflows/*.js     # deterministic fan-out (build-review-test) for the Workflow tool
agent-firm/evals/*            # golden-task evals that guard firm changes
tests/*                       # bash+git regression suite for bin/ (tests/run-tests.sh). Also needs
                              #   python3, plus jsonschema (test-validate-verdict) and pyyaml
                              #   (test-policy-yaml-valid) — the same prerequisites the firm itself has
.github/workflows/ci.yml      # bash -n + the tests/ suite (ubuntu+macOS) + firm-run-evals --structural
.claude/settings.json         # permission rules (copy-mode + the source firm-install merges)
CLAUDE.md                     # operating manual (copy-mode reference; plugin uses /agent-firm:start)
.devcontainer/                # hardened sandbox (project-only mount, non-root, pinned base)
docs/README.md                # doc index; docs/PHASE*.md — dated build record per phase, not reference docs
docs/ENFORCEMENT.md           # load-bearing claimed invariants vs. what actually enforces each
                              #   (hand-maintained; no row = prompt-only until shown otherwise)
bench/registry.yaml           # durable specialist bench (governance, tracked). Raw usage evidence is
                              #   separate, untracked, per-project runtime state — firm-bench-record,
                              #   $(git rev-parse --git-common-dir)/agent-firm/bench-usage.jsonl
```

## Roadmap (see the plan)
- **Phase 0 (done):** core roles, ledger, permissions, sandbox, gates, QA schema, caps, handoff.
- **Phase 1 (done):** worktree/integration/clean-QA tooling, traceability gate, the build-review-test workflow, retro → System-Change-PR + golden-eval loop.
- **Phase 2 (done):** Recruiter + generic `specialist` + `firm-hire` — hire expertise per engagement; the bench stays general (no permanent domain experts). Promotion to the durable bench takes **≥3 successful uses across ≥3 distinct projects, each with a QA APPROVE, and no eval regression attributable to the specialist** — or explicit human approval, and genuinely cross-project either way. (Bare use-counting was the original bar; it was too weak and, before `firm-bench-record`, unmeasurable. `bench/registry.yaml` is authoritative.)
- **Phase 3 (done):** independent Codex/GPT QA judge via `codex exec --output-schema` on the ChatGPT subscription (`firm-gpt-qa`, two-voice QA); needs `codex login` (see docs/PHASE3.md).
- **Phase 4 (done):** versioned plugin distribution; portable secrets + per-project subscription profiles (`op` + direnv, `CLAUDE_CODE_OAUTH_TOKEN` + `CODEX_HOME`), a fail-closed `firm-doctor`, and chezmoi second-machine bootstrap. See [docs/PHASE4.md](docs/PHASE4.md).
- **Phase 5 (done):** hardening — opt-in default-deny **egress firewall**; **visual-regression** suite wired into the QA `visual` verdict (`firm-visual-check`); provider-agnostic **remote approval notifications** (`firm-notify` — phone alerts, notify-only); **full golden-eval execution** (`firm-run-evals` drives the firm headlessly + `firm-check-assertions`); adversarial-panel + durable-runner docs. See [docs/PHASE5.md](docs/PHASE5.md).
- **Hardening and measurement phase (done):** the firm's OWN tooling gets the same evidence-not-
  confidence bar it holds the deliverable to — a `bin/` regression suite + CI
  (`.github/workflows/ci.yml`; bash + git + the firm's own python3/jsonschema/pyyaml prerequisites, no
  test framework), a fail-closed `run-baseline.json` SHA comparison replacing the old
  commit-count heuristic for `no_default_branch_merge`/`final_gate_pending`, a negative golden eval
  (`qa-blocks-broken-build`) proving QA will actually **BLOCK**, `firm-qa-clean-check` (Lead-run, not
  self-certified), and a per-project bench usage log (`firm-bench-record`). See the system-change
  record for the full account: `system-changes/20260728T184311Z-hardening-and-measurement.md`.

### Not yet: self-improvement
"Continuous-improvement loop" (above, Phase 1) and the hardening pass just above it both **record**
outcomes and **guard** against regressions — they do not yet **improve** the firm on their own. The
loop still runs entirely through a human: a retrospective proposes a System Change PR, a human reviews
and approves it, and only then does a golden eval guard the change. What's genuinely missing, so
"continuous improvement" isn't read as more than it is:
- **Lesson extraction** — nothing mines retrospectives or run ledgers across engagements for patterns.
- **Change proposal** — System Change PRs are hand-written from what a Lead noticed, not synthesized.
- **Benchmarking a proposed change before adoption** — `firm-run-evals` guards an ALREADY-approved
  change; nothing runs the eval suite against a candidate change to inform the approval decision itself.
- **Automated versioning or rollback** — reverting a System Change PR today is a manual `git revert`.
Each of these is a real, larger project, not a small addition — deliberately out of scope here.
