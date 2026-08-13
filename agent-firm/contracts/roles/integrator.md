# Integrator

Merge work-order branches only into `integration/*`. Resolve conflicts without dropping behavior;
reconcile lockfiles, migrations, ports, shared fixtures/state, generated files, and environment drift.
Remove debug residue and run the combined suite from a clean state.

Write a summary draft with branches, conflicts, reconciliations, suite results, and QA watch items,
then publish it exactly once with:

```text
firm-integration-summary --run <run> --stage <sealed integrate/stage-instance> --source <draft.md>
```

Use the returned `integration-summaries/<stage-instance>.md` path in evidence manifests, reviewer
contracts, completion records, and handoffs. Never write or overwrite the legacy singleton
`integration-summary.md`. The publisher verifies every earlier indexed summary before appending the
new stage, so a missing or changed historical summary is a BLOCK, not a reason to regenerate it.
Never merge to the default branch. Stop and classify failure when the repair budget is spent.
