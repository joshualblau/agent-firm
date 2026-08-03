# System Change PR: validate run-ledger artifacts at write time

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260803T092058Z-review-system-change-prs` (promoted on independent review;
  originally SC-3 in `20260801T203648Z-evaluate-remote-changes/11-retrospective.md`)
- **Date (UTC):** 2026-08-03
- **Status:** proposed

## Motivation

`CLAUDE.md` first principle 1: *"Artifacts are the source of truth. The run-ledger on disk is the state
machine."* Nothing validates them. Across this engagement the ledger repeatedly failed to be a source of
truth, and every instance was found by a reviewer or a judge rather than by the firm:

| What | Consequence |
|---|---|
| `01-acceptance-criteria.yaml` was **invalid YAML** (an unquoted ` #` opened a comment mid-list) | The traceability gate's "PASS 26/26" came from a regex fallback, not a parse. The gate was decorative for that run. |
| `07-review-findings-GOV.yaml` was **invalid YAML** (brace-expansion inside a flow sequence) | Found only by a sweep prompted by the first failure. |
| `04-staffing-plan.yaml` shipped with `task_slug: null`; `03-decision-log.md` shipped as a bare template | Two runs reached a **final gate** in that state. |
| `remediate-remote-delta` shipped a **full_track** run with a template `01-acceptance-criteria.yaml` and `acceptance_criteria_coverage: []` | A full-track run with no recorded criteria at all. |
| `traceability.yaml` shipped as a template while `10-handoff.md` claimed all eleven criteria covered | Directly contradictory artifacts in one run dir. |

The pattern is **not closed by learning**: the fifth run of this engagement — completed *after* all of
these lessons were written down — still has a template `00-intake.md` and a template
`11-retrospective.md`.

There is a precedent that makes the cost concrete and predates the engagement: commit `9797bba` records
that `agent-firm/policy/definition-of-done.yaml` **had been invalid YAML since PR1**. All **15** items it
then declared (16 today) were unloadable for an entire release. Nothing noticed — and the reason is the
point: **no code parses this file at all**, so "silently failed to load" overstates it. Nothing ever
tried. Its 15 obligations were enforced only by whichever agent happened to read the prose.
*(Second review: an earlier draft said "14 items" and "silently failed to load" in the same breath as
"nothing parses it" — a wrong count and a self-contradiction, inherited from `12-owner-override.md` and
from the reviewer's own prior finding. Both corrected.)* The same class of defect this firm spent four waves closing in its *gate scripts* was sitting
in its *policy files* the whole time.

Cited: `20260801T203648Z-evaluate-remote-changes/11-retrospective.md` (SC-3);
`20260803T092058Z-review-system-change-prs/07-review-findings.yaml`.

## Proposed change

- Files: `bin/firm-ledger-log` or a new `bin/firm-validate-ledger`, `bin/firm-new-run`, `CLAUDE.md`,
  `agent-firm/policy/definition-of-done.yaml`

1. **Add `firm-validate-ledger <run_dir>`.** Parses every `*.yaml` and `*.json` in a run dir; validates
   the ones with schemas (`acceptance-criteria`, `qa-verdict`, `staffing-plan`, `job-spec`) against them;
   flags any artifact still byte-identical to its template; and reports required-but-empty fields
   (`task_slug: null` is the canonical case). Fails closed — an unparseable artifact is a failure, not a
   warning.
2. **Make it a Lead obligation at the final gate**, alongside `firm-traceability-check`. This is the
   mechanism the criteria-before-Build PR is missing: that PR states an obligation, and this PR is what
   would actually check it. The two should be reviewed together.
3. **Validate the policy files too**, not just run artifacts. `definition-of-done.yaml` was dead for a
   release. A parse check over `agent-firm/policy/**` and `agent-firm/schemas/**` costs milliseconds.
   (`tests/test-policy-yaml-valid.sh`, added during this engagement, now covers part of this — the gap
   is that nothing runs it *at gate time*, only in CI and the suite.)

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes, strongly. Any project run by this firm produces the same ledger,
  and a ledger that cannot be parsed is worse than no ledger — it produces confident false verdicts, as
  the traceability "PASS 26/26" did.
- **Risk of overfitting the firm to one repo:** none apparent. The check is over the firm's own artifact
  formats, which are project-independent by construction.

## Risk & rollback

- **Risk:** a fail-closed ledger validator will block gates that previously passed, including on runs
  whose *substance* is fine and whose bookkeeping is not. That is the intent, but it will feel
  obstructive at first and there is a real hazard of it being routed around. Second risk: flagging
  "byte-identical to template" as a failure penalises legitimately-not-applicable artifacts (a fast_path
  run has no architecture doc) — so the check needs an explicit, justified skip mechanism, or it will
  train people to ignore it.
- **Rollback:** revert this PR (firm config is versioned in git).

## Golden eval to guard it

- Test: `tests/test-validate-ledger.sh` (new), plus extend `tests/test-policy-yaml-valid.sh`
- What it asserts: a run dir containing (a) an unparseable YAML artifact, (b) a schema-invalid verdict,
  (c) an artifact byte-identical to its template, or (d) a required field left null, each **fails**
  validation with a distinguishable reason; and a complete, valid run dir passes. Every one of these
  four cases is drawn from an artifact that actually shipped in this engagement, so the fixtures are
  real rather than invented.
- Feasibility: high — pure file-in / exit-code-out, no model involvement, constructible under
  `mktemp -d`. This is the shape the review recommended for guarding script properties, and it applies
  cleanly here.
- [ ] Golden evals pass (`firm-run-evals`) — attach the run output. If an eval changed, explain why the
      new behavior is correct (not just newly-passing).

## Evidence availability (read this before following a citation)

Every `.agent-firm/runs/...` path cited above lives in the **run ledger, which is not in git**. It is
excluded by **committed policy** — `.gitignore:32` (`.agent-firm/runs/`) — and additionally by a local
`.git/info/exclude:8`. **This PR is committable; its evidence is not.**

*(Corrected on second review: an earlier version of this note claimed the exclusion was machine-local
only and "not a committed `.gitignore`". It is committed. The conclusion is unchanged but the remedy is
different — this is a deliberate project policy to revisit, not an accident to fix.)*

Consequences a reviewer should weigh:
- A future reader (including the author) cannot verify any citation from a fresh clone.
- The firm's first principle is "artifacts are the source of truth", and those artifacts are outside
  version control — so the source of truth is unreviewable by anyone but the machine that wrote it.

Found by independent review (F-22). **No longer an open question.** It is now a specific proposal:
`system-changes/20260803T101922Z-commit-the-decision-bearing-ledger.md`, whose shape was settled at the
Requirements gate of run `20260803T120043Z-cleanup-and-identity-gate` — tier A is the decision artifacts
`00`-`12` **plus `run.jsonl`** (measured 0.44 MB/run over seven closed runs, ~44 MB at 100 runs), and
bulk `09-test-evidence/` stays local but **curated**: the specific artifacts an approved PR cites are
copied into `system-changes/evidence/<pr-slug>/` so the document is checkable from a clone. That PR is
still `Status: proposed` and still needs its own approval; only its shape is settled.

*(Corrected on third review: this footer previously offered three undecided options and named a narrower
tier — `00`, `01`, `03`, `07`, `08`, `10`, `11`, without `run.jsonl`. That enumeration is superseded and was
stale in six files at once. `run.jsonl` in particular belongs in tier A: it is the only durable source for
the agent-active measurement in the wall-clock PR, and the judge-round attribution in the stop-rule PR is
recoverable from nothing else. Fixing it in one file and not the other five is the failure mode this batch
was rejected for three times.)*

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
