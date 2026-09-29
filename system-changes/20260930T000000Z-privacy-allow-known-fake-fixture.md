# System Change PR: allow one known-fake fixture token in the sealed source diff

A change to the **firm itself** (not a project deliverable).

- **Proposed by run:** `20260928T213510Z-pr12-merge-guard-closeout-3` (blocked at `firm-seal-qa-evidence`)
- **Date (UTC):** 2026-09-30
- **Status:** proposed — the human chose this option at the seal block; awaiting merge
- **Files:** `agent-firm/policy/evidence-privacy.yaml`, `tests/test-evidence-seal.sh`

## Motivation

With the earlier seal defects fixed (#16, #18, #19), the PR #12 closeout run's seal reached the
candidate diff and blocked:
`PRIVACY_MATCH: 09-test-evidence/final-evidence/g1/candidate.diff:secret_assignment`.

It is the only match in the 1.33 MiB diff: a comment in `tests/test-judge-input-integrity.sh` (commit
`7c23e6d`, on the PR #12 branch) that describes a redaction regression: "Textual redaction caught
`` `password: hunter2` `` because the key and value sat in one string". `hunter2` is the conventional fake
password, and the test exists to prove that secrets are redacted. The `source_diff` surface had no
allow rule, so the only other ways past it were to change the candidate (a new SHA, redoing QA and
the handoff, and reopening the decision not to run further build rounds) or to abandon the second
voice.

## Proposed change

One allow rule, `known_fake_secret_fixture_hunter2`: category `secret_assignment`, surface
`source_diff` only, pattern `` password: hunter2` `` (the exact matched token, backtick included). The
seal full-matches the token against the pattern, so any other value, key, spacing or suffix still
blocks, and the same token on any other surface still blocks. The rule is appended, so existing rule
positions are unchanged.

## Generalizability check

- Applies beyond this project? No, not by itself: it names one literal. The general question it
  raises is still open: should the seal's secret categories apply to source diffs of test fixtures at
  all? That is a retrospective candidate, not part of this change.
- Overfitting risk: this is deliberately a one-token exception, not a class.

## Risk & rollback

- Risk: effectively none for real secrets; the exact string is a public joke password in a comment.
  Allowances are recorded in the privacy report, so the judge and a reader can see it was applied.
- Rollback: revert this PR (the PR #12 seal would then block again).

## Golden eval to guard it

- `tests/test-evidence-seal.sh`, case "the known-fake fixture allowance covers one exact token on
  the source diff and nothing else". The candidate's exact comment line is allowed on `source_diff`;
  the same line is still blocked on the handoff, verdict, traceability and test evidence; eight near
  variants are still blocked on `source_diff`. Without the rule, the case fails.

## Human decision

- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
