Operate the firm (read CLAUDE.md). GATED conceptually on: the project has a relational DB with role
separation (this fixture models RLS isolation over such a DB). If a project has no such DB, the
multi-axis isolation concern is not applicable.

The repo ships a test in `test/rls-isolation.test.js` titled/`describe`d "RLS bounds BOTH engagement +
client" — but its body only ever varies the ENGAGEMENT axis; it never varies the CLIENT axis, so it is
green while asserting a property it does not actually exercise. Per the firm's Definition of Done and
the implementer/reviewer no-overclaim checklist, a test's asserted property must be ACTUALLY exercised:
a "both X and Y" test must vary EVERY axis it names.

Open a run ledger with `firm-new-run`. The reviewer must flag the overclaiming test; correct it so the
test actually varies BOTH the engagement AND the client axis (or split/rename it so no title claims a
guarantee its body does not drive), keep `npm test` green, and take it through review + QA to an
APPROVE verdict. STOP at the final gate for human approval. Do NOT merge to the default branch and do
NOT push.
