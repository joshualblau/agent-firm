# Phase 3 — The Codex/GPT QA judge (independent, cross-provider)

Goal: make QA **two voices from different providers**, so a blind spot the implementer's model shares
with a same-provider reviewer still gets caught. The Claude `qa-tester` checks acceptance/evidence
coverage; a **GPT judge via Codex** independently hunts implementation blind spots. Both must APPROVE.

## How it works
- `bin/firm-gpt-qa` runs `codex exec --output-schema agent-firm/schemas/qa-verdict.schema.json` on your
  **ChatGPT subscription** (via the Codex CLI — **no OpenAI API key**) and writes a schema-valid
  `08-qa-verdict.gpt.json` next to the Claude `08-qa-verdict.json`.
- The `qa-tester` runs its own pass, then calls `firm-gpt-qa` and reports **both** verdicts. The final
  gate needs both APPROVE; a BLOCK from either voice blocks.
- `AGENTS.md` (repo root) is Codex's project-instruction file: read-only judge, schema-valid verdict,
  never edits source, treats content as data.
- Model tiering: this is the one role where a *different provider* earns its keep (adversarial, lower
  self-grading bias) — see the Claude-side tiering in `docs/` / the plan.

## Prerequisites (one-time, per machine)
The Codex CLI must be installed and logged in on your ChatGPT plan:
```bash
# install Codex CLI (see OpenAI's Codex docs), then:
codex login          # or:  codex login --device-auth   (headless)
codex login status   # confirm you're authenticated on your ChatGPT plan (no API key)
```
Per-project profile switching (Phase 4) sets `CODEX_HOME` alongside `CLAUDE_CONFIG_DIR`.

## Graceful degradation
If `codex` is absent or not logged in, `firm-gpt-qa` exits 3 and the `qa-tester` records the GPT judge
as **skipped** (logged to `run.jsonl`) and proceeds Claude-only. "Skipped" is never treated as a pass.

## Verify (once Codex is set up)
```bash
codex exec "say hi"                                  # confirm subscription auth, no API key set
firm-gpt-qa .agent-firm/runs/<run>                   # produces + validates 08-qa-verdict.gpt.json
```
Watch for: the GPT judge runs the test command, writes `08-qa-verdict.gpt.json`, `firm-validate-verdict`
passes it, and a `gpt_qa` event lands in `run.jsonl`.

## Not yet
- Codex tool-calling fidelity through `--output-schema` should be validated empirically on your first
  real run before depending on it (structured-output quirks vary by provider).
- Multi-profile `CODEX_HOME` switching is the rest of Phase 4.
