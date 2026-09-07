# 10 · Handoff
<!-- The Packager first assembles a NON-SHIP-READY DRAFT. Finalize only after the applicable fresh
firm-final-qa-check exits 0 following the one FINAL human interaction. -->

- **Handoff state:** NON-SHIP-READY DRAFT | FINALIZED AFTER FRESH MECHANICAL PASS
- **Task slug:**
- **Candidate SHA (full 40 characters):**
- **Primary provider:** claude | codex
- **What was delivered:**
- **Acceptance criteria:** covered / partial / blocked (with current-SHA evidence paths)
- **Primary QA verdict:** APPROVE | BLOCK | pending (see 08-qa-verdict.json)
- **Cross-provider verdict:** APPROVE | BLOCK | unavailable (name provider, attempt/event, and required corrective action)
- **Final QA check:** PASS | BLOCK | not run — command: `firm-final-qa-check <run-dir>`
- **Final QA check run:** before-interaction exit ___; after-record fresh exit ___; evidence/event:
- **Decision-required artifact:** none | path, event id, SHA-256, kind
- **Exact objections:**
- **Permitted typed record options:**
- **Definition of Done:** verified | blocked (see policy/definition-of-done.yaml)
- **Platform evidence:** macOS Bash 3.2: pass/block/not run; modern Bash: pass/block/not run; interpreter versions and logs:
- **Live smoke evidence:** Codex-primary: pass/block/not run; Claude-primary: pass/block/not run (exact current SHA only)
- **Readiness statement:** distinguish this repair candidate from any predecessor BLOCK; do not call it ready without all required evidence
- **Changelog / docs:**
- **Migration / rollback notes:**
- **Known limitations & untested risks:**
- **One Final human decision:** approve | reject | exact permitted option — actor/date (UTC):
- **Typed record and ledger reference:** none | path, type, SHA-256, bytes, producer event
- **Finalization rule:** rejection, stale/mismatched record, or nonzero fresh check leaves this draft blocked; do not prompt again in this Final cycle

<!-- BEGIN COMPLETE LOCAL PR BODY -->
<!-- Replace this line with the complete local PR body before `firm-seal-qa-evidence`. -->
<!-- END COMPLETE LOCAL PR BODY -->
