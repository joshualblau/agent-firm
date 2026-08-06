# System Change PR: a stop rule for adversarial review

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260803T051454Z-remediate-wave4` (engagement-level)
- **Date (UTC):** 2026-08-03
- **Status:** proposed

## Motivation

`CLAUDE.md` states that the team never self-approves. What the firm's own documents disagree about is
whether the second voice can *block*: `CLAUDE.md:106` says the two-voice rule requires **both** the Claude
QA gate and the independent Codex/GPT judge to APPROVE, while `agent-firm/policy/gate-matrix.md:64` says
the judge is **advisory by default**. Proposal 4 below resolves that contradiction rather than restating
it, and the resolution narrows this PR. What *neither* document says, on either reading, is **what to do
when the second voice keeps blocking and keeps being right.**

*(Corrected on third review (S-16): this paragraph previously asserted the "both must APPROVE" reading as
settled fact, while proposal 4 four sections later asked the reader to pick between the two. A motivation
that assumes the answer to its own open question is the same body-versus-grading-section defect this batch
was rejected for; the difference here is that both halves were in the same file.)*

The judge ran five times across this engagement and found something real every time.

**This table has been wrong in some row in all three drafts, and each correction introduced a different
error (T-01 names it as the third consecutive failure). It has therefore been re-derived mechanically, and
the method matters more than the result** — see *How the table was rebuilt* below. Blocker text is quoted
verbatim from the judge's own emissions.

| Round | Where the verdict lives | What it found | Verdict on the finding |
|---|---|---|---|
| 1 | run 1 `gpt-qa.log` only (`md5 6e5a9569`) | `01-acceptance-criteria.yaml` was invalid YAML (Ruby Psych, line 252); AC-001's commit→group matrix was never produced; AC-020/AC-040 only partial; AC-051 violated by host scratchpad writes | all true — and a second broken YAML file it missed was found by the sweep it prompted |
| 2 | run 1 `gpt-qa.log` only (`md5 e3939745`) | `bin/firm-traceability-check` treated `covered=partial` as passing; **`04-staffing-plan.yaml` failed schema validation because `task_slug` is null and `03-decision-log.md` remained empty**; coverage incomplete (AC-002/014/020/040 partial, AC-016/051 not satisfied); `git diff --check` fails at `docs/INTERACTIVE-TEST.md:54` | all true — the first a live fail-open in the coverage gate; two runs reached a final gate with a null-`task_slug` staffing plan and an empty decision log |
| 3 | run 1 `08-qa-verdict.gpt.json` (`md5 c51fe25c`) | `Q5-full-vacuous-simulation.log` proves the negative eval `qa-blocks-broken-build` passes **8/8 with QA never invoked**; and **`.git/info/exclude` acquired an `.agent-firm/` rule *during* QA**, so the environment was not stable | true, and its single most valuable catch — the eval meant to prove QA blocks a broken build could not tell that QA had not run |
| 4 | run 2 `gpt-qa.log` only (`md5 2f51d7cc`) | The persisted `traceability.yaml` was still an uncovered template and `08-qa-verdict.json` contained none of AC-001..AC-011 in `acceptance_criteria_coverage`; AC-001 described behaviour the implementation contradicts; AC-011 genuinely violated | all true |
| 5 | run 2 `08-qa-verdict.gpt.json` (`md5 7005ad60`) | Intermediate-symlink escape in the harness `rm -rf`; `traceability_passes` inverting an exit code without classifying it | both true, both fixed in wave 4 |

**What T-01 corrected, and it is the substantive part.** Row 2 previously credited round 2 with
"`traceability.yaml` was still a template". It did not say that. A keyword scan of round 2's verdict object
finds `task_slug`, `decision-log`, `covered=partial` and `partial as passing`, and **not**
`traceability.yaml` — which belongs to **round 4**, where it already sits, and to round 1's AC-040
coverage-evidence field. To make room for the misplaced item, round 2's genuine second finding
(`03-decision-log.md` empty) had been dropped. Both are restored above. One further attribution worth
pinning while the row is being touched: `covered: partial` passing was **first raised as a round-1
warning** ("the traceability checker's regex fallback … treats partial coverage as passing") and escalated
to a round-2 blocker. Crediting round 2 with the blocker is fair; crediting it with the discovery is not.

### How the table was rebuilt — and why three of its five rows are not durably citable

The five rounds were re-extracted by parsing every balanced JSON object containing a `verdict` key out of
both `gpt-qa.log` files, discarding schema echoes and prompt echoes, de-duplicating by content hash, and
ordering by character offset into the UTF-8-decoded text.

**Read the `md5`s in this document as object hashes, not file hashes (F-DOC-03).** Every `md5` here and in
the table above is `md5(json.dumps(obj, sort_keys=True))` — the canonical form the de-duplication used.
Running `md5 <file>` against the two persisted verdicts therefore gives *different* digests, and a reader
who tries that first will conclude the block is fabricated. It is not; both readings reproduce exactly:

```
                                   CHAR offset   object md5   slice bytes md5 == md5 of the persisted file
round 3  evaluate-remote-changes      3278637     c51fe25c        c406f541    == 08-qa-verdict.gpt.json (12,942 B)
round 5  remediate-wave2              2625273     7005ad60        3fc09a51    == 08-qa-verdict.gpt.json  (9,796 B)

  object md5 = md5(json.dumps(obj, sort_keys=True));  slice bytes md5 = md5 of the balanced object
  taken at that CHARACTER offset and re-encoded UTF-8. Offsets are character positions in the decoded
  text, not byte positions — the logs are not pure ASCII.
```

That second column is the stronger claim and is why it is printed: the surviving files are not merely
*consistent with* rounds 3 and 5, they are **byte-identical** to the slices at those offsets. The
commit-the-ledger PR quotes the `c406f541`/`3fc09a51` form, because its block is labelled by filename.

```
20260801T203648Z-evaluate-remote-changes/09-test-evidence/gpt-qa.log   (3,304,543 chars)
  -> 27 raw verdict-shaped objects -> 4 DISTINCT with a non-empty blocker list
     #1 md5 05e4aef4  offset   203919  BLOCK  1 blocker: "verdict not yet produced"   <- stub, not a round
     #2 md5 6e5a9569  offset  1649787  BLOCK  5 blockers  -> ROUND 1
     #3 md5 e3939745  offset  2314645  BLOCK  5 blockers  -> ROUND 2
     #4 md5 c51fe25c  offset  3278637  BLOCK  5 blockers  -> ROUND 3
20260802T192726Z-remediate-wave2/09-test-evidence/gpt-qa.log           (2,644,887 chars)
  -> 30 raw -> 2 DISTINCT
     #1 md5 2f51d7cc  offset   965811  BLOCK  5 blockers  -> ROUND 4
     #2 md5 7005ad60  offset  2625273  BLOCK  5 blockers  -> ROUND 5
```

Five substantive rounds plus one stub. "Five" is confirmed. Two things follow that the previous drafts
could not have known:

- **`firm-gpt-qa` overwrites `08-qa-verdict.gpt.json` on each invocation, so only the LAST round of each
  run survives as a decision artifact.** The two persisted files hold round 3 (object `md5 c51fe25c`, file
  `md5 c406f541`) and round 5 (object `md5 7005ad60`, file `md5 3fc09a51`) — see the note above on the two
  hashings. **Rounds 1, 2 and 4 — including this PR's own corrected row 2, and round 4's
  id-reconciliation finding — exist nowhere but inside a 2.6–3.3 MB transcript under
  `09-test-evidence/`.** Three fifths of the evidence for this PR's central table is in the tier that is
  not committed and not curated. This is the single most concrete instance in the batch of the problem the
  commit-the-decision-bearing-ledger PR addresses, and it argues specifically for its curation clause
  rather than for committing everything.
- **Cite by content, never by object index.** The third review located round 2 as "verdict object 8 in run
  1's `gpt-qa.log`". This independent parse of the same bytes puts the same content at **distinct object
  #3, offset 2314645** — while raw object 8 (offset 1660995) is a *re-emission of round 1*. The blocker
  text the reviewer quoted matches round 2 exactly, so the finding was right; the locator was not
  reproducible. Two correct parses of one file disagree on numbering, so an index is not a citation. Every
  row above therefore carries an md5 and a **character** offset into the UTF-8-decoded text — not a byte
  offset; neither log is pure ASCII (3,312,028 bytes to 3,304,543 characters), and seeking to these numbers
  as byte positions lands mid-string. **A fourth wrong version of row 2 was the most
  likely outcome of this edit, and quoting content instead of counting objects is what prevented it.**

**Correction to this PR's first draft.** It credited the judge with catching the Lead's stale test
baseline (747/12 vs 749/10). That is **false** — the **Claude QA gate** caught it, and its own verdict
says so: *"this QA pod caught the 747/12-vs-749/10 baseline discrepancy at cefdb8e"*
(`20260802T192726Z-remediate-wave2/08-qa-verdict.json`). No GPT verdict mentions it; the figure appears
in `gpt-qa.log` only because the Lead's own brief was quoted into the judge's prompt. The draft also
misassigned rounds 2 and 4 and **omitted the judge's strongest catch entirely** (round 3 above).

That error originated in `12-owner-override.md` — the file this PR holds up as the model for the artifact's
*structure* — and propagated from there into this document unchecked. It has been corrected in both. It is
also the best available argument for this PR: a self-authored record of an override, unreviewed, acquired a
false attribution that made the overridden judge look *more* indispensable than the evidence supports.

*(Wording corrected on third review: this said "the file this PR proposes to bless as the template". After
T-06 the PR no longer proposes to bless it as a template at all — there is no `12-owner-override` template
and the clause depending on one was withdrawn. Fixed here rather than left, because it is a sentence in the
motivation citing a claim the guard section had just changed.)*

It never converged, and there was no reason to expect it to: each round examined a changed artifact, so
each round had new surface. Meanwhile its *residual* objections became structural — its sandbox denies
Docker and `mktemp`, so it cannot execute the suite it asks for, and one objection (a genuinely
violated read-only criterion, recorded as violated) cannot be un-violated by another pass.

The firm offered exactly two options at that point: loop forever, or override with no documented basis.
The engagement took the override and recorded it in `12-owner-override.md`, but that was an improvised
decision rule, not a firm one.

Cited: `20260803T051454Z-remediate-wave4/11-retrospective.md` (SC-12) and `12-owner-override.md`.

## Proposed change

- Files: `CLAUDE.md`, `agent-firm/policy/gate-matrix.md`, `commands/start.md`

1. **Encode the stop rule that actually worked.** A second-voice BLOCK may be escalated to the human as
   an override candidate when **all three** hold:
   - the branch is **strictly better than the baseline** on every measured axis — and **the axis set
     must be fixed before the override is sought, not chosen by the party seeking it.** The review's
     sharpest criticism of the first draft: condition (1) as written was unfalsifiable, because in this
     very engagement an axis on which the branch was *not* better (AC-011, recorded VIOLATED) was simply
     absent from the comparison the Lead presented. The axis set must come from the run's acceptance
     criteria, which are fixed earlier and by someone else. (The first draft cited "this engagement's
     table of 8 axes" as a model; no such table exists in `12-owner-override.md` — it is a prose list of
     defects closed. Citation withdrawn.)
   - every residual objection is **named, tracked, and carried forward** in the handoff; and
   - each remaining objection is **unresolvable by another round** — i.e. it is a limitation of the
     judge's environment, a recorded historical fact, or an accepted design tradeoff, rather than a
     defect another fix could close.
2. **Require the override to be a written artifact, not a shrug.** If the human overrides, the Lead
   writes `12-owner-override.md` quoting the judge's objections **verbatim** with a disposition for
   each. **It must name the run id and the verdict filename it disposes of**, because the BLOCK it answers
   routinely lives in a *different* run dir — that is what actually happened here, and a bare
   `08-qa-verdict.gpt.json` reference does not resolve (see the guard section: the existing file's own
   citation is broken for exactly this reason). This engagement's file is the model for the *structure* —
   verbatim quotes plus an indexed disposition list — but it is **not** currently a template in
   `agent-firm/templates/`, and this proposal does not add one. See T-06 in the guard section for why that
   matters and what was withdrawn as a result.
3. **Distinguish "judge unavailable" from "judge blocked" from "judge blocked on its own
   environment."** `firm-gpt-qa` already separates exit 3 (UNAVAILABLE) from exit 1 (a real judgement).
   The gate matrix should add the third case, because it is the one that recurs and the one that has
   no remedy inside the loop.
4. **Resolve a live contradiction this PR sits on top of — and here is the resolution, not the question**
   (S-16). Verified at `b1868eb`: `CLAUDE.md:106` says the judge is "two-voice — both must APPROVE";
   `agent-firm/policy/gate-matrix.md:64` says it is *"**advisory by default** and **REQUIRED for any run
   touching auth / permissions / crypto / PII**"*. Those cannot both hold, and which governs decides
   whether the situation this PR addresses is an *override* at all. Two drafts said "pick one", which
   leaves the load-bearing decision to the reader — the same inversion T-04 flagged in a sibling PR.
   **Decided:**
   - **`gate-matrix.md` is authoritative.** The second voice is advisory by default and REQUIRED for
     auth / permissions / crypto / PII. It is the more specific statement, it is in the policy directory
     the manual itself calls authoritative, and it is the one the code already matches (`firm-gpt-qa`'s
     exit-3 degradation path is a policy for an *advisory* gate).
   - **`CLAUDE.md:106` is amended to match.** It is a summary line in a phase-status paragraph, not a
     policy.
   - **This stop rule therefore binds only in the REQUIRED case**, because that is the only case where a
     BLOCK actually blocks. In the advisory case there is nothing to override and no artifact is owed.
     That materially narrows this PR, and the narrowing is the point — **but it does not narrow anything
     on this engagement's own history.** The five rounds sit on exactly two runs (1–3 on
     `evaluate-remote-changes`, 4–5 on `remediate-wave2`), and both touch permissions on their face:
     run 1's `01-acceptance-criteria.yaml` names `settings.json` 7 times, `auth` 3 and `permission` 2,
     and the run shipped a `settings-reconciliation.proposed.json`; wave 2's names `settings.json` 4
     times, requires a newly-created `settings.json` to be mode 0600 (`:41`), and puts owner ratification
     of the `settings.json` permissive-policy change explicitly out of scope (`:110`). Under the adopted
     rule the second voice would have been **REQUIRED on all five rounds**. The narrowing bites on future
     runs, not on these.
     *(Corrected on fourth review (F-DOC-05): this read "two of the five judge rounds tabulated above
     were on runs that would have been advisory-only" — an unnamed quantity, not derivable from any
     artifact, and contradicted by both runs' criteria files. It was the sentence quantifying the only
     "decided, not deferred" resolution in the batch, which is the worst place in the document for a
     number nobody can check.)*
   - **An override under this rule waives no other Final-gate precondition.** Verdict validation,
     acceptance-coverage traceability and ledger validation must still have been run and passed — see the
     criteria-before-Build and validate-run-artifacts PRs. An override answers the second voice, not the
     gate matrix.

   > ### PROPOSAL 4 IS ANSWERED — by the repository owner, 2026-08-07. This PR is still `proposed`.
   >
   > The contradiction proposal 4 raised (`CLAUDE.md:106` "both must APPROVE" vs
   > `agent-firm/policy/gate-matrix.md:64` "advisory by default", both verified at `ad817a9` as well as
   > at the `b1868eb` cited above) has been **settled by the repository owner**, not by a reviewer, and
   > is now canon in `agent-firm/policy/gate-matrix.md` §2 with the owner's instruction quoted verbatim
   > in `system-changes/20260807T000000Z-two-voice-rule-judge-binds-unless-qa-dissents.md` (`Status:
   > approved`). **The question is closed; this PR is not approved by that closure** — the stop rule
   > below and everything else here remains `Status: proposed`.
   >
   > **The owner's answer is not the one this section reached.** Proposal 4 decided "advisory by
   > default". The owner decided the judge's BLOCK **binds unless QA dissents**, with a bounded
   > escalation: high-risk dissent must be resolved (blocking); otherwise attempt resolution and, failing
   > that, record the judge's dissent and proceed on QA's decision. Neither "always binding" nor
   > "advisory".
   >
   > **Two claims in this PR are therefore stale and must be re-derived before it is approved.** Named
   > rather than silently rewritten, because they are this PR's own reasoning and its author owns the
   > repair:
   > - *This section's third bullet* — "**This stop rule therefore binds only in the REQUIRED case**,
   >   because that is the only case where a BLOCK actually blocks." Its premise is gone. Under the
   >   owner's rule a BLOCK blocks on **every** run absent QA dissent, so the stop rule's scope is
   >   **wider**, not narrower. The rest of that bullet — that the second voice would have been required
   >   on all five tabulated judge rounds — is unaffected; it was a claim about those runs' criteria
   >   files, not about the default.
   > - *The **Generalizability** section's third bullet* ("Narrowed on third review, following proposal
   >   4's decision"), which is downstream of the same premise.
   >
   > Also worth the author's attention: the owner's rule creates a case the stop rule does not cover —
   > case 2b, where a non-high-risk judge dissent is **recorded and carried** rather than overridden.
   > That is a third disposition alongside "fix it" and "override it", and it needs no
   > `12-owner-override.md`, because nothing is overridden.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes, and it is arguably the most portable lesson here. Any firm
  running an adversarial second voice needs a termination rule; without one, the two-voice rule is
  either theatre (overridden ad hoc) or a deadlock.
- **Risk of overfitting the firm to one repo:** the real risk is the opposite — that the stop rule
  becomes an easy exit. Condition (1) is only as strong as the axis set, which is why the axis set must be
  fixed in advance and drawn from artifacts **the overriding party did not author** — the run's own
  acceptance criteria and the prior handoff's named-defect list. Condition (3) forces an argument that no
  further work would help.
  *(Corrected on second review: this bullet previously called condition (1) "deliberately strict", which
  was the exact claim the first review refuted — the body was tightened and this sentence was left
  standing. Leaving a rebutted claim in the section that grades the proposal is the failure mode this
  whole PR is about.)*
- **Narrowed on third review, following proposal 4's decision.** **STALE as of 2026-08-07 — see the boxed
  note under proposal 4.** The owner's ruling replaced "advisory by default" with "binds unless QA
  dissents", so this bullet's premise no longer holds and the narrowing it describes does not follow.
  Left in place, marked, for the author to re-derive; not rewritten here. The text as written:
  The rule binds only where the second voice
  is REQUIRED (auth / permissions / crypto / PII). So its portability claim is narrower than the previous
  drafts implied: what generalises is the *shape* — a termination rule for an adversarial gate, plus a
  written, pointer-carrying disposition artifact — not the frequency. On this engagement's own history the
  rule would have bound on a minority of **runs** — 3 of the 8 run dirs' `01-acceptance-criteria.yaml`
  files mention `settings.json` / `auth` / `permission` at all — **but on all five of the judge
  rounds**, because every round landed on one of those three runs. Both halves matter and they point
  opposite ways: the narrowing is real going forward and cost this engagement nothing.
  *(Corrected on fourth review alongside F-DOC-05, which is where the round-level half was wrong.
  Caveat on the run-level half, stated because it weakens it: 4 of those 8 criteria files are still
  byte-identical to the template, so "does not mention permissions" is partly an artefact of a criteria
  file nobody filled in — a run with no criteria cannot be shown to touch anything.)*

## Risk & rollback

- **Risk:** a stop rule can be abused to dismiss a judge that is simply correct. This is a genuine
  hazard and the reason condition (3) exists — "we are tired of this" is not "unresolvable by another
  round".
- **The reassurance this section used to offer does not survive execution, and it is withdrawn.** It said
  "in this engagement the rule was applied only after the judge's *substantive* code findings were all
  fixed, not to dodge them." That is true of **wave 2's** five blockers — all five are dispositioned
  verbatim in `12-owner-override.md`. It is **false as a statement about the engagement**: running the
  proposed guard over all eight run dirs (see the guard section) shows
  `20260801T203648Z-evaluate-remote-changes` also holds a BLOCK verdict with five blockers, and **none of
  the five is dispositioned in writing: 0 of 5 appear verbatim in any override document, and the only one
  the override mentions at all — the negative eval that scored 8/8 with QA never invoked — is cited under
  *"Why the override was reasonable"* as a credit to the judge, not answered.** Two persisted
  second-voice BLOCK verdicts existed when this was measured; one was answered in writing and one was not.
  *(Corrected on fourth review (F-DOC-04): "none of them is dispositioned anywhere" outran its own
  measurement by one step — the measurement is verbatim-match, and the override does touch blocker 4's
  substance. The gap it illustrates is sharper stated exactly, not stated absolutely. Also pinned: the
  "two BLOCK verdicts" count is as of 2026-08-03; a third second-voice BLOCK has since been persisted by
  this batch's own `cleanup-and-identity-gate` run.)* The honest version of this risk bullet
  is therefore: *the hazard is not hypothetical — it has already happened once, silently, and nobody
  noticed until a proposed guard was run against the ledgers.* That strengthens the case for proposal 2
  and for the guard, and it is a better argument than the reassurance it replaces.
- **Rollback:** revert this PR (firm config is versioned in git). Note that the rule has no code behind it,
  so a revert restores the status quo exactly — which is also this PR's central weakness, not a virtue.

## Golden eval to guard it

**This section was rejected twice and is now replaced.** The first review found the proposed
`agent-firm/evals/second-voice-block-is-not-silently-passed/` unassertable: `verdict_is` reads only
`08-qa-verdict.json` and cannot see `08-qa-verdict.gpt.json`; the human-decision branch is unreachable
headlessly; and it duplicates `agent-firm/evals/gpt-judge-availability/`. The second review found I had
left it **unchanged** — the one finding I neither fixed nor acknowledged. Recorded plainly because a PR
about not silently passing a blocking review should not silently ignore one.

**Third review rejected the replacement too (T-05), by running it. The premise was wrong, so the
assertion could not be right. Fixed below — the scope first, then the assertion.**

The previous specification was: *given a run dir containing a BLOCK `08-qa-verdict.gpt.json`, a
`12-owner-override.md` must exist and must not be byte-identical to any template, and must contain a
disposition line for each blocker in that verdict.* Executed against all eight real run dirs:

```
VARIANT A -- exactly as previously specified
  evaluate-remote-changes            BLOCK(5 blockers) + NO 12-owner-override.md -> **FAIL**
  remediate-remote-delta             premise not satisfied (no gpt verdict) -> vacuous pass
  remediate-wave2                    BLOCK(5 blockers) + NO 12-owner-override.md -> **FAIL**
  remediate-wave4                    premise not satisfied (no gpt verdict) -> vacuous pass
  close-import-yaml-failopen         premise not satisfied -> vacuous pass
  review-system-change-prs           premise not satisfied -> vacuous pass
  close-phantom-coverage-failopen    premise not satisfied -> vacuous pass
  cleanup-and-identity-gate          premise not satisfied -> vacuous pass
  RESULT: fail=2   vacuous-pass=6   real-pass=0

Where the artifacts actually are:
  08-qa-verdict.gpt.json -> evaluate-remote-changes, remediate-wave2   (only these two)
  12-owner-override.md   -> remediate-wave4                            (the only one in the firm's history)
```

**The check never produces a real pass anywhere in the firm's history, and fails every run whose premise it
satisfies.** It is worse than the review found: T-05 named one false positive (wave 2); there are **two**.
And `remediate-wave4` — the single canonical instance of the behaviour this PR exists to govern — has no
GPT verdict at all, so the check evaluates nothing there and passes vacuously. That is the
`qa-blocks-broken-build` vacuity class, in the third revision of a section rejected twice for that class.

**The cause is a unit mismatch, and it is a fact about how the firm works rather than a bug in the
wording.** A BLOCK raised against run N's verdict was dispositioned in run N+1's override: wave 2's
five blockers were answered in `remediate-wave4/12-owner-override.md`, one run later. "The run dir" is the
wrong scope for the invariant.

**Scope decision: option (b), the forward pointer. Option (a) is withdrawn.** The review offered both.
Option (a) — require the disposition in the *same* run dir as the BLOCK — would require editing two closed
run ledgers to make history conform, which the commit-the-decision-bearing-ledger PR's own correction
policy forbids and which would falsify a record the human already signed off. A guard that can only be
satisfied by rewriting the past is not a guard. Option (b) is also the form the existing artifact **already
takes**, which is the strongest argument for it: `12-owner-override.md` names
`20260802T192726Z-remediate-wave2` and `08-qa-verdict.gpt.json` explicitly, and quotes all five of wave 2's
blockers verbatim.

- Test, not eval: `tests/test-second-voice-override.sh` (new)
- What it asserts, restated against the corrected scope: **an override document must name the run id and
  verdict file it disposes of; and for every blocker in that referenced verdict there must be a
  disposition marker.** The check follows the pointer rather than looking in the same directory.
- **Executed against the real ledgers, both directions, from the actual artifacts:**

  ```
  Does the ONE existing override carry a resolvable forward pointer?
    run ids named in 12-owner-override.md : 20260802T192726Z-remediate-wave2
                                            20260803T092058Z-review-system-change-prs
    verdict files named                   : 08-qa-verdict.gpt.json, 08-qa-verdict.json

  Are the referenced verdict's blockers verbatim in the override?
    --- 20260802T192726Z-remediate-wave2 (5 blockers)   -> 5 of 5 verbatim   => PASS (wave4-shaped)
    --- 20260801T203648Z-evaluate-remote-changes (5)    -> 0 of 5 verbatim   => FAIL (undispositioned)
  ```

  So the corrected check yields **one genuine pass and one genuine fail on real data** — exactly the two
  cases the review asked to see, and both drawn from ledgers rather than constructed. The FAIL is not a
  false positive: `evaluate-remote-changes` carries a BLOCK whose five blockers are **not dispositioned in
  writing** — 0 of 5 verbatim, and the single one the override touches at all appears there as a credit to
  the judge rather than an answer (F-DOC-04). That is a real gap in the record, surfaced by executing the
  guard, and it is the first thing this PR has produced that the firm did not already know.
  *(Matching note, so the numbers are re-runnable: both figures are whitespace-normalised substring
  matches. Wave 2's override line-wraps its five quotes, so a raw substring match scores it 1 of 5 and the
  guard would report a false FAIL on the one case that should pass. Any implementation of this check must
  normalise whitespace before comparing.)*
- **A defect in the existing artifact that only execution reveals, and it is why the pointer must be
  explicit.** `12-owner-override.md:16` says the objections are *"verbatim from `08-qa-verdict.gpt.json`"* —
  an unqualified filename, resolved relative to the document, and **there is no such file in wave 4's run
  dir**. The citation is already broken as written; it happens to be recoverable only because the same
  document names wave 2 elsewhere. A checker must require the run id *and* the filename together.
- **"A disposition per blocker" is checkable only as a COUNT, and only against markers that actually
  exist** (T-07's closing note, verified). The word "disposition" appears **once** in the real override, so
  a line-level grep for it finds nothing to count. What is countable is the `(N)` index markers under
  `## Disposition of each, at override time` — the real file carries `(4)`, `(5)`, `(2)`, `(3)`, `(1)`,
  i.e. all five, out of order. So the assertion is: *for each blocker index 1..N in the referenced verdict,
  a marker for that index appears in the override.* It is a count and a set-membership test, never a
  correspondence check — nothing can verify that disposition (3) actually answers blocker 3. Stated so
  nobody builds the impossible version.
- **The template-identity clause is withdrawn** (T-06). It required the override not to be "byte-identical
  to any template". Verified: `agent-firm/templates/` contains `00`, `01`, `02`, `03`, `04`, `06`, `07`,
  `08`, `10`, `11`, `system-change-pr.md`, `traceability.yaml` and `visual/` — **there is no
  `12-owner-override` template**, so the clause can never fire and adds nothing. Proposal 2 blesses wave
  4's file as "the template" without proposing to add it to `agent-firm/templates/`, which is the
  inconsistency. Either add it there as part of proposal 2 — at which point the clause becomes
  load-bearing, because copying the blessed file verbatim is then the likely failure mode — or drop the
  clause and rely on the per-blocker count, which is the part that discriminates. **This PR drops it.**
- **One home, and the dependency declared in the right direction** (T-07). The previous text simultaneously
  named a standalone `tests/test-second-voice-override.sh` *and* said the check "belongs *in* PR6's
  `firm-validate-ledger`", leaving an implementer unable to tell which artifact to build — and PR6 does not
  carry the invariant. Grepping PR6 for `override`, `second.voice` and `gpt` returns only its citation of
  `12-owner-override.md` as a source of the "14 items" error. **Decision: it stands alone**, as
  `tests/test-second-voice-override.sh`. The "belongs in PR6" sentence is deleted rather than reciprocated,
  because folding a cross-run pointer-following check into a single-run-dir artifact validator would widen
  that tool's contract for one caller. If a future reviewer prefers the other home, that is a change to
  PR6 and must be written there.
- **What it cannot assert, stated rather than implied:** whether the human actually decided, whether the
  three stop-rule conditions were honestly evaluated, or whether the override was reasonable. Those are
  judgement, and this firm has no mechanism to assert judgement. **The substance of this PR is therefore
  guarded by nothing mechanical** — which is the same flaw the wall-clock PR's proposal 3 **still carries**
  (its own guard section says "Proposal 3 is therefore guarded by nothing today", and S-04 is still open).
  Both should be gated as separate decisions rather than approved inside a batch.
  *(Corrected on third review (T-11): this previously said PR1 "was rewritten for exactly that flaw". It was
  not. PR1 was rewritten for a measurement error and a vacuous eval; its unmechanized obligation survived
  both rewrites. The old sentence flattered a sibling PR and weakened this one's own argument, which is the
  stronger version: two PRs in the batch carry the same unguarded-obligation flaw, and that is a reason to
  gate them separately rather than a reason to rank this one last.)*
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

## Third-review edit record

**Blocking edits closed: T-01 and T-05.**
- **T-01** — round 2's row credited the judge with a finding it did not make (`traceability.yaml` still a
  template, which belongs to round 4), and had dropped round 2's genuine second item
  (`03-decision-log.md` empty) to make room for it. Third consecutive draft in which this row was wrong.
  Rather than patch the row a fourth time, **every row was re-derived** by parsing both `gpt-qa.log` files
  for balanced verdict objects, de-duplicating by content hash and ordering by character offset. Each row
  now carries an md5 and an offset, because two correct parses of the same file assign different *indices* to
  the same object — an index is not a citation. Also restored: `covered: partial` was first raised as a
  round-1 warning and escalated to a round-2 blocker.
- **T-05** — the proposed guard was executed against all eight real run dirs and was wrong in both
  directions: **2 fails, 6 vacuous passes, 0 real passes**, including a vacuous pass on `remediate-wave4`,
  the only run in the firm's history that ever took an override. Worse than the review found, which named
  one false positive; there are two. Scope fixed first, per the review's option **(b)**: the override
  carries a forward pointer naming the run id and verdict file it disposes of. Option **(a)** — require the
  disposition in the same run dir — is **withdrawn**, because satisfying it against history would require
  editing two closed ledgers, which the commit-the-ledger PR's own correction policy forbids. The corrected
  check was then re-executed and yields one genuine PASS (wave4 -> wave2, 5 of 5 blockers verbatim) and one
  genuine FAIL (`evaluate-remote-changes`, 0 of 5) — the two real-ledger cases the review asked for.

**Non-blocking edits closed: T-06, T-07, T-11, S-16.**
- **T-06** — the "not byte-identical to any template" clause is **withdrawn**. Verified: there is no
  `12-owner-override` template in `agent-firm/templates/`, so the clause could never fire.
- **T-07** — one home picked (**standalone** `tests/test-second-voice-override.sh`); the "belongs in PR6"
  sentence is deleted rather than reciprocated, with the reason given. Also states that a
  disposition-per-blocker is checkable only as a **count** of index markers — verified against the real
  artifact, where the word "disposition" appears once and the countable structure is `(1)`..`(5)`.
- **T-11** — the claim that PR1 "was rewritten for exactly that flaw" is corrected: PR1 still carries it
  (S-04 open). The corrected sentence is a stronger argument for separate gating, not a weaker one.
- **S-16** — proposal 4 no longer says "pick one". It decides: `gate-matrix.md` is authoritative, the second
  voice is advisory by default and REQUIRED for auth/permissions/crypto/PII, `CLAUDE.md:106` is amended to
  match, and **this stop rule binds only in the REQUIRED case**. That narrows the PR, which is correct.

**AC-005 cross-section propagation — performed, and it forced a withdrawal.** After the table and the guard
section changed, this PR's **Generalizability** and **Risk & rollback** sections were re-read:
- *Generalizability* gained the narrowing that follows from proposal 4's decision (the rule binds on a
  minority of runs), and condition (1)'s mitigation is now stated as S-14 asked — the axis set must come
  from artifacts the overriding party did not author.
- *Risk* is where it paid. The section claimed "in this engagement the rule was applied only after the
  judge's substantive findings were all fixed, not to dodge them." Running the guard showed that is true of
  wave 2 and **false of the engagement**: `evaluate-remote-changes` holds a BLOCK with five blockers, none
  of them dispositioned in writing. The reassurance is **withdrawn** and replaced with the measured fact. A sentence
  that comforts the reader and does not survive execution is worse than no sentence.
- Batch grep for the changed claims: "PR1 was rewritten" (this file only); `12-owner-override.md` as
  "the template" (this file and PR7 — PR7's reference is to the *correction note* in it, not to template
  status, so it needed no change); "both must APPROVE" (`CLAUDE.md:106`, named in proposal 4 as the line to
  amend, not amended here since this is a document).

**AC-006 — every guard premise in this PR was executed against the real run dirs, and the raw output is
pasted in the guard section.** That is what produced T-05's real resolution, the undispositioned
`evaluate-remote-changes` BLOCK, and the discovery that `firm-gpt-qa` overwrites
`08-qa-verdict.gpt.json` so that **three of this PR's five rounds survive only inside `09-test-evidence/`**.

**Standing recommendation, unchanged:** this PR still has no mechanism behind its substance and should be
gated alone. It is no longer the weakest of the six on *accuracy* — every row is now content-addressed and
the guard is executable — but it remains the weakest on *enforceability*.

## Fourth-review edit record (2026-08-06)

Three findings from an independent document review (LENS-DOC), all re-derived here from the artifacts
rather than accepted from the finding text.

- **F-DOC-03 — the `md5`s are object hashes and the document never said so.** Every digest in the table
  and the rebuild block is `md5(json.dumps(obj, sort_keys=True))`; `md5 <file>` on the two persisted
  verdicts returns `c406f541` and `3fc09a51` instead. Nothing was fabricated — all six object digests
  reproduce exactly — but a reviewer's first check disagrees with the page, and in a batch about checkable
  evidence a hash that looks wrong is worse than no hash. The normalisation is now stated once, up front,
  together with the **stronger** fact it was hiding: the raw slices at offsets 3278637 and 2625273 are
  byte-identical to the two persisted files, so "these files ARE rounds 3 and 5" is provable by a better
  method than the one printed. Also corrected: the offsets are **character** offsets into the decoded
  text, not byte offsets — neither log is pure ASCII, so the distinction is load-bearing for anyone
  re-running the parse.
- **F-DOC-04 — "none of them is dispositioned anywhere" outran its own measurement.** The measurement is
  a verbatim match (0 of 5, reproduced). The override *does* touch blocker 4's substance, crediting "the
  negative eval that scored 8/8 with QA never invoked" under *Why the override was reasonable*. Restated
  exactly, which is a sharper illustration of the gap than the absolute was. The "two BLOCK verdicts"
  count is now dated, since a third has been persisted since.
- **F-DOC-05 — "two of the five judge rounds … would have been advisory-only" is not derivable.** The five
  rounds sit on two runs and both touch permissions on their face (counts quoted inline from their
  criteria files), so under proposal 4's adopted rule the second voice would have been REQUIRED on all
  five. Replaced with the checkable version, which is also stronger for the PR: the narrowing costs this
  engagement nothing and bites only on future runs. An unnamed quantity in the sentence that quantifies
  the batch's only "decided, not deferred" resolution is the same shape as the round-2 row that was wrong
  three times.

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
