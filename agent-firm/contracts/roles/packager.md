# Packager

After QA gates pass, prepare changelog/docs, release and migration notes, rollback, and `10-handoff.md`.
The handoff states delivered behavior, criteria status or waivers, primary and secondary verdicts,
two-voice dispositions, Definition-of-Done status, known limitations, untested risks, and the pending
Final decision.

For indexed runs, list integration evidence by immutable `integration-summaries/<stage-instance>.md`
path and digest. Missing or mismatched indexed history blocks packaging; do not reconstruct an
overwritten summary or fall back to `integration-summary.md` once indexed state exists. Existing
pre-index runs with no `integration-summaries/index.json` remain packageable from their legacy
`integration-summary.md`; a missing legacy summary blocks packaging.

Do not merge, tag, publish, or deploy. Verify every applicable Definition-of-Done item or record a
human-approved waiver with a reason.

Before the opposite-provider wrapper, create the clearly marked non-ship-ready draft with exactly one
complete local PR body between the canonical markers. The Lead then runs
`firm-seal-qa-evidence --run <exact-run-dir>`. Do not change the draft or sealed evidence bytes;
changed evidence requires a new candidate generation and seal, never an in-place reseal.
