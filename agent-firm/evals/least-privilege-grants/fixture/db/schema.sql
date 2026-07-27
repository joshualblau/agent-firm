-- Minimal schema for the least-privilege golden-eval fixture (Postgres-flavored, illustrative).
-- The authoritative grant state the audit checks lives in grants.json.

CREATE TABLE users (            -- identity table (PII)
  id      bigserial PRIMARY KEY,
  email   text NOT NULL,
  pw_hash text NOT NULL
);

CREATE TABLE audit_log (        -- config / append-only
  id      bigserial PRIMARY KEY,
  at      timestamptz NOT NULL DEFAULT now(),
  event   text NOT NULL
);

CREATE TABLE engagement_notes ( -- engagement-scoped: MUST have FORCE RLS + repo-only access
  id            bigserial PRIMARY KEY,
  engagement_id bigint NOT NULL,
  body          text NOT NULL
);

-- Roles: request_path (the API's request-path role) must NOT hold write on protected tables above;
-- engagement-scoped tables must be reachable only via the repository role, with FORCE RLS.
-- (Grants are asserted from grants.json by test/grants.test.js.)
