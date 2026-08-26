# System Change PR: the merge guard writes a ledger record the ledger refuses to read

A proposed change to the **firm itself** (not a project deliverable).

- **Proposed by run:** `20260821T172243Z-reviewer-capability-probe`; the damage occurred in
  `20260821T034506Z-kehillat-ahuza-site`
- **Date (UTC):** 2026-08-21
- **Status:** proposed
- **Severity:** this one **destroys a run's ability to record anything further**. It is the most
  damaging of the three defects in this family, and unlike the other two it is not merely
  suppressive — it is corrupting.

## Motivation

`bin/firm-merge-guard:1437`, the **refusal** path, writes:

```python
ledger("merge_guard_block", {
    "decision": "refused" if code == REFUSE else "cannot_evaluate",
    "cmd": cmd[:2000], "matched": hit,
    "gh_login": gh_login or "", "gh_status": gh_status,
    "git_email": git_email or "", "git_status": git_status,
    "exit": code})
```

`bin/firm-ledger-log:382`, `classify_record`, accepts that event **only** in one exact shape:

```python
elif exact_keys(record, {"ts", "event", "cmd", "decision", "reason"}) and record.get("event") == "merge_guard_block":
```

The refusal record carries six extra keys (`matched`, `gh_login`, `gh_status`, `git_email`,
`git_status`, `exit`) and **omits `reason` entirely**, so it falls through to the ordinary-record
branch, which requires `run_id` and `event_id` it does not have, and raises `LedgerError`.

The guard's three other call sites (`:1331`, `:1349`, `:1365`) emit the narrow
`{decision, reason, cmd}` shape and classify correctly. **Only the refusal path is malformed** — the
path that fires precisely when the guard is doing its most important work.

### Observed consequence

In run `20260821T034506Z-kehillat-ahuza-site`, ten `merge_guard_block` records classified fine. The
eleventh — written when the guard correctly refused a QA tester's attack command — did not. From
that line on, **every read of that ledger raised, and no further event could be appended to the
run**. The failure surfaces as the opaque `firm-ledger-log: could not append target ledger`, with no
indication that a single record is responsible or which one.

Diagnosis required bisecting an 895-line ledger against a scratch run. The mode is silent: nothing
warns at write time, and the ledger stays readable by ordinary tools — only the firm's own reader
refuses it.

### Why this is worse than the sibling defects

- The capability and readiness defects **suppress** a check. This one **destroys the audit record**,
  which is the firm's stated state machine: "Artifacts, not chat memory, are the state machine."
- It is triggered by the guard **succeeding**. A run that never trips the merge guard is fine; a run
  where the guard does its job is bricked.
- Recovery requires either abandoning the run or editing an append-only ledger — the firm forbids the
  latter, so the defect forces a choice between two rules.
- Any run can hit it. It is not provider-specific, project-specific, or track-specific.

## Proposed change

- Files: `bin/firm-merge-guard` and/or `bin/firm-ledger-log`, plus tests and a golden eval.
- Summary:
  1. **Make writer and reader agree, from one definition.** The observation shapes the guard emits
     and the shapes `classify_record` accepts must come from a single declaration, so they cannot
     diverge. This is the same remedy adopted for the capability contract, and for the same reason.
  2. **Decide deliberately whether observation records are open or closed.** `merge_guard_permit` is
     accepted by event name with **no** key constraint, while `merge_guard_block` is pinned to five
     exact keys — an asymmetry with no evident rationale that is itself the bug's cause. Pick one
     posture per record family and enforce it in both directions.
  3. **A malformed observation record must not be able to brick a ledger.** An audit line the reader
     cannot classify should fail loudly **at write time**, where the writer can be fixed, rather than
     silently at every subsequent read. Whether an unclassifiable line is then quarantined, rejected
     at write, or read-skipped with a recorded warning is the design question this proposal opens.
     **It must not remain the case that one bad observation ends a run's ability to record its own
     decisions.**
  4. **Make the failure diagnosable.** `could not append target ledger` should name the offending
     line and why it could not be classified. Bisecting a ledger to find one record is not a
     reasonable diagnostic path.

## Generalizability check (reviewer)

- **Applies beyond this project?** Entirely. Every run of this firm, in both provider directions, on
  every track, is exposed the moment the merge guard refuses a command.
- **Risk of overfitting:** low. The remedy is a shared declaration and a write-time check, neither of
  which is specific to any repository or CLI.

## Risk & rollback

- **Risk:** low for the shape fix; the design question in item 3 carries the real weight. Loosening
  the reader to skip anything it cannot classify would trade a bricked ledger for a ledger that
  silently drops audit records — a worse trade on an artifact whose entire value is completeness.
  Failing at write time is the safer direction.
- **Rollback:** revert this PR; firm config is versioned in git.
- **Related records question:** any run that ever tripped the merge guard's refusal path may have a
  truncated-in-effect ledger. Worth an audit once this is fixed; that is a records question, not a
  code change.

## Golden eval to guard it

- **Eval:** `agent-firm/evals/merge-guard-ledger-shape/` (to be added)
- **What it asserts:**
  1. A record emitted by **every** guard call site, including the refusal path, is classifiable by
     `firm-ledger-log` — the regression that would have caught this defect.
  2. After the guard refuses a command, the run's ledger **remains appendable**.
  3. A deliberately malformed observation fails at **write** time with a message naming the record,
     and does not make previously-written records unreadable.
- [ ] Golden evals pass (`firm-run-evals`) — run BEFORE and AFTER; attach both outputs.
      Same caveat as the sibling proposals: the behavioural baseline is already red on unmodified
      `main`, so the structural pass and the firm test suite carry the regression gate.

## Human decision

- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:

## Evidence

- Offending record: `merge_guard_block`, `decision: refused`, keys
  `{cmd, decision, event, exit, gh_login, gh_status, git_email, git_status, matched, ts}` — no
  `reason`. It was line 833 of 895 in the affected ledger.
- Ten sibling `merge_guard_block` records in the same ledger, all `decision: cannot_evaluate` with
  the narrow shape, classify correctly.
- Bisection: prefixes through line 832 append successfully; line 833 fails. A fresh run in the same
  repository appends normally, isolating the fault to the record rather than the environment.
- Recovery in the affected run was performed **only under explicit human authorization**, with the
  pre-quarantine ledger preserved byte-for-byte
  (`sha256 3b099031a9f5f1b4fe4d62d04cb64f82f35ce7b7662f717c180edf7a82f43c5e`), the removed record
  written to `run.jsonl.quarantine` with its provenance, and reinsertion verified to reproduce the
  original exactly. Logged as `ledger_record_quarantined`. **That recovery should not have been
  necessary and must not become a pattern** — which is what this proposal exists to prevent.
