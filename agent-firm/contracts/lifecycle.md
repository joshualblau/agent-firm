# Agent Firm lifecycle contract

This is the provider-neutral operating contract. The Claude adapter uses Claude staff and GPT as
the cross-provider judge; the Codex adapter uses GPT staff and Claude as the cross-provider judge.
Provider choice changes no gate, artifact, budget, worktree rule, merge rule, or acceptance standard.

## Lead contract

The Lead coordinates and synthesizes; it does not implement. It owns the run ledger, staffing,
execution budget, human gates, and final handoff. It is the only role that pauses the human.

Start with `firm-new-run --primary <claude|codex> <slug> <fast_path|full_track>`. Treat the returned
run directory as the source of truth. Record ordinary non-role milestones through ordinary
`firm-ledger-log`; every delegated role start uses the canonical boundary below.

## Delegated role-start boundary

Immediately before each delegated role start, the Lead runs exactly one canonical
`firm-model-resolve --provider <claude|codex> --role <role> --format activation` call (or its
explicitly justified tier/alias form). Without changing that resolver JSON, the Lead calls:

```text
firm-ledger-log --run <run> --strict --role-start \
  --stage <stage-instance> --role <role> --contract <run-relative-contract> \
  --event <expected-start-event> --authority-json <authority-json> \
  --agent <native-agent-id> --activation-json <exact-resolver-activation-json> \
  [--activation-justification <text>]
```

All contextual identity is explicit. Never infer the run or authority, manually stat or hash the
sealed contract, directly log a role start through ordinary mode, hand-create or transcribe an event
id, scrape it from the ledger, or run a second model resolution. The producer derives contract
provenance, validates the complete resolver object, appends and proves exactly one start event, and
only then emits its closed proof-instant receipt. The native result and zero return mean that the final
same-inode exact-byte proof observed exactly the accepted prefix plus its one complete record at that
instant; they do not attest later byte stability during result handling, output, cleanup, or return,
and the direct writer has no seal against a same-UID retained writer. Any nonzero exit, missing field,
extra field, schema mismatch, or value mismatch is BLOCKING.

Ledger writes in this release are supported only on the exact P2 row: macOS 26.5.1, Darwin 25.5.0,
arm64, local APFS, and CPython 3.9.6. The ordinary and native producers use the same centralized gate
before any ledger mutation or creation of a coordination lock or transaction temp. Linux and every
other mismatched or unverifiable environment are unsupported and fail closed without a success
result; ordinary best-effort mode is not a fallback. Expanding support requires new Architecture
approval and proving evidence.

The Lead parses only that proof-instant receipt result, applies its exact `activation.apply.model`,
`activation.apply.display`, `activation.apply.effort`, and `agent` to the provider-native launch,
and retains its exact `event_id` for downstream start, stop, block, and completion records. The
Codex-primary Lead performs a native Codex subagent launch; the Claude-primary Lead performs a native
Claude agent launch. Both launches occur outside repository automation. The producer validates and
records; it does not invoke or simulate either provider. Provider choice changes none of the
producer, result, retention, or failure semantics, and `firm-model-resolve` remains the sole
role-to-tier/model authority.

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
| Integrate | integrator | immutable `integration-summaries/<stage-instance>.md` + digest-bound index, integration branch | none |
| Review | reviewer panel | `07-review-findings.yaml` | crit; human when risky |
| Test | primary qa-tester | `08-qa-verdict.json`, `09-test-evidence/` | none |
| Cross-provider QA | opposite provider | `.gpt.json` or `.claude.json` verdict | two-voice rule |
| Package | packager | draft then finalized `10-handoff.md` | Final, always |
| Close | Lead | `11-retrospective.md`, proposed system changes | human per proposal |

Fast path collapses planning, integration, and panel overhead only when risk and dependency shape
permit it. It never waives clean QA, cross-provider disposition, traceability, merge authority, or
the Final gate.

Each integration cycle publishes through `firm-integration-summary`; it never reuses the legacy
singleton path. `integration-summaries/index.json` is append-only by stage and binds every summary's
path, byte count, and SHA-256. Review, QA, traceability, and packaging reference the immutable stage
path returned by the publisher. Existing runs without an index remain readable through their legacy
`integration-summary.md`; once indexed state exists, missing or mismatched history fails closed and
may not fall back to the singleton.

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
Immediately before the one Final interaction, run `firm-ledger-log final_gate_pending`. Present the
draft handoff together with every exact objection from the current `decision_required` artifact and
only its `permitted_record_types`; do not summarize objections into a broader authorization.

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
Persistent raw retention is unsupported: every nonzero `--retain-raw-seconds` request is rejected
before provider execution. Transient raw bytes exist only below the package-excluded, owned
`private-reviewer-control` tree and an independent guardian removes the complete attempt tree after
normal exit or wrapper death; any cleanup failure is visibly marked mode 0600 and makes the wrapper
BLOCK. They do not install, authenticate, upgrade, deploy, push, or otherwise change external state.

The secondary provider's BLOCK binds unless primary QA positively dissents on that exact point.
High-risk state is derived from accepted security/privacy criteria and the committed candidate diff
matched against `high-risk-paths.yaml`; ambiguity is high-risk. High-risk disagreement remains
blocking. A low-risk positive dissent may proceed only after exactly one evidenced bounded resolution
round is recorded. Fixed or withdrawn objections require a fresh secondary approval on the same
candidate generation; human decisions require an exact typed record. Every secondary blocker gets one
producer-authored object with a stable id, exact text, affected criteria, and affected paths; its
`two_voice_diff` entry must bind that id and repeat those fields exactly. Risk is derived from the
producer object, never from disposition-authored affected fields. An unavailable required judge needs a
matching trusted availability-attempt record and an exact logged human waiver. Primary QA BLOCK always
blocks. Run `firm-final-qa-check <run_dir>` before the Final interaction:

- exit 0 permits the Packager to present the draft handoff with the ordinary approve/reject Final
  choice once; after approval, the Packager finalizes it against that current passing result;
- exit 4 (`decision_required`) permits only a non-ship-ready draft handoff and one Final interaction
  naming the exact objections and permitted typed record options from that artifact;
- exits 1, 2, or 3 block the interaction as stale, invalid, unevaluable, or unavailable evidence.

The decision-required artifact aggregates the complete relevant objection set and each producer id,
text, derived risk, and permitted record type. If the human chooses a permitted option, the Lead
appends exactly one shared typed, digest-bound, current-run/current-full-SHA record naming every
relevant producer id and text, references it from every relevant disposition, and then runs one fresh
`firm-final-qa-check <run_dir>`. Finalize `10-handoff.md` only when that fresh run exits 0. A rejection,
wrong record type, mismatched objection, stale SHA/generation, or nonzero rerun stays blocked; never
manufacture a record, reinterpret the answer, or prompt a second time in the same Final cycle.

## Completion

After review, the Packager may assemble a clearly marked non-ship-ready draft. It names delivered
behavior, criteria status, evidence, both provider verdicts, exact objections/options, recorded
disagreements/waivers, known risks, rollback/migration notes, and the pending human decision. It is
finalized only after the applicable fresh mechanical Final check exits 0. Nothing is merged, deployed,
published, or otherwise shipped automatically.
