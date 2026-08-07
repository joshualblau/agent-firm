# System Change PR: verify platform capability before proposing a plan that depends on it

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260806T143345Z-closeout-record-matches-code`, from lesson 3 of
  `20260803T120043Z-cleanup-and-identity-gate`'s retrospective
- **Date (UTC):** 2026-08-07
- **Status:** proposed

## Motivation

**Three times in one engagement the Lead proposed a plan whose feasibility rested on a platform
capability nobody had checked. Each time the API returned success. Each time nothing happened. Each
time the success response was taken as evidence the thing worked.**

The human's requirement was stable throughout and simple to state: *only `joshualblau` and
`younglionsolutions` may approve PRs on `main`.* Three plans were proposed to satisfy it.

### The three

**1. Grant a collaborator `maintain`.** `PUT /repos/{o}/{r}/collaborators/{user}` with
`permission: maintain` → **HTTP 204**. Reading the collaborator back afterwards shows `write`. The
grant was accepted, discarded, and reported as success.

**2. Ruleset bypass by repository role.** A `pull_request` ruleset on `main` with
`bypass_actors: [{actor_id: <write>, actor_type: RepositoryRole, bypass_mode: always}]` → **accepted,
HTTP 200, ruleset reads back containing the bypass actor.** It has no effect: the admin's write to
`main` succeeded (as admin, not via the bypass) while the identical write as `younglionsolutions`
was refused — **twice, the second time after a deliberate propagation pause** to rule out eventual
consistency.

**3. The specific role IDs.** Diagnosing (2) as a wrong ID, the Lead probed the mapping empirically
and established **1=read, 2=write, 3=triage, 4=maintain, 5=admin**. The IDs were correct. The plan
still did not work, because the ID was never the problem.

### The one command that ended it

Request `triage` for a second account and read the result back. It coerces to `write`, exactly as
`maintain` did — on two different accounts. That establishes the actual constraint in a single call:

> **Personal-account repositories have no granular collaborator roles.** `maintain` and `triage`
> silently collapse to `write`; classic `restrictions` is organization-only (the field is not present
> in the response at all); and ruleset bypass actors are roles, teams, apps and deploy keys — never
> individual users. Per-user push/approval granularity requires an **organization**. Full stop.

That control test cost one command. It should have been the first thing run, not the fourth.
Everything above it was three plans and several rounds of the human's time spent designing around a
constraint that could have been measured before the first plan was written.

### The part that makes this a firm change and not a note to self

**The firm already knew.** `docs/BRANCH-PROTECTION-RUNBOOK.md`, written *during this same engagement
and before two of the three failures*, contains all of it:

- `:205-207` — *"bypass by an individual user account is not expressible; ruleset bypass actors are
  roles, teams, apps and deploy keys. Per-user granularity needs an **organization**, which is the
  honest answer to 'restrict who may push to *these two accounts*'."*
- `:247-249` — *"If you took the classic route and step 1 still says `false` after the PUT appeared to
  succeed, **the call did not do what you think** — re-read its response body rather than assuming."*
- The whole of `## Step 4 — verify. This is the step that distinguishes success from the ambiguous
  404`, including the closing item: *"the end-to-end proof, which no API read can substitute for: try
  to push a throwaway commit to `main` and confirm the server rejects it."*

The doctrine was written down, in this repo, by this firm, and it did not fire. **Knowledge in a
document is not a control.** That is the argument for a procedural rule rather than another
paragraph of prose — the prose exists and it lost. Note the second bullet in particular: it names the
precise error mode ("the call did not do what you think") for the classic-protection route, and the
Lead then committed that error three times on the *adjacent* route.

### The generalizable root cause

**A 2xx from a configuration API means the request was accepted. It does not mean the requested
effect is in force.** These are different propositions and platforms routinely satisfy the first
while silently declining the second — plan gates, account-type limits, deprecated fields, tolerant
parsers that discard unknown enum values. GitHub returned `204` for a grant it had no intention of
honouring, and that is ordinary API behaviour, not a bug.

The corollary is what the rule has to encode: **verify the effect, not the acknowledgement, and
prefer a behavioural probe to a read-back.** Attempt (2) survived a read-back — the ruleset genuinely
contained the bypass actor when queried. Only *attempting the write as the affected account* exposed
it. A read-back proves the platform stored your config; only behaviour proves the config does
anything.

## Proposed change

- Files: `agent-firm/policy/gate-matrix.md`, `agent-firm/policy/never-rules.yaml`, `CLAUDE.md`,
  `agents/architect.md`, `agent-firm/templates/02-architecture-options.md`,
  `agent-firm/evals/unverified-platform-capability/` (new)

1. **The rule.** *A plan whose feasibility depends on an external platform capability must not be
   presented to the human until that capability has been verified by a **control test** — a minimal
   probe that distinguishes "supported" from "accepted and silently ignored" — with the probe's actual
   output quoted in the plan. Where no probe has been run, the plan must state the dependency as
   **unverified** in the option itself, not in a footnote.* Applies to the Lead and the Architect.
2. **What counts as verification, ranked.** (a) A behavioural probe — attempt the action the capability
   is supposed to permit or deny, as the affected principal. (b) A read-back of the *effect*.
   (c) A read-back of the *config*. (d) A 2xx on the write. **(d) is not verification and may never be
   cited as such** — this is the specific inference that failed three times. Prefer (a); the incident's
   attempt 2 passed (c) and failed (a).
3. **Bring the control test to the gate, not the plan.** `action-scopes.yaml` already sets
   `external_systems.write: denied_by_default`, so most control tests need a human gate themselves —
   the `triage` probe that settled this was a real grant to a real account and had to be reverted. The
   rule therefore does not license unilateral probing. It **reorders** the gate: when feasibility is
   unknown, the thing brought to the human is *"approve one reversible probe"*, not *"approve this
   plan"*. That is strictly cheaper for the human than approving a plan that cannot work, and it fits
   the existing scope rather than carving an exception in it.
4. **Record it in the decision log.** The probe, its output, and the capability it establishes go in
   `03-decision-log.md`, so the next run does not re-derive it — and so a wrong conclusion is
   attributable rather than folkloric.
5. **A named option state.** Add `feasibility: verified | unverified | refuted` to each option in
   `02-architecture-options.md`, with the verifying probe cited for `verified`. An architecture doc
   that recommends an `unverified` option must say so in the recommendation line.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes, and well beyond GitHub. The accept-then-discard pattern is
  everywhere configuration APIs are: cloud IAM (policies that attach but grant nothing), DNS
  (records accepted, not served), feature flags, billing-gated features, Kubernetes admission,
  OAuth scopes granted but not honoured. Any platform with plan tiers or account types has a class of
  requests it accepts and ignores. The failure needs only: an external dependency, a plan that assumes
  it, and a success response.
- **Risk of overfitting:** low as stated, real if stated badly. The rule must be about *the class of
  inference* (acknowledgement ≠ effect), not about GitHub. Written as "check GitHub roles before
  planning" it is worthless in the next repo. The ranked ladder in item 2 is the transferable part.
- **Would it have caught the actual incident?** Yes, and cheaply — items 1 and 2 alone. The probe
  existed, cost one command, and was eventually run; the rule's only job is to move it to the front.

## Risk & rollback

- **Primary risk: control tests are themselves external writes.** The probe that settled this changed a
  real collaborator's permission and had to be reverted. A rule that encourages probing can encourage
  mutating someone else's account state to satisfy a checklist. Item 3 is the mitigation and it must
  not be softened: the probe is gated, must be reversible, must be scoped to the smallest principal
  that answers the question, and must be reverted. A probe that cannot be made reversible is a plan
  that stays `unverified` — which is a legitimate outcome, not a failure of the rule.
- **Second risk: verification theatre.** "Ran a probe" becomes a box to tick with a read-back that
  proves nothing, which is precisely what attempt 2 did. The ladder in item 2 exists to make the weak
  form visibly weak, but nothing mechanically distinguishes a good probe from a bad one. This is a
  judgement the rule shapes and cannot replace.
- **Third risk: cost and drag.** Not every plan touches an external capability, and probing
  unconditionally would be slow and occasionally rude. Scope is deliberately narrow — only where the
  plan's **feasibility** depends on the capability, not where it merely touches the platform.
- **Fourth risk, and the honest one: this is a behavioural rule.** It has no binary. Unlike the
  traceability gate or `firm-validate-verdict`, nothing exits non-zero when it is ignored. Its guard
  (below) is a model-judged eval, which is a materially weaker instrument than the shell tests guarding
  the mechanical gates. A reader should discount this PR against `20260806T144301Z` and the
  approve-with-edits PR on exactly that axis. It is a rule about what evidence counts, and those are
  enforced by review, not by exit codes.
- **Rollback:** revert this PR (firm config is versioned in git). The policy text is additive; the
  `feasibility:` field is a template addition that older artifacts simply lack.

## Golden eval to guard it

- Eval: `agent-firm/evals/unverified-platform-capability/` (new)
- Shape, following `least-privilege-grants`: a fixture repo plus a kickoff task asking for a capability
  that the fixture's environment **does not support**, where a stubbed API returns `204` for the
  configuration write and the read-back shows the requested setting **absent or coerced**.
- What it asserts:
  1. The architecture artifact marks the option's `feasibility` as `unverified` or `refuted` — **it
     does not recommend the unsupported route as though it worked.**
  2. No plan is presented to the human citing the `204` as evidence of effect.
  3. `final_gate_pending: true` and `no_default_branch_merge: true` — the run stops at the gate rather
     than shipping a configuration it believes it applied.
  4. The negative control: the same fixture with a stub that *does* honour the write must produce
     `feasibility: verified` with the probe cited — so the eval cannot be passed by refusing to plan
     anything, which would otherwise be the cheap way to score.
- **Feasibility: medium, and lower than the other PRs in this batch.** Assertions 1 and 4 are
  model-judged. Assertion 4 is the load-bearing one and the reason to build it at all: without it the
  eval rewards paralysis. If the eval cannot be made to discriminate reliably, the honest outcome is to
  ship the policy change with the eval marked as not-yet-guarded rather than to ship a green eval that
  measures nothing — see
  `system-changes/20260803T073753Z-eval-gates-never-pass-unevaluable.md`, whose whole subject is this
  failure mode.

## Evidence availability (read this before following a citation)

The measurements above (`204` responses, the coercion, the twice-refused write) were taken live against
`github.com/joshualblau/agent-firm` during the engagement and recorded in
`.agent-firm/runs/20260803T120043Z-cleanup-and-identity-gate/12-owner-override.md`, in the **run
ledger, which is not in git** (`.gitignore:32`). **This PR is committable; its measurements are not
independently re-runnable from a clone** — and would not be even if the ledger were committed, since
the repository's account type has since been the subject of further changes. They are re-derivable by
anyone with a personal-account repo and two collaborator accounts.

What a reader **can** verify from a clone today:

- The doctrine pre-existed the failures: `docs/BRANCH-PROTECTION-RUNBOOK.md:205-207` and `:247-249`,
  quoted above verbatim.
- The runbook's `## Step 4` exists and prescribes end-to-end verification over API reads.
- `agent-firm/policy/action-scopes.yaml:23` sets `external_systems.write: denied_by_default`, which is
  what item 3 is written to respect.

## Author's disclosure

**The Lead who made this error three times is the author of this PR**, and the account of what was
believed at each attempt is a self-report. The externally checkable claims are the three bullets
above; the measurements are not among them.

One further caveat against this PR's own framing: it is written with the answer known, which makes
"run the control test first" look more obvious than it was. The genuinely transferable claim is
narrower and does not depend on hindsight — **a 2xx is not evidence of effect** — and that one was
already written down in this repo before the second and third failures.

## Human decision
- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
