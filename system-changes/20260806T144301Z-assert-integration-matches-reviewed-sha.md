# System Change PR: assert the integration HEAD matches a REVIEWED sha, not a branch tip

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260806T143345Z-closeout-record-matches-code`, from two reproduced incidents in
  `20260803T120043Z-cleanup-and-identity-gate`
- **Date (UTC):** 2026-08-06
- **Status:** proposed

## Motivation

**The same defect occurred twice in one engagement, and the Lead caught it neither time.**

The firm has a traceability gate that asserts every acceptance criterion is covered before a Final gate.
It has no equivalent assertion that the code being certified is the code that was reviewed.

### Incident 1 — integrated, then the branch moved

The Lead cut `integration/cg2` from the gate branch at `6f058df`. A later work-order (WO-E) added five
commits — **including the fix for the exact bypass the security reviewer had raised as merge condition 1**.
The integration branch was never refreshed. So the artifact proposed for merge contained the gate *with
the bypass still open*, and those five commits had been seen by no reviewer and no QA pass.

Caught by: **the Packager**, while reconciling suite numbers for the handoff. It measured `int-cg2` at
2019/0 against the brief's 2241/0 and refused to reconcile the difference silently.

### Incident 2 — re-integrated, and the wrong parity was checked

Told about incident 1, the Lead re-integrated and added an explicit check. **The check compared the
integration branch against the work-order branch tip.** It passed. Two further commits (WO-F: the SEC-19
parse-time bound and the framework-timeout measurement) were still unreviewed, because the reviewer's
sign-off was at `8fcb3a9` and the tip had moved to `acfa1ab`.

Caught by: **the GPT second-voice judge**, as a blocker:

> the latest security review targets `8fcb3a9` and does not review the subsequent `acfa1ab` changes now in
> `730ca7f`

**The lesson is not "be more careful."** A check was added after the first incident and it was the wrong
check — parity with the *tip* proves the integration is current, which is a different property from the
integration having been *reviewed*. The security reviewer's own formulation, which this PR adopts:

> The mechanical fix isn't "check parity with the tip" — that's what failed this time. It's to record the
> exact SHA each reviewer signed off, and assert before the Final gate that the integration HEAD's gate
> content is byte-identical to a reviewed SHA. Same shape as the traceability gate, applied to review
> coverage instead of criteria coverage.

### Why this is worth a firm change rather than a note

Both incidents were caught **downstream, by roles whose job is something else**. Neither was caught by the
role that created it, and the second happened *after* the first was known — the strongest available
evidence that vigilance is not the control. The engagement also ran five security passes; if the record of
which SHA each pass examined had been machine-checkable, incident 2 would have been a one-line failure
rather than a judge's blocker three stages later.

## Proposed change

- Files: `bin/firm-ledger-log` (or a new `bin/firm-review-coverage`), `CLAUDE.md`,
  `agent-firm/policy/gate-matrix.md`, `agent-firm/templates/07-review-findings.yaml`

1. **Record the reviewed SHA as structured data.** Every reviewer and QA verdict must carry the exact
   commit it examined. `08-qa-verdict.json` already has `commit_sha`; `07-review-findings.yaml` has no
   equivalent and should. Without this the assertion has nothing to compare against — and in this
   engagement the reviewed SHAs were recoverable only from prose in the findings file.
2. **Add `firm-review-coverage <run_dir> <integration_ref>`.** It fails unless the integration ref's
   *content* is byte-identical, over the reviewed paths, to a SHA that some review or QA artifact in the
   run dir records as examined. Content-identity rather than ancestry is the right test: a merge commit is
   never literally a reviewed SHA, but its tree can be identical over the paths that matter — which is
   exactly the check the Lead ran by hand as `git diff <tip> HEAD -- bin/ tests/ …` and which passed while
   still being the wrong baseline.
3. **Make it a Final-gate precondition**, listed in `gate-matrix.md` beside `firm-traceability-check`. The
   Lead must run it before presenting, using the binary from the branch under test.
4. **Fail closed, and say which SHA is missing.** If no artifact records a reviewed SHA, that is
   cannot-evaluate, not a pass — per this repo's never-rule, now closed in ten places.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes, and to any firm that reviews on branches and merges integrations.
  The failure needs only: parallel work-orders, a review that takes time, and an integration cut once. That
  is the firm's normal shape, not a quirk of this engagement.
- **Risk of overfitting:** low. The change is a comparison between two things the firm already produces
  (review artifacts, an integration ref). It adds no new concept — it applies the existing
  traceability-gate pattern to a second dimension.

## Risk & rollback

- **Risk:** a content-identity check over "reviewed paths" needs those paths defined, and a wrong
  definition either blocks legitimate merges (too broad — docs churn) or passes unreviewed code (too
  narrow — the real hazard). Start from the paths each review actually names and prefer too broad;
  a false block is visible, a false pass is not.
- **Second risk:** it may encourage treating a passing check as sufficient review. It is not — it proves
  only that the reviewed bytes are the merged bytes, never that the review was any good.
- **Rollback:** revert this PR (firm config is versioned in git). The check is additive; nothing depends on
  it until `gate-matrix.md` lists it.

## Golden eval to guard it

- Test: `tests/test-review-coverage.sh` (new)
- What it asserts, using the two real incidents as fixtures:
  1. Integration content identical to a recorded reviewed SHA → **pass**.
  2. Integration containing commits beyond every recorded reviewed SHA → **fail**, naming the unreviewed
     range. (Incident 1 and incident 2 are both this shape and both must fail.)
  3. Integration whose *tip parity* passes but whose *reviewed-SHA* check fails → **fail**. This is
     incident 2 exactly, and it is the case that distinguishes this control from the one that already
     failed.
  4. No review artifact records a SHA → **cannot-evaluate**, never pass.
- Feasibility: high — file-in / exit-code-out, no model involvement, constructible under `mktemp -d`. Case
  3 is the load-bearing one and is the reason to write this as a test rather than an eval.

## Evidence availability (read this before following a citation)

Every `.agent-firm/runs/...` path cited above lives in the **run ledger, which is not in git**. It is
excluded by **committed policy** — `.gitignore:32` (`.agent-firm/runs/`) — and additionally by a local
`.git/info/exclude:8`. **This PR is committable; its evidence is not.**

Both incidents are, however, independently reconstructable from committed history: the commit graph shows
`6f058df`, `100ab19`, `acfa1ab` and the integration merges, so a reader with a clone can verify *that* the
integration lagged, even without the findings file that records *which* SHA each reviewer examined. That
gap is itself the argument for `system-changes/20260803T101922Z-commit-the-decision-bearing-ledger.md`.

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
