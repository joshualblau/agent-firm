# System Change PR: the two-voice rule — the judge binds unless QA dissents

A change to the **firm itself** (not a project deliverable). This one is **not** a proposal awaiting a
decision: it *is* the decision, issued by the repository owner and transcribed here.

- **Proposed by run:** `20260806T143345Z-closeout-record-matches-code` (WO-H)
- **Date (UTC):** 2026-08-07
- **Status:** approved

*(Filename timestamp is normalised to the decision date. The authoring shell's `date -u` read
`20260806T233302Z` — 27 minutes short of the UTC date boundary. Noted so the two are not later read as
a discrepancy.)*

## The authority for this change

The repository owner's instruction, quoted verbatim and in full:

> "let's make sure the canon rule is that judge must approve where there's no QA dissent, and if there
> is QA dissent, if it's a high-risk issue, the disagreement must be resolved, and otherwise attempt to
> resolve but if not easily resolvable, note the judge dissent but keep the QA decision."

Everything below is either that sentence restated as a decision procedure, or the operational detail
required to apply it without argument. Where this document adds something the sentence does not say —
the definition of "high-risk", what counts as dissent, the attempt budget — it is marked as such and
justified from rules the repo already has.

## Motivation — a live contradiction, verified

Two committed documents said incompatible things about the same gate. Verified at `ad817a9`:

| Where | Text |
|---|---|
| `CLAUDE.md:106` | "the independent Codex/GPT QA judge (`firm-gpt-qa`, two-voice — **both must APPROVE**)" |
| `agent-firm/policy/gate-matrix.md:64` | "…is **advisory by default** and **REQUIRED for any run touching auth / permissions / crypto / PII**." |

Both quotes are reproducible with `git show ad817a9:<file> | sed -n '<line>p'`.

`system-changes/20260803T073753Z-stop-rule-for-adversarial-review.md` (committed, `Status: proposed`)
flagged this in its **proposal 4** and offered a provisional resolution — "`gate-matrix.md` is
authoritative … the second voice is advisory by default" — reached by a reviewer, not by the owner. That
provisional answer is now **superseded**: the owner's rule is neither "always binding" nor "advisory".
It is **binding unless QA dissents**, with a bounded escalation. PR3 has been annotated to record that
its open question is answered and by whom; it is **not** approved by this PR and remains `proposed`.

### How the contradiction arose — and why this change overturns nothing that was approved

Worth pinning, because it justifies the two-axis split rather than merely asserting it. The phrase
"advisory by default" entered the firm through
`system-changes/20260727T191117Z-fix-gpt-second-voice-judge.md` (`Status: approved`, signed
2026-07-27), whose proposal 3 asked a **narrower question than the phrase later carried**:

> "**Set the policy explicitly** in the gate matrix: is the GPT second voice **advisory** (skip →
> documented warning, human accepts) or **required** for high-risk/security-sensitive runs (skip → the
> Lead must get explicit human waiver at the Final gate)? Recommend: advisory by default, REQUIRED for
> runs touching auth/permissions/crypto/PII"

Every branch of that question is about a **skip** — what happens when the judge does not run. It never
asked what happens when the judge *does* run and blocks. The phrase then landed in `gate-matrix.md:64`
unqualified, where it read as an answer to both questions, and `CLAUDE.md:106` answered the second one
the opposite way. That is the whole contradiction.

So the fix is a split, not a reversal: **§1 keeps the 2026-07-27 decision intact** (advisory-on-skip,
REQUIRED-for-auth/permissions/crypto/PII, human waiver otherwise) and **§2 answers the question that was
never actually asked**. No approved decision is overturned by this PR.

Why the contradiction was not academic: the run
`20260803T120043Z-cleanup-and-identity-gate` ended with **six live Claude-vs-GPT disagreements**
(AC-001, AC-008, AC-012, AC-026, AC-027, AC-028, enumerated in that run's `traceability.yaml` under
`two_voice_diff`). Under "both must APPROVE" all six block. Under "advisory" none of them do. The
firm had no rule that told the difference, so the disagreements were recorded and left. They are worked
through the new rule in that run's `10-handoff.md` §12.

## The change

- Files: `agent-firm/policy/gate-matrix.md`, `CLAUDE.md`
  - `gate-matrix.md` — the "Second-voice (GPT) QA judge policy" section is restructured into two
    explicitly separate questions and the rule is written into the second:
    - **§1 · Must the judge run? (availability)** — unchanged in substance. Runs when available;
      REQUIRED for auth/permissions/crypto/PII; exit 3 = unavailable (Claude-only, surfaced as a
      Final-gate warning); a required-but-unavailable judge needs a logged human waiver.
    - **§2 · The judge RAN and BLOCKED — does the block bind?** — new. The three-branch table below,
      the operational definition of "high-risk", what counts as dissent, and the ambiguity tie-breaks.
    - The phrase **"advisory by default" is deleted**, because it answered §2 and answered it wrongly.
      The "REQUIRED for auth/permissions/crypto/PII" clause is **kept** — it belongs to §1 (whether the
      judge must run at all) and the owner's rule does not touch it.
  - `CLAUDE.md` — line 106's "two-voice — both must APPROVE" is amended to match, and the rule is
    stated in the "Self-testing before approval (non-negotiable)" section where the Lead will actually
    read it, pointing at `gate-matrix.md` as authoritative.

### The decision procedure

Applied **per disputed point**, not per verdict — a judge BLOCK usually carries several blockers and
they can land in different branches.

| # | Situation | Outcome |
|---|---|---|
| 1 | Judge BLOCKs · **QA does not dissent** (agrees, or silent on that point) | **The block stands.** The gate does not clear until the objection is fixed and the judge re-run to APPROVE. |
| 2a | Judge BLOCKs · QA dissents · **high-risk** | **Blocking.** The disagreement must be **RESOLVED**. Recording it is not resolving it. |
| 2b | Judge BLOCKs · QA dissents · **not** high-risk | **Attempt** resolution (one bounded round). If not easily resolvable, **record the judge's dissent and proceed on QA's decision.** |

Supporting clauses, each of which exists to stop a predictable argument:

- **"Resolved" is one of exactly three artifacts** (case 2a): a voice withdraws its reading on the
  record; the defect is fixed so the dispute is moot; or the human decides at the Final gate, in
  writing. Fatigue is not resolution.
- **The attempt budget is one round** (case 2b): re-read the disputed evidence and, where the artifact
  actually changed, re-run `firm-gpt-qa` once. **No new key is added to `execution-budget.yaml`** — a
  second round is a human call at the Final gate. (Adding a cap key would have been a code-adjacent
  change; this PR is policy text only.)
- **Case 2b is never a silent pass.** The dissent goes in `traceability.yaml` `two_voice_diff` (and the
  per-criterion `disagreement_note`), is restated in `10-handoff.md`, and is listed in the Final-gate
  payload.
- **The reverse direction is unchanged.** A **QA BLOCK is blocking** whatever the judge says;
  `definition-of-done.yaml:12` requires a schema-valid **APPROVE** from QA and no second voice
  substitutes for it. Stated because a rule written in only one direction invites the other.
- **The human override survives in every branch**, and must be written down. The conditions under which
  the *Lead* may propose one are PR3's subject and are **not** canon — PR3 is still `proposed`.

### "High-risk", operationally — and why no new taxonomy

A rule that turns on an undefined term gets argued about at exactly the wrong moment. Every clause below
points at a rule the repo already carries, so the definition tracks those files instead of drifting from
them. The disputed point is high-risk if **any** holds:

| | Clause | Grounded in |
|---|---|---|
| (a) | Resolving it wrongly would permit a **never-rule** violation | `never-rules.yaml` (all 13 entries, by reference) |
| (b) | It falls in a scope marked `human_gate`, `denied_by_default`, or `prohibited` — merge to default branch, push, external/production writes, PR/issue creation, deploys, migrations, value transfer, signing | `action-scopes.yaml` |
| (c) | **Defense-in-depth surface**: permissions, hooks, sandbox, egress allowlist, credentials/secrets (`.claude/settings.json`, `hooks/`, `agent-firm/policy/merge-authority.yaml`, any allowlist) | `CLAUDE.md` first principle 5; `never-rules.yaml` ("never disable the sandbox, egress allowlist, or permission rules") |
| (d) | **Security control or its proof**: auth, crypto, PII, operator identity; or a control whose only evidence *is* the disputed evidence | `gate-matrix.md` §1's own REQUIRED list (auth/permissions/crypto/PII) |
| (e) | **Irreversible or outward-facing**: anything in the **External action** or **Risky change** rows — auth, payments, data deletion, migrations, permissions, crypto/forensics; anything a local `git revert` cannot undo | `gate-matrix.md` gate table, the **External action** and **Risky change** rows; the file's own "gate on reversibility and impact" |

Not high-risk **for this rule**: document wording, ledger/record accuracy, coverage bookkeeping,
formatting, and criterion-*interpretation* disputes with no effect on (a)–(e). That is a statement about
which branch applies, not about whether the issue matters.

Two things this definition is careful **not** to be:

- It is not a new severity scale. The firm already has three overlapping ones (never-rules,
  action-scopes, the gate table). A fourth would just create a mapping problem.
- It is not a file-path list. (c) names paths only as examples of a category; a new hook in a new
  directory is still a hook.

### What counts as QA dissent

Only a *positive, contrary* position by the Claude QA voice on the disputed point, visible in its own
artifact: a differing `acceptance_criteria_coverage` score, a `disagreement_note`, or an explicit
rebuttal in `08-qa-verdict.json`. **Silence, absence, "not assessed", or a shrug is not dissent** — that
is case 1 and the block stands.

Anti-gaming clause, because case 2b is an exit and exits get used: a dissent recorded *after* the judge
blocked must state which evidence it reads differently and why. A bare reversal written to clear a gate
is not a reading, and it is reviewable as such at the Final gate.

### Ambiguity resolves toward blocking

Matching this repo's established convention (`firm-validate-verdict` exit 4 does not pass; a
required-but-unavailable judge does not pass; `firm-traceability-check` fails closed):

- Unclear whether **QA dissents** → treat as **no dissent** → case 1, the block stands.
- Unclear whether the issue is **high-risk** → treat as **high-risk** → case 2a, resolve it.

## Worked example — the six live disagreements

Run `20260803T120043Z-cleanup-and-identity-gate` is the first real test. The two voices there are
**`08-qa-verdict.json` = APPROVE (0 blockers)** and **`08-qa-verdict.gpt.json` = BLOCK (9 blockers)**,
both pinned to `730ca7f` — squarely the situation this rule governs. The full derivation, quoting each
voice's own evidence string, is in that run's `10-handoff.md` §12 (appended by this work-order). Summary:

| AC | Claude / GPT | QA dissents? | High-risk? | Outcome under the rule |
|---|---|---|---|---|
| AC-001 | yes / no | **No** — QA's whole evidence string is "Unchanged from the prior pin." | not reached | **MOOT.** Case 1 would block, but the disputed fact changed: `git status --porcelain system-changes/` is empty at `ad817a9`. Resolved by ordinary work, not by the rule. |
| AC-008 | yes / no | **Yes** — a reasoned defence of the deviation, on the record | No — criterion interpretation, records only | **2b** — record the judge's dissent, **QA's decision stands.** |
| AC-012 | yes / no | **Yes** — "UNCHANGED POSITION, restated"; both readings recorded | **Yes** — (e), a rollback/reversibility dispute | **2a — BLOCKING.** Must be resolved; already queued as Final-gate decision 3. |
| AC-026 | yes / partial | **No** — "Not re-audited this pass; unchanged." | not reached | **Case 1 — BLOCKING.** |
| AC-027 | yes / partial | **No** — "Not re-audited this pass; unchanged." | not reached | **Case 1 — BLOCKING.** |
| AC-028 | partial / no | **Split** — dissents on the residual `ask` entry; silent on the two-file removal point | **Yes** — (c), the permissions surface | **BLOCKING both ways** — 2a on the dissented point, case 1 on the silent one. |

**Four of six are blocking, and the reasons are instructive.** Only two of the four turn on the risk
test at all. AC-026 and AC-027 block under case 1, where **no risk assessment is performed**: QA scored
them `yes` with the evidence string "Not re-audited this pass; unchanged", which is a carry-forward, not
a reading of the judge's objection. Under this rule that is silence, and silence does not overcome a
block. The cheapest path to clearing them is not an argument — it is for QA to actually audit them.

AC-028 shows why the rule is applied **per disputed point**: the judge gives two reasons, QA engages one
and never mentions the other, so one point is 2a and the other is case 1. Both block, by different
routes.

The rule is therefore not a rubber stamp for the status quo: before it, all six were recorded and none
blocked.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes. Any firm running an adversarial second voice must answer "what
  happens when the two voices disagree" *before* they disagree. The specific shape here — binding by
  default, one narrow non-blocking exit gated on a risk test grounded in the project's existing
  prohibition lists — is portable to any repo that has such lists. A repo without them would have to
  supply clause (a)/(b) equivalents, and that is the honest portability limit.
- **Risk of overfitting:** the six worked examples come from one run, and the rule was written knowing
  their outcomes. Mitigation: the rule was derived from the owner's sentence first and applied to the
  six second — but a reviewer should treat the worked example as *illustration*, not as evidence the
  rule is correctly calibrated. One run is not a calibration set.
- **The dangerous clause is 2b**, and it is dangerous in a specific way: "not easily resolvable" is a
  judgement made by the party who benefits from making it. Three things bound it — the high-risk test
  routes anything consequential to 2a, the dissent must be published in three places, and the
  anti-gaming clause makes a manufactured dissent reviewable. None of the three is mechanical.

## Risk & rollback

- **Risk 1 — 2b becomes the default exit.** Every non-high-risk disagreement can be dissented into
  "recorded, QA stands". The structural mitigation is that the exit is *loud*: three artifacts and a
  Final-gate line. It is not silent, so it is auditable after the fact even though it is not prevented.
- **Risk 2 — the ambiguity tie-breaks make the gate stricter than the owner intended.** Both resolve
  toward blocking, so a run with a vague QA verdict now blocks where it previously proceeded. This is
  deliberate and matches the repo's convention, but it is a real cost and the owner should know it is
  the direction chosen.
- **Risk 3 — nothing enforces this.** There is no code behind it. `firm-validate-verdict` validates one
  verdict at a time and has no notion of two voices disagreeing; nothing reads `two_voice_diff`. This
  rule is the Lead reading the policy and complying, exactly like the row already recorded in
  `docs/ENFORCEMENT.md:47` for the required-judge waiver. **Stated plainly rather than implied**: this
  PR ships policy text, not a control.
- **Rollback:** revert this PR. Firm config is versioned; the revert restores the prior text of both
  files exactly — and restores the contradiction, which is the point of not doing it.

## Golden eval to guard it

**None is proposed, and the reason is a limitation rather than an omission.** The rule's inputs are two
verdicts' *positions on the same point* and a risk judgement about the disputed subject. The firm has no
artifact that pairs them: `08-qa-verdict.json` and `08-qa-verdict.gpt.json` are independent documents
with no cross-references, and `two_voice_diff` is hand-written by the Packager into a **gitignored**
`traceability.yaml` that `bin/firm-traceability-check` does not read (that file's own header says so).
There is nothing an eval could assert against without first building the pairing.

- The mechanisable **precondition** is a machine-readable two-voice diff — a tool that reads both
  verdicts and emits the per-criterion disagreement set. That does not exist; `bin/` has 23 scripts and
  none of them does it (`ls bin/`).
- A guard is therefore **deferred, and the dependency is named**: it needs the diff tool first. Filing a
  guard that cannot be satisfied would repeat the vacuous-eval defect PR3's own guard section was
  rejected for twice.
- [ ] Golden evals pass (`firm-run-evals`) — **not applicable to this PR: no eval added or changed.**
      Suite state was measured before and after this change instead: `bash tests/run-tests.sh` →
      **1172 passed / 0 failed** both times. This PR touches only `.md` policy text; no test reads it.

## Human decision

- [x] **approved by the repository owner (josh@heightslabs.com) on 2026-08-07 (UTC)**
      — authority: the verbatim instruction quoted at the top of this document. This PR transcribes that
      decision; it does not request one.
- [ ] rejected — reason:

**Scope of this approval, stated so it cannot be read wider than it is:** it approves the two-voice rule
in `gate-matrix.md` §2 and the matching `CLAUDE.md` amendment. It does **not** approve
`system-changes/20260803T073753Z-stop-rule-for-adversarial-review.md`, which remains `Status: proposed`
with only its proposal-4 question answered, nor any other PR in the `system-changes/` batch — every one
of those is still `Status: proposed`.
