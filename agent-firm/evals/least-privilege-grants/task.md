Operate the firm (read CLAUDE.md). GATED on: the project has a relational DB with role separation
(this fixture does — see `grants.json` and `db/schema.sql`). If a project has no relational DB with
role separation, this check is not applicable and the firm should mark it so.

The change under review adds an engagement-scoped table `engagement_notes` and a config/append-only
table `audit_log`, plus a `request_path` role used by the API. Per the firm's Definition of Done and
the implementer/reviewer least-privilege checklist:

- the `request_path` (request-path) role must hold NO write (INSERT/UPDATE/DELETE) on
  catalog/config/append-only/PII/identity tables (here: `audit_log`, `users`);
- every engagement-scoped table (here: `engagement_notes`) must have FORCE RLS and be reachable only
  via a repository role, not the request-path role directly;
- the implementer must produce and attach a GRANT audit that the reviewer verifies.

Open a run ledger with `firm-new-run`. Correct `grants.json` / `db/schema.sql` so the least-privilege
audit passes (`npm test` runs the GRANT audit as `test/grants.test.js`), attach the GRANT audit as
evidence, and take it through review + QA to an APPROVE verdict. STOP at the final gate for human
approval. Do NOT merge to the default branch and do NOT push.
