# Interactive live test — driving the firm from Claude or Codex

A demo work-project with the firm config installed, at `/tmp/firm-live`. **`/tmp` does not survive a
reboot**, so recreate it first — this is not an edge case, it's the normal state of this doc between
sessions:
```bash
rm -rf /tmp/firm-live && mkdir -p /tmp/firm-live && cd /tmp/firm-live && git init -q
~/agent-firm/bin/firm-bootstrap
firm-install
git add -A && git commit -qm "init: firm config installed"
```
`firm-bootstrap` requires both provider CLIs, preflights them before either install is changed,
installs both adapters from the same checkout, and links the shared tools.
`firm-install` merges Claude's per-project permission policy; it intentionally does not overwrite
Codex config, rules, or hooks. The firm's own `tests/` and `.github/` remain in the plugin source, not
the work project. To work on the tooling itself rather than drive it, use the agent-firm repo.

Run the firm for real and watch the lifecycle engage.

## Run it from Claude
```bash
cd /tmp/firm-live
claude
```
(All your MCP servers connect cleanly now. If you ever hit unrelated MCP startup noise,
`claude --strict-mcp-config` runs the firm with no MCP servers, which is fine at Phase 0/1.)

Then invoke:

> `/agent-firm:start` Run a **fast_path** engagement: add a `greet(name)` function in
> `src/greet.js` that returns `"Hello, <name>!"`, with a unit test in `test/greet.test.js` using
> node:test. Follow the complete two-voice QA and final-gate process, then stop for my approval.

## Run it from Codex

```bash
cd /tmp/firm-live
codex
```

Then invoke the symmetric Codex-first workflow:

> `$agent-firm:start` Run a **fast_path** engagement: add a `greet(name)` function in
> `src/greet.js` that returns `"Hello, <name>!"`, with a unit test in `test/greet.test.js` using
> node:test. Follow the complete two-voice QA and final-gate process, then stop for my approval.

## What to watch for (this is the test)
1. **Ledger opens** — a dir appears under `.agent-firm/runs/<ts>-greet/`, and `run.jsonl` starts logging.
2. **Delegation** — the Lead uses provider-native subagents for `implementer`, then `qa-tester`
   (separate contexts, each returns a summary).
3. **Self-test** — the implementer runs `node --test` and self-corrects to green; qa-tester re-runs it
   and captures evidence under `09-test-evidence/`.
4. **Permission gates engage** — anything in the `ask` list (e.g. `git commit`) prompts you; `git push`
   / `sudo` are denied. Reads and the test runner run without prompts.
5. **Two schema-valid verdicts** — primary QA writes `08-qa-verdict.json`; the cross-provider judge
   writes `.gpt.json` or `.claude.json`, and `firm-final-qa-check` exits 0 before handoff.
6. **No auto-finish** — the Lead pauses at the **final gate** with a well-formed approval payload
   (decision, context, options, recommendation, default, risk, blocking) and waits for your sign-off.

## Inspect afterward
```bash
RUN=$(cat /tmp/firm-live/.agent-firm/CURRENT_RUN)
cat "/tmp/firm-live/$RUN/run.jsonl"          # the event log
cat "/tmp/firm-live/$RUN/08-qa-verdict.json" # the verdict
ls  "/tmp/firm-live/$RUN"/*.json             # primary + cross-provider verdicts
ls  "/tmp/firm-live/$RUN/09-test-evidence/"  # captured evidence
```

## If you want to point it at a real project instead
Install/refresh the shared plugin, initialize the project policy, then choose either provider:
```bash
~/agent-firm/bin/firm-bootstrap
cd <your-repo>
firm-install
claude   # /agent-firm:start <goal>
# or: codex   # $agent-firm:start <goal>
```
This uses the repository root as the single plugin source; updates to that checkout refresh both
provider caches. A missing provider CLI stops the refresh before either cache is changed. See
[INSTALL.md](INSTALL.md) for lifecycle, safe obsolete-hook migration, and version details.
