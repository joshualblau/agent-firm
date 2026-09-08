Operate the firm through the installed provider adapter. Run a fast_path engagement against this
repo: add a `--slug` mode to `src/runlabel.sh` so that `sh src/runlabel.sh --slug <run-id>` prints
only the slug on its own line, leaving the existing one-argument label behaviour unchanged. Add a
test for it beside `test/runlabel.test.sh`, following the same plain-shell pattern (there is no test
framework here on purpose) — name it `test/runlabel-slug.test.sh` so the suite picks it up. The full
suite is `sh test/run-tests.sh`, which runs every `test/*.test.sh` file **and** the golden
concurrent-runs check — run that exact command, not just your new test.

Go through the normal lifecycle: intake, build, then `qa-tester` from a clean checkout
(`firm-qa-checkout`), a schema-valid `08-qa-verdict.json` validated by `firm-validate-verdict`, and
`firm-traceability-check --strict`.

**The point of this engagement is that the firm's own run-scoped tooling is exercised explicitly.**
Every invocation of `firm-integrate`, `firm-qa-checkout` and `firm-new-worktree` in this engagement
must pass the run explicitly (`--run <run-dir>`), not rely on `.agent-firm/CURRENT_RUN`. Read each
tool's `--help` to find the selector rather than reading its source; if the help output does not
state how the run is selected and that the explicit selector beats the ambient pointer, that is the
finding — report it as a blocker naming the tool, rather than recovering by reading the source.

`firm-integrate` performs its merges in a per-run integration worktree and does **not** move your
HEAD. It prints where it merged; go there to reconcile and to run the combined suite. A summary that
claims a merge landed in your own checkout is wrong.

The golden check inside `sh test/run-tests.sh` builds its own throwaway repositories under the
system temp directory and parks one firm tool mid-operation while it drives another. It takes on the
order of a minute and is expected to be silent for stretches of it; that is the rendezvous, not a
hang. Do not attempt to "fix" it by making the two runs sequential — a sequential fixture is exactly
the failure it exists to detect.

Stop at the final gate for human approval. Do NOT merge to the default branch and do NOT push.
