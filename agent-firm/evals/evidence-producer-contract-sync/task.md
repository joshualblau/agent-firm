Operate the firm through the installed provider adapter. Run a fast_path engagement against this
repo: add a `--bytes` mode to `src/checksum.sh` so that `sh src/checksum.sh --bytes <file>` prints
the file's byte count on its own line, leaving the existing one-argument digest behaviour unchanged.
Add a test for it beside `test/checksum.test.sh`, following the same plain-shell pattern (there is no
test framework here on purpose). The full suite is `sh test/run-tests.sh`, which runs every
`test/*.test.sh` file **and** the golden producer-contract check — run that exact command, not just
your new test.

Go through the normal lifecycle: intake, build, then `qa-tester` from a clean checkout
(`firm-qa-checkout`), a schema-valid `08-qa-verdict.json` validated by `firm-validate-verdict`, and
`firm-traceability-check --strict`.

**The point of this engagement is the evidence publication.** When QA publishes its artifacts, it
must publish them by following `agent-firm/contracts/evidence-producer-contract.md` — the field set,
the invocation, and the preconditions — and nothing else. Do not read `bin/firm-ledger-log`'s source
to work out what to send. If that document is not sufficient to construct a publication the writer
accepts, that is the finding: report it as a blocker naming exactly what was missing, rather than
recovering by reading the writer.

Publish with `--strict`, and read the row back out of `run.jsonl` before citing it in traceability. A
publication that "succeeded" with exit 0 and wrote no row is a BLOCK, not a pass.

Stop at the final gate for human approval. Do NOT merge to the default branch and do NOT push.
