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

For delegated role starts, each Lead resolves once immediately before calling the single canonical
`firm-ledger-log --run <run> --strict --role-start` producer with explicit stage, role, contract,
event, authority, agent, and exact resolver activation JSON. The producer validates and records but
does not invoke a provider. The Lead parses only its proof-instant receipt result, launches the
provider-native agent
with the returned activation and agent fields, and retains the same returned `event_id` for later
lifecycle records. Manual contract hash/stat, ambient run or authority selection, direct ordinary
role-start logging, event-id transcription or ledger scraping, and a second model resolution are not
valid paths. Ordinary non-role milestones continue through ordinary `firm-ledger-log`; see the
[delegated role-start boundary](agent-firm/contracts/lifecycle.md#delegated-role-start-boundary).

Ledger writes in this release are supported only on a closed allowlist of proven P2 rows: macOS
26.5.1 with Darwin 25.5.0, or macOS 26.6.1 with Darwin 25.6.0, each on arm64, local APFS, and CPython
3.9.6. A row is matched whole and exactly; the allowlist is never a floor, range, prefix or wildcard,
so an OS row nobody has proven is unsupported until it is proven and added. The ordinary and native
producers use the same centralized gate before any ledger mutation or creation of a coordination lock
or transaction temp. Linux and every other mismatched or unverifiable environment are unsupported and
fail closed without a success result; ordinary best-effort mode is not a fallback. Expanding support
requires new Architecture approval and proving evidence.

**"P2" names two different predicates, and they are not interchangeable.** The *write-host row* is
the whole tuple above — OS pair, architecture, filesystem and interpreter together — matched entire,
and it is the only thing that admits a ledger write. The *interpreter row* is narrower: Darwin,
arm64, CPython 3.9.6, implementation `cpython`, with no OS-pair clause at all. It decides which
interpreter every `firm-*` tool executes, and it is what `firm-python --status` reports as
`p2=<yes|no>` and what `firm-python --require-p2` enforces with exit 17. `SUPPORTED_P2_OS_ROWS` in
`bin/firm-ledger-log` is the sole source for the OS-pair half; the resolver deliberately carries no
copy of it.

The two answers coincide on most machines, which is exactly why the distinction has to be written
down rather than inferred. They diverge on a Darwin/arm64 host that ships a compliant CPython 3.9.6
whose OS pair has never been proven — a supported *interpreter* on an unsupported *write host*.
Therefore `firm-python --status` reporting `p2=yes` is not a statement that ledger writes are
admitted here, `firm-doctor` exiting 0 does not follow from a compliant interpreter, and neither
answer may be derived from the other. Anything that needs the write-host answer asks the producer's
gate; anything that needs the interpreter answer asks the resolver. A check that reads one and
asserts about the other is wrong even when it happens to be green.

**A change touching either predicate is verified on a host where they diverge, or it is not
verified.** A green run on a fully proven row demonstrates nothing about the distinction, so it does
not discharge this requirement; the divergent case is exercised directly, or modelled by refusing the
host's own row and re-running. Where a claim is genuinely unattainable on the host at hand, it is
skipped visibly and by name — never quietly passed, and never quietly dropped, because a suite that
reports success while a claim went unexamined is the failure this rule exists to prevent.

A printed ordinary event ID or native result followed by exit zero means the producer completed its
final same-inode exact-byte proof and observed exactly the accepted prefix plus its one complete record
at that proof instant. It does not attest that those bytes remain stable during later result handling,
output, cleanup, or return, and the direct writer provides no seal against a same-UID retained writer.

To update both caches from local changes, run `firm-version --local-refresh`. For a release, run
`firm-version --release X.Y.Z`, then `firm-bootstrap`. Start a new Codex task and restart/reload the
Claude session after either refresh.

The plugin install carries the firm's **runtime** only. It does not bring `tests/` or
`.github/workflows/ci.yml` into your project: those are the firm's own regression suite and CI, and
they test `bin/` inside this repo. So don't expect `tests/run-tests.sh` or a `ci` workflow to appear in
`<repo>`; that's the design, not a broken install. To change the firm's tooling, work in this repo,
where CI runs.

Hosted CI runs `tests/run-tests.sh --unsupported-p2`: it exercises modern GNU and macOS Bash 3.2/BSD
behavior, plus the production gate's real-host fail-closed result, while omitting suites that require
successful ledger mutation. The complete `tests/run-tests.sh` write-path proof runs locally on any
proven P2 row (the set above, matched whole) or through the manual `run_exact_p2` workflow dispatch
on a trusted self-hosted runner labelled `agent-firm-p2`. Pull-request code cannot schedule that runner.

The runner executes the test **files** concurrently — one worker per CPU by default, overridden by
`--jobs N`, `$FIRM_TEST_JOBS`, or `--serial`. This is a change of schedule and nothing else: every
file and every assertion still runs, each file's output is still printed whole and in the order a
serial run prints it, and any file exiting non-zero still fails the suite. It also prints a per-file
wall-clock profile, because "which file is slow" is otherwise unanswerable. On this repo's 8-CPU
reference host that took the full suite from 21m27s (1287s serial) to **~591s mean**, measured across
three consecutive full runs at 581.2s / 589.4s / 602.2s. Budget a QA or CI window against ~10 minutes,
not against the ~4m this paragraph used to claim: that number predates the scheduling change below
and was never true of the shipped runner.

The reason it is ~10m rather than ~4m is recorded at the lever in the runner's own header.
`test-merge-guard.sh` measures the guard's parse phase against its real 4000ms production budget, and
sharing the host does not merely narrow that assertion's margin — it changes what the assertion
measures (2675ms alone, 3829ms co-scheduled, on the same unchanged guard). So that file is classified
`runs_alone` and takes most of the speedup with it. The measured consequence is that the budgeted case
now lands at 2664–2726ms, 67–68% of budget, bracketing the serial reference: **`--serial` buys that
case nothing extra**, and running it costs 1287s to buy a margin the default schedule already
provides.
`--fast` narrows a run to the files
your changes can reach and is a **development convenience only** — it announces that in its own
output and deliberately does not print the line a passing full run prints. `full` is what runs before
QA, the Final gate and CI. `tests/test-suite-runner.sh` holds the runner to its behaviour — ordering, skipping, exit codes, the `runs_alone` classification, and the fact that a worker killed without reporting its exit status is a named FAILURE rather than a hang. It does **not** hold the runner to the timing numbers above; those are measurements, re-measure them rather than trusting them.

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
                              #   firm-integrate, firm-integration-summary, firm-qa-checkout,
                              #   firm-qa-clean-check, firm-traceability-check,
                              #   firm-policy, firm-hire, firm-bench-record, firm-gpt-qa, firm-claude-qa,
                              #   firm-final-qa-check, firm-version, firm-model-resolve,
                              #   firm-propose-system-change, firm-run-evals, firm-check-assertions,
                              #   firm-visual-check, firm-visual-baseline, firm-notify, firm-install,
                              #   firm-link, firm-bootstrap, firm-doctor,
                              #   firm-python  <- decides WHICH python3 every one of the above runs;
                              #     `bin/firm-python --status` reports it and whether it is P2.
                              #     $FIRM_PYTHON overrides the candidate order (it is probed like any
                              #     other candidate, so it cannot make a non-compliant interpreter
                              #     report p2=yes)
                              #     ONE EXCEPTION, deliberately: firm-merge-guard is a security
                              #     control and resolves from fixed absolute paths only, consulting
                              #     neither $FIRM_PYTHON nor $PATH. `firm-python --trusted-status`
                              #     reports what it would run.
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
                              #   Node, plus jsonschema (test-validate-verdict) and pyyaml
                              #   (test-policy-yaml-valid) installed FOR THE INTERPRETER bin/firm-python
                              #   resolves — not for PATH's python3. See docs/INSTALL.md
.github/workflows/ci.yml      # hosted unsupported-P2 matrix + manual exact-P2 suite + structural evals
.claude/settings.json         # permission rules (copy-mode + the source firm-install merges)
.devcontainer/                # hardened sandbox (project-only mount, non-root, pinned base)
docs/README.md                # doc index; docs/PHASE*.md — dated build record per phase, not reference docs
docs/ENFORCEMENT.md           # load-bearing claimed invariants vs. what actually enforces each
                              #   (hand-maintained; no row = prompt-only until shown otherwise)
bench/registry.yaml           # durable specialist bench (governance, tracked). Raw usage evidence is
                              #   separate, untracked, per-project runtime state — firm-bench-record,
                              #   $(git rev-parse --git-common-dir)/agent-firm/bench-usage.jsonl
```

## Historical implementation milestones (not current-candidate readiness)
- **Phase 0 implementation:** core roles, ledger, permissions, sandbox, gates, QA schema, caps, handoff.
- **Phase 1 implementation:** worktree/integration/clean-QA tooling, traceability gate, the build-review-test workflow, retro → System-Change-PR + golden-eval loop.
- **Phase 2 implementation:** Recruiter + generic `specialist` + `firm-hire` — hire expertise per engagement; the bench stays general (no permanent domain experts). Promotion to the durable bench takes **≥3 successful uses across ≥3 distinct projects, each with a QA APPROVE, and no eval regression attributable to the specialist** — or explicit human approval, and genuinely cross-project either way. (Bare use-counting was the original bar; it was too weak and, before `firm-bench-record`, unmeasurable. `bench/registry.yaml` is authoritative.)
- **Phase 3 implementation:** symmetric cross-provider QA via `firm-gpt-qa` and `firm-claude-qa`, with the
  binding two-voice matrix mechanically enforced by `firm-final-qa-check` (see docs/PHASE3.md).
- **Phase 6 / 0.8.0 implementation:** one root-source plugin for both runtimes, GPT-primary native subagents,
  shared lifecycle/role contracts, provider-specific hooks, dual bootstrap/update flow, and
  provider-aware behavioral evals. This describes repository content, not readiness of this repair.
- **Phase 4 implementation:** versioned plugin distribution; portable secrets + per-project subscription profiles (`op` + direnv, `CLAUDE_CODE_OAUTH_TOKEN` + `CODEX_HOME`), a fail-closed `firm-doctor`, and chezmoi second-machine bootstrap. See [docs/PHASE4.md](docs/PHASE4.md).
- **Phase 5 implementation:** hardening — opt-in default-deny **egress firewall**; **visual-regression** suite wired into the QA `visual` verdict (`firm-visual-check`); provider-agnostic **remote approval notifications** (`firm-notify` — phone alerts, notify-only); **full golden-eval execution** (`firm-run-evals` drives the firm headlessly + `firm-check-assertions`); adversarial-panel + durable-runner docs. See [docs/PHASE5.md](docs/PHASE5.md).
- **Hardening and measurement implementation:** the firm's OWN tooling gets the same evidence-not-
  confidence bar it holds the deliverable to — a `bin/` regression suite + CI
  (`.github/workflows/ci.yml`; hosted unsupported-P2 coverage plus a manual trusted exact-P2 job,
  bash + git + Node + the firm's own resolved-interpreter/jsonschema/pyyaml prerequisites, no test framework), a
  fail-closed `run-baseline.json` SHA comparison replacing the old
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
Hosted unsupported-P2 CI is useful portability and fail-closed evidence, but is not a substitute for
that full-suite exact-P2 record. No modern-Bash run or live provider smoke is performed by the
ordinary build tests. Until those
records exist and Final QA passes, report the candidate as BLOCKED/unproved rather than “done” or
ready. A trusted secondary exit 3 is unavailable—not APPROVE—and must retain the target-run attempt,
matching ledger event, traceability state, and provider-specific verdict presence/absence. The Final
checker may then emit nonpassing `decision_required` (exit 4), which permits only a non-ship-ready
draft and one exact human interaction; a matching typed record plus one fresh exit 0 is required before
finalization. Provider-native
configuration suppression is a supported CLI boundary, not an OS/container or network-isolation
guarantee. Bootstrap compensation uses only supported inverse operations for freshly created entries.
Refreshing a pre-existing installed entry has no proven exact inverse; failure records
`BLOCKED_RECOVERY_REQUIRED` for manual comparison/restoration rather than repeating the forward
update/add command as a supposed rollback.
