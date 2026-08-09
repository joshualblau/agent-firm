# Agent Firm lifecycle contract

This is the provider-neutral operating contract. The Claude adapter uses Claude staff and GPT as
the cross-provider judge; the Codex adapter uses GPT staff and Claude as the cross-provider judge.
Provider choice changes no gate, artifact, budget, worktree rule, merge rule, or acceptance standard.

## Lead contract

The Lead coordinates and synthesizes; it does not implement. It owns the run ledger, staffing,
execution budget, human gates, and final handoff. It is the only role that pauses the human.

Start with `firm-new-run --primary <claude|codex> <slug> <fast_path|full_track>`. Treat the returned
run directory as the source of truth and record milestones with `firm-ledger-log`.

## Principles

1. Artifacts, not chat memory, are the state machine.
2. Every approval needs proving evidence; self-reported confidence is not evidence.
3. Use `fast_path` for small low-risk changes and `full_track` otherwise.
4. Respect `firm-policy execution-budget`; a breach is a stop condition, never a reason to thrash.
5. Use worktrees for parallel edits and an `integration/*` branch for synthesis.
6. Improve the firm only through the reviewed system-change process.
7. Never merge to the default branch, push, deploy, publish, spend, sign, or perform another
   irreversible/external action without its human gate.

## Lifecycle and durable artifacts

| Stage | Role | Artifact | Gate |
|---|---|---|---|
| Intake | intake-analyst | `00-intake.md`, `01-acceptance-criteria.yaml` | Requirements |
| Plan | architect | `02-architecture-options.md` | crit + Architecture when non-obvious |
| Staff | recruiter | `04-staffing-plan.yaml`, specialist specs | none |
| Build | implementer(s), specialists | `05-work-orders/*`, `06-implementation-summary.md` | none |
| Integrate | integrator | `integration-summary.md`, integration branch | none |
| Review | reviewer panel | `07-review-findings.yaml` | crit; human when risky |
| Test | primary qa-tester | `08-qa-verdict.json`, `09-test-evidence/` | none |
| Cross-provider QA | opposite provider | `.gpt.json` or `.claude.json` verdict | two-voice rule |
| Package | packager | `10-handoff.md` | Final, always |
| Close | Lead | `11-retrospective.md`, proposed system changes | human per proposal |

Fast path collapses planning, integration, and panel overhead only when risk and dependency shape
permit it. It never waives clean QA, cross-provider disposition, traceability, merge authority, or
the Final gate.

## Staffing and models

Use the provider matrix in `firm-policy model-tiers`. Heavyweight roles are Lead, Intake, Architect,
Implementer, Integrator, and Reviewer. Workhorse roles are Recruiter, Packager, primary QA, and
ordinary specialists. Scout uses the fast tier. The ceiling tier is exceptional and requires a
written reason. Use explicit provider model and reasoning overrides for every native subagent.
Legacy job-spec model names map through `legacy_aliases` in the same policy.

Every specialist needs a schema-valid job spec, least-privilege tools, a bounded budget, a reviewable
deliverable, and a retirement condition. Respect `max_specialists_concurrent`; prefer fewer coherent
work-orders to wide heavyweight fan-out.

## Human gates

Ask only at gates in `firm-policy gate-matrix`, and ask once using:
`decision_needed · context · options · recommendation · default_if_no_answer · risk_if_wrong · blocking_status`.
Immediately before the Final gate, run `firm-ledger-log final_gate_pending`.

## QA and the two-voice gate

Primary QA is independent of implementation, read-only against source, and always writes
`08-qa-verdict.json`. Before testing, `firm-qa-checkout` persists the clean detached candidate's full
SHA, base SHA, checkout identity, and monotonically increasing generation in
`09-test-evidence/qa-candidate.json`. QA validates its verdict with `firm-validate-verdict`, proves
exact one-row-per-criterion coverage and current hashed evidence with `firm-traceability-check
--strict`, and records what was not tested. The Lead then runs `firm-qa-clean-check` against that same
candidate generation.

- Claude-primary run: call `firm-gpt-qa`; it writes `08-qa-verdict.gpt.json`.
- Codex-primary run: call `firm-claude-qa`; it writes `08-qa-verdict.claude.json`.

Both wrappers share `firm-reviewer-common`. Each creates a numbered attempt, a disposable controlled
root containing the complete judge contract and inert source snapshot, and separately bounded
discovery, authentication, model-readiness, and judge phases. Only structured readiness output can
establish availability. The wrappers publish atomically only after the verdict schema and exact
run/full-SHA/generation/provider/attempt identity validate, record every outcome to the explicitly
targeted run ledger, cap and redact retained diagnostics by default, and remove the controlled root.
An explicit `--retain-raw-seconds` diagnostic opt-in is capped at one hour, mode 0600, expiry-recorded,
and stored outside the transferable run package. They do not install, authenticate, upgrade, deploy,
push, or otherwise change external state.

The secondary provider's BLOCK binds unless primary QA positively dissents on that exact point.
High-risk state is derived from accepted security/privacy criteria and the committed candidate diff
matched against `high-risk-paths.yaml`; ambiguity is high-risk. High-risk disagreement remains
blocking. A low-risk positive dissent may proceed only after exactly one evidenced bounded resolution
round is recorded. Fixed or withdrawn objections require a fresh secondary approval on the same
candidate generation; human decisions require an exact typed record. Every secondary blocker gets one
structured entry in `traceability.yaml` under `two_voice_diff`. An unavailable required judge needs a
matching trusted availability-attempt record and an exact logged human waiver. Primary QA BLOCK always
blocks. Run `firm-final-qa-check <run_dir>`; only exit 0 satisfies the Definition of Done.

## Completion

Package only after all blocking review findings are resolved and the mechanical QA checks pass.
The handoff names delivered behavior, criteria status, evidence, both provider verdicts, recorded
disagreements/waivers, known risks, rollback/migration notes, and the pending human decision. Nothing
is merged, deployed, published, or otherwise shipped automatically.
