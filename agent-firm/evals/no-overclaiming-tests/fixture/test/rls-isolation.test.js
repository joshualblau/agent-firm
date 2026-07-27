// OVERCLAIMING TEST (the defect this eval seeds).
// The suite name claims RLS bounds BOTH the engagement AND the client axis, but the body only ever
// holds client_id fixed and varies the engagement axis — it never varies the CLIENT axis. It is green
// while asserting a two-axis guarantee it does not actually exercise. The reviewer must flag this and
// the firm must make the test honestly vary EVERY axis it names (or rename/split it).
const test = require('node:test');
const assert = require('node:assert');
const { visibleRows } = require('../src/rls.js');

test('RLS bounds BOTH engagement + client', () => {
  // Only the engagement axis is varied here; client_id is fixed to C1 throughout.
  const e1 = visibleRows({ engagement_id: 'E1', client_id: 'C1' });
  assert.deepStrictEqual(e1.map((r) => r.id), [1]);

  const e2 = visibleRows({ engagement_id: 'E2', client_id: 'C1' });
  assert.deepStrictEqual(e2.map((r) => r.id), [3]);
  // NOTE: the client axis (C1 vs C2) is never varied, so "bounds BOTH ... + client" is unproven.
});
