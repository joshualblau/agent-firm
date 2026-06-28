// build-review-test.js — the firm's deterministic fan-out for the Build → Integrate → Review → Test
// stages. The Lead invokes this via the Workflow tool so heavy parallelism stays OUT of its context.
//
// Invoke (from the Lead, after Intake + Plan gates are passed):
//   Workflow({ scriptPath: "agent-firm/workflows/build-review-test.js", args: {
//     run_dir: ".agent-firm/runs/<ts>-<slug>",
//     track: "full_track",                         // or "fast_path"
//     work_orders: [ { id: "wo1", brief: "..." }, { id: "wo2", brief: "..." } ],
//     review_lenses: ["correctness","security_privacy","acceptance_fit"],
//     ci_command: "npm test"                        // the exact command QA must run
//   }})
//
// Notes:
//  - Stages map to the firm's own subagents (agentType). Build runs implementers in parallel, each in
//    its own git worktree via bin/new-worktree. Integration, clean-checkout QA, and verdict validation
//    are done by agents running the firm's bin/ scripts (workflow scripts cannot run shell directly).
//  - fast_path collapses to a single reviewer and skips the integrator when there is one work order.

export const meta = {
  name: 'firm-build-review-test',
  description: 'Firm fan-out: parallel build in worktrees, integrate, review panel, independent QA verdict',
  phases: [
    { title: 'Build' },
    { title: 'Integrate' },
    { title: 'Review' },
    { title: 'Test' },
  ],
}

const a = args || {}
const runDir = a.run_dir || '.agent-firm/runs/current'
const track = a.track || 'full_track'
const workOrders = Array.isArray(a.work_orders) && a.work_orders.length ? a.work_orders : [{ id: 'wo1', brief: 'implement the task' }]
const lenses = (track === 'fast_path') ? ['correctness'] : (a.review_lenses || ['correctness', 'security_privacy', 'acceptance_fit'])
const ciCommand = a.ci_command || 'npm test'

const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['work_order', 'branch', 'files_changed', 'tests_added', 'test_result', 'summary'],
  properties: {
    work_order: { type: 'string' },
    branch: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    tests_added: { type: 'array', items: { type: 'string' } },
    test_result: { type: 'string', enum: ['green', 'red', 'blocked'] },
    summary: { type: 'string' },
    integrator_asks: { type: 'array', items: { type: 'string' } },
  },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['lens', 'verdict', 'findings'],
  properties: {
    lens: { type: 'string' },
    verdict: { type: 'string', enum: ['approved', 'changes_requested'] },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['severity', 'location', 'issue'],
        properties: {
          severity: { type: 'string', enum: ['low', 'medium', 'high', 'blocker'] },
          location: { type: 'string' },
          issue: { type: 'string' },
          suggested_fix: { type: 'string' },
        },
      },
    },
  },
}

// ---------- Build: one implementer per work-order, in parallel, each in its own worktree ----------
phase('Build')
log(`Building ${workOrders.length} work-order(s) in parallel worktrees...`)
const built = await parallel(workOrders.map(wo => () =>
  agent(
    `You are an Implementer in the firm. Run \`bin/new-worktree implementer ${wo.id}\` from the project root, ` +
    `then implement this work-order INSIDE that worktree directory and self-correct to green:\n\n${wo.brief}\n\n` +
    `Add tests for new behavior. Run the project's test command. Stop after the firm's max_test_repair_loops ` +
    `and report test_result:"red" rather than thrashing. Return your structured summary; do NOT commit to or ` +
    `merge the default branch.`,
    { label: `build:${wo.id}`, phase: 'Build', agentType: 'implementer', schema: IMPL_SCHEMA }
  )
)).then(r => r.filter(Boolean))

const reds = built.filter(b => b.test_result !== 'green')
if (reds.length) log(`WARNING: ${reds.length} work-order(s) not green: ${reds.map(r => r.work_order).join(', ')}`)

// ---------- Integrate: single integrator merges worktrees into the integration branch ----------
let integration = null
const needIntegrator = built.length > 1 || track === 'full_track'
if (needIntegrator) {
  phase('Integrate')
  integration = await agent(
    `You are the Integrator. Run \`bin/integrate\` to merge this run's worktree branches into the integration ` +
    `branch. Resolve any reported conflicts by hand (never drop a change), reconcile lockfiles/migrations/ports/` +
    `fixtures, run the COMBINED test suite, and write integration-summary.md into ${runDir}. ` +
    `Return a short status: branch name, conflicts resolved, combined-suite result.`,
    { label: 'integrate', phase: 'Integrate', agentType: 'integrator' }
  )
} else {
  log('Single work-order on fast_path — skipping the Integrator (Lead does a lightweight check).')
}

// ---------- Review: one reviewer per lens, in parallel ----------
phase('Review')
log(`Review panel: ${lenses.join(', ')}`)
const reviews = await parallel(lenses.map(lens => () =>
  agent(
    `You are a Reviewer with the ${lens} lens. Review the integration branch's diff and the test evidence in ` +
    `${runDir}/09-test-evidence/ (use read-only git: \`git diff\`, \`git log\`). Work only from the spec, the ` +
    `diff, and the evidence. Produce actionable findings only. Return your structured review.`,
    { label: `review:${lens}`, phase: 'Review', agentType: 'reviewer', schema: REVIEW_SCHEMA }
  )
)).then(r => r.filter(Boolean))

const blockers = reviews.flatMap(r => (r.findings || []).filter(f => f.severity === 'blocker' || f.severity === 'high'))

// ---------- Test: independent QA from a clean checkout, schema-valid verdict ----------
phase('Test')
const qa = await agent(
  `You are the QA / Test pod. Run \`bin/qa-checkout\` to get a clean checkout at the integration branch HEAD. ` +
  `Install from the lockfile and run the exact CI command: \`${ciCommand}\`. Capture each command's output under ` +
  `${runDir}/09-test-evidence/. Check acceptance-criteria coverage against ${runDir}/01-acceptance-criteria.yaml. ` +
  `Write ${runDir}/08-qa-verdict.json conforming to agent-firm/schemas/qa-verdict.schema.json, then validate it ` +
  `with \`bin/validate-verdict\` and run \`bin/traceability-check\`. You are READ-ONLY against source. ` +
  `Emit BLOCK on any uncertainty. Return the verdict (APPROVE/BLOCK), the top blockers, and the untested risks.`,
  { label: 'qa', phase: 'Test', agentType: 'qa-tester' }
)

return {
  built,
  reds: reds.map(r => r.work_order),
  integration,
  reviews,
  open_blockers: blockers,
  qa,
  note: 'Lead: surface QA verdict + handoff at the FINAL human gate. Nothing merges/ships without sign-off.',
}
