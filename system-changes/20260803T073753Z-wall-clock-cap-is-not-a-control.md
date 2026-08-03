# System Change PR: the wall-clock stop condition exists and was never obeyed

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260803T051454Z-remediate-wave4` (engagement-level)
- **Date (UTC):** 2026-08-03
- **Status:** proposed
- **Revision:** **v3.** v1 claimed the cap was "breached 4 of 4 runs, far past 120 minutes" and asked to
  raise it 2–4×. An independent review
  (`.agent-firm/runs/20260803T092058Z-review-system-change-prs/07-review-findings.yaml`, F-01) found
  that measurement was **calendar span**, which in this engagement was dominated by the Lead waiting on
  the human. v1 was arguing to weaken a runaway-spend guardrail on a measurement error, and one of its
  four data points was not a breach at all. The thesis below is different and narrower.
  **v3 closes S-08** — the table's live-run row — and re-measures every row from scratch. See
  *Measurement provenance* below.

## Motivation

`agent-firm/policy/execution-budget.yaml:40` already contains the control:

> `- any cap above is reached -> stop the offending agent, log budget_or_usage_limit, escalate to Lead`

**It was never executed.** Across the **seven closed** ledgers in `.agent-firm/runs/` — 3,210 events —
**not one event has `event: budget_or_usage_limit`.** (Eight run dirs exist; the eighth is the run
writing this and its count changes with every command, so it is excluded to make the figure
reproducible. That is the S-08 discipline applied to a second number in the same document.) The Lead
noticed the overrun at Package time each run and reported it in the retrospective as prose. The policy
is not missing — compliance is.

That sentence has to be stated as an *event-field* claim, not a grep, and this is not pedantry: a plain
`grep -l budget_or_usage_limit .agent-firm/runs/*/run.jsonl` now matches **two** ledgers, because the
string appears inside the `cmd` field of `bash` events belonging to agents who went looking for it. The
check that means what this PR means is:

```
$ python3 -c '...for l in open(p): json.loads(l).get("event")=="budget_or_usage_limit"...'
  20260801T203648Z-evaluate-remote-changes/run.jsonl: 0
  20260802T145947Z-remediate-remote-delta/run.jsonl: 0
  20260802T192726Z-remediate-wave2/run.jsonl: 0
  20260803T051454Z-remediate-wave4/run.jsonl: 0
  20260803T075321Z-close-import-yaml-failopen/run.jsonl: 0
  20260803T092058Z-review-system-change-prs/run.jsonl: 0
  20260803T102953Z-close-phantom-coverage-failopen/run.jsonl: 0
SEVEN CLOSED runs: total events=3210   events with event==budget_or_usage_limit: 0
```

A future `bin/firm-budget-check` (proposal 3) must match on the event field for the same reason.

### Measurement — re-derived from the ledgers on 2026-08-03, all eight runs

Method: parse every `run.jsonl` timestamp, sort, take `last - first` as calendar span, then subtract the
sum of inter-event gaps > 20 minutes (those are the Lead awaiting a human decision). Caps are from
`agent-firm/policy/execution-budget.yaml` (`fast_path` 20, `full_track` 120 — confirmed by reading it).

| Run | Track | Cap | Calendar span | Agent-active | >20 min gaps removed | Verdict |
|---|---|---|---|---|---|---|
| `evaluate-remote-changes` | full_track | 120 | 1103 | **211** | 26.9, 20.8, 358.6, 23.4, 462.5 | breached ×1.8 |
| `remediate-remote-delta` | full_track | 120 | 268 | **208** | 59.8 | breached ×1.7 |
| `remediate-wave2` | full_track | 120 | 588 | **151** | 415.8, 21.0 | breached ×1.3 |
| `remediate-wave4` | full_track | 120 | 158 | **57** | 78.5, 22.6 | **within cap (×0.5)** |
| `close-import-yaml-failopen` | **fast_path** | **20** | 88 | **88** | none | breached **×4.4** |
| `review-system-change-prs` | **fast_path** | **20** | 69 | **69** | none | breached **×3.4** |
| `close-phantom-coverage-failopen` | **fast_path** | **20** | 91 | **39** | 24.6, 27.6 | breached ×1.9 |
| `cleanup-and-identity-gate` | full_track | 120 | *in progress* | *in progress* | — | **deliberately not numeralised** |

**Measurement provenance — this is what S-08 was about, and the row is instructive enough to keep.**
The `review-system-change-prs` row has now been printed with four different values in four drafts:
**×1.2** (v1, written ~09:44Z while the run was live), **×1.8** (second review, ~09:58Z), **×3.0**
(third review, at 60.1 min), and **×3.4** now that the run is closed at 68.9 min. Every one was
arithmetically correct on the ledger as it stood; every one was superseded within the hour. The lesson
is not "the earlier numbers were sloppy" — it is that **elapsed time on a live run is not a
measurement**, and a document arguing for honest measurement must not print one. Hence the last row
above carries no number: this run is still open as this is written. It gets a figure when it closes,
or it gets none.

Two caveats a reader should be able to check, because they bound every figure above:

- **Each run's final event is its successor's creation.** `.agent-firm/CURRENT_RUN` still points at run
  N when the Lead runs `firm-new-run` for N+1, so N's ledger records that command. Every span therefore
  ends at "the moment the next run was opened", not at N's true last action — an over-estimate bounded
  by the 20-minute gap filter. Verified: `close-import-yaml-failopen`'s last event is
  `firm-new-run review-system-change-prs fast_path`, timestamped identically to the successor's first.
- **~50% of every ledger is a byte-identical duplicate of the preceding line** (measured: 47–51% across
  all eight, e.g. 473 of 932 lines in `remediate-remote-delta`). The PreToolUse ledger path writes each
  `bash` event twice. This does not move any span or gap — the duplicate carries the same timestamp —
  but it does mean **every event count in this engagement's artifacts is roughly double the number of
  real events**, and it halves `run.jsonl`'s information per byte. Out of scope here; carried forward as
  a named defect.

Three corrections to the record this changes:

1. **`full_track` is roughly right.** 3 of 4 breached, by 1.3–1.8×, not "far past". A modest raise is
   arguable; a 2–4× raise is not, and v1's most-cited row (wave4, "four subagents breached a
   120-minute cap") used **57 minutes**.
2. **`fast_path`'s 20-minute cap is the badly-broken one**, and v1 did not mention it. **All three**
   completed fast_path runs breached it — by ×4.4, ×3.4 and ×1.9. Per-subagent duration is **not**
   recorded in any ledger (there are no agent-completion events), so the claim that a single Opus
   implementer typically exceeds 20 minutes is an impression from this engagement, not a measurement —
   flagged as such rather than left reading like data. The review's generalizability finding is that
   this is the cap a *small* project actually hits — so v1 would have legitimised long full-track runs
   while leaving the real problem untouched.
3. **The `fast_path` evidence is no longer a single run.** Second review's caveat — "the fast_path
   figure rests on a single run, which is thin evidence for a policy number" — was true when written and
   is now obsolete: there are three completed fast_path measurements (39, 69, 88 agent-active minutes).
   Three is still thin, but it is a *distribution*, and it changes the recommended number (see
   proposal 2). Recorded as a correction rather than silently updated, because the caveat is quoted in
   this PR's own Generalizability section.

Cited: all four `11-retrospective.md` files (SC-1);
`20260803T092058Z-review-system-change-prs/07-review-findings.yaml` F-01, F-02, F-03, S-08.

## Proposed change

- Files: `agent-firm/policy/execution-budget.yaml`, `CLAUDE.md`, `commands/start.md`

1. **Define what the cap measures.** State in `execution-budget.yaml` that
   `max_wall_clock_minutes` is **agent-active time, excluding time awaiting a human decision**.
   The ambiguity is what produced v1's error, and any future Lead will make the same mistake.
2. **Re-baseline `fast_path` to a realistic figure.** Three completed fast_path runs now measure
   **39 / 69 / 88** minutes agent-active (`close-phantom-coverage-failopen`;
   `review-system-change-prs`; `close-import-yaml-failopen` — the last carrying **two** work-orders plus
   review and QA, `757782b`, `e927f13`). A cap of **90** covers all three observations; **70** covers two
   and would have stopped the outlier. Either is defensible and the choice is the human's; what is not
   defensible is 20, which every fast_path run in the firm's history has breached. Leave `full_track` at
   120 or raise it modestly to ~180, citing the measured 151–211 range — not 240–480 as v1 proposed.
   *(Second review: v1 of this proposal called the 88-minute run "one-work-order". It was two.)*
   **Coupling a reviewer should check before approving a number** (found by re-reading this PR's own
   guard section, below): the proposed test asserts every `fast_path` cap is *strictly below* the
   corresponding `full_track` cap. Today that holds on all seven dimensions (1<3, 4<12, 25<60, 20<120,
   15<80, 2<3, 1<4). A `fast_path` wall-clock of 90 against an unchanged `full_track` 120 still holds,
   but with a 30-minute margin — and any later nudge of `fast_path` past `full_track` turns this
   proposal into a *test failure* rather than a policy question. If the human picks 90, raise
   `full_track` to 180 in the same edit so the invariant keeps real headroom. The two numbers are not
   independent, which v1 and v2 of this document both treated them as.
3. **Make the existing stop condition executable rather than aspirational.** It says "log
   `budget_or_usage_limit`, escalate to Lead" but nothing computes elapsed time. Give the Lead a
   concrete obligation with a mechanism: check elapsed agent-active time at each stage boundary, and on
   breach log the event **and pause to the human** with continue / narrow-scope / stop. Without a
   mechanism this remains a rule that reads well and never fires.
   *(S-04, still open and still the reason this PR should not be approved as one item. The reviewer's
   two options were (a) put `bin/firm-budget-check [run_dir]` with a 0/1/2 contract in scope, or (b)
   split proposal 3 into its own PR. Evidence has since accumulated for (a): the reconstruction script
   has now been written **three** independent times — by the reviewer, by the Lead, and again by this
   run — each time thrown away. A measurement three people have re-implemented is a tool. It is still
   not in this PR's scope, and this PR does not claim it is.)*

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes, and more so than v1. Proposal 1 (define the unit) and proposal 2
  (`fast_path` is unusable as capped) affect every project, especially small ones. v1's full_track-only
  raise was the least generalizable part and is dropped.
- **Risk of overfitting the firm to one repo:** the `fast_path` figure now rests on **three** measured
  runs, not one (39 / 69 / 88 min) — still a small sample and still all from this repo, so treat the
  number as an estimate, not a law. *(Updated in v3: this bullet previously said "a single measured run",
  which was true when written and is no longer. Corrected here because it is the sentence that grades
  proposal 2.)* Prefer the "define the unit" change, which is correct independent of any number.
- **What does not generalise at all:** the ×4.4 outlier is a fast_path run that carried two work-orders.
  That is a *track-selection* defect, not a cap defect — the Lead chose fast_path for work that was
  full_track shaped. Raising the cap makes the symptom go away and leaves the misclassification. A
  reviewer should weigh whether proposal 2 is fixing the number or hiding the judgement.

## Risk & rollback

- **Risk:** any raise weakens a spend guardrail. Mitigated by making the cap *enforced* (proposal 3) —
  an obeyed 180 beats an ignored 120. The honest residual: proposal 1 makes the cap *harder* to breach
  by excluding human-wait time, which could mask a genuinely runaway run that spends most of its span
  idle. Accepted because the alternative — the current ambiguity — produced a false claim in v1 of this
  very document.
- **Risk introduced by proposal 1's own unit, measured.** Excluding >20-minute gaps is not a small
  correction: on `evaluate-remote-changes` it removes 892 of 1103 minutes (81% of the span), and on
  `remediate-wave2` 437 of 588 (74%). A cap defined this way cannot bound calendar duration at all. If
  the human wants a bound on "how long before I hear back", that is a **second, separate** number and
  this PR does not propose one. Naming it because the excluded 81% is exactly the interval a human
  experiences as the run taking a day.
- **Rollback:** revert this PR (firm config is versioned in git).

## Golden eval to guard it

**v1's eval was rejected as vacuous** (it named a ledger-event verb that does not exist in
`bin/firm-check-assertions`, and `final_gate_pending: true` is true on every correct headless stop, so
it would have passed the way `qa-blocks-broken-build` originally did).

- Test, not eval: `tests/test-execution-budget.sh`
- What it asserts: that the documented cap semantics and the `fast_path`/`full_track` figures in
  `execution-budget.yaml` parse, are internally consistent, and that `fast_path` caps are strictly
  below `full_track` caps on every dimension. This is a real, checkable property.
- **Premise executed against the real policy file, not reasoned about** (`agent-firm/policy/
  execution-budget.yaml` at `b1868eb`): the invariant holds today on all seven dimensions —
  `max_specialists_concurrent` 1<3, `max_subagents_total` 4<12, `max_turns_per_agent` 25<60,
  `max_wall_clock_minutes` 20<120, `max_files_changed` 15<80, `max_test_repair_loops` 2<3,
  `max_review_panel_size` 1<4. So the test would pass on day one, which is what a regression pin should
  do. **But there is a third track**: `greenfield_build` has caps *identical* to `full_track` on every
  dimension. A test written as "`fast_path` < every other track on every dimension" passes; one written
  as "each track is strictly below the next" **fails immediately** on the `full_track` /
  `greenfield_build` pair. The assertion has to be stated against `full_track` specifically, and
  `greenfield_build`'s equality has to be asserted as *deliberate* (it is — the policy file says the
  caps are per-run and greenfield is delivered as multiple runs). An implementer who did not read the
  third track would ship a red test. Stated here so nobody has to discover it.
- **Honest limitation:** whether the *Lead* obeys the stop condition is agent behaviour, and this firm
  has no mechanism to assert it from a test. Proposal 3 is therefore guarded by nothing today. Naming
  that gap is better than shipping an eval that appears to cover it. A future durable-runner seam
  (documented but unshipped, see `docs/PHASE5.md`) is where this becomes assertable.
- **Second honest limitation, newly visible from the measurement above:** even a shipped
  `firm-budget-check` could not have fired *at a stage boundary* inside the runs measured here, because
  the ledger barely marks stage boundaries. Executed against the seven closed ledgers:

  ```
  total events 3210 -- bash 2992 (93.2%) | qa_clean_check 192 (6.0%)
    run_started 7 | agent_spawn 5 | gpt_qa 5 | worktree_created 2 | run_start 1
    recon_complete 1 | gate_decision 1 | review_panel_wave1 1 | qa_sandbox_pass_complete 1
    qa_verdict 1 | final_gate_decision 1
  ```

  99.2% of the stream is `bash` + `qa_clean_check`. **26 events in seven runs** are anything else, and
  there is **no agent-completion event of any kind** — `agent_spawn` appears 5 times with no matching
  close, so per-subagent duration is not merely unrecorded (as noted above) but *unrecordable* from this
  schema. Proposal 3's "check at each stage boundary" therefore depends on ledger events that do not
  exist yet. That is a real prerequisite this PR does not carry — a further reason S-04 should be
  decided rather than bundled.
- [ ] Golden evals pass (`firm-run-evals`) — attach the run output. If an eval changed, explain why the
      new behavior is correct (not just newly-passing).

## Evidence availability (read this before following a citation)

Every `.agent-firm/runs/...` path cited above lives in the **run ledger, which is not in git**. It is
excluded by **committed policy** — `.gitignore:32` (`.agent-firm/runs/`) — and additionally by a local
`.git/info/exclude:8`. **This PR is committable; its evidence is not.**

*(Corrected on second review: an earlier version of this note claimed the exclusion was machine-local
only and "not a committed `.gitignore`". It is committed. The conclusion is unchanged but the remedy is
different — this is a deliberate project policy to revisit, not an accident to fix.)*

Consequences a reviewer should weigh:
- A future reader (including the author) cannot verify any citation from a fresh clone.
- The firm's first principle is "artifacts are the source of truth", and those artifacts are outside
  version control — so the source of truth is unreviewable by anyone but the machine that wrote it.

Found by independent review (F-22). **No longer an open question.** It is now a specific proposal:
`system-changes/20260803T101922Z-commit-the-decision-bearing-ledger.md`, whose shape was settled at the
Requirements gate of run `20260803T120043Z-cleanup-and-identity-gate` — tier A is the decision artifacts
`00`-`12` **plus `run.jsonl`** (measured 0.44 MB/run over seven closed runs, ~44 MB at 100 runs), and
bulk `09-test-evidence/` stays local but **curated**: the specific artifacts an approved PR cites are
copied into `system-changes/evidence/<pr-slug>/` so the document is checkable from a clone. That PR is
still `Status: proposed` and still needs its own approval; only its shape is settled.

*(Corrected on third review: this footer previously offered three undecided options and named a narrower
tier — `00`, `01`, `03`, `07`, `08`, `10`, `11`, without `run.jsonl`. That enumeration is superseded and was
stale in six files at once. `run.jsonl` in particular belongs in tier A: it is the only durable source for
the agent-active measurement in the wall-clock PR, and the judge-round attribution in the stop-rule PR is
recoverable from nothing else. Fixing it in one file and not the other five is the failure mode this batch
was rejected for three times.)*

## Third-review edit record (v3)

**Blocking edit closed: S-08** — the `review-system-change-prs` row was a live run's elapsed time. Every
row in the table was re-measured from the ledgers rather than copied forward; the live row now carries no
number, and the four values that row has held across four drafts are listed as the argument for that rule.

**AC-005 cross-section propagation — performed, and what it changed.** After the table and motivation were
rewritten, this PR's **Generalizability**, **Risk & rollback** and **Golden eval** sections were re-read
against the new text:
- *Generalizability* said the `fast_path` figure "comes from a single measured run". Now three. Corrected
  in place with a note, because that sentence grades proposal 2.
- *Risk* gained the measured size of proposal 1's own effect (81% of `evaluate-remote-changes`' span is
  excluded by the >20-minute rule) — the section previously described the risk qualitatively.
- *Golden eval* is where the propagation actually paid: reading it forced the discovery that the proposed
  assertion (`fast_path` strictly below `full_track` on every dimension) **couples to proposal 2's number**,
  and that a third track, `greenfield_build`, has caps identical to `full_track` — so a plausible phrasing
  of the assertion is red on day one. That coupling is now stated in proposal 2 itself.
- Batch grep for the changed claims: `budget_or_usage_limit` (this file only); the ledger-exclusion tier
  list (six files, all corrected — see the footer note); "single measured run" (this file only).

**Not closed, by design:** S-04. Proposal 3 still has no mechanism. The review's recommendation stands —
approve proposals 1 and 2, decide proposal 3 separately.

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
