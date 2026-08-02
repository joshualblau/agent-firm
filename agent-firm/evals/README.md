# Golden evals

A golden eval is a fixed task + a starting fixture + machine-checkable assertions. They protect the
firm from regressions: when a System Change PR edits an agent prompt, policy, or workflow, the evals
re-run so an "improvement" can't silently break something that worked.

## Eval contract
Each eval is a directory `agent-firm/evals/<name>/` containing:
- `task.md` — the kickoff message given to the Lead.
- `fixture/` — the starting project state (copied to a scratch dir before the run).
- `assertions.yaml` — what must hold after the run (artifacts, verdict, files, tests, gate behavior).

**A fixture's test/CI command must be allow-listed in `bin/firm-run-evals`'s `--allowedTools`, or the
agents inside the eval can't run it.** `firm-run-evals` drives the firm under a bounded permission
posture (no `--dangerously-skip-permissions`), so a command the qa-tester agent needs to execute —
`node --test`, `pytest`, or a project-specific `sh test/run-tests.sh` — has to be an *exact* allowed
rule, not assumed. This bit `qa-blocks-broken-build` during authoring: its shell-based suite needed
`Bash(sh test/run-tests.sh)` added before the eval could actually run, even though `firm-check-assertions`
itself (which evaluates `test_passes` afterward, from outside the agent session) was never permission-gated.
Prefer the narrowest exact command over a wildcard like `Bash(sh:*)` — see that eval's `assertions.yaml`
comment for the reasoning.

## Running
- **`firm-run-evals --structural`** validates every eval's **structure** (files present, assertion
  count) and lists the suite. No `claude` login, no spend. This is what CI runs on every push/PR.
- **`firm-run-evals [eval-name]`** (no `--structural`) actually **drives the firm** headlessly against
  the fixture under a bounded permission posture, then checks `assertions.yaml` against the result.
  Needs a `claude` login and real budget (`--max-budget-usd`, default $5) — this does not run in CI,
  and is a deliberate, manual, budget-spending act.

## Assertion vocabulary (assertions.yaml)
- `artifact_exists: <ledger file>` / `artifact_absent: <ledger file>` — presence/absence relative to
  the run ledger (resolved via `CURRENT_RUN`), plus a recursive `.agent-firm/**` scan. **Caution:**
  every file `agent-firm/templates/*` seeds is copied into a run at `firm-new-run` time, so
  `artifact_exists` on one of those is true from the moment the run starts, before anything real has
  happened — it is not, on its own, proof the corresponding stage ran. Pair it with a
  content-checking assertion (`verdict_is`, `traceability_passes`) or a signal that genuinely
  requires real execution (`qa_checkout_clean`, `final_gate_pending`) to prove anything.
  The mirror-image caution applies to `artifact_absent`: it **cannot** express "this stage never
  ran" for any template-seeded file (`10-handoff.md`, `08-qa-verdict.json`, …) — those exist at t=0,
  so such an assertion FAILs on a perfectly correct run. It is usable only for a ledger path the
  template scaffold does not create. Both verbs **fail closed** when no ledger can be resolved:
  `artifact_absent` used to read "no ledger" as "absent" and PASS on a repo where nothing had ever
  run, while skipping the `.agent-firm/**` scan that would have found the artifact anyway.
- `file_exists: <path>` / `file_absent: <path>` — relative to the scratch repo root (source files, not
  ledger artifacts).
- `verdict_is: APPROVE|BLOCK` — checks the `verdict` field of the RUN LEDGER's `08-qa-verdict.json`.
  **Fails closed** when no ledger can be resolved: it used to build its path from `led or ""`, which
  left a bare relative name that resolved against the checker process's own working directory, so a
  run that produced no ledger at all could be satisfied by a verdict file in an unrelated folder.
- `test_passes: <command>` — the command must exit 0. To assert the OPPOSITE (a command must genuinely
  fail — useful as a fixture-sanity check independent of anything the firm does), negate it with a
  shell `!`: `test_passes: "! sh test/run-tests.sh"`.
- `traceability_passes: true` — runs `firm-traceability-check` against the run: every acceptance
  criterion must appear in the verdict's coverage, and every gap (`covered: no` or `covered: partial`)
  must carry a justification. A justified gap still exits 0 (so this assertion still passes) but the
  check prints `TRACEABILITY: INCOMPLETE`, never `PASS` — read its output, not just the exit code, if
  you care whether coverage was *full* or merely *justified*.
- `qa_checkout_clean: true` — delegates to `firm-qa-clean-check` against the run's QA checkout. Proves
  QA left **no visible changes**, not that QA is read-only (see `docs/ENFORCEMENT.md`). Fails closed
  (not a vacuous pass) if the checkout directory doesn't exist.
- `no_default_branch_merge: true` — the default branch's CURRENT sha must equal
  `default_branch_start_sha` from `run-baseline.json` (written by `firm-new-run` at run start). **Fails
  closed** if that baseline is missing or unusable — there is no fallback to a weaker guess, so a run
  whose ledger predates this mechanism, or whose baseline can't be resolved, FAILs this assertion
  rather than passing on an unverifiable claim.
- `final_gate_pending: true` — requires BOTH an *explicit* `final_gate_pending` event actually logged
  to `run.jsonl` (via `firm-ledger-log final_gate_pending` — see `CLAUDE.md` / `commands/start.md`'s
  Final-gate instruction to the Lead) AND the default-branch-unchanged check above. This is **not**
  inferred from the outer `claude -p` result envelope's `subtype`/`is_error` fields — an earlier version
  was, and a run that crashed or did nothing at all could satisfy that inference just as easily as a
  correct one. Same fail-closed rule: no ledger, or no logged event, FAILs — never inferred as true.

## How `assertions.yaml` is parsed — and when the checker refuses to run
`firm-check-assertions` exits **0** only when every assertion ran and passed, **1** when an assertion
failed, and **2** when it could not evaluate the file at all. That third code exists because "nothing
was checked" must never be reportable as "everything passed" — an empty, prose-only, or
parses-to-nothing `assertions.yaml` used to print `0/0 assertions passed` and exit 0.

- **Zero parsed assertions is a hard failure.** An eval that checks nothing cannot pass.
- **pyyaml when installed; a narrow `- key: value` line parser when not.** These are separate paths
  and separate risks. A **YAML syntax error is never a fallback trigger** — it is a hard failure, so a
  typo that moves an assertion out of the `assertions:` list reads as "this file is broken", not "that
  assertion simply isn't there".
- **The fallback accounts for every list item it sees.** Anything under `assertions:` it can't turn
  into a `- key: value` mapping is reported with its line number and fails the file, because a dropped
  assertion is an unrun check. It reads only the `assertions:` block, so a `- key: value` line under
  some other top-level key is not silently promoted into an assertion.
- **A list entry that isn't a single-key mapping FAILs** instead of being skipped and then counted in
  the `N/N assertions passed` denominator.
- Keep values simple. The fallback strips at most one matched pair of surrounding quotes and does not
  interpret flow style (`assertions: [ ... ]`), anchors, or multi-line scalars; it refuses rather than
  guessing.
