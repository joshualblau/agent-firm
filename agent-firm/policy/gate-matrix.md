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

The Lead decides the track at intake and records it in `00-intake.md`.
