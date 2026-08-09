# Phase 3 — Cross-provider QA judges

> **This is a dated build-journal entry, not reference documentation.** For current behavior, read
> `agent-firm/contracts/lifecycle.md`, `agent-firm/policy/gate-matrix.md`, and the `firm-*-qa` tools.

The goal is two voices from different providers, so a blind spot shared by primary staff and a
same-provider reviewer still gets caught. In 0.8.0 this is symmetric: GPT judges Claude-primary runs,
while Claude judges Codex-primary runs. The cross-provider BLOCK binds unless primary QA positively
dissents on that point; high-risk disagreement remains blocking.

## How it works

- `firm-gpt-qa` runs `codex exec --output-schema` with a read-only sandbox and ChatGPT subscription
  auth. It writes `08-qa-verdict.gpt.json` for Claude-primary runs.
- `firm-claude-qa` runs Claude structured output with read/search tools and Claude subscription auth.
  Bash and write tools are disabled; it judges already captured test evidence and writes
  `08-qa-verdict.claude.json` for Codex-primary runs.
- Primary QA always writes `08-qa-verdict.json`, regardless of provider.
- `AGENTS.md` selects Codex-primary mode for `$agent-firm:start`; `FIRM_QA_JUDGE=1`, set by reviewer
  wrappers, always restores the independent read-only judge contract.
- `firm-final-qa-check` validates primary and secondary verdicts, primary traceability, required
  unavailable-judge waivers, and one structured `two_voice_diff` entry per secondary blocker.

Wrapper exits are stable: **0** schema-valid APPROVE · **1** schema-valid BLOCK, failure, or timeout ·
**2** usage · **3** provider CLI/auth/model unavailable. A valid BLOCK is exit 1; it is never mistaken
for a successful wrapper run.

## Prerequisites

Both CLIs must be installed and logged into subscription accounts:

```bash
codex login
codex login status
claude auth status
```

Per-project profile switching uses `CODEX_HOME` alongside `CLAUDE_CONFIG_DIR`.

## Availability and waivers

An unavailable reviewer is recorded as skipped, never as passed. On ordinary work this may continue
to the Final gate with a warning. On auth, permissions, crypto, or PII work, a skipped reviewer needs
an explicit logged human waiver. `firm-final-qa-check` enforces the recorded state but cannot judge
whether a self-reported risk classification or positive dissent is substantively correct.

## Verify

```bash
firm-gpt-qa .agent-firm/runs/<run>
firm-claude-qa .agent-firm/runs/<run>
firm-final-qa-check .agent-firm/runs/<run>  # 0 satisfied · 1 blocked · 2 cannot evaluate
```

Both wrappers close stdin, use a bounded wall-clock alarm, create fresh per-attempt logs/output, and
publish a canonical verdict only after schema validation. GPT runs with Codex's read-only sandbox.
Claude has no equivalent filesystem sandbox flag, so it receives only Read/Grep/Glob and is explicitly
denied Edit/Write/Bash; it cannot execute tests and must evaluate the captured test evidence. QA test
execution should occur first in the same pinned toolchain CI uses so environment drift does not create
misleading evidence.
