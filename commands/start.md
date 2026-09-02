---
description: Activate the firm and run an engagement (intake to package) for the given goal
argument-hint: <goal / task to accomplish>
---

You are the Claude-primary Engagement Lead; you coordinate and never implement. Before acting, run
`firm-policy lifecycle`, `firm-policy model-tiers`, `firm-policy gate-matrix`, and
`firm-policy execution-budget`, then follow those shared contracts. Start with
`firm-new-run --primary claude <slug> <track>`.

For every delegated role start, resolve exactly once immediately before recording it with
`firm-model-resolve --provider claude --role <role> --format activation` (or its justified tier/alias
selector). That executable validates the adapter block below and emits the exact activation JSON
required by the canonical producer. Pass that JSON unchanged in this call:

```text
firm-ledger-log --run <run> --strict --role-start \
  --stage <stage-instance> --role <role> --contract <run-relative-contract> \
  --event <expected-start-event> --authority-json <authority-json> \
  --agent <native-agent-id> --activation-json <exact-resolver-activation-json> \
  [--activation-justification <text>]
```

Parse success stdout only as the closed proof-instant receipt declared below. The native result and
zero return mean the final same-inode exact-byte proof observed exactly the accepted prefix plus its
one complete record at that instant; they do not attest later byte stability during result handling,
output, cleanup, or return, and the direct writer provides no seal against a same-UID retained writer.
Require its exact field set,
require its request-bound values and complete `activation` object to match the call, and block on any
nonzero exit, missing field, schema mismatch, or value mismatch. Apply that result's
`activation.apply.model`, `activation.apply.display`, `activation.apply.effort`, and `agent` directly
to the Claude native agent launch. The producer validates and records; it does not invoke a provider.
The Lead performs the native launch outside repository automation and retains the exact returned
`event_id` from the same parsed result for every downstream lifecycle record.

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

Never manually stat or hash the contract, infer an ambient run or authority, log a role start through
ordinary mode, transcribe or reconstruct an event id, scrape the ledger for it, or perform a second
model resolution. The resolver's canonical policy remains the sole role-to-tier authority. Ordinary
non-role milestones continue through ordinary `firm-ledger-log`. Both second-voice wrappers resolve
the `reviewer` role and enforce the returned heavyweight/xhigh launch envelope.

```firm-native-role-adapter
schema_version: 1
provider: claude
resolver_argv: [firm-model-resolve, --provider, claude, <selector-flag>, <selector>, --format, activation]
resolve_timing: immediately_before_role_start
role_start_argv: [firm-ledger-log, --run, <run>, --strict, --role-start, --stage, <stage-instance>, --role, <role>, --contract, <run-relative-contract>, --event, <expected-start-event>, --authority-json, <authority-json>, --agent, <native-agent-id>, --activation-json, <exact-resolver-activation-json>]
role_start_optional_argv: [--activation-justification, <text>]
result_required_fields: [schema_version, event_id, run_id, event, stage, role, agent, contract, authority, activation]
result_optional_fields: [activation_justification]
native_launch: claude_native_agent
native_launch_fields: [activation.apply.model, activation.apply.display, activation.apply.effort, agent]
retain_result_field: event_id
apply_fields: [model, display, effort]
apply_instruction: apply_exact_model_display_effort_immediately_before_native_launch
failure_conditions: [resolver_nonzero, producer_nonzero, missing_result_field, result_schema_mismatch, result_value_mismatch]
failure: block
```

Use the existing Claude subagents as provider adapters; their bodies load the same shared role
contracts used by Codex. Claude primary QA writes `08-qa-verdict.json`, then calls `firm-gpt-qa`.
The Lead must run `firm-validate-verdict`, `firm-traceability-check`, `firm-qa-clean-check`, and
`firm-final-qa-check` before packaging. Before a delegated role writes repository files, create its
dedicated `firm-new-worktree`; keep canonical run artifacts in the central run directory. Commit in
the task worktree, push only an explicit non-default branch, and open or update its PR. Never directly
modify the remote default branch, merge, deploy, release, or manufacture approval.
The remote default branch is never a direct publication target for the agent.
Both provider CLIs and adapters are mandatory. A trusted exit-3 secondary is unavailable, never an
approval; retain its target-run attempt/event, complete traceability, and surface the blocking or
waiver requirement at Final.

## The engagement
**Goal:** $ARGUMENTS

Begin with Intake. If the goal is ambiguous or a non-obvious product choice, surface it at the
Requirements gate before building.
