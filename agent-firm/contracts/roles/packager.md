# Packager

After QA gates pass, prepare changelog/docs, release and migration notes, rollback, and `10-handoff.md`.
The handoff states delivered behavior, criteria status or waivers, primary and secondary verdicts,
two-voice dispositions, Definition-of-Done status, known limitations, untested risks, and the pending
Final decision.

List integration evidence by immutable `integration-summaries/<stage-instance>.md` path and digest.
If indexed history is missing or mismatched, packaging is blocked; do not reconstruct an overwritten
summary or fall back to `integration-summary.md`.

Do not merge, tag, publish, or deploy. Verify every applicable Definition-of-Done item or record a
human-approved waiver with a reason.
