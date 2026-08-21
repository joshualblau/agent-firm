# System Change PR: readiness probes ask for shapes the provider CLIs do not have

A proposed change to the **firm itself** (not a project deliverable).

- **Proposed by run:** `20260821T172243Z-reviewer-capability-probe`, discovered while fixing
  `20260821T170654Z-reviewer-capability-probe-wrong-help-surface`
- **Date (UTC):** 2026-08-21
- **Status:** approved

## Motivation

This is the **second of three defects in the same family**, each of which was invisible until the one
in front of it was fixed. All three share a shape: *a firm probe asks a provider a question the
provider does not answer in that form, and the firm records the non-answer as a fact about the
provider.*

With the capability-discovery fix in place, `firm-gpt-qa` clears discovery and stops at the next
gate:

```
firm-gpt-qa: authentication readiness was not a trusted structured available result; BLOCK   (exit 1)
```

`bin/firm-reviewer-common:1066` and `:1093` run:

| probe | measured behaviour (codex-cli 0.149.0, Claude Code 2.1.238) |
|---|---|
| `codex login status --json` | **rc=2**, `error: unexpected argument '--json' found`. Plain `codex login status` prints `Logged in using ChatGPT` — human text, not JSON. |
| `codex models list --json` | **rc=2**, no `list` subcommand |
| `claude auth status --json` | rc=0, valid JSON, but keys are `{apiProvider, authMethod, email, loggedIn, orgId, orgName, subscriptionType}` |
| `claude models list --json` | **rc=1**, `error: unknown option '--json'` |

`structured_readiness` (`:1068-1081`) reads `data["status"]` or `data["authentication"]` and accepts
only `ok | available | authenticated | logged_in | logged-in`. Claude reports authentication as
**`loggedIn: true`**, which matches neither key, so a genuinely authenticated CLI returns `None` —
"not a trusted structured available result" — and the wrapper BLOCKs.

**Net effect: the cross-provider second voice cannot run in either direction on a correctly
configured, fully authenticated machine.** `firm-doctor` reports both subscriptions ready, and it is
right; the readiness probe simply asks in a dialect neither CLI speaks.

Note the failure mode is **better** than the one it replaced — exit 1 BLOCK is honest, where the
discovery bug produced a *trusted* exit 3 that laundered itself into human waiver requests. But the
judge still does not run, and this is what now stands between the firm and an actual second opinion.

## Proposed change

- Files: `bin/firm-reviewer-common` (readiness phase), plus a golden eval and test coverage.
- Summary:
  1. **Bind each readiness probe to the command and response shape the CLI actually implements**, per
     provider, in the same declarative style the capability contract now uses — so probe and reality
     cannot drift apart silently. Accept `loggedIn: true` as an authenticated result for claude, and
     use a codex authentication query that exists.
  2. **Preserve the three-way outcome and keep the distinctions sharp.** A *trusted structured*
     unavailable answer stays exit 3; a probe that errors, times out, or returns an unrecognised
     shape must **not** be silently upgraded to "available". Widening this into "assume ready" would
     be the false-positive mirror of the bug being fixed, on the gate that guards PII-touching runs.
  3. **Do not invent a JSON contract the CLIs do not offer.** Where a provider answers only in human
     text, parse it explicitly and narrowly, or drop that probe and let the judge invocation itself
     be the authority — but say which, and never treat "could not determine" as "fine".
  4. **Reconsider whether `models list` is a required gate at all.** It exists to confirm the
     resolved model is offered; neither CLI supports the invoked form, and the judge call already
     fails loudly on an unknown model. If it is kept, it must be implemented against a real surface.
  5. Add a drift assertion in the spirit of the capability contract: every readiness command the
     wrapper runs must be declared, and every declared response key must be one a real CLI emits.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes. This is firm-wide and affects both provider directions
  equally. Nothing about it is specific to any engagement.
- **Risk of overfitting the firm to one repo:** The real risk is overfitting to **one CLI version**.
  Both vendors change their CLI surfaces; the durable value here is the declaration plus drift
  assertion, not today's key names. Any fix that hardcodes `loggedIn` without a drift check will rot
  the same way.

## Risk & rollback

- **Risk: moderate, and higher than the capability fix**, because this gate decides whether a judge
  runs *at all*. The failure direction that matters is permissiveness: accepting an ambiguous or
  unparsed response as "available" would let the firm believe it obtained an independent opinion it
  did not. The mitigation is that unrecognised responses must remain BLOCK, never "available", and
  never trusted-unavailable.
- **Second-order risk:** once the judge genuinely runs, its verdicts become load-bearing for the
  first time in this firm's history. Expect the first real cross-provider run to surface further
  latent defects downstream of a gate that has never been passed.
- **Rollback:** revert this PR; firm config is versioned in git.

## Golden eval to guard it

- **Eval:** `agent-firm/evals/reviewer-readiness-probes/` (to be added)
- **What it asserts:**
  1. A stub answering in each provider's **real** shape (`loggedIn: true` for claude; codex's actual
     authenticated response) is recognised as ready.
  2. A stub returning an **unrecognised** shape is BLOCK exit 1 — never "available", never
     trusted-unavailable.
  3. A stub returning a *trusted structured* unavailable answer is exit 3, so the legitimate waiver
     path still exists.
  4. Every readiness command the wrapper runs is declared, and the declared response keys are ones a
     real CLI emits — checked against the installed CLIs, failing closed if they are absent.
- [ ] Golden evals pass (`firm-run-evals`) — run BEFORE and AFTER; attach both outputs.
      **Note:** the behavioural baseline is already red on unmodified `main`
      (`gpt-judge-availability` rc=124 timeout, `ambiguous-gate` assertion failure), so a
      green-to-green comparison is not available and the structural pass plus the firm test suite
      carry the regression gate.

## Human decision

- [x] approved by josh@heightslabs.com on 2026-08-21 (UTC)   |   [ ] rejected — reason:

## Evidence

- All four probe measurements above were taken directly on the P2 row (macOS 26.5.1, Darwin 25.5.0,
  arm64, CPython 3.9.6) against codex-cli 0.149.0 and Claude Code 2.1.238.
- Reached only because the capability-discovery fix let execution past the previous gate; recorded in
  run `20260821T034506Z-kehillat-ahuza-site` as `second_voice_state_changed`, where the held-open
  website candidate's second-voice disposition moved from exit 3 unavailable to exit 1 BLOCK.
- `firm-doctor` on the same host: "Codex ChatGPT subscription authentication is ready",
  "Claude subscription authentication is ready".
