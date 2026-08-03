# System Change PR: commit the decision-bearing ledger

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260803T092058Z-review-system-change-prs` (F-22 / S-28, promoted at the human's
  request)
- **Date (UTC):** 2026-08-03
- **Status:** proposed
- **Revision:** **v2 — rewritten to the tiering settled at the Requirements gate of
  `20260803T120043Z-cleanup-and-identity-gate`.** v1 proposed a three-tier split in which `run.jsonl` was
  excluded from the committed set alongside `09-test-evidence/`. That was wrong on the evidence: `run.jsonl`
  is the highest-value artifact per byte in the whole ledger and the only durable source for several claims
  the sibling PRs rest on. v1 also treated `09-test-evidence/` as a binary keep-or-drop; the settled shape
  is **curation**, not exclusion. Every figure below was re-measured for this revision.

## Motivation

`CLAUDE.md` first principle 1: *"Artifacts are the source of truth. The run-ledger on disk is the state
machine — not this chat."* **The run ledger is excluded from version control.** So the firm's declared
source of truth is unversioned, unreviewable from a clone, and silently mutable.

Four concrete consequences, all observed in this engagement. The fourth was found while rewriting this
document and is the sharpest.

1. **Every citation in the sibling System Change PRs is unresolvable from a fresh clone.** Those PRs are
   being committed; the `.agent-firm/runs/...` evidence they rest on is not. A reviewer on GitHub — or the
   author in six months — cannot check a single claim.
2. **A ledger artifact was edited after the fact.** `12-owner-override.md` carried a false attribution (it
   credited the GPT judge with a finding the Claude QA gate made); the Lead corrected it in place. The
   correction is visible only because the Lead chose to add a note saying so. Under version control that
   edit would be a diff whether anyone chose to disclose it or not. **Right now the audit trail depends on
   the good behaviour of the thing being audited.**
   *Measured addendum:* this was not the only post-hoc edit. In `remediate-wave2`,
   `01-acceptance-criteria.yaml` (05:05Z), `traceability.yaml` (05:06Z) and `08-qa-verdict.json` were all
   rewritten **after** `10-handoff.md` (04:20Z) — i.e. after a final gate had been presented. All three
   disclosed it in-document, which is the discipline proposal 5 makes a rule; but the *only* reason that is
   checkable today is file mtimes on one laptop.
3. **Claims about past runs cannot be checked.** Three rounds of review of these PRs turned up ~20 factual
   errors about what the ledgers contained — miscounts, misattributions, wrong line references. Each was
   caught only because the reviewer had filesystem access to the same machine. That is not a reviewable
   process; it is a trusted one.
4. **Three fifths of one sibling PR's central evidence exists only inside an uncommitted 2.6–3.3 MB
   transcript.** `bin/firm-gpt-qa` overwrites `08-qa-verdict.gpt.json` on each invocation, so **only the
   last judge round per run survives as a decision artifact.** The stop-rule PR's five-round table was
   re-derived for this batch by parsing `09-test-evidence/gpt-qa.log`; rounds 1, 2 and 4 — including the row
   that has been wrong in three consecutive drafts — have no durable artifact at all. Verified:

   ```
   08-qa-verdict.gpt.json present in : evaluate-remote-changes (md5 c51fe25c = round 3)
                                       remediate-wave2         (md5 7005ad60 = round 5)
   rounds 1, 2, 4          live in   : 09-test-evidence/gpt-qa.log only
   ```

   This is the strongest available argument for the *curation* clause specifically (proposal 3), rather than
   for committing everything or for committing nothing: the three lost rounds are a few hundred bytes of
   quoted blockers inside 5.9 MB of transcript.

### Measured cost — the reason this is a tiered proposal, not a toggle

Measured 2026-08-03 across the **seven closed** run dirs. The eighth run dir is live and its own byte count
moves with every command, so it is excluded to make these figures reproducible — the same discipline the
wall-clock PR adopted after S-08, applied here because this table is the one a reader will re-run.

| Tier | Total (7 runs) | Files | Per run | At 100 runs |
|---|---|---|---|---|
| **A** · decision artifacts `00`–`12` (incl. `05-work-orders/`) | 1.08 MB | 80 | 158 KB | ~16 MB |
| **A** · `traceability.yaml`, `run-baseline.json`, `integration-summary.md`, `system-change-pr.md` | 0.05 MB | 19 | 7 KB | ~1 MB |
| **A** · `run.jsonl` (machine event log) | 1.99 MB | 7 | 291 KB | ~28 MB |
| **A — total** | **3.11 MB** | **106** | **456 KB (0.44 MB)** | **~44 MB** |
| **B** · `09-test-evidence/` (bulk) | 7.43 MB | 118 | 1,087 KB | ~106 MB |
| **excluded** · `settings*.json`, `*.bak` | 0.02 MB | 3 | 2 KB | — |
| Everything | 10.56 MB | 229 | 1.51 MB | ~151 MB |

For scale, `.git` is currently **1.5 MB**. Committing everything would grow the repository roughly 7× from a
single engagement and reach ~151 MB at 100 runs — untenable for a plugin repo people install. **Tier A costs
~0.44 MB per run and ~44 MB at 100 runs**, which is ordinary for a decision record and is the tier this PR
proposes.

Three notes on the numbers, because a reviewer should be able to attack them:

- **The human settled this shape on a ~0.47 MB/run figure; it now measures 0.44.** Nothing was re-scoped —
  two smaller runs closed in between and pulled the mean down. The difference is not decision-relevant and
  is recorded rather than quietly conformed to.
- **`run.jsonl` is ~50% waste, and fixing that would nearly halve tier A.** Adjacent byte-identical
  duplicate lines run 47–51% across all eight ledgers (e.g. 473 of 932 lines in `remediate-remote-delta`):
  the PreToolUse ledger path writes each `bash` event twice. Deduplicated, `run.jsonl` is 146 KB/run instead
  of 291, and tier A becomes **0.30 MB/run / ~30 MB at 100**. That is a separate defect in a file `bin/`
  owns; it is **not** proposed here, but it means the 44 MB figure is an upper bound with a known, cheap
  reduction available.
- **`00`–`12` is not a sufficient glob, and this is a trap for the implementer.** `traceability.yaml` — the
  acceptance matrix, i.e. the most decision-bearing file in the run — has no numeric prefix, and neither
  does `run-baseline.json`, which records the default-branch SHA a rollback depends on. A naive
  `.agent-firm/runs/*/[01]*` pattern misses both. It also **sweeps in** three files that must not be
  committed: `settings.json.pre-merge.bak`, `settings.json.pre-permissive.bak` and
  `settings-reconciliation.proposed.json` — verbatim copies of `.claude/settings.json` permission postures
  left in run dirs as backups. The tier must be an explicit allow-list, never a prefix glob.

### Why `run.jsonl` is in tier A, against v1

v1 grouped `run.jsonl` with `09-test-evidence/` as bulk. It is the opposite: it is the highest evidentiary
value per byte in the ledger, and several claims in this batch are recoverable from nothing else.

- **It is the only source for the wall-clock measurement.** The sibling wall-clock PR's entire table —
  agent-active minutes per run, and the >20-minute human-wait gaps subtracted to get there — is derived
  purely from `run.jsonl` timestamps. There is no other record of when anything happened. That PR has been
  re-measured three times by three different agents; without `run.jsonl` in git, none of those measurements
  is checkable by a fourth.
- **It is the only place a negative claim can be established.** The wall-clock PR's load-bearing assertion
  is that *no* `budget_or_usage_limit` event was ever logged in 3,210 events across seven runs. A negative
  of that shape is unprovable from prose and unprovable from a summary; it requires the full event stream.
- **It is small.** 291 KB/run as-is, 146 KB deduplicated — 4% of what `09-test-evidence/` costs.
- **It is the artifact most likely to be silently mutated,** because it is append-only by convention and
  nothing enforces that. A committed `run.jsonl` makes a rewritten history a diff.

### The blocker that makes the obvious fix a no-op

**Editing `.gitignore` alone would change nothing.** Both rules exist, and the one actually in force is the
machine-local one:

```
$ git check-ignore -v .agent-firm/runs/20260803T051454Z-remediate-wave4/11-retrospective.md
.git/info/exclude:8:.agent-firm/    .agent-firm/runs/.../11-retrospective.md

$ cat -n .git/info/exclude | tail -2
     7  .agent-firm-worktree.env
     8  .agent-firm/

$ sed -n '31,32p' .gitignore
# Per-run ledgers live in the WORK project, not in the firm repo; ignore if generated here
.agent-firm/runs/
```

`git check-ignore` attributes the exclusion to **`.git/info/exclude:8`**, not to `.gitignore:32`. **Both must
be narrowed**, and they fail differently:

- `.git/info/exclude:8` (`.agent-firm/`) is (a) **broader** than `.gitignore:32`'s `.agent-firm/runs/`,
  (b) **machine-local**, so no commit can change it, and (c) **regenerated** — verified at
  `bin/firm-new-worktree:33`:

  ```
  excl="$(git rev-parse --git-common-dir)/info/exclude"
  for pat in '.agent-firm-worktree.env' '.agent-firm/'; do
    grep -qxF "$pat" "$excl" 2>/dev/null || printf '%s\n' "$pat" >> "$excl"
  done
  ```

  The script appends `.agent-firm/` on every machine that creates a worktree, for a legitimate reason
  (keeping per-worktree scratch out of git). **Any plan that does not fix the script will work on one
  machine and silently fail on the next.**
- `.gitignore:32` (`.agent-firm/runs/`) is committed, so it *can* be changed by this PR — but on its own,
  changing it accomplishes nothing while `:8` stands. A reviewer who sees only the `.gitignore` diff will
  believe the change landed.

## Proposed change

- Files: `.gitignore`, `bin/firm-new-worktree`, `bin/firm-new-run`, `CLAUDE.md`,
  `agent-firm/policy/definition-of-done.yaml`, plus a new `bin/firm-ledger-scan`

1. **Narrow the worktree exclude.** `bin/firm-new-worktree:33` must append `.agent-firm/worktrees/`, not
   `.agent-firm/`. That is the directory it actually needs hidden. **Ship a one-line migration note**,
   because existing machines carry the broad pattern and a commit cannot remove it.
2. **Commit tier A, by explicit allow-list.** `.gitignore` keeps `.agent-firm/worktrees/` and
   `.agent-firm/runs/*/09-test-evidence/` excluded, adds `.agent-firm/runs/*/settings*` and
   `.agent-firm/runs/**/*.bak`, and stops excluding the rest. Net addition: **~0.44 MB and ~15 files per
   run** — intake, criteria, decision log, staffing, architecture, work-orders, implementation summaries,
   review findings, verdicts, traceability matrix, handoff, retrospective, override, run baseline, and
   `run.jsonl`. Enumerate the set; do not use a prefix glob (see the third note under *Measured cost*).
3. **Curate cited evidence — this replaces v1's "inline the excerpt" rule.** Bulk `09-test-evidence/` stays
   local. But when a System Change PR (or a handoff) cites a path under it, the specific artifact is
   **copied into `system-changes/evidence/<pr-slug>/`** as part of approving that PR, and the citation
   points there. Two reasons this beats both alternatives:
   - Against committing all of `09-test-evidence/`: it is 1,087 KB/run against tier A's 456, and most of it
     is never cited by anything.
   - Against v1's "inline the decisive excerpt": an excerpt is authored by the party making the claim. The
     five-round table in the stop-rule PR is the counterexample — its rows were *wrong in three consecutive
     drafts*, each time in a way an excerpt would have faithfully reproduced. Copying the artifact preserves
     the reader's ability to disagree with the author's reading of it.

   Cost is small and measurable: the artifacts the six sibling PRs actually cite are the two `gpt-qa.log`
   files (5.9 MB — the one genuinely large case, and the one where an extract of the six verdict objects,
   ~12 KB, is the right curation) plus a handful of sub-100 KB logs.
4. **Scan before committing.** New `bin/firm-ledger-scan <run_dir>`: refuses to pass if a to-be-committed
   artifact matches credential patterns, absolute home paths, or environment dumps. Ledgers contain verbatim
   agent output — this engagement's secret scan covered the *delta*, never the ledger.
   **This is a hard prerequisite, not a nice-to-have. Nothing should be committed until it exists.**

   **It does not exist. Confirmed, not assumed:**

   ```
   $ ls bin/ | grep -c '^firm-'
   23
   $ ls bin/firm-ledger-scan
   ls: bin/firm-ledger-scan: No such file or directory     (exit 1)
   ```

   Twenty-three `firm-*` scripts, none named `ledger-scan`. **This PR ships no capability**; proposals 1–5
   are text, and proposal 4 names a tool that must be built, reviewed and tested under its own work-order
   before proposal 2 may be executed. A first target for it is already visible: the three
   `settings*.json` / `*.bak` files above are permission postures sitting in run dirs, and they are exactly
   what a scanner should refuse.
5. **State a correction policy.** Once a run closes, its committed artifacts are append-only: a correction
   is a new commit with a visible in-document note, never a silent rewrite. That is what the Lead did
   voluntarily in `12-owner-override.md` and in wave 2's three reconciled artifacts; this makes it the rule
   and makes violations diffable. **Note the coupling to the stop-rule PR:** its override guard was scoped
   to follow a *forward pointer* precisely because the alternative — requiring a disposition in the same run
   dir as the BLOCK it answers — would have required editing two closed ledgers. Under this proposal that
   becomes impossible rather than merely discouraged, which is the right outcome and is worth stating
   explicitly so the two PRs are approved consistently.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes, and this is the most portable of the batch. Every project run by
  this firm produces the same ledger and inherits the same gap: an audit trail that exists on one machine.
  A consulting engagement or a client project would want the decision record in git far more urgently than
  this repo does.
- **Risk of overfitting the firm to one repo:** the tier *boundaries* are drawn from this engagement's
  file-size distribution, which is a tooling-repo profile. A project generating large visual-regression
  artefacts would want a different cut — and note that `09-test-evidence/` is already 1,087 KB/run here with
  **no** visual baselines in play. The tiering *mechanism* and the curation rule generalise; the specific
  allow-list should be configurable, not hardcoded.
- **What does not generalise, and cuts against this PR:** in a *client* project, tier A is the tier most
  likely to contain material that must not be in a shared repo — intake notes, decision logs and
  retrospectives are where names, commercial terms and candid assessments live. The size argument says
  "commit tier A, skip tier B"; the confidentiality argument points the other way. This repo is the firm's
  own and the tension does not bite here, which is exactly why it must be written down before the pattern is
  copied. Proposal 4's scanner addresses credentials, **not** confidentiality, and cannot.

## Risk & rollback

- **Committing verbatim agent output is the real risk.** Ledgers hold full subagent transcripts, command
  output, and file paths. Proposal 4 mitigates but cannot eliminate it — a scanner catches patterns, not
  judgement. Anything committed is public if the repo ever is, and `git rm` does not remove history.
  **This is the reason to gate this PR on its own and not bundle it.**
- **`run.jsonl` is where that risk concentrates, and moving it into tier A moves the risk with it.** Every
  `bash` event carries a verbatim `cmd` field. Measured: 2,992 of the 3,210 events in the seven closed
  ledgers (93.2%) are `bash`, and their `cmd` values contain absolute home paths in essentially every entry.
  This is the single strongest argument *against* this revision, and it is not answered by asserting that
  `run.jsonl` is valuable — both are true. It is why proposal 4 is a hard prerequisite rather than a
  companion, and why the scanner's absolute-home-path rule is not optional.
- **Churn.** Every run adds ~15 files. `git log` becomes dominated by ledger commits unless they are batched
  (one commit per closed run) — worth specifying.
- **Half-measures are worse than either extreme.** Committing decision artifacts while leaving the evidence
  they cite unreachable leaves citations broken *and* adds weight. Proposal 3 is what prevents that, so 2
  and 3 must land together or neither should.
- **Second-order:** once the ledger is in git, `firm-new-run` writing template artifacts creates committed
  placeholders. Measured, and worse than v1 assumed: **63 artifacts across the eight run dirs are
  byte-identical to their templates**, including four `01-acceptance-criteria.yaml` and six
  `06-implementation-summary.md`. Under proposal 2 those become committed decision records that are in fact
  blank forms. The `validate-run-artifacts-at-write-time` PR is therefore a **hard prerequisite**, not a
  companion — a template committed as a decision record is a false record, and there are 63 of them waiting.
- **Rollback:** revert this PR; re-add the `.gitignore` entries. Already-committed ledgers stay in history —
  **this decision is not cleanly reversible**, which is itself an argument for the narrow tier. Note also
  that reverting the `.gitignore` change does **not** restore `.git/info/exclude:8` on a machine where
  proposal 1's narrowing has already been applied by hand.

## Golden eval to guard it

- Test: `tests/test-ledger-committable.sh` (new), plus extend `tests/test-new-worktree.sh`
- What it asserts:
  1. `bin/firm-new-worktree` appends `.agent-firm/worktrees/` and **never** the broader `.agent-firm/` —
     the regression that would silently re-hide the ledger on a fresh machine. This is the highest-value
     assertion here and it directly pins the blocker described above. Pure string check on a script.
  2. A run dir's tier-A artifacts are **not** ignored (`git check-ignore` returns non-zero for each,
     including the two that carry no numeric prefix, `traceability.yaml` and `run-baseline.json`), while
     `09-test-evidence/`, `settings*.json` and `*.bak` **are**. Both directions, and specifically the files
     a prefix glob would get wrong.
  3. `firm-ledger-scan` fails closed on a fixture containing a planted credential pattern, and passes on a
     clean fixture — **and returns its cannot-evaluate code, not a pass, on a run dir it cannot read.**
     (Per the sibling never-rule PR: a new gate script shipping without a cannot-evaluate outcome would be
     the next instance of that batch's defect class, in a tool written *after* the rule was proposed.)
- Feasibility: high for 1 and 2 — file-in / exit-code-out, no model involvement, constructible under
  `mktemp -d`. **Assertion 3 is not yet constructible: `bin/firm-ledger-scan` does not exist** (verified
  above). Stated rather than listed as though it were ready, since a test for an absent binary is the
  vacuity class this batch keeps rejecting.
- **Premise executed, where it is executable.** Assertion 2's premise was run against the current
  repository, and it is why the assertion is specified in both directions:

  ```
  $ git check-ignore -v .agent-firm/runs/.../11-retrospective.md
  .git/info/exclude:8:.agent-firm/     -> currently IGNORED (exit 0)
  ```

  Today every tier-A file returns exit 0 from `git check-ignore` — i.e. assertion 2 fails on all counts
  before proposal 1 lands, which is the correct starting state for a regression pin and confirms the test
  measures the right thing rather than passing vacuously.
- **Honest limitation:** whether a *human* reviews what gets committed is not assertable. The scanner is a
  floor, not a guarantee. Nothing here addresses the confidentiality concern raised under Generalizability.
- [ ] Golden evals pass (`firm-run-evals`) — attach the run output. If an eval changed, explain why the
      new behavior is correct (not just newly-passing).

## Sequencing

This PR must land **after** the `validate-run-artifacts-at-write-time` PR (63 template-identical artifacts
would otherwise be committed as decision records) and **after** proposal 4's scanner exists and has passed
its own review. Recommended order within the batch: never-rule → validate-run-artifacts → **this PR** →
firm-tools-resolution → criteria-before-Build → wall-clock → stop-rule.

## Evidence availability (read this before following a citation)

Every `.agent-firm/runs/...` path cited above lives in the **run ledger, which is not in git**. It is
excluded by **committed policy** — `.gitignore:32` (`.agent-firm/runs/`) — and, in force ahead of it, by the
machine-local `.git/info/exclude:8`. **This PR is committable; its evidence is not.**

This PR is the proposal to fix exactly that, so the irony is load-bearing rather than incidental: the
document arguing that the audit trail should be reviewable is itself unreviewable by the standard it
proposes. Every figure in it is reproducible from any checkout by walking `.agent-firm/runs/` — but only on
the machine that has it. If this PR is approved, the *first* curation under proposal 3 should be its own
measurements.

## Third-review edit record

**This document was rewritten in full**, to the tiering settled at the Requirements gate of
`20260803T120043Z-cleanup-and-identity-gate`. It carried no numbered blocking edit from the three review
passes — it was the newest PR in the batch and had not been reviewed. What changed and why:

- **Tier A now includes `run.jsonl`.** v1 grouped it with bulk evidence. A dedicated subsection argues the
  reverse from measurement: it is the only durable source for the wall-clock PR's entire table, and the only
  artifact from which that PR's load-bearing *negative* claim (no `budget_or_usage_limit` event in 3,210
  events) can be established at all, at 4% of `09-test-evidence/`'s cost.
- **`09-test-evidence/` is curated, not excluded.** v1's alternative — inline the decisive excerpt — is
  argued against explicitly: an excerpt is authored by the party making the claim, and the stop-rule PR's
  five-round table is the counterexample, having been wrong in three consecutive drafts in ways an excerpt
  would have faithfully reproduced.
- **`bin/firm-ledger-scan` is stated as a hard prerequisite that does not exist**, with the `ls` output
  showing 23 `firm-*` scripts and no `ledger-scan`. The document asserts no capability that ships with it.
- **The `.git/info/exclude:8` vs `.gitignore:32` analysis is kept and sharpened**: both must be narrowed,
  `git check-ignore` output shows which one is actually in force, and `bin/firm-new-worktree:33` is quoted
  verbatim as the regenerating source.

**AC-005 cross-section propagation — performed.** Because the tiering changed, the sections that grade it
were re-read and all three changed:
- *Generalizability* gained the argument that cuts **against** this PR — in a client project tier A is the
  tier most likely to hold confidential material, so the size argument and the confidentiality argument
  point in opposite directions, and proposal 4's scanner cannot address the second.
- *Risk* gained the consequence of moving `run.jsonl` into tier A: 93.2% of ledger events are `bash` events
  carrying verbatim `cmd` fields with absolute home paths. That is the strongest argument against this
  revision and it is stated as such rather than answered.
- *Golden eval* gained a third direction for assertion 2 (the two tier-A files that carry no numeric prefix,
  which a prefix glob would silently drop), the note that assertion 3 is **not constructible** because the
  binary does not exist, and the executed `git check-ignore` premise showing the assertion currently fails
  on every tier-A file — the correct starting state for a pin.
- Batch grep: the shared evidence-availability footer named a narrower tier without `run.jsonl` in **six**
  files; all six were corrected in the same pass with a visible note, including the already-committed
  `validate-run-artifacts-at-write-time.md`. Leaving a superseded enumeration in five siblings is the exact
  propagation failure this batch was rejected for three times.

**AC-006 — every figure and every premise in this document was executed, not estimated.** The tier table,
the 50% duplicate-line rate, the 63 template-identical artifacts, the `git check-ignore` attribution, the
`firm-new-worktree:33` quote, the missing `firm-ledger-scan`, and the three stray `settings*`/`*.bak` files a
prefix glob would sweep in — all measured against the real run dirs at `b1868eb`. The three
`settings*`/`*.bak` files and the 63 templates were both found this way and neither appeared in v1.

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
