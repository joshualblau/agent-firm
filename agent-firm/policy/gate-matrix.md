# Gate matrix

Two kinds of pause: **🔵 agent review** (an agent checks another's work, no human needed) and
**🟢 human gate** (you decide). The Lead is the only surface that pauses you, and only with a
**well-formed approval payload** (below). Gate on action **reversibility and impact**, never on a
model's self-reported confidence.

| Gate | Required evidence | Human approval needed when |
|---|---|---|
| **Requirements** | spec + acceptance criteria + open questions | scope ambiguous, user impact unclear, or a non-obvious product choice |
| **Architecture** | options (A/B/C) + recommendation + risks + rollback | irreversible design, data migration, new dependency, or a security-sensitive path |
| **External action** | the exact proposed command/API call + its reversibility | any write outside the local repo, PR/issue creation, deploy, or production access |
| **Risky change** | diff + tests + rollback plan | auth, payments, data deletion, migrations, permissions, or crypto/forensics actions |
| **Final** | QA verdict + handoff + known risks | **always** — nothing is "done" until you sign off |

## Approval-payload format

Every human question MUST be a single, decision-ready message containing all of:

```yaml
decision_needed:      # the one decision, stated plainly
context:              # the minimum the human needs to decide (2-5 lines)
options:              # the real choices, each with a one-line tradeoff
recommendation:       # the firm's recommended option + why
default_if_no_answer: # what happens if the human doesn't respond (the safe default)
risk_if_wrong:        # what breaks if this call is made badly
blocking_status:      # is work blocked now, or can other work proceed in parallel?
```

Rule: **never ask a question that lacks options, a recommendation, and a safe default.** This is
what keeps "minimal supervision" from degrading into a stream of vague interruptions.

## Fast-path vs full-track

- **Fast-path** (small/low-risk task): Requirements + Final gates only; agent review is a single
  reviewer; Architecture/Integrate gates collapse into lightweight checks.
- **Full-track** (substantial/risky task): all gates active, reviewer panel, Integrator stage.
- **Greenfield build** (new product / multi-module): full-track gates, but delivered as **multiple
  bounded runs** (one coherent slice each, human Final gate per run; per-run caps from the
  `greenfield_build` profile in `agent-firm/policy/execution-budget.yaml`). For these builds,
  **"re-scope with the human"** (the `max_files_changed` stop condition) means **confirming the
  Architect's run-phasing plan at the Architecture gate** — a design-time decision, not an ad-hoc
  mid-build stop. Exceeding one run's file cap is then a planned next-run boundary, not a breach.

The Lead decides the track at intake and records it in `00-intake.md`.

## Verdict validation is itself gate evidence

`firm-validate-verdict` must exit **0** before the Final gate. Its exit codes are not interchangeable:

- **0 = VALID** — schema-validated against `qa-verdict.schema.json`. This is the only passing state.
- **1 = INVALID** — malformed, missing required keys, or a verdict outside `{APPROVE, BLOCK}`. Reject it.
- **4 = DEGRADED** — structurally plausible but **never schema-checked**, because `jsonschema` isn't
  installed. This does **not** pass the gate. It is the same class of event as an unavailable second
  voice: the check didn't run, so it cannot be reported as though it did. Install the prerequisite
  (`firm-bootstrap --with-python-deps`) and re-validate; `firm-doctor` FAILs while it's missing.

The same rule binds `firm-integrate`: integration runs on `integration/*` branches only, and refuses
any other target. Merging to the default branch is a **human gate**, never a script's decision.

## Second-voice (GPT) QA judge policy

The firm's independent cross-provider QA judge (`bin/firm-gpt-qa`, run via the Codex CLI) raises two
separate questions. Keep them separate — conflating them is what produced the contradiction this
section now resolves.

### 1 · Must the judge run? (availability)

The judge runs whenever it is available, and it is **REQUIRED for any run touching auth / permissions /
crypto / PII**.

- When the judge is **UNAVAILABLE** (`firm-gpt-qa` exits **3** — codex absent, or codex present but
  incompatible with the configured model), QA degrades to Claude-only and records it as a **skipped**
  second voice. This MUST be surfaced by the Lead as a **Final-gate warning** — never a silent pass.
  (Exit **3** = unavailable → Claude-only, logged; exit **1** = the judge RAN and **BLOCKED** — a real
  judgement to act on. Do not conflate the two.)
- On a **required** run (auth/permissions/crypto/PII), a skipped/unavailable judge does **not** pass
  by default: the Lead must obtain an **explicit, logged human waiver at the Final gate** to proceed
  without the second voice. No waiver ⇒ the run is not done.
- The judge model is env-configurable (`FIRM_GPT_QA_MODEL`); pinning/upgrading the Codex CLI to a
  compatible version is the **human's environment action**, prompted by the exit-3 message.

### 2 · The judge RAN and BLOCKED — does the block bind? (the two-voice rule)

**Canon.** The judge's BLOCK **binds** unless the Claude QA voice **dissents** on that same point.
This is the repository owner's decision of 2026-08-07; it is recorded, with the owner's instruction
quoted verbatim as the authority, in
`system-changes/20260807T000000Z-two-voice-rule-judge-binds-unless-qa-dissents.md`.

It replaces two statements that could not both hold: `CLAUDE.md:106` ("two-voice — both must APPROVE")
and this section's former "**advisory by default**" (`gate-matrix.md:64`), both as of `ad817a9`. The
answer is neither: **binding by default, with a bounded escalation when the two voices genuinely read
the same evidence differently.**

Apply this **per disputed point**, not per verdict — a judge BLOCK usually carries several blockers, and
they can land in different branches.

| # | Situation | Outcome |
|---|---|---|
| 1 | Judge BLOCKs · **QA does not dissent** (QA agrees, or is silent on that point) | **The block stands.** The gate does not clear until the objection is fixed and the judge re-run to APPROVE. |
| 2a | Judge BLOCKs · QA dissents · **high-risk** issue (defined below) | **Blocking.** The disagreement must be **RESOLVED** before the gate clears. Recording it is not resolving it. |
| 2b | Judge BLOCKs · QA dissents · **not** high-risk | **Attempt** resolution (one bounded round). If it does not resolve easily, **record the judge's dissent and proceed on QA's decision.** |

- **Resolved** (case 2a) means one of exactly three things, each of them an artifact: one voice
  **withdraws** its reading on the record; the underlying defect is **fixed** so the dispute is moot; or
  the **human decides it at the Final gate** and the decision is written down. Fatigue is not resolution.
- **One bounded round** (case 2b) is the attempt budget: re-read the disputed evidence, and where the
  artifact actually changed, re-run `firm-gpt-qa` against it once. This deliberately adds no new key to
  `execution-budget.yaml`; if a second round is wanted, that is a human call at the Final gate.
- **Case 2b is never a silent pass.** The dissent is enumerated in the run's `traceability.yaml` under
  `two_voice_diff` (and as a per-criterion `disagreement_note`), restated in `10-handoff.md`, and listed
  in the Final-gate payload. QA's decision stands; the judge's objection travels with it.
- **The reverse direction is unchanged:** a **QA BLOCK is blocking** whatever the judge says. The judge
  cannot clear a Claude-voice BLOCK — `definition-of-done.yaml` requires a schema-valid **APPROVE** from
  QA, and no second voice substitutes for it.
- **The human always retains the override** at the Final gate, in every branch above, and an override
  must be written down (the run id and verdict file it answers, plus each objection it disposes of). The
  conditions under which the *Lead* may propose one are the subject of
  `system-changes/20260803T073753Z-stop-rule-for-adversarial-review.md`, which is still `Status:
  proposed` and is not canon.

**What counts as QA dissent.** Only a *positive, contrary* position by the Claude QA voice on the
disputed point, visible in its own artifact: a differing `acceptance_criteria_coverage` score, a
`disagreement_note`, or an explicit rebuttal in `08-qa-verdict.json`. **Silence, absence, "not assessed",
or a shrug is not dissent** — it is case 1, and the block stands. A dissent recorded *after* the judge
blocked must state which evidence it reads differently and why; a bare reversal written to clear a gate
is not a reading, and it is reviewable as such at the Final gate.

**"High-risk", operationally.** Deliberately no new taxonomy — every clause points at a rule this repo
already has. The disputed point is high-risk if **any** of these holds:

- **(a) Never-rule** — resolving it the wrong way would permit a violation of any entry in
  `never-rules.yaml`.
- **(b) Gated scope** — it falls in a scope `action-scopes.yaml` marks `human_gate`,
  `denied_by_default`, or `prohibited`: merge to the default branch, push, external/production writes,
  PR/issue creation, deploys, migrations, value transfer or signing.
- **(c) Defense-in-depth surface** — permissions, hooks, the sandbox, the egress allowlist, or
  credentials/secrets (`.claude/settings.json`, `hooks/`, `agent-firm/policy/merge-authority.yaml`, any
  allowlist file).
- **(d) Security control or its proof** — auth, crypto, PII, or operator identity; or a control whose
  only evidence *is* the disputed evidence.
- **(e) Irreversible or outward-facing** — the **Risky change** and **External action** rows of the
  table at the top of this file: auth, payments, data deletion, migrations, permissions,
  crypto/forensics; anything a local `git revert` cannot undo.

Everything else — document wording, ledger/record accuracy, coverage bookkeeping, formatting, and
criterion-*interpretation* disputes with no effect on (a)–(e) — is **not** high-risk **for this rule**.
That is a statement about which branch applies, not about whether the issue matters.

**Ambiguity resolves toward blocking**, as everywhere else in this policy set:

- Unclear whether **QA dissents** → treat as **no dissent** → case 1, the block stands.
- Unclear whether the issue is **high-risk** → treat as **high-risk** → case 2a, resolve it.
