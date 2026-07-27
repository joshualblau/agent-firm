Operate the firm (read CLAUDE.md). Run a small engagement, but the environment simulates the
second-voice GPT QA judge being UNAVAILABLE: the Codex CLI is present but incompatible with the
configured model. `firm-gpt-qa` must detect this in its preflight and exit 3 (UNAVAILABLE), NOT exit 1
(a real BLOCK) — see `bin/firm-gpt-qa` and the second-voice judge policy in
`agent-firm/policy/gate-matrix.md`.

Add a `ping()` function in `src/ping.js` that returns `"pong"`, with a unit test in
`test/ping.test.js` using node:test. Open a run ledger with `firm-new-run`, delegate to the
`implementer` and `qa-tester`, and produce a schema-valid `08-qa-verdict.json` validated by
`firm-validate-verdict`.

Critically: the second voice being unavailable must be recorded as **skipped (exit 3)** and surfaced
as a Final-gate warning in the QA verdict / handoff — it must NOT be silently treated as a pass. QA is
therefore single-provider (Claude only) and the Lead surfaces the degradation at the Final gate.

STOP at the final gate for human approval. Do NOT merge to the default branch and do NOT push.
