// Minimal in-memory model of row-level-security isolation over an engagement- and client-scoped table.
// `visibleRows(ctx)` returns only rows matching BOTH the caller's engagement_id AND client_id — i.e.
// isolation is bounded on two axes. A correct test of "bounds BOTH engagement + client" must vary each.
const ROWS = [
  { id: 1, engagement_id: 'E1', client_id: 'C1', body: 'e1/c1' },
  { id: 2, engagement_id: 'E1', client_id: 'C2', body: 'e1/c2' },
  { id: 3, engagement_id: 'E2', client_id: 'C1', body: 'e2/c1' },
  { id: 4, engagement_id: 'E2', client_id: 'C2', body: 'e2/c2' },
];

function visibleRows(ctx) {
  return ROWS.filter((r) => r.engagement_id === ctx.engagement_id && r.client_id === ctx.client_id);
}

module.exports = { ROWS, visibleRows };
