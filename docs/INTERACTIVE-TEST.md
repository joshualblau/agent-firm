# Interactive live test — driving the firm with a real Claude session

A demo work-project with the firm config installed is at `/tmp/firm-live` (ephemeral; recreate with
the steps at the bottom if `/tmp` was cleared). Run the firm for real and watch the lifecycle engage.

## Run it
```bash
cd /tmp/firm-live
claude
```
Then paste this kickoff message:

> Operate the firm (read CLAUDE.md). Run a **fast_path** engagement: add a `greet(name)` function in
> `src/greet.js` that returns `"Hello, <name>!"`, with a unit test in `test/greet.test.js` using
> node:test. Open a run ledger with `bin/new-run`, delegate coding to the `implementer` subagent and
> testing to the `qa-tester` subagent, have qa-tester produce a schema-valid `08-qa-verdict.json`
> validated by `bin/validate-verdict`, then stop at the final gate for my approval.

## What to watch for (this is the test)
1. **Ledger opens** — a dir appears under `.agent-firm/runs/<ts>-greet/`, and `run.jsonl` starts logging.
2. **Delegation** — the Lead uses the Agent tool to spawn `implementer`, then `qa-tester` (separate
   contexts, each returns a summary).
3. **Self-test** — the implementer runs `node --test` and self-corrects to green; qa-tester re-runs it
   and captures evidence under `09-test-evidence/`.
4. **Permission gates engage** — anything in the `ask` list (e.g. `git commit`) prompts you; `git push`
   / `sudo` are denied. Reads and the test runner run without prompts.
5. **Schema-valid verdict** — `08-qa-verdict.json` is produced and `bin/validate-verdict` passes.
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

## Recreate the demo project (if /tmp was cleared)
```bash
rm -rf /tmp/firm-live && mkdir -p /tmp/firm-live && cd /tmp/firm-live && git init -q
cp -R ~/agent-firm/.claude ~/agent-firm/CLAUDE.md ~/agent-firm/bin ~/agent-firm/agent-firm .
git add -A && git commit -qm "init: firm config installed"
```
