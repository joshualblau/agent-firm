# System Change PR: Two standing quality gates — least-privilege DB grants + no-overclaiming tests

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by golden evals.

- **Proposed by run:** 20260727T102815Z-consulting-ops-lifecycle (least-privilege) +
  20260727T131416Z-consulting-ops-intake (no-overclaim)
- **Date (UTC):** 2026-07-27
- **Status:** approved

## Motivation
Two failure modes recurred and were each caught only by an independent review lens, not by the build or
the automated suite — so they belong in the firm's Definition of Done + golden evals, not just in a good
reviewer's memory:

1. **Inherited blanket DB grants (least-privilege).** New DB roles/tables silently inherited write access
   they shouldn't have. Run 1: the request-path role could delete audit rows and read password/token
   columns. Run 2: the same pattern let the request-path role forge/mutate/delete *published* catalog
   blueprints (config-immutability defeated at the DB). Both were security-review catches, both were the
   *same* root cause. (Run 3 did NOT recur — because that implementer ran a GRANT audit proactively,
   proving the check is effective when applied.) → make it a standing check.

2. **Tests that overclaim (no-overclaim).** Run 3 shipped an adversarial test titled "RLS bounds BOTH
   engagement + client" that only ever exercised the engagement axis — a green test asserting a DB
   property it never actually tested. A larger honest failure than a smaller honest suite; caught only by
   the security lens reading the test body.

(See `07-review-security.yaml` in runs 2 & 3 and the retrospectives.)

## Proposed change
- Files: `agent-firm/policy/definition-of-done.yaml`, the reviewer + implementer agent prompts
  (`.claude/agents/reviewer.md`, `.claude/agents/implementer.md`), `agent-firm/evals/…`.
- Summary of the change:
  1. **DoD + implementer/reviewer checklist item (least-privilege):** for any run that adds DB
     tables/roles, the request-path role must hold no write on catalog/config/append-only/PII/identity
     tables, and every engagement-scoped table must have FORCE RLS + be reachable only via a repository.
     Implementer must run and attach a GRANT-audit; reviewer verifies it.
  2. **DoD + reviewer checklist item (no-overclaim):** a test's asserted property must be actually
     exercised — e.g. a "dual-axis"/"both X and Y" isolation test must vary BOTH axes; a title/`describe`
     may not claim a guarantee the body doesn't drive. Reviewer explicitly checks test bodies vs. titles.
  3. Add the two golden evals below.

## Generalizability check (reviewer)
- Applies beyond this project? **yes** — least-privilege DB roles + FORCE RLS is standard for any
  multi-tenant/isolation-bearing system; "tests must not overclaim" is universal test hygiene. Neither
  encodes anything consulting-ops-specific.
- Risk of overfitting the firm to one repo: **low** — phrased as general checklist items + evals. The
  least-privilege eval is Postgres/RLS-flavored; keep its assertion generic ("request-path role lacks
  write on protected tables") so it transfers to any DB with role-based grants.

## Risk & rollback
- Risk: false positives on projects with no DB, or non-Postgres stacks — gate both evals on "project has
  a relational DB with role separation," skip otherwise. Low risk of slowing trivial work.
- Rollback: revert this PR (firm config is versioned in git).

## Golden eval to guard it
- Eval: `agent-firm/evals/least-privilege-grants/` — asserts that, for a change adding an
  engagement-scoped or config/append-only table, QA/review fails if the request-path role has write on it
  or the table lacks FORCE RLS.
- Eval: `agent-firm/evals/no-overclaiming-tests/` — asserts a review flags a test whose title/`describe`
  claims a multi-axis property its body does not exercise (fixture: a "both engagement+client" test that
  only varies one axis).
- [x] Golden evals pass (`firm-run-evals`) — structural validation passed for both
      `least-privilege-grants` and `no-overclaiming-tests` (task.md + assertions.yaml + fixture/ present
      and well-formed; all assertion types recognized by `firm-check-assertions`). Both fixtures were
      smoke-tested: the least-privilege GRANT audit fails in its seeded-violating start state, and the
      overclaiming RLS test is green-but-dishonest as seeded. Full model-run evals require a Claude
      login and are deferred.

## Human decision
- [x] approved by josh@heightslabs.com on 2026-07-27 (UTC)   |   [ ] rejected — reason:
