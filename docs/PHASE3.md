# Phase 3 — Cross-provider QA judges

> **This is a dated build-journal entry, not reference documentation.** For current behavior, read
> `agent-firm/contracts/lifecycle.md`, `agent-firm/policy/gate-matrix.md`, and the `firm-*-qa` tools.
> Historical implementation here is not evidence that the current repair candidate is ready.

The goal is two voices from different providers, so a blind spot shared by primary staff and a
same-provider reviewer still gets caught. In 0.8.0 this is symmetric: GPT judges Claude-primary runs,
while Claude judges Codex-primary runs. The cross-provider BLOCK binds unless primary QA positively
dissents on that point; high-risk disagreement remains blocking.

## How it works

- `firm-gpt-qa` and `firm-claude-qa` are thin provider selectors over `firm-reviewer-common`. The
  common wrapper validates a contained run path and persisted candidate, serializes invocations per
  provider, creates a monotonically numbered attempt, and archives any prior canonical verdict before
  a re-run.
- Every attempt uses a disposable controlled root with the complete `qa-judge.md` contract, empty MCP
  configuration, inert committed-source snapshot, bounded evidence/diff bundle, controlled HOME and
  provider state, and provider-native read-only/tool restrictions. It does not depend on a consumer
  repository's `AGENTS.md` or `CLAUDE.md` for judge mode.
- Discovery, authentication readiness, and judge execution are separate bounded process groups.
  Readiness is established only by a response the wrapper DECLARES for that provider in
  `READINESS_CONTRACT` — command, body and exit status together (`codex login status` answering
  `Logged in using ...` with exit 0; `claude auth status --json` answering `loggedIn: true` with
  exit 0). A declared unavailable answer is the trusted exit 3 path; an error, timeout, truncated
  stream, unrecognised body, or a ready-looking body with an undeclared exit status is BLOCK exit 1
  and is never upgraded to available. There is no configured-model readiness probe: neither CLI
  implements `models list` (on claude it is a prompt, not a query), and the resolved model is
  enforced by the judge invocation itself, which fails loudly on an unknown model. Default/max seconds are discovery 15/120, readiness 30/180, judge 300/900, and kill
  grace 2/30. Output defaults to 64 KiB and is capped at 1 MiB.
- The wrapper validates schema and exact run/full-SHA/generation/provider/attempt identity, rechecks
  candidate generation, then atomically publishes `08-qa-verdict.gpt.json` for Claude-primary runs or
  `08-qa-verdict.claude.json` for Codex-primary runs.
- Primary QA always writes `08-qa-verdict.json`, regardless of provider.
- `firm-final-qa-check` validates the persisted clean candidate, exact primary and secondary verdict
  identity, strict traceability, derived high-risk state, trusted required-unavailable attempts and
  waivers, and exact typed dispositions for every secondary blocker.

Wrapper exits are stable: **0** schema-valid APPROVE · **1** schema-valid BLOCK, failure, or timeout ·
**2** usage · **3** provider CLI/auth/model unavailable. A valid BLOCK is exit 1; it is never mistaken
for a successful wrapper run.

## Prerequisites

Both CLIs must already be installed and logged into subscription accounts:

```bash
codex login
codex login status
claude auth status
```

The wrappers never install, upgrade, log in, or alter a user's provider profile. They create isolated
attempt-local provider state and use subscription authentication only through the provider-native CLI.

## Availability and waivers

An unavailable reviewer is recorded as skipped, never as passed. Only a matching numbered attempt
showing trusted CLI, subscription-authentication, or configured-model absence qualifies. Timeout,
malformed output, tool failure, schema failure, identity mismatch, or candidate drift is BLOCK. On
ordinary work an unavailable required voice makes the Final checker emit nonpassing
`decision_required` (exit 4): only a draft and one exact human interaction are allowed, followed by a
matching typed record and one fresh mechanical rerun. On work whose
accepted criteria or committed paths derive auth/permissions/crypto/PII or another configured
high-risk surface, that permitted record must be an exact logged human waiver tied to the run, SHA,
provider, reason, attempt, and objections. Any nonzero fresh rerun remains blocked.

## Verify

```bash
firm-gpt-qa .agent-firm/runs/<run>
firm-claude-qa .agent-firm/runs/<run>
firm-final-qa-check .agent-firm/runs/<run>  # 0 satisfied · 1 blocked · 2 cannot evaluate
```

Both wrappers close stdin, bound and kill whole process trees, and persist phase/result metadata. By
default they retain only capped redacted diagnostics: authorization headers, cookies, tokens, secrets,
device/account identifiers, request ids, URLs, JWTs, and email-like identifiers are removed or
masked. Persistent raw retention is unsupported: every nonzero `--retain-raw-seconds` request is
rejected before provider execution. Transient raw bytes exist only below the owned,
package-excluded `.agent-firm/private-reviewer-control/` attempt tree, which an independent guardian
removes after normal exit or wrapper death; a cleanup failure creates a mode-0600 marker and makes the
wrapper BLOCK. GPT uses Codex's read-only sandbox; Claude receives only Read/Grep/Glob and is
explicitly denied Edit/Write/Bash and network tools. Neither OS ownership nor mode bits are represented
as a complete sandbox boundary; the provider-native controls and the disposable bounded input are the
enforcement boundary. The judge cannot execute tests and must evaluate evidence captured first in the
same pinned toolchain CI uses.
