# System Change PR: Repair the GPT second-voice QA judge + define its gate policy

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** 20260727T080220Z-consulting-ops-system (recurred in all three runs)
- **Date (UTC):** 2026-07-27
- **Status:** approved

## Motivation
The independent second-provider QA judge (`firm-gpt-qa`, via the `codex` CLI) was **unavailable for all
three runs** of the consulting-operations engagement: the installed `codex` v0.142.5 is incompatible
with the configured model (`gpt-5.6-sol` → HTTP 400 "requires a newer version of Codex"). QA correctly
recorded it as *skipped, not passed*, so **every run's QA was single-provider (Claude only)**. The whole
point of the second voice is defense-in-depth against a single model's blind spots; silently running
without it for an entire engagement erodes that guarantee. Two problems: (1) the tooling is broken, and
(2) there is no explicit policy on whether the second voice is advisory or a required gate — so its
absence degraded quietly instead of forcing a decision. (See `11-retrospective.md`, all three runs, and
the `warnings` in each `08-qa-verdict.json`.)

## Proposed change
- Files: `bin/firm-gpt-qa`, `agent-firm/policy/execution-budget.yaml` (or a QA policy file),
  `agent-firm/policy/gate-matrix.md`, firm install/setup docs (`README`/`firm-bootstrap`).
- Summary of the change:
  1. **Fix the tooling:** pin/upgrade the `codex` CLI to a version compatible with the configured model,
     OR make the model configurable via env with a compatibility preflight. `firm-gpt-qa` should run a
     one-line **version/compatibility preflight** and emit a clear, actionable error (with the fix) when
     mismatched — not a bare exit code.
  2. **Fail loudly, not silently:** distinguish `unavailable-tooling` (exit 3, as a first-class QA
     `warning` that the Lead MUST surface at the Final gate) from `judge-ran-and-blocked` (exit 1).
     Today a version mismatch and a real block both looked like nonzero exits.
  3. **Set the policy explicitly** in the gate matrix: is the GPT second voice **advisory** (skip →
     documented warning, human accepts) or **required** for high-risk/security-sensitive runs (skip →
     the Lead must get explicit human waiver at the Final gate)? Recommend: advisory by default, REQUIRED
     for runs touching auth/permissions/crypto/PII (all three consulting-ops runs would have triggered it).

## Generalizability check (reviewer)
- Applies beyond this project? **yes** — the second-voice judge is a core firm QA mechanism used on every
  engagement; a version-drift break and an undefined skip-policy affect all future runs.
- Risk of overfitting the firm to one repo: **none** — this is pure firm infrastructure/policy.

## Risk & rollback
- Risk: pinning `codex`/model could break if the provider changes again; mitigated by the preflight +
  env-configurable model. Making it "required" for sensitive runs could block work if the human is absent
  — mitigated by allowing an explicit, logged human waiver.
- Rollback: revert this PR (firm config is versioned in git).

## Golden eval to guard it
- Eval: `agent-firm/evals/gpt-judge-availability/`
- What it asserts: (a) `firm-gpt-qa` preflight detects a simulated version/model mismatch and returns
  exit 3 with an actionable message (not a bare failure); (b) a QA run where the judge is unavailable
  produces a surfaced Final-gate warning; (c) for a security-sensitive run, an unavailable required judge
  forces an explicit human-waiver step rather than a silent pass.
- [x] Golden evals pass (`firm-run-evals`) — structural validation passed for `gpt-judge-availability`
      (task.md + assertions.yaml + fixture/ present and well-formed; all assertion types recognized by
      `firm-check-assertions`). The exit-3 UNAVAILABLE path was smoke-tested directly
      (`FIRM_GPT_QA_FORCE_INCOMPAT=1 firm-gpt-qa` returns 3 with an actionable message). Full model-run
      evals require a Claude login and are deferred.

## Human decision
- [x] approved by josh@heightslabs.com on 2026-07-27 (UTC)   |   [ ] rejected — reason:
