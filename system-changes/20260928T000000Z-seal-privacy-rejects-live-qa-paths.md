# System Change PR: the evidence seal's privacy scan rejects paths the live QA tools write on a macOS operator's repository

A change to the **firm itself** (not a project deliverable).

- **Proposed by run:** found before opening the third PR #12 closeout run, while checking the wedged
  run `20260925T053346Z-pr12-merge-guard-two-voice-closeout` against the seal after PR #16
- **Date (UTC):** 2026-09-28
- **Status:** proposed — awaiting human merge
- **Files:** `bin/firm-qa-checkout`, `bin/firm-qa-clean-check`, `agent-firm/lib/evidence_seal.py`,
  `agent-firm/schemas/qa-verdict.schema.json`, `agent-firm/contracts/roles/qa-tester.md`,
  `tests/test-evidence-seal.sh`

## Motivation

No real run on this repository has ever sealed. The only protocol-v1 run wedged on
`DUPLICATE_DECLARATION` (fixed in PR #16). Running the seal's own privacy scanner over that run showed
two more failures that the duplicate fix could not reach:

1. **The ledger prefix.** Both mandatory QA steps write absolute paths into `run.jsonl`:
   `firm-qa-checkout` records `dir=<repo>/.agent-firm/qa-checkout/<run-id>` and
   `candidate=<run>/09-test-evidence/qa-candidate.json`, and `firm-qa-clean-check` records the same `dir`.
   On a repository under `/Users/<operator>/`, the seal's `operator_home` category rejects them
   (`PRIVACY_MATCH run.jsonl#prefix:operator_home`). No exception applies there. QA can't avoid it,
   and the append-only ledger can't be repaired afterwards.
2. **Command evidence.** The seal requires every `commands_run[].artifact` to be a command-result
   JSON whose `cwd` is canonical absolute. A QA command's cwd is the QA checkout, which on such a host
   lies under `/Users/<operator>/`, so the same scan rejects every command result. The verdict schema
   described the field only as "path to captured output", so QA had no way to know.

The seal's tests never caught either problem, because they hand-write `qa-candidate.json` instead of
calling `firm-qa-checkout`, and they seal no command results.

## Proposed change

Record fixed-location paths relative, following the precedent `_privacy_command_cwd` already set
for the sealer's own cwd, instead of widening the deliberately closed five-field operator-home
exception:

- `firm-qa-checkout` writes `dir=.agent-firm/qa-checkout/<run-id>` (repository-relative) and
  `candidate=09-test-evidence/qa-candidate.json` (run-relative). Both locations are fixed by
  construction, so no information is lost.
- `firm-qa-clean-check` writes the same relative `dir`, and matches a `qa_checkout` event in either
  form, so existing ledgers still verify.
- The seal accepts a command-result `cwd` that is repository-relative, provided it resolves to a real,
  non-symlinked directory inside the repository (`.` is the root). `..`, non-normalized paths,
  missing directories and symlinks are rejected.
- The verdict schema and the QA role contract now say that `commands_run[].artifact` is a
  command-result JSON, and that sealed bytes must pass the privacy policy.

## Generalizability check

- Applies beyond this project? Yes. It affects every macOS operator whose repositories live under their home
  directory, which is the default layout.
- Overfitting risk: low. Nothing is exempted from the scan. Paths that were always fixed by
  construction are simply recorded without the home directory.

## Risk & rollback

- Risk: a reader expecting an absolute `dir`/`candidate` in `qa_checkout` events. The only reader
  in the repository (`firm-qa-clean-check`) accepts both forms. A relative `cwd` narrows what a command
  result can claim: the directory must exist inside the repository and contain no symlinked component.
- Rollback: revert this PR.

## Golden eval to guard it

- `tests/test-evidence-seal.sh`, case "real macOS users hierarchy…". It now also builds a run under
  `/Users/<operator>/` with the **real** `firm-qa-checkout` and `firm-qa-clean-check` and a command
  result whose cwd is the QA checkout. It then requires the seal to publish and verify, the ledger prefix
  to carry no match and no exception, and the exception count to stay at five. Without the fix it fails with
  `PRIVACY_MATCH: run.jsonl#prefix:operator_home`. The direct command-result mutation matrix adds the
  accepted and rejected relative `cwd` forms.
- The case needs a supported P2 ledger-write host (the operator's Mac); hosted CI skips it by name, as
  it already did for that case.

## Human decision

- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
