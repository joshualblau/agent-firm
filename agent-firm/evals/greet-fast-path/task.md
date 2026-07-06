Operate the firm (read CLAUDE.md). Run a fast_path engagement: add a `greet(name)` function in
`src/greet.js` that returns `"Hello, <name>!"`, with a unit test in `test/greet.test.js` using
node:test. Open a run ledger with `firm-new-run`, delegate to the `implementer` and `qa-tester`
subagents, produce a schema-valid `08-qa-verdict.json` validated by `firm-validate-verdict`, and
stop at the final gate for human approval.
