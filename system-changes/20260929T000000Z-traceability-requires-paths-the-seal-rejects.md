# System Change PR: firm-traceability-check requires absolute candidate paths in traceability.yaml that the evidence seal rejects

A change to the **firm itself** (not a project deliverable).

- **Proposed by run:** `20260928T213510Z-pr12-merge-guard-closeout-3`, found by primary QA before it
  published producer records, so that run is still repairable
- **Date (UTC):** 2026-09-29
- **Status:** proposed — awaiting human merge
- **Files:** `bin/firm-traceability-check`, `tests/test-traceability-check.sh`,
  `agent-firm/contracts/roles/qa-tester.md`

## Motivation

`firm-traceability-check --strict` required `traceability.yaml`'s `candidate` block to equal
`09-test-evidence/qa-candidate.json` exactly, including the absolute `repository_root`,
`git_common_dir` and `checkout_path`. On a repository under `/Users/<operator>/`, all three contain the
operator's home path. The evidence seal scans `traceability.yaml` against the `operator_home` deny
category, and its one exception covers only the two declared-metadata files. So a traceability file
that passes the strict check can never be sealed, and one that can be sealed can never pass the
check. Primary QA found this by running the seal pre-check before publishing, and stopped.

This is the fourth defect of the same family found on the path to sealing a real run on this host,
after PRs #16 and #18.

## Proposed change

`firm-traceability-check` accepts each of the three path fields either exactly as in
`qa-candidate.json` (unchanged) or in its repository-relative form, anchored at `qa-candidate.json`'s
`repository_root`: `.` for the root, `.git`, `.agent-firm/qa-checkout/<run-id>`. A relative value
must be exactly that projection, so it cannot climb out of the repository. All other candidate fields
still require exact equality, and the key set must still match exactly. The privacy policy and its
five-field exception are unchanged. The QA role contract tells QA to use the relative form.

## Generalizability check

- Applies beyond this project? Yes. It affects every run on a macOS operator's home-directory repository.
- Overfitting risk: low. The same identity is carried in a form that doesn't name the operator's home.

## Risk & rollback

- Risk: a relative value is now accepted where only an absolute one was. It must equal the projection
  of the value `qa-candidate.json` already binds, which the check itself validates against the live
  checkout, so the identity bound does not weaken.
- Rollback: revert this PR.

## Golden eval to guard it

- `tests/test-traceability-check.sh`, strict matrix: the relative form passes; a wrong relative
  checkout and a `../` escape fail. Without the fix, the relative-form case fails with `traceability
  candidate identity does not exactly match qa-candidate.json`.

## Human decision

- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
