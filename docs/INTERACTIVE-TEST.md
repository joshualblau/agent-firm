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
`firm-bootstrap` requires both provider CLIs and, before either install is changed, runs bounded
capability/selector/schema checks and captures the exact matching provider state. It installs both
adapters from the same checkout and links the shared tools. This changes real provider stores: use it
only after approving that external action. Failure triggers supported-inverse compensation, not
atomicity. Freshly created entries have remove/uninstall inverses; a pre-existing plugin refresh does
not. Bootstrap never reuses a forward update/add call as a reverse. Such a failure remains
`BLOCKED_RECOVERY_REQUIRED` and names a mode-0600 recovery record that must be manually reconciled
before retry.
`firm-install` merges Claude's per-project permission policy; it intentionally does not overwrite
Claude/Codex config, rules, or hooks. Claude and Codex each receive one hook source from their plugin
manifest; confirmed legacy project/user duplicates make `firm-doctor` FAIL and require a configuration-preserving
manual review. The firm's own `tests/` and `.github/` remain in the plugin source, not the work project.
To work on the tooling itself rather than drive it, use the agent-firm repo.

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
   writes `.gpt.json` or `.claude.json`. The Packager may assemble only a non-ship-ready draft before
   the Final interaction.
6. **One Final interaction, then one fresh check** — exit 4 `decision_required` presents its exact
   objections and permitted typed record options once. If you choose one, the Lead appends the matching
   current-SHA record and reruns `firm-final-qa-check` once. Only fresh exit 0 finalizes the handoff;
   rejection, mismatch, staleness, or another nonzero result remains blocked without a second prompt.

This smoke is not package-readiness proof by itself. Release evidence must bind to the exact full SHA,
first exercise both real loaders and repeat cache refreshes in disposable provider homes, and later
exercise normal and interruption-between-providers rollback with a human-reviewed record. Never use
active homes/configuration as a substitute when isolation cannot be established.

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
provider caches. A missing or incompatible provider CLI, unreadable prior state, or selector/schema
mismatch stops the refresh before either cache is changed. See
[INSTALL.md](INSTALL.md) for lifecycle, safe obsolete-hook migration, and version details.
