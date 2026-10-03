# Agent Firm lifecycle contract

This is the provider-neutral operating contract. The Claude adapter uses Claude staff and GPT as
the cross-provider judge; the Codex adapter uses GPT staff and Claude as the cross-provider judge.
Provider choice changes no gate, artifact, budget, worktree rule, merge rule, or acceptance standard.

## Lead contract

The Lead coordinates and synthesizes; it does not implement. It owns the run ledger, staffing,
execution budget, human gates, and final handoff. It is the only role that pauses the human.

Start with `firm-new-run --primary <claude|codex> [--base <rev>] <slug> <fast_path|full_track>`.
EVERY OPTION GOES BEFORE THE SLUG; one placed after it is refused rather than silently discarded.
`--base` states the commit this run records as already reviewed, and it is REQUIRED whenever HEAD is
not at the tip of this repository's default branch — which includes the ordinary case of opening the
next run from an integration branch, and the case where the default branch cannot be resolved at all.
Without it the run is refused, not derived from wherever HEAD happens to be. `firm-new-run --help`
prints the full synopsis. Treat the returned run directory as the source of truth. Record ordinary
non-role milestones through ordinary `firm-ledger-log`; every delegated role start uses the canonical
boundary below.

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

That distinction is not academic. Both CI platforms went red on 2026-08-25 from this single
confusion, at two different layers: four assertions expected `firm-doctor` readiness `0` on hosts
whose OS pair can never match, and three predicted `firm-python --status` from the whole-tuple
answer. Both were introduced by correct changes that made the distinction observable for the first
time, and neither was caught before landing, because verification ran only on a proven P2 row —
the one configuration where the two predicates cannot disagree.

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
| Seal | Lead + draft packager | immutable `09-test-evidence/final-evidence/gN/` | none |
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
Immediately before the one Final interaction, run
`firm-ledger-log --run <run_dir> --strict final_gate_pending sha=<candidate_sha> generation=<N>` for the
current candidate generation; a sealed run admits that event with exactly those fields. Present the
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

For evidence-seal protocol v1, the Packager now freezes a non-ship-ready draft `10-handoff.md` with
one complete local PR body between the canonical markers. The Lead runs
`firm-seal-qa-evidence --run <exact-run-dir>` before either opposite-provider wrapper. The seal binds
the exact final primary bytes, privacy result, producer identities, ledger prefix, acyclic self
projection, and closed reviewer suffix grammar. Present, declared, or required partial seal state
blocks; only genuinely markerless historical runs retain manifest v3 compatibility.

After the publication the suffix admits reviewer events and, only once at least one reviewer attempt
is terminal and none is open, a closed post-judge phase interleavable with further attempts: the Final
check's own `final_decision_required`, the Lead's `final_gate_pending`, native primary-QA
(`qa-tester`) role windows (`qa_started` and its `qa_completed`), and
`post_judge_artifact_published` (`path`, `sha256`, `bytes`, `sha`, `generation`, `kind` of
`two_voice_dispositions`, `disposition_evidence`, or `human_decision`, `secondary_attempt_id`,
`seal_event_id`, `seal_projection_sha256`). Every one is bound to the seal's candidate and
generation; a post-judge artifact lies under `09-test-evidence/post-judge/g<N>/`, is published once
with its exact digest and size, names the seal's publication event and projection, and names an
attempt already terminal in that suffix. Post-judge artifacts and decision states are not sealed, so
verification scans them with the seal's own privacy policy, and the Final check scans every one it
consumes and refuses to write a decision state that would carry a privacy-policy match. Primary QA's own kinds, `two_voice_dispositions` and
`disposition_evidence`, also carry `stage`, `role=qa-tester` and `role_start_event_id`, and must be
published inside one native `qa-tester` window that was opened after the attempt they answer and is
closed by its `qa_completed`; a `human_decision` is published by the Lead, carries no window, and
names in `decision_required_event_id` the earlier `final_decision_required` it answers, whose decision
state names the same attempt. Any
other event after the seal still fails verification, and so does a post-judge event before the first
terminal attempt or while an attempt is open.

A recapture starts the next generation. `firm-qa-checkout` rewrites `qa-candidate.json` before it
appends its `qa_checkout` event, and verification always checks the seal of the live candidate's
generation, so from that moment generation N+1's seal is the one verified and the event lies in its
prefix. A `qa_checkout` inside a suffix that is being verified is therefore always refused; it never
ends or shortens the suffix. Earlier rows stay valid history only while each is bound to its own
generation's unique `qa_checkout` event, and a new evidence publication must match the current
candidate exactly. The new generation republishes its
fixed-root producers in fresh role windows and seals `final-evidence/g<N+1>/` before either wrapper
runs again; each generation's seal counts only its own producer rows.

- Claude-primary run: call `firm-gpt-qa`; it writes `08-qa-verdict.gpt.json`.
- Codex-primary run: call `firm-claude-qa`; it writes `08-qa-verdict.claude.json`.

Both wrappers share `firm-reviewer-common`. Each creates a numbered attempt, a disposable controlled
root containing the complete judge contract and inert source snapshot, and separately bounded
discovery, authentication, model-readiness, and judge phases. Only structured readiness output can
establish availability, read at the surface the installed CLI actually publishes; a readiness surface
a provider does not expose is never simulated, and configured-model readiness that cannot be
established is recorded as not established rather than assumed. The controlled root isolates provider
configuration and state, not identity: exactly one credential per provider crosses, and nothing else
does. Where that credential is a file it is copied by value into the attempt-local provider directory,
mode 0400, with the operator's own directory opened read-only and never written; where the provider
has no credential file it is the single operator-supplied credential environment variable, forwarded
only into the judge's own environment, size-bounded, never written to disk, and never recorded by
value. The wrappers never create a credential — minting one stays an operator action — and no
credential can establish readiness by itself: only the structured authentication phase can. The schema
handed to a provider is a generation projection derived at runtime from the canonical verdict schema,
which remains the sole validator of what comes back. The wrappers publish atomically only after the verdict schema and exact
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
blocks.

A sealed run's `traceability.yaml` is frozen before the judge, so primary QA answers a CURRENT
secondary BLOCK after it. It opens a fresh primary-QA window for the post-judge answer
(`firm-ledger-log --run <run_dir> --strict --role-start --stage <new stage> --role qa-tester
--event qa_started ...`), writes `09-test-evidence/post-judge/g<N>/two-voice-dispositions.<k>.json`
and publishes it inside that window with `firm-ledger-log --run <run_dir> --strict
post_judge_artifact_published path=<that path> sha256=<digest> bytes=<size> sha=<candidate_sha>
generation=<N> kind=two_voice_dispositions secondary_attempt_id=<current attempt> stage=<the window's
stage> role=qa-tester role_start_event_id=<the window's start> seal_event_id=<publication event>
seal_projection_sha256=<projection>`, the last two being `publication_event_id` and `projection_sha256`
from `firm-seal-qa-evidence --verify --run <run_dir>`, and then closes the window with `qa_completed`.
Disposition evidence is published the same way. The document is JSON with
exactly `schema_version` (1), `run_id`, `candidate_sha`, `generation`, `secondary_attempt_id`,
`secondary_verdict_sha256` and `secondary_verdict_bytes` (the current attempt's immutable verdict,
`verdict_sha256`/`verdict_bytes` on its terminal event), and `two_voice_diff`, whose entries have
exactly the traceability disposition shape. Evidence it cites may be a `disposition_evidence`
post-judge artifact and a human record a `human_decision` one; neither may stand in for the other,
each counts only when bound to this generation's seal, and a human record counts only when the
decision it answers was required after the current judge verdict, so nothing staged before the seal
can answer it.
Every post-judge file is published once, so a revision is a new `<k>`. Once the live candidate's
generation has a published seal, `firm-ledger-log` checks every row except the reviewer wrapper's own
against that seal's suffix grammar before appending it -- post-judge rows, role starts such as a
primary-QA window, and any ordinary event -- and refuses a row the grammar would refuse (an event it
does not admit, wrong field set, binding, path, digest, window, attempt, a window opened while a judge
attempt is open, or a privacy-policy match), naming why; nothing is appended, so correct the file or
command and publish again. A refused role start fails with `INPUT_INVALID: sealed-suffix`. A
recapture is not affected: `firm-qa-checkout` moves the live candidate to the next generation before
it appends, and that generation has no seal yet. A disposition must repeat the judge's objection text exactly, so if that text
itself carries a privacy-policy match no disposition of it can be published: run a new judge attempt
rather than editing around it. For a current BLOCK the Final
check uses the LATEST such publication for the generation when it names the current canonical attempt
and verdict digest and comes from a primary-QA window opened after that attempt ended; a latest publication naming anything else is ignored, never replaced by an older
one, and the check falls back to `traceability.yaml`. An unsealed run keeps its dispositions in
`traceability.yaml`. An objection with no disposition still blocks: silence is not dissent.

Run `firm-final-qa-check <run_dir>` before the Final interaction:

- exit 0 permits the Packager to present the draft handoff with the ordinary approve/reject Final
  choice once; after approval, the Packager finalizes it against that current passing result;
- exit 4 (`decision_required`) permits only a non-ship-ready draft handoff and one Final interaction
  naming the exact objections and permitted typed record options from that artifact;
- exits 1, 2, or 3 block the interaction as stale, invalid, unevaluable, or unavailable evidence.

The decision-required artifact aggregates the complete relevant objection set and each producer id,
text, derived risk, and permitted record type. If the human chooses a permitted option, the Lead
appends exactly one shared typed, digest-bound, current-run/current-full-SHA record naming every
relevant producer id and text, references it from every relevant disposition, and then runs one fresh
`firm-final-qa-check <run_dir>`. In a sealed run that record is a `human_decision` post-judge
artifact published with `secondary_attempt_id=<current attempt>` and
`decision_required_event_id=<the decision_required event it answers>`, and the dispositions citing it
are re-published as the next `two-voice-dispositions.<k>.json`. Each decision state names the attempt
it is about, and every post-judge record and evidence file answers exactly one attempt: after a
further judge attempt, nothing published for an earlier attempt answers the new verdict, and a new
BLOCK needs its own decision.
Finalize `10-handoff.md` only when that fresh run exits 0. A rejection,
wrong record type, mismatched objection, stale SHA/generation, or nonzero rerun stays blocked; never
manufacture a record, reinterpret the answer, or prompt a second time in the same Final cycle.

## Completion

After review, the Packager may assemble a clearly marked non-ship-ready draft. It names delivered
behavior, criteria status, evidence, both provider verdicts, exact objections/options, recorded
disagreements/waivers, known risks, rollback/migration notes, and the pending human decision. It is
finalized only after the applicable fresh mechanical Final check exits 0. Nothing is merged, deployed,
published, or otherwise shipped automatically.
