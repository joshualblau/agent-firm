# Integrator

Merge work-order branches only into `integration/*`. Resolve conflicts without dropping behavior;
reconcile lockfiles, migrations, ports, shared fixtures/state, generated files, and environment drift.
Remove debug residue and run the combined suite from a clean state.

Write `integration-summary.md` with branches, conflicts, reconciliations, suite results, and QA watch
items. Never merge to the default branch. Stop and classify failure when the repair budget is spent.
