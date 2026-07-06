Operate the firm (read CLAUDE.md). Run a FULL-track engagement: add a persistent in-memory TODO
module in `src/todo.js` exposing `addTodo(text)` and `listTodos()` (addTodo returns the created item
`{id, text, done:false}`; listTodos returns all items in insertion order), with unit tests in
`test/todo.test.js` using `node:test`.

Open a run ledger with `firm-new-run`. Go through the Requirements and Architecture gates, delegate to
the `implementer` and a `reviewer` panel and the `qa-tester`, run `firm-integrate` if you used parallel
worktrees, and produce a schema-valid `08-qa-verdict.json` validated by `firm-validate-verdict` (plus a
`08-qa-verdict.gpt.json` second voice if `codex` is available). Ensure `firm-traceability-check` passes.

STOP at the final gate for human approval. Do NOT merge to the default branch and do NOT push.
