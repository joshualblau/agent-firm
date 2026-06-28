# Golden evals

A golden eval is a fixed task + a starting fixture + machine-checkable assertions. They protect the
firm from regressions: when a System Change PR edits an agent prompt, policy, or workflow, the evals
re-run so an "improvement" can't silently break something that worked.

## Eval contract
Each eval is a directory `agent-firm/evals/<name>/` containing:
- `task.md` — the kickoff message given to the Lead.
- `fixture/` — the starting project state (copied to a scratch dir before the run).
- `assertions.yaml` — what must hold after the run (artifacts, verdict, files, tests, gate behavior).

## Running
- Phase 1 (now): `bin/run-evals` validates eval **structure** and lists the suite. Full execution
  (drive the firm against the fixture, then check assertions) lands in **Phase 5**, where the
  permission posture for autonomous runs is settled.
- Full run sketch: copy `fixture/` to a scratch git repo + install the firm config → run the Lead
  with `task.md` → evaluate `assertions.yaml` against the resulting run-ledger.

## Assertion vocabulary (assertions.yaml)
- `artifact_exists: <ledger file>` — e.g. `08-qa-verdict.json`
- `verdict_is: APPROVE|BLOCK`
- `file_exists: <path>` / `file_absent: <path>`
- `test_passes: <command>`
- `traceability_passes: true`
- `no_default_branch_merge: true` — the run must NOT have merged to the default branch autonomously
- `final_gate_pending: true` — the run must stop for human approval, not self-finish
