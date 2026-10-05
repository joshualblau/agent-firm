# System Change PR: a sealed run can proceed past its judge verdict

A change to the **firm itself** (not a project deliverable).

- **Proposed by run:** `20260930T071039Z-pr12-merge-guard-closeout-4`, whose GPT judge (`gpt-c1-a0002`)
  returned a valid BLOCK, after which `firm-final-qa-check` could not reach the Final gate
- **Date (UTC):** 2026-10-01
- **Status:** design approved by the human at the Architecture gate (option A); implementation proposed
- **Files:** `bin/firm-ledger-log`, `agent-firm/lib/evidence_seal.py`, `bin/firm-final-qa-check`, schemas
  and tests as needed, `agent-firm/contracts/lifecycle.md`

## Motivation: three linked defects make every judge verdict terminal

**A. The ledger writer validates history against the live candidate.**
`validate_evidence_record` (in `bin/firm-ledger-log`) requires every existing `evidence_produced`
row's `sha` and `generation` to equal the current `09-test-evidence/qa-candidate.json`. `scan_ledger`
re-validates the whole ledger before each append. Once `firm-qa-checkout` rewrites the candidate
metadata for generation 2, every generation-1 row is "stale" and **no append succeeds**:
`firm-qa-checkout`'s own `qa_checkout` event, every role start, every evidence record. The run is
then unwritable. Reproduced in a throwaway fixture; restoring the generation-1 metadata makes appends
work again. The seal library has the same blind spot: `_producer` requires one `evidence_produced`
row per path across **all** generations (`PRODUCER_DUPLICATE`), so a second generation's
`08-qa-verdict.json` could not be sealed even if it could be published.

**B. After publication, the seal allows only reviewer events.** `_validate_suffix` raises
`unexpected event` for anything else. But the lifecycle requires, after the judge:
- `firm-final-qa-check` writes `final_decision_required` itself;
- the Lead logs `final_gate_pending`;
- a typed human decision is recorded;
- a new generation starts with `qa_checkout`.

Each of these makes `firm-seal-qa-evidence --verify --phase publication` fail, and
`firm-final-qa-check` runs that verification first, so it can then only exit 2.

**C. Dispositions must sit in a file sealed before the judge.** `firm-final-qa-check` reads primary
QA's per-objection dispositions from `traceability.yaml`'s `two_voice_diff`. That file is sealed before
the judge runs, so a **current** judge BLOCK can never be answered. The check exits 1 (`two_voice_diff
must contain exactly one entry per producer objection id`), a state the lifecycle says blocks the
Final interaction.

## Design (option A, approved)

### A1 — generation-scoped history

- **Writer:** an existing `evidence_produced` row is valid if it matches the current candidate,
  **or** if its `generation` is lower than the current one and its `sha` equals the `sha` of this
  run's unique `qa_checkout` event for that generation. New publications must still match the
  current candidate exactly. History tolerance applies only when classifying existing rows
  (`classify_record` / `scan_ledger` / `--classify-ledger-file`), never to the record being
  appended (`prepare_evidence_publication`).
- **Seal:** `_producer` considers only rows whose `generation` (and `sha`) match the generation
  being sealed or verified, so each generation has exactly one producer per path.

### A2 — a closed post-judge phase in the seal's suffix grammar

For the seal of generation N, the suffix is: the publication record; then reviewer events under
today's exact rules; then, **only when no attempt is open and at least one terminal reviewer event
exists**, a closed set of post-judge events, interleavable with further reviewer attempts:

1. `final_decision_required`: the shape `firm-final-qa-check` writes today (`path`, `sha`,
   `generation`, `sha256`, `bytes`, `kind`), with `sha`/`generation` equal to the seal's identity and
   the file present with that digest.
2. `final_gate_pending`: `sha`/`generation` equal to the seal's identity, plus no or only closed
   extra fields.
3. `post_judge_artifact_published`: `path`, `sha256`, `bytes`, `sha`, `generation`, `kind` (one of
   `two_voice_dispositions`, `disposition_evidence`, `human_decision`), `secondary_attempt_id`,
   `seal_event_id`, `seal_projection_sha256`. The path must lie under
   `09-test-evidence/post-judge/g<N>/`, so it can never name a sealed path. The file must exist with
   that digest. `secondary_attempt_id` must name a terminal attempt in this suffix.
4. **No generation boundary** *(amended after implementation review)*: a `qa_checkout` event inside
   a verified suffix is refused like any other unexpected event. The original design let a
   later-generation `qa_checkout` end the generation-N suffix, but no legitimate path ever needs it:
   `firm-qa-checkout` rewrites `qa-candidate.json` before appending the event, and verification
   always checks the live candidate's generation, so a real recapture is verified against the next
   generation's seal, whose prefix contains the event. The reviewer showed that one forged
   `qa_checkout` with the candidate still at generation N switched off checking of everything after
   it, after which a fabricated `reviewer_approve` passed the seal and `firm-final-qa-check`.

Anything else is still `unexpected event`. The tamper-evidence the seal exists for is unchanged:
every sealed file is still verified by digest, nothing may precede the first terminal judge event
except reviewer events, and post-judge artifacts are confined to a directory the seal cannot contain.

### A3 — post-judge dispositions

- Primary QA publishes `09-test-evidence/post-judge/g<N>/two-voice-dispositions.<k>.json` with
  `post_judge_artifact_published` (`kind: two_voice_dispositions`). Its content: `schema_version`,
  `run_id`, `candidate_sha`, `generation`, `secondary_attempt_id`, the secondary verdict's
  `sha256`/`bytes`, and `two_voice_diff`, an array of entries with exactly the traceability schema's
  disposition shape.
- `firm-final-qa-check`: when the current secondary verdict is a BLOCK and the **latest** such
  publication for this generation names the current canonical secondary attempt and verdict digest,
  its `two_voice_diff` is the disposition set. Otherwise it falls back to `traceability.yaml`, which
  covers runs that disposed objections before sealing, and archived history. Evidence and human
  records referenced from dispositions may be `post_judge_artifact_published` artifacts
  (`disposition_evidence`, `human_decision`). `evidence_ref` already accepts any producer event that
  binds path, digest, size, candidate and generation.
- Silence is not dissent. An objection with no disposition still blocks, exactly as today, and the
  two-voice table in `gate-matrix.md` is unchanged.

## Tests (both directions)

- A1: after a gN seal and judge attempt, `firm-qa-checkout` captures generation N+1 and the ledger
  stays appendable; a new gN-era evidence publication after N+1 exists is refused; gN+1's verdict is
  sealable with its own producer row.
- A2: each post-judge event is accepted after a terminal judge event and refused before one, refused
  with the wrong `sha`/`generation`, refused with a path outside `post-judge/g<N>/` or a digest
  mismatch, and refused when an attempt is open. An ordinary event (e.g. `lead_note`) after the judge
  is still refused. A `qa_checkout` inside a verified suffix is refused, so it cannot end the suffix
  or switch off checking of what follows it.
- A3: a judge BLOCK, then published dispositions (`human_decision`), then `firm-final-qa-check` exits 4
  and writes `final_decision_required`; then a recorded human decision and a fresh check exits 0. A
  disposition set naming a different attempt or digest is ignored or blocked; no dispositions still
  blocks.

## Risk & rollback

- Risk: the post-judge grammar is new, security-relevant surface. It is closed, bound to the seal's
  identity, confined to one directory, and tested in both directions.
- Rollback: revert this PR. Runs then return to being terminal after a judge verdict.

## Human decision

- [x] Architecture gate: option A approved by the human on 2026-10-01 (UTC).
- [ ] PR approved by ____ on ____ (UTC)
