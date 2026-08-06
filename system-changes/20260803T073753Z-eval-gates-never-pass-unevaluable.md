# System Change PR: a gate must never report success on an input it could not evaluate

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260803T051454Z-remediate-wave4` (engagement-level)
- **Date (UTC):** 2026-08-03
- **Status:** proposed

## Motivation

This is the firm's characteristic defect. **Ten distinct instances** were found in one engagement,
across three scripts, all with the same shape: *a check that cannot evaluate its input reports success.*

(The first draft said "six". Independent review found the count **understated** — the five in the table
below, plus two in `firm-doctor`, plus the two pyyaml-import instances, is nine. The **tenth** was found
by the third review, by executing a guard a sibling PR proposed, and is the subject of its own section
below. Corrected upward twice; every instance is verified against git.)

| # | Where | The fail-open |
|---|---|---|
| 1 | `firm-check-assertions` — `artifact_absent` | With no ledger, nothing is found, `not found` is True, **PASS**. Worse: a short-circuit meant it reported "absent" for an artifact that demonstrably existed. |
| 2 | `firm-check-assertions` — `verdict_is` | `led or ""` resolved the path against the checker's **CWD**, so a verdict file in an unrelated directory produced a PASS. |
| 3 | `firm-traceability-check` — ASCII locale | Crashed on a decorative `·` before printing any verdict, exiting 1 regardless of coverage. `traceability_passes: false` therefore **passed vacuously** — the gate silently inverted. |
| 4 | `firm-check-assertions` — `traceability_passes` | Inverted the child's exit code without **classifying** it, so `false` was satisfied by a crash, a usage error, or a genuine coverage gap alike. |
| 5 | `firm-check-assertions` — zero parsed assertions | An empty or unparseable `assertions.yaml` produced `0/0 assertions passed` and **exit 0**. |

Two more of the same class were closed in `firm-doctor` (a retired-rule finding that never reached the
exit code; a missing policy file silently skipped).

**The two pyyaml-import instances were closed after this PR was first drafted**, in run
`20260803T075321Z-close-import-yaml-failopen` (`757782b`, `e927f13`): both
`firm-check-assertions` and `firm-traceability-check` guarded `import yaml` with only
`except ImportError`, which conflated "pyyaml genuinely absent" (a legitimate regex fallback) with
"pyyaml installed but broken" (unevaluable) — and let a non-`ImportError` import failure exit **1**,
i.e. report a crash as a verdict. Both now classify with `importlib.util.find_spec` and route a broken
install to their cannot-evaluate exit code.

The behavioural demonstration is the clearest evidence in the engagement for why this rule matters.
With a partially-installed pyyaml, QA reproduced both halves independently:

```
pre-fix  (main @ ad3e7ef):  firm-run-evals --structural  ->  "all evals passed", exit 0
post-fix (main @ e927f13):  firm-run-evals --structural  ->  every eval NOT EVALUABLE, exit 1
```

A broken parser made the entire golden-eval suite report green. **That is what this never-rule
prevents**, and it is why the rule belongs in `never-rules.yaml` rather than in **three** separate script
headers. *(T-08: this said "six". The nine instances span three scripts —
`firm-check-assertions`, `firm-traceability-check`, `firm-doctor` — so six was wrong on the corrected
count, and it was one of the five residues the second review named. Fixed.)*

### The count is ten, and the tenth is the strongest evidence in this batch

**The batch's best argument for this never-rule is not any of the nine. It is the tenth — a live
fail-open found by *executing* a guard that a sibling PR proposed, during the review of this PR set.**

While reviewing `criteria-before-build-or-from-diff.md`, the reviewer stopped reading its proposed guard
and ran it. A scratch ledger whose criteria were all covered `yes`, plus two coverage entries naming ids
no criterion declared, produced:

```
acceptance criteria: 2  verdict coverage entries: 4
coverage: 2 full (yes) | 0 partial | 0 waived | 0 problem(s) | 0 unverifiable
TRACEABILITY: PASS -- all 2 criteria marked fully covered (covered=yes).
rc=0
```

The acceptance-coverage gate **printed the 2-versus-4 mismatch and passed anyway**, silently discarding
two entries it could not interpret while its headline claimed full coverage. That is verbatim the shape
of every row in the table above: a check reporting success over input it did not evaluate. It was the
tenth instance, in the same script as three of the nine, and it was live at `e927f13` — after this PR's
first draft asserted "all nine known instances are now fixed".

**It is now fixed, at `76814ad`** *("fix(traceability): a coverage entry naming no criterion is
cannot-evaluate")* — `bin/firm-traceability-check` **+132/-10** and 16 new `t_case` blocks / 110 new
`assert_*` call sites in `tests/test-traceability-check.sh` (+382; that commit totals 515 insertions and
11 deletions across three files). Same fixture, same gate, re-executed at that commit:

```
acceptance criteria: 2  verdict coverage entries: 4  -- MISMATCH: 2 of these entries name NO criterion
coverage: 2 full (yes) | ... | 2 phantom
TRACEABILITY: CANNOT VERIFY -- coverage could not be evaluated, so this run has no
  traceability verdict in either direction
rc=2
```

So: **ten known instances, all ten fixed.** The sentence this replaces — "all nine known instances are
now fixed" — was false when written, and it was the weakest sentence in the batch. What replaces it is
the thesis being vindicated inside its own review: the never-rule exists because a gate that cannot
evaluate its input will report success, and the proof arrived while the document arguing for it was being
graded. The rule was not derived from the nine; the nine and the tenth are instances of it.

Two further notes a reader should have:

- The tenth was found by **execution, not by reading**. Nine of the ten were originally found the same
  way. Reading prose has never once produced an instance of this defect class in this repo. That is the
  argument for proposal 3 below being a *question the reviewer runs*, not a question the reviewer asks.
- The fix classified the case as **exit 2 (cannot evaluate)**, not exit 1. That is this PR's proposal 1
  applied literally — "cannot evaluate is a distinct, non-passing outcome and must have its own exit
  code" — decided in a real commit before the rule was adopted. Worth citing when weighing whether
  proposal 1 is operable: it already was, once, correctly.

*(Second review caught three internal inconsistencies in this section: it said "six", the header said
"five scripts" where the nine span three, and two instances were referred to by table-row numbers that
describe something else. Those were corrected — except the "six separate script headers" residue at the
top of this section, which survived and is fixed now (T-08). Third review also rejected the previous
correction note's claim that they were "**all** corrected"; a completeness claim in this PR is exactly the
kind of sentence a future reader will check, so this note no longer makes one. The count has been revised
upward twice — six, then nine, then ten — and an author miscounting its own evidence twice, in a PR
arguing for honest reporting, is worth leaving on the record rather than quietly tidying.)*

Every one of these was in the machinery that certifies every other gate. A firm whose value is its
gates cannot have gates that pass when they cannot see.

Cited: all four `11-retrospective.md` files; `20260802T145947Z-remediate-remote-delta/07-review-findings-{SEC,CODE}.yaml`.

## Proposed change

- Files: `agent-firm/policy/never-rules.yaml`, `CLAUDE.md`, `docs/ENFORCEMENT.md`, `agents/reviewer.md`
  <!-- NB: agent definitions live at agents/, NOT .claude/agents/ — the first draft cited a path that
       does not exist. -->

1. **Elevate it to a never-rule.** Add to `never-rules.yaml`: *no gate script may report PASS, APPROVE,
   or exit 0 on an input it could not evaluate. "Cannot evaluate" is a distinct, non-passing outcome
   and must have its own exit code.* This is currently folk knowledge, restated ad hoc in individual
   script headers; it should be a rule that overrides any task instruction. **This is the load-bearing
   proposal** — the rest are secondary.
2. **Document the three-way contract where it applies; do NOT renumber existing codes.** The first draft
   said "apply the same scheme to every gate script", which review found would renumber
   `firm-validate-verdict`'s exit 4 (DEGRADED) and `firm-gpt-qa`'s exit 3 (UNAVAILABLE) — both
   load-bearing in `gate-matrix.md`, `definition-of-done.yaml`, the test suite, and the stop-rule PR.
   Revised: record in one place that **a non-passing "cannot evaluate" outcome must be distinguishable
   from an evaluated failure**, and list each script's actual codes. `firm-traceability-check`,
   `firm-check-assertions` and `firm-qa-clean-check` happen to use 0/1/2; the others use their own and
   should keep them. **Also in scope, though neither is renumbered** (S-20): `bin/firm-run-evals`
   collapses cannot-evaluate into its generic exit 1, and `bin/firm-doctor` has no cannot-evaluate code
   at all — its only verdict paths are `exit 1` (:436) and `exit 0` (:439).
3. **Add it to the reviewer checklist.** `agents/reviewer.md` should ask, for any check under review:
   *what happens when this cannot evaluate its input?* Most instances above were found by asking exactly
   that, and it costs one line. Sharpened by experience: the reviewer should not *ask* the question, they
   should **run it**. Every instance in this document was found by execution; none was found by reading.

*(The first draft's proposal 3 — "close the remaining instance in `firm-check-assertions`' `import
yaml`" — was removed: review noted the same document already records it as shipped in `757782b`.)*

### Proposal 2's registry premise, executed — and it found two more, live at `b1868eb`

Proposal 2 asserts a list of exit codes. Rather than assert it, here it is run: each gate script given an
input it cannot evaluate (no arguments, and an empty directory standing in for an artifact-less run dir).

```
SCRIPT                     no-args  empty-dir  headline on empty-dir (verbatim; '...' = truncated here)
firm-traceability-check      2 †        2       TRACEABILITY: CANNOT VERIFY -- MISSING <dir>/01-acceptance-criteria.yaml
firm-check-assertions         2         2       usage: firm-check-assertions <assertions.yaml> <scratch-repo> [result.json]
firm-qa-clean-check           2         2       firm-qa-clean-check: CANNOT VERIFY — 'git status' failed (rc=128) in '<dir>' ...
firm-validate-verdict         2         1       INVALID: not valid JSON: [Errno 21] Is a directory: ...

† PRECONDITION, and it changes the answer. Run from a cwd with NO `.agent-firm/CURRENT_RUN`.
  firm-traceability-check defaults its argument to the active run, so in the primary checkout
  during a live engagement "no arguments" is NOT an input it cannot evaluate: it evaluates that
  run and returns an earned 0 or 1. Re-measured 2026-08-06 in the primary checkout: rc=1, a real
  FAIL on the active run. That is correct behaviour, not a fail-open — but a reader who runs the
  command where they are standing will see 1, not the 2 printed above. The unconditionally
  unevaluable input for this script is the empty-dir column, which is 2 either way.
```

The first three rows confirm proposal 2's claim — row 1 only under the stated precondition, which is why
it is stated. The last two rows are findings, and **they are not part of the count of ten above** — they
were found now, by executing this proposal, and they are live:

- **`firm-validate-verdict` reports an I/O error as a syntax error, at its evaluated-failure code.**
  `[Errno 21] Is a directory` is a `IsADirectoryError`, not a JSON parse failure; the tool prints it as
  "not valid JSON" and exits **1** (INVALID = evaluated and failed) rather than distinguishing "I could
  not read this input at all". That is table row 4's shape — a non-zero result whose *reason* is not
  classified. Whether the right code here is 2, or its existing 4 (DEGRADED), is precisely the decision
  proposal 2 exists to make; it should be made rather than left, and this row is why.
- **`firm-run-evals` exits 0 having evaluated nothing, on a one-character typo.** Argument parsing is
  `mode=run; [ "${1:-}" = "--structural" ] && { mode=structural; shift; }; want="${1:-}"` — so any
  unrecognised flag silently becomes the *eval name to filter on*, matches nothing, and falls through to
  `:278`, `[ "$n" -eq 0 ] && { echo "no evals in $EVALS"; exit 0; }`:

  ```
  $ firm-run-evals --structual            # '--structural' with one letter dropped
  no evals in .../agent-firm/evals
  exit=0                                   <-- and there are EIGHT evals in that directory

  $ firm-run-evals --structural           # the correct spelling, for contrast
  ok   qa-blocks-broken-build (10 assertions) — parsed + EVALUABLE ...
  ok   todo-full-track (10 assertions) — parsed + EVALUABLE ...
  all evals passed (structural: ...)
  exit=0
  ```

  Both exit 0. A CI step, a human, or a headless agent running the typo gets green having asserted
  nothing, and the message it prints — "no evals in \<dir\>" — is itself false. This is the same shape as
  table row 5 (zero parsed assertions → `0/0 assertions passed`, exit 0), one level up: **zero *evals*
  selected → exit 0**. It is also the argument for the registry-driven test in the guard section, since
  `firm-run-evals` would be in that registry and "selected nothing" is exactly the input the registry
  test feeds every entry.

**Neither is fixed here.** This is a document, not a change; a behaviour change to a gate script needs its
own work-order, tests and mutation evidence. They are recorded so the never-rule this PR proposes has two
concrete, live, executable targets on day one — and so that nobody reads "all ten fixed" as "the class is
closed". The class is not closed. The count went six → nine → ten → and executing one proposal of this PR
found two more within the hour. That is the argument for the rule, not an objection to it.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes — this is a general property of verification tooling, not a
  quirk of this repo. Any firm asserting invariants needs its assertion machinery to fail closed.
- **Risk of overfitting the firm to one repo:** none apparent. The never-rule is stated in terms of
  behaviour, not of specific scripts.
- **Evidence that it generalises *within* the repo, which is the weaker claim but the measured one**
  *(added on third review, since the count in the section this grades moved)*: the twelve instances now on
  record span five distinct scripts (`firm-check-assertions`, `firm-traceability-check`, `firm-doctor`,
  `firm-validate-verdict`, `firm-run-evals`) written at different times by different agents, three of them
  in the same file. A defect that recurs across five independently authored scripts is a property of how
  the authors think, not of any one script — which is the argument for a never-rule over a code fix, and
  it is stronger now than when this section was first written.

## Risk & rollback

- **Risk:** fail-closed gates produce more red. A gate that fails when it cannot see will interrupt
  runs that previously sailed through — which is the point, but it will feel like a regression the
  first few times. `--structural` invoking the real checker (SEC-R15, shipped) already increases this
  surface. Second risk: a badly-drawn line between "cannot evaluate" and "legitimately degraded" turns
  benign environment gaps into hard stops; the pyyaml-absent fallback is the model for getting that
  distinction right.
- **Third risk, newly evidenced above: adopting the rule makes two currently-green things red.**
  `firm-run-evals` on an unmatched filter and `firm-validate-verdict` on an unreadable input both exit as
  they do today *because* nobody has drawn the line the rule draws. Approving proposal 1 without
  scheduling those two means the firm carries a never-rule it is knowingly violating in two places — worse
  than not having the rule, because a rule with known unfixed violations teaches that rules are decorative.
  The honest ask: approve proposal 1 **and** open a work-order for the two live instances, or defer both.
- **Rollback:** revert this PR (firm config is versioned in git). Note that `76814ad` (the tenth instance's
  fix) is already merged independently and is *not* part of this PR — reverting this document does not
  revert that behaviour, and should not.

## Golden eval to guard it

**The first draft proposed an `agent-firm/evals/` entry. Review found that a category error** and it is
worth recording why: `evals/` entries are model-driven, and their `test_passes` assertions run with
`cwd=<scratch repo>` where `bin/` is not present — so an eval cannot invoke the gate scripts it would be
asserting about. The property is a property of the *scripts*, not of the firm's behaviour, so it belongs
in `tests/`.

- Test, not eval: `tests/test-gates-fail-closed.sh` — **new**, with an explicit gate-script registry.
- What it asserts: for **each** script in the registry, an input it cannot evaluate (empty, unparseable,
  missing, or crash-inducing) produces a non-passing outcome whose exit code is distinguishable from
  "evaluated and failed" — never 0, and never the evaluated-failure code. Registry-driven, so a
  newly-added gate script is covered by adding one line rather than by remembering to write a test.
  The registry itself is the "covered by construction" piece, and it is the part the first draft
  missed.
- Feasibility: high. Every condition is constructible with a `mktemp -d` fixture, the suite already has
  the `PYTHONPATH`/`sitecustomize` techniques for simulating a broken or absent parser, and all ten fixed
  instances above were reproduced this way during the engagement. The tenth's fix at `76814ad` is the
  worked example: 16 `t_case` blocks and 110 `assert_*` call sites, all file-in / exit-code-out.
- **Registry contents, and the two rows that would fail on day one.** The registry premise was executed
  (see the proposed-change section): `firm-traceability-check`, `firm-check-assertions` and
  `firm-qa-clean-check` already return 2 on unevaluable input and would pass immediately. **Each registry
  entry must name the input, not just the script** — for `firm-traceability-check` the unevaluable input
  is a missing or artifact-less run dir, *not* bare no-args, which resolves to the active run and returns
  an earned verdict (the `†` precondition above). A registry row that feeds no-args from a checkout with a
  live `CURRENT_RUN` asserts nothing about fail-closed behaviour.
  `firm-validate-verdict` returns 1 and `firm-run-evals` returns 0 — so a registry-driven test written
  honestly is **red the moment it is written**, on two entries. That is the correct outcome and it should
  be stated up front, because the alternative is an implementer quietly omitting those two rows from the
  registry to get a green suite, which reproduces the exact defect the test exists to catch. Ship the test
  red with the two rows marked as known-red-and-carried, or ship the fixes first. Do not ship a registry
  that omits the entries that fail.
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

**Blocking edits closed: T-02 and T-08.**
- **T-02** — "All nine known instances are now fixed" was false; a tenth was live at `e927f13`. The count
  is now **ten, all ten fixed** (the tenth at `76814ad`), and the tenth is presented as the batch's
  strongest evidence rather than as a stale count: it was a live fail-open found by *executing* a guard a
  sibling PR proposed, during this PR set's own review.
- **T-08** — `:47`'s "six separate script headers" is now **three**. The previous correction note's
  completeness claim ("All corrected") is withdrawn, since one residue had in fact survived it.

**AC-005 cross-section propagation — performed.** After the count changed from nine to ten:
- *Motivation* header: "Nine distinct instances" → "Ten".
- *Generalizability* gained the measured span (five distinct scripts, three of them in one file), which is
  the argument for a never-rule over a code fix and is stronger at twelve instances than at nine.
- *Risk* gained the consequence nobody had stated: adopting proposal 1 makes two currently-green things
  red, so approving the rule without scheduling them ships a rule the firm knowingly violates.
- *Golden eval*: "all nine instances above were reproduced this way" → ten, and the registry section now
  states which two entries are **red on day one**, so no implementer quietly omits them to get green.
- Batch grep: "nine" (this file only); "six separate script headers" (this file only); `76814ad` (this
  file and the criteria PR, consistent).

**AC-006, and it found things.** Proposal 2's exit-code registry was executed rather than asserted. Three
of four rows confirmed the claim — row 1 only under a precondition that is now printed with it (see the
correction note below); two new live instances surfaced (`firm-validate-verdict` reporting an I/O error at its
evaluated-failure code, and `firm-run-evals` exiting 0 having selected no evals on a one-character typo).
Both are recorded as **found now and not fixed here**, explicitly outside the count of ten. Neither is
folded into the headline, because inflating a count to strengthen an argument is the defect this PR is
about.

**Corrected on fourth review (F-DOC-01, F-DOC-02, F-DOC-08), re-measured 2026-08-06:**
- `bin/firm-traceability-check` **+142/-11 → +132/-10**. The `-11` was the *commit's* total deletions
  (10 in the script + 1 in `docs/ENFORCEMENT.md`) mislabelled as the script's; `+142` matched nothing in
  the commit. The same wrong pair sat in `criteria-before-build-or-from-diff.md:148`; both are fixed.
  `git diff --numstat 76814ad^ 76814ad -- bin/firm-traceability-check` → `132  10`.
- The registry table's `firm-traceability-check` no-args cell is **environment-dependent** and now says
  so. From the primary checkout with a live `CURRENT_RUN` it returns 1, not the 2 printed. Presenting an
  unstated precondition as executed output is the same defect class this document argues against, one
  level down.
- The `firm-check-assertions` headline was a paraphrase (`<repo>`), not the output
  (`<scratch-repo> [result.json]`). Real line pasted; the column is now labelled as truncated where it
  is truncated.
- Propagated: the guard section's registry spec now requires each entry to name its *input*, because
  "feed it no arguments" is not a fail-closed probe for this script. That is the F-DOC-02 defect
  reaching the test it would otherwise have produced.

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
