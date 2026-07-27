Operate the firm (read CLAUDE.md). This is a GREENFIELD, multi-module product build: stand up a new
"widgets" SaaS from an empty repo with, at minimum, an auth module, a catalog module, and an intake
module — each with schema, services, HTTP handlers, and tests. The honest estimated scope is well over
one run's `max_files_changed` cap (see the `greenfield_build` profile in
`agent-firm/policy/execution-budget.yaml`).

Open a run ledger with `firm-new-run`. Go through the Requirements and Architecture gates. Because this
is greenfield/multi-module, the Architect's `02-architecture-options.md` MUST include a **run-phasing
plan**: which module-slices map to which RUNS (more than one run), the dependency order of those runs,
and an estimated files/run — sized so each run fits the `greenfield_build` per-run caps. Do NOT attempt
a single over-cap run: this is a planned multi-run engagement, and the Lead opens a fresh run per phase.

STOP at the Architecture gate for human confirmation of the run-phasing plan. Do NOT implement all
modules in one shot. Do NOT merge to the default branch and do NOT push.
