# Interactive live test — driving the firm with a real Claude session

A demo work-project with the firm config installed, at `/tmp/firm-live`. **`/tmp` does not survive a
reboot**, so recreate it first — this is not an edge case, it's the normal state of this doc between
sessions:
```bash
rm -rf /tmp/firm-live && mkdir -p /tmp/firm-live && cd /tmp/firm-live && git init -q
cp -R ~/agent-firm/.claude ~/agent-firm/CLAUDE.md ~/agent-firm/bin ~/agent-firm/agent-firm .
git add -A && git commit -qm "init: firm config installed"
```
**What this copy does and does not include.** It carries permissions (`.claude/settings.json`), the
operating manual (`CLAUDE.md`), the tools (`bin/`), and the policies/schemas/templates (`agent-firm/`).
The role subagents are **not** in that list — they come from the installed plugin; without it, also
`cp -R ~/agent-firm/agents /tmp/firm-live/.claude/agents` (copy mode, as in the README). And it
deliberately does **not** copy `tests/` or `.github/`: those are the firm's own regression suite and
CI, which test `bin/` itself, not anything a work project runs. So in `/tmp/firm-live`,
`tests/run-tests.sh` does not exist and no workflow runs — expected, not a broken install. To work on
the firm's tooling (rather than drive the firm), use the agent-firm repo itself.

Run the firm for real and watch the lifecycle engage.

## Run it
```bash
cd /tmp/firm-live
claude
```
(All your MCP servers connect cleanly now. If you ever hit unrelated MCP startup noise,
`claude --strict-mcp-config` runs the firm with no MCP servers, which is fine at Phase 0/1.)

Then paste this kickoff message:

> Operate the firm (read CLAUDE.md). Run a **fast_path** engagement: add a `greet(name)` function in
> `src/greet.js` that returns `"Hello, <name>!"`, with a unit test in `test/greet.test.js` using
> node:test. Open a run ledger with `firm-new-run`, delegate coding to the `implementer` subagent and
> testing to the `qa-tester` subagent, have qa-tester produce a schema-valid `08-qa-verdict.json`
> validated by `firm-validate-verdict`, then stop at the final gate for my approval.

## What to watch for (this is the test)
1. **Ledger opens** — a dir appears under `.agent-firm/runs/<ts>-greet/`, and `run.jsonl` starts logging.
2. **Delegation** — the Lead uses the Agent tool to spawn `implementer`, then `qa-tester` (separate
   contexts, each returns a summary).
3. **Self-test** — the implementer runs `node --test` and self-corrects to green; qa-tester re-runs it
   and captures evidence under `09-test-evidence/`.
4. **Permission gates engage** — anything in the `ask` list (e.g. `git commit`) prompts you; `git push`
   / `sudo` are denied. Reads and the test runner run without prompts.
5. **Schema-valid verdict** — `08-qa-verdict.json` is produced and `firm-validate-verdict` passes.
6. **No auto-finish** — the Lead pauses at the **final gate** with a well-formed approval payload
   (decision, context, options, recommendation, default, risk, blocking) and waits for your sign-off.

## Inspect afterward
```bash
RUN=$(cat /tmp/firm-live/.agent-firm/CURRENT_RUN)
cat "/tmp/firm-live/$RUN/run.jsonl"          # the event log
cat "/tmp/firm-live/$RUN/08-qa-verdict.json" # the verdict
ls  "/tmp/firm-live/$RUN/09-test-evidence/"  # captured evidence
```

## If you want to point it at a real project instead
Copy the firm config into that repo, then `cd` there and run `claude`:
```bash
cp -R ~/agent-firm/.claude ~/agent-firm/CLAUDE.md ~/agent-firm/bin ~/agent-firm/agent-firm <your-repo>/
```
Same scope as above: this is the firm's *runtime* config only. `tests/` and `.github/` stay behind —
they exercise `bin/` inside the agent-firm repo and have nothing to say about your project — so don't
expect `tests/run-tests.sh` or a `ci` workflow to appear in `<your-repo>`. The supported path for a
real project is the plugin plus `firm-install` ([INSTALL.md](INSTALL.md)); this copy is the fallback.
