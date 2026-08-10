# agent-firm

A reusable **dual-provider AI engineering firm** for Claude Code and Codex. Either runtime can lead
the same disciplined lifecycle—**intake → plan → build → integrate → review → test → package**—using
the shared contract in [lifecycle.md](agent-firm/contracts/lifecycle.md). Claude-first runs use Claude
staff plus a GPT judge; Codex-first runs use GPT staff plus a Claude judge.

It is built as an **operating system, not a chatty org chart**: every role emits a durable artifact,
every gate carries evidence, every run is bounded, and the firm improves only through changes you review.

## Why it's shaped this way
- **Runtimes:** Claude Code and Codex CLIs, both subscription-authenticated. Each has a thin native
  adapter; lifecycle, roles, policies, tools, ledgers, hooks, and gates stay shared.
- **Cross-provider QA:** GPT judges Claude-primary runs; Claude judges Codex-primary runs. A secondary
  BLOCK follows the recorded two-voice rule and is mechanically checked by `firm-final-qa-check`.
- **Source of truth:** a per-run **ledger** on disk (`.agent-firm/runs/<ts>-<slug>/`), not chat context.

## Use it on a work project

> **Setup, including on a new device, is recorded in [docs/INSTALL.md](docs/INSTALL.md).** Quickest path
> on a machine that has this repo: `~/agent-firm/bin/firm-bootstrap` (registers the marketplace,
> installs both plugin caches, and links `firm-*` onto your shell PATH), then `firm-install` per
> project for Claude permissions. Start with `/agent-firm:start <goal>` in Claude or
> `$agent-firm:start <goal>` in Codex.
>
> **Wiring accounts/secrets/hardening** (1Password, per-project profiles, egress firewall, visual
> baselines, phone approvals, eval calibration) is a one-time runbook in [docs/WIRING.md](docs/WIRING.md).

**Required: install both provider CLIs and both adapters from this one checkout.**
```bash
~/agent-firm/bin/firm-bootstrap
```
Bootstrap fails before changing either installation unless both CLIs are present; there is no
single-provider install or refresh mode. It registers the
Claude `local` marketplace and Codex `agent-firm-local` marketplace, installs/refreshes both plugins,
and links the shared `firm-*` tools.

Then, in any work project (one-time, since a plugin can't ship permissions):
```bash
firm-install                                       # merge the firm's allow/ask/deny into .claude/settings.json
```
Now start an engagement in either runtime:
```bash
claude                                             # /agent-firm:start <your goal>
codex                                              # $agent-firm:start <your goal>
```
The Lead opens a run ledger (`firm-new-run`), delegates each stage to its subagent, pauses only at the
gates (with a well-formed approval payload), and gates on schema-valid QA evidence
(`firm-validate-verdict`, `firm-traceability-check`, and `firm-final-qa-check`) before final sign-off.

Runtime selection is fail-closed and inspectable. `firm-model-resolve --provider <claude|codex>
--role <role>` returns the exact tier, model, display, and effort; tier and legacy-alias selectors are
also supported. The canonical cells are: ceiling = Fable 5 (`fable`, `max`) / GPT-5.6 sol
(`gpt-5.6-sol`, `ultra`); heavyweight = Opus 5 (`opus`, `xhigh`) / GPT-5.6 sol
(`gpt-5.6-sol`, `xhigh`); workhorse = Sonnet 5 (`sonnet`, `high`) / GPT-5.6 terra
(`gpt-5.6-terra`, `high`); fast = Haiku 4.5 (`haiku`, `low`) / GPT-5.6 terra
(`gpt-5.6-terra`, `low`). Unknown roles, tiers, aliases, models, displays, or efforts block; there is
no fallback downgrade.

To update both caches from local changes, run `firm-version --local-refresh`. For a release, run
`firm-version --release X.Y.Z`, then `firm-bootstrap`. Start a new Codex task and restart/reload the
Claude session after either refresh.

The plugin install carries the firm's **runtime** only. It does not bring `tests/` or
`.github/workflows/ci.yml` into your project: those are the firm's own regression suite and CI, and
they test `bin/` inside this repo. So don't expect `tests/run-tests.sh` or a `ci` workflow to appear in
`<repo>`; that's the design, not a broken install. To change the firm's tooling, work in this repo,
where CI runs.

## Layout
```
.claude-plugin/plugin.json    # plugin manifest (name, version) — drives the versioned install
.claude-plugin/marketplace.json # local marketplace entry (this repo hosts the plugin)
.codex-plugin/plugin.json     # Codex manifest; root source, Codex skill adapter
.agents/plugins/marketplace.json # Codex local marketplace, agent-firm-local
agents/*.md                   # roles: intake, architect, implementer, integrator, reviewer, qa, packager,
                              #   recruiter, specialist, scout — model tiers: agent-firm/policy/model-tiers.yaml
commands/start.md             # /agent-firm:start — activates the firm and begins an engagement
codex-skills/start/SKILL.md   # $agent-firm:start — Codex-primary adapter
hooks/claude.json             # Claude PreToolUse + Notification hooks
hooks/hooks.json              # Codex default PreToolUse + PermissionRequest hooks
AGENTS.md                     # Codex primary/judge mode selection; FIRM_QA_JUDGE=1 wins
bin/firm-*                    # firm-new-run, firm-ledger-log, firm-validate-verdict, firm-new-worktree,
                              #   firm-integrate, firm-qa-checkout, firm-qa-clean-check, firm-traceability-check,
                              #   firm-policy, firm-hire, firm-bench-record, firm-gpt-qa, firm-claude-qa,
                              #   firm-final-qa-check, firm-version, firm-model-resolve,
                              #   firm-propose-system-change, firm-run-evals, firm-check-assertions,
                              #   firm-visual-check, firm-visual-baseline, firm-notify, firm-install,
                              #   firm-link, firm-bootstrap, firm-doctor
.envrc.example / .env.op.example # per-project profile + op:// secret references (direnv loads .envrc)
agent-firm/templates/visual/  # Playwright visual-regression config + specs (firm-visual-check gates on these)
agent-firm/policy/*           # action-scopes, gate-matrix, never-rules, definition-of-done, failure-taxonomy,
                              #   execution-budget, model-tiers, retired-permissions
agent-firm/contracts/*        # shared provider-neutral lifecycle and role contracts
agent-firm/schemas/*.json     # acceptance-criteria, job-spec, qa-verdict, staffing-plan
agent-firm/templates/*        # run-ledger artifact templates
agent-firm/workflows/*.js     # deterministic fan-out (build-review-test) for the Workflow tool
agent-firm/evals/*            # golden-task evals that guard firm changes
tests/*                       # bash+git regression suite for bin/ (tests/run-tests.sh). Also needs
                              #   python3, plus jsonschema (test-validate-verdict) and pyyaml
                              #   (test-policy-yaml-valid) — the same prerequisites the firm itself has
.github/workflows/ci.yml      # bash -n + the tests/ suite (ubuntu+macOS) + firm-run-evals --structural
.claude/settings.json         # permission rules (copy-mode + the source firm-install merges)
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
- **Phase 3 (done):** symmetric cross-provider QA via `firm-gpt-qa` and `firm-claude-qa`, with the
  binding two-voice matrix mechanically enforced by `firm-final-qa-check` (see docs/PHASE3.md).
- **Phase 6 / 0.8.0 (done):** one root-source plugin for both runtimes, GPT-primary native subagents,
  shared lifecycle/role contracts, provider-specific hooks, dual bootstrap/update flow, and
  provider-aware behavioral evals.
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

## Evidence boundaries for this repair

`firm-run-evals --structural [name]` is parse/shape-only: it validates a non-empty known assertion
vocabulary and value shapes, but never dispatches assertions or their shell, provider, reviewer, Git,
interpreter, filesystem, listener, or network payloads. Use `firm-run-evals --list` only to list valid
selectors. An unknown explicit selector exits 2 and prints the valid names. Behavioral runs use
`firm-run-evals --provider claude|codex [name]`; Codex turn events are streamed into a process-group
supervisor and Claude receives a provider-native `--max-turns`, in addition to post-run accounting.

The historical phase labels above describe shipped predecessor milestones, not approval of the
current repair candidate. Readiness requires evidence from the exact candidate SHA: the full suite
and security/final-gate matrices on macOS Bash 3.2 and a genuinely modern Bash, isolated real loader
checks, exactly one bounded live smoke in each primary orientation, and the gated rollback exercise.
No modern-Bash run or live provider smoke is performed by the ordinary build tests. Until those
records exist and Final QA passes, report the candidate as BLOCKED/unproved rather than “done” or
ready. A trusted secondary exit 3 is unavailable—not APPROVE—and must retain the target-run attempt,
matching ledger event, traceability state, provider-specific verdict presence/absence, and a plain-
text Final warning with `firm-final-qa-check <run-dir>` as the corrective command. Provider-native
configuration suppression is a supported CLI boundary, not an OS/container or network-isolation
guarantee; bootstrap restoration is compensating rollback, not atomic cross-provider installation.
