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

## Second-voice (GPT) QA judge policy

The firm's independent cross-provider QA judge (`bin/firm-gpt-qa`, run via the Codex CLI) is
**advisory by default** and **REQUIRED for any run touching auth / permissions / crypto / PII**.

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
