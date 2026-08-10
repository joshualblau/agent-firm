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
//    its own git worktree via firm-new-worktree. Integration, clean-checkout QA, and verdict validation
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
const workOrders = a.work_orders === undefined ? [{ id: 'wo1', brief: 'implement the task' }] : a.work_orders
const lenses = (track === 'fast_path') ? ['correctness'] :
  (a.review_lenses === undefined ? ['correctness', 'security_privacy', 'acceptance_fit'] : a.review_lenses)
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
const INTEGRATION_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['status', 'branch', 'conflicts_resolved', 'test_result', 'summary'],
  properties: {
    status: { type: 'string', enum: ['green', 'red', 'blocked'] },
    branch: { type: 'string' },
    conflicts_resolved: { type: 'array', items: { type: 'string' } },
    test_result: { type: 'string', enum: ['green', 'red', 'blocked'] },
    summary: { type: 'string' },
  },
}
// Exported so artifact-contract tests validate the exact schema passed to reviewer agents.
export const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['lens', 'verdict', 'findings'],
  properties: {
    lens: { type: 'string' },
    verdict: { type: 'string', enum: ['approved', 'changes_requested'] },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['severity', 'confidence', 'location', 'issue', 'suggested_fix', 'status'],
        properties: {
          severity: { type: 'string', enum: ['low', 'medium', 'high', 'blocker'] },
          confidence: { type: 'string', enum: ['low', 'medium', 'high'] },
          location: { type: 'string' },
          issue: { type: 'string' },
          suggested_fix: { type: 'string' },
          status: { type: 'string', enum: ['open', 'accepted', 'rejected', 'fixed'] },
        },
      },
    },
  },
}

export const aggregateReviewArtifact = (panel, taskSlug) => ({
  task_slug: taskSlug,
  reviewers: panel.map(review => review.lens),
  findings: panel.flatMap(review => (review.findings || []).map(finding => ({ lens: review.lens, ...finding }))),
  verdict: panel.every(review => review.verdict === 'approved') ? 'approved' : 'changes_requested',
})

// Workflow agents receive schemas at their native boundary, but orchestration must also distrust the
// returned value: a missing/rejected agent result or a host adapter that fails to enforce `schema`
// must be a typed nonpassing stage, never something `.filter(Boolean)` can erase.
export const validateStageArtifact = (schema, value, path = '$') => {
  const errors = []
  if (schema.type === 'object') {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return [`${path}: expected object`]
    const keys = Object.keys(value)
    for (const field of schema.required || []) {
      if (!Object.prototype.hasOwnProperty.call(value, field)) errors.push(`${path}.${field}: required`)
    }
    if (schema.additionalProperties === false) {
      for (const field of keys) {
        if (!Object.prototype.hasOwnProperty.call(schema.properties || {}, field)) errors.push(`${path}.${field}: additional property`)
      }
    }
    for (const [field, childSchema] of Object.entries(schema.properties || {})) {
      if (Object.prototype.hasOwnProperty.call(value, field)) {
        errors.push(...validateStageArtifact(childSchema, value[field], `${path}.${field}`))
      }
    }
  } else if (schema.type === 'array') {
    if (!Array.isArray(value)) return [`${path}: expected array`]
    value.forEach((item, index) => errors.push(...validateStageArtifact(schema.items, item, `${path}[${index}]`)))
  } else if (schema.type === 'string') {
    if (typeof value !== 'string') errors.push(`${path}: expected string`)
  }
  if (schema.enum && !schema.enum.includes(value)) errors.push(`${path}: not in enum`)
  return errors
}

const rejectedMessage = error => error instanceof Error ? error.message : String(error)
const settledAgent = async invoke => {
  try {
    return { ok: true, value: await invoke() }
  } catch (error) {
    return { ok: false, error: rejectedMessage(error) }
  }
}
const stageBlocked = (status, failedStage, stageErrors, state = {}) => ({
  status,
  failed_stage: failedStage,
  stage_errors: stageErrors,
  built: state.built || [],
  reds: state.reds || [],
  integration: state.integration || null,
  reviews: state.reviews || [],
  review_artifact: state.reviewArtifact || null,
  open_blockers: state.openBlockers || [],
  qa: null,
  note: `${failedStage} BLOCKED: exact schema/cardinality/green-state proof failed. Test/QA was not launched.`,
})

// ---------- Build: one implementer per work-order, in parallel, each in its own worktree ----------
phase('Build')
const inputErrors = []
if (!Array.isArray(workOrders) || workOrders.length === 0) {
  inputErrors.push('work_orders: expected a non-empty array')
} else {
  const ids = new Set()
  workOrders.forEach((wo, index) => {
    if (wo === null || typeof wo !== 'object' || Array.isArray(wo)) {
      inputErrors.push(`work_orders[${index}]: expected object`)
      return
    }
    if (typeof wo.id !== 'string' || !wo.id.trim()) inputErrors.push(`work_orders[${index}].id: expected non-empty string`)
    if (typeof wo.brief !== 'string' || !wo.brief.trim()) inputErrors.push(`work_orders[${index}].brief: expected non-empty string`)
    if (typeof wo.id === 'string' && ids.has(wo.id)) inputErrors.push(`work_orders[${index}].id: duplicate ${wo.id}`)
    ids.add(wo.id)
  })
}
if (!Array.isArray(lenses) || lenses.length === 0) {
  inputErrors.push('review_lenses: expected a non-empty array')
} else {
  const names = new Set()
  lenses.forEach((lens, index) => {
    if (typeof lens !== 'string' || !lens.trim()) inputErrors.push(`review_lenses[${index}]: expected non-empty string`)
    if (typeof lens === 'string' && names.has(lens)) inputErrors.push(`review_lenses[${index}]: duplicate ${lens}`)
    names.add(lens)
  })
}
if (inputErrors.length) return stageBlocked('build_blocked', 'Build', inputErrors)

log(`Building ${workOrders.length} work-order(s) in parallel worktrees...`)
const buildSettled = await parallel(workOrders.map(wo => () => settledAgent(() => agent(
    `You are an Implementer in the firm. Run \`firm-new-worktree implementer ${wo.id}\` from the project root, ` +
    `then implement this work-order INSIDE that worktree directory and self-correct to green:\n\n${wo.brief}\n\n` +
    `Add tests for new behavior. Run the project's test command. Stop after the firm's max_test_repair_loops ` +
    `and report test_result:"red" rather than thrashing. Return your structured summary; do NOT commit to or ` +
    `merge the default branch.`,
    { label: `build:${wo.id}`, phase: 'Build', agentType: 'implementer', schema: IMPL_SCHEMA }
  )
)))
const built = buildSettled.filter(result => result.ok).map(result => result.value)
const buildErrors = []
buildSettled.forEach((result, index) => {
  const expected = workOrders[index].id
  if (!result.ok) {
    buildErrors.push(`build:${expected}: rejected: ${result.error}`)
    return
  }
  const errors = validateStageArtifact(IMPL_SCHEMA, result.value, `build:${expected}`)
  buildErrors.push(...errors)
  if (!errors.length && result.value.work_order !== expected) {
    buildErrors.push(`build:${expected}.work_order: expected exact id ${expected}, got ${result.value.work_order}`)
  }
  if (!errors.length && result.value.test_result !== 'green') {
    buildErrors.push(`build:${expected}.test_result: ${result.value.test_result}`)
  }
})
const returnedBuildIds = built.filter(value => value && typeof value.work_order === 'string').map(value => value.work_order)
for (const id of new Set(returnedBuildIds)) {
  if (returnedBuildIds.filter(value => value === id).length !== 1) buildErrors.push(`build result id ${id}: duplicate`)
}
const reds = built.filter(value => value && value.test_result !== 'green')
if (buildErrors.length || built.length !== workOrders.length) {
  if (built.length !== workOrders.length) buildErrors.push(`Build result count: expected ${workOrders.length}, got ${built.length}`)
  return stageBlocked('build_blocked', 'Build', buildErrors, { built, reds: reds.map(result => result.work_order) })
}

// ---------- Integrate: single integrator merges worktrees into the integration branch ----------
let integration = null
const needIntegrator = built.length > 1 || track === 'full_track'
if (needIntegrator) {
  phase('Integrate')
  const integrationSettled = await settledAgent(() => agent(
    `You are the Integrator. Run \`firm-integrate\` to merge this run's worktree branches into the integration ` +
    `branch. Resolve any reported conflicts by hand (never drop a change), reconcile lockfiles/migrations/ports/` +
    `fixtures, run the COMBINED test suite, and write integration-summary.md into ${runDir}. ` +
    `Return the exact structured status: green/red/blocked status, branch name, conflicts resolved, ` +
    `green/red/blocked combined-suite test_result, and summary.`,
    { label: 'integrate', phase: 'Integrate', agentType: 'integrator', schema: INTEGRATION_SCHEMA }
  ))
  if (!integrationSettled.ok) {
    return stageBlocked('integration_blocked', 'Integrate', [`integrate: rejected: ${integrationSettled.error}`], { built })
  }
  integration = integrationSettled.value
  const integrationErrors = validateStageArtifact(INTEGRATION_SCHEMA, integration, 'integrate')
  if (!integrationErrors.length && integration.status !== 'green') integrationErrors.push(`integrate.status: ${integration.status}`)
  if (!integrationErrors.length && integration.test_result !== 'green') integrationErrors.push(`integrate.test_result: ${integration.test_result}`)
  if (integrationErrors.length) {
    return stageBlocked('integration_blocked', 'Integrate', integrationErrors, { built, integration })
  }
} else {
  log('Single work-order on fast_path — skipping the Integrator (Lead does a lightweight check).')
}

// ---------- Review: one reviewer per lens, in parallel ----------
phase('Review')
log(`Review panel: ${lenses.join(', ')}`)
const reviewSettled = await parallel(lenses.map(lens => () => settledAgent(() => agent(
    `You are a Reviewer with the ${lens} lens. Review the integration branch's diff and the test evidence in ` +
    `${runDir}/09-test-evidence/ (use read-only git: \`git diff\`, \`git log\`). Work only from the spec, the ` +
    `diff, and the evidence. Produce actionable findings only. Return your structured review.`,
    { label: `review:${lens}`, phase: 'Review', agentType: 'reviewer', schema: REVIEW_SCHEMA }
  )
)))
const reviews = reviewSettled.filter(result => result.ok).map(result => result.value)
const reviewErrors = []
reviewSettled.forEach((result, index) => {
  const expected = lenses[index]
  if (!result.ok) {
    reviewErrors.push(`review:${expected}: rejected: ${result.error}`)
    return
  }
  const errors = validateStageArtifact(REVIEW_SCHEMA, result.value, `review:${expected}`)
  reviewErrors.push(...errors)
  if (!errors.length && result.value.lens !== expected) {
    reviewErrors.push(`review:${expected}.lens: expected exact lens ${expected}, got ${result.value.lens}`)
  }
  if (!errors.length && result.value.verdict !== 'approved') {
    reviewErrors.push(`review:${expected}.verdict: ${result.value.verdict}`)
  }
})
const returnedLenses = reviews.filter(value => value && typeof value.lens === 'string').map(value => value.lens)
for (const lens of new Set(returnedLenses)) {
  if (returnedLenses.filter(value => value === lens).length !== 1) reviewErrors.push(`review result lens ${lens}: duplicate`)
}
if (reviewErrors.length || reviews.length !== lenses.length) {
  if (reviews.length !== lenses.length) reviewErrors.push(`Review result count: expected ${lenses.length}, got ${reviews.length}`)
  return stageBlocked('review_blocked', 'Review', reviewErrors, { built, integration, reviews })
}

// Canonical aggregation is deliberately field-for-field: ranking (`confidence`) and disposition
// (`status`) survive the panel boundary instead of being dropped by a hand-written projection.
const reviewArtifact = aggregateReviewArtifact(reviews, a.task_slug || runDir.split('/').pop())
const blockers = reviewArtifact.findings.filter(
  f => f.status === 'open' && (f.severity === 'blocker' || f.severity === 'high')
)

// Review is a real control boundary. QA must not be launched against a candidate the panel has
// already identified as blocked; the Lead resolves the exact findings and runs a fresh workflow.
if (blockers.length) {
  return {
    status: 'review_blocked',
    built,
    reds: reds.map(r => r.work_order),
    integration,
    reviews,
    review_artifact: reviewArtifact,
    open_blockers: blockers,
    qa: null,
    note: 'Review BLOCKED: resolve every open blocker/high finding, then launch one fresh workflow. QA was not launched.',
  }
}

// ---------- Test: independent QA from a clean checkout, schema-valid verdict ----------
phase('Test')
const qa = await agent(
  `You are the QA / Test pod. Run \`firm-qa-checkout\` to get a clean checkout at the integration branch HEAD. ` +
  `Install from the lockfile and run the exact CI command: \`${ciCommand}\`. Capture each command's output under ` +
  `${runDir}/09-test-evidence/. Check acceptance-criteria coverage against ${runDir}/01-acceptance-criteria.yaml. ` +
  `Write the primary ${runDir}/08-qa-verdict.json conforming to agent-firm/schemas/qa-verdict.schema.json, ` +
  `validate it with \`firm-validate-verdict\`, and run \`firm-traceability-check\`. Then invoke the opposite ` +
  `provider selected by run metadata (Claude-primary calls \`firm-gpt-qa\`; Codex-primary calls ` +
  `\`firm-claude-qa\`) and record availability plus one traceability two_voice_diff entry per secondary blocker. ` +
  `You are READ-ONLY against source. Emit BLOCK on uncertainty. Return both verdicts, blockers, and untested risks.`,
  { label: 'qa', phase: 'Test', agentType: 'qa-tester' }
)

return {
  status: 'qa_complete',
  built,
  reds: reds.map(r => r.work_order),
  integration,
  reviews,
  review_artifact: reviewArtifact,
  open_blockers: blockers,
  qa,
  note: 'Lead: run firm-qa-clean-check and firm-final-qa-check, then surface both verdicts + handoff at the FINAL human gate. Nothing merges/ships without sign-off.',
}
