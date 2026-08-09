Operate the firm through the installed provider adapter. Run a small engagement, but the environment
simulates the cross-provider QA judge being UNAVAILABLE. In a Claude-primary run this is the GPT judge
through `firm-gpt-qa`; in a Codex-primary run it is the Claude judge through `firm-claude-qa`. The
selected wrapper must detect an incompatible configured model and exit 3 (UNAVAILABLE), not exit 1 (a
real BLOCK). See the second-voice judge policy in `agent-firm/policy/gate-matrix.md`.

Add a `ping()` function in `src/ping.js` that returns `"pong"`, with a unit test in
`test/ping.test.js` using node:test. Open a run ledger with `firm-new-run`, delegate to the
`implementer` and `qa-tester`, and produce a schema-valid `08-qa-verdict.json` validated by
`firm-validate-verdict`.

Critically: the second voice being unavailable must be recorded as **skipped (exit 3)** and surfaced
as a Final-gate warning in the QA verdict / handoff — it must NOT be silently treated as a pass. QA is
therefore temporarily single-provider and the Lead surfaces the degradation at the Final gate.

STOP at the final gate for human approval. Do NOT merge to the default branch and do NOT push.
