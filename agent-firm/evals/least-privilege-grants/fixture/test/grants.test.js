// GRANT audit for the least-privilege golden eval. DB-agnostic: it reads grants.json (the audit
// manifest the implementer must produce/correct) and enforces the firm's least-privilege rules.
// It is designed to FAIL against the starting fixture and PASS only once the request-path role's
// blanket writes are removed and engagement-scoped tables get FORCE RLS + repo-only access.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const grants = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'grants.json'), 'utf8'));
const WRITE = new Set(['INSERT', 'UPDATE', 'DELETE']);
const PROTECTED = new Set(['catalog', 'config', 'append_only', 'config_append_only', 'pii', 'identity']);

function hasWrite(privs) {
  return (privs || []).some((p) => WRITE.has(String(p).toUpperCase()));
}

test('request-path role holds NO write on catalog/config/append-only/PII/identity tables', () => {
  const rp = grants.roles.request_path.tables || {};
  for (const [table, privs] of Object.entries(rp)) {
    const meta = grants.tables[table] || {};
    if (PROTECTED.has(meta.classification)) {
      assert.ok(
        !hasWrite(privs),
        `request_path must NOT hold write on protected table '${table}' (classification=${meta.classification}); got ${JSON.stringify(privs)}`
      );
    }
  }
});

test('every engagement-scoped table has FORCE RLS and is repo-only (request-path cannot write it directly)', () => {
  const rp = grants.roles.request_path.tables || {};
  for (const [table, meta] of Object.entries(grants.tables)) {
    if (meta.classification === 'engagement_scoped') {
      assert.strictEqual(meta.force_rls, true, `engagement-scoped table '${table}' must have FORCE RLS`);
      assert.strictEqual(meta.reachable_only_via_repository, true, `engagement-scoped table '${table}' must be reachable only via the repository role`);
      assert.ok(!hasWrite(rp[table]), `request_path must NOT write engagement-scoped table '${table}' directly; got ${JSON.stringify(rp[table])}`);
    }
  }
});
