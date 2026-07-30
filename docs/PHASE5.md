# Phase 5 — Hardening

> **This is a dated build-journal entry, not reference documentation.** It records what shipped
> and why, at the time it shipped. For current behavior, read the actual code/docs it describes —
> `CLAUDE.md`, `agent-firm/policy/*`, `bin/firm-*` — not this file. See [docs/README.md](README.md).

Phase 5 makes the firm safer to run unsupervised and closes the last gaps in "tests its own work" and
"minimal supervision." Five tracks: an **egress firewall**, a **visual-regression suite**, **remote
approval notifications**, **full golden-eval execution**, and docs for **adversarial panels** +
**durable runners**. Everything is scaffolding + tooling + docs — you wire the real accounts/secrets;
every secret is an `op://` reference.

---

## 1. Egress firewall (opt-in, default-deny)

`.devcontainer/egress-firewall.sh` turns the sandbox's outbound network default-**deny** with an
allowlist. This is the main lever that bounds prompt-injection blast radius: even a fully compromised
agent can't phone home or exfiltrate to a non-allowlisted host.

**How it works.** iptables sets `OUTPUT` policy to `DROP`; only DNS, established connections, and an
`ipset` of allowlisted destinations on ports 80/443 get out. GitHub's ranges are pulled live from
`api.github.com/meta` (web+api+git); other hosts come from `.devcontainer/egress-allowlist.conf`
(`host <fqdn>` resolved at boot, or literal `cidr <a.b.c.d/nn>`). Denied traffic is rate-limited-LOGged
then dropped (a compromised agent's exfil attempt stalls silently and is audited) — swap the final
`-j DROP` for `-j REJECT` if you prefer fast failures while debugging.

**Fail-safe & opt-in.** It refuses to boot if it can't build the rules (never silently runs open), and
it's off by default because it needs elevated caps. Enable it in `.devcontainer/devcontainer.json`:
uncomment `--cap-add=NET_ADMIN`, `--cap-add=NET_RAW`, and the `postStartCommand`. `verify.sh` proves
enforcement (un-allowlisted `example.com` blocked; `api.anthropic.com` reachable).

**The OpenAI/Codex caveat (honest).** `chatgpt.com` / `api.openai.com` / `auth.openai.com` sit behind
Cloudflare with **rotating IPs**, so a boot-time `ipset` pins only the anycast IPs returned at that
moment — they can stop being served minutes later, causing intermittent connection-refused. Three
mitigations, none silently perfect: (a) uncomment those `host` lines **and** run
`refresh-cdn-allowlist.sh` on a ~2-min timer; (b) allowlist Cloudflare's published CIDRs (widest exfil
surface); (c) best — an SNI-filtering egress proxy (CDN-agnostic), documented not shipped.
`api.anthropic.com` is a single stable IP and needs no mitigation.

**macOS Docker Desktop.** iptables/ipset run inside the container's netns in the LinuxKit VM — no
host-side macOS config; the binaries are baked into the image. If you ever hit `xt_set not found`,
that's an unusually stripped kernel. Even with the firewall, still never mount `~/.ssh`/cloud creds —
the firewall bounds blast radius but can't stop exfil to an allowlisted host.

The base image is pinned by digest (`node:20-bookworm-slim@sha256:2cf067…`); the Dockerfile documents
how to refresh it. That image is a Node base, **not** a Playwright browser image — see visual below.

---

## 2. Visual-regression suite

Completes the original "unit, integration, **and visual**" requirement. Playwright `toHaveScreenshot`
asserts rendered UI against committed baselines; the `qa-tester` writes the result into the QA verdict's
`visual` field. **Project-gated** (only for UI-visible changes) and **read-only** — QA never updates
baselines.

- `firm-visual-check [dir]` — what `qa-tester` runs: `npx playwright test --update-snapshots=none`.
  Exit 0 = match, 3 = not_applicable (no config/specs), other = diff → **BLOCK**. Never writes baselines.
- `firm-visual-baseline [dir]` — **human-only**, never QA: `--update-snapshots=changed` so a person
  reviews the git image diff before committing. A baseline change is a deliberate, reviewed act.
- Templates in `agent-firm/templates/visual/` (`playwright.config.ts`, `tests/visual.spec.ts`,
  `tests/screenshot.css`): animations disabled, caret hidden, per-test `mask` for live regions,
  `maxDiffPixelRatio: 0.01`, stable `snapshotPathTemplate`.

**Container-pinned baselines (the contract).** Baselines differ per browser+OS (font hinting,
sub-pixel AA). Generate them in the version-matched Playwright image, not the node base:
```bash
docker run --rm -it -v "$PWD:/work" -w /work mcr.microsoft.com/playwright:v1.61.0-noble \
  npx playwright test --update-snapshots=changed
```
Baselines are valid only for the exact image that made them; pin the Playwright tag to your
`@playwright/test` version and bump them together. Needs `@playwright/test` (not bare `playwright`).

---

## 3. Remote approval notifications

Push a "a gate is waiting" alert to your phone so you can leave a run unattended and come back to
approve. **Notify-only by design** — the alert is a side-channel; you still approve in-session.

`bin/firm-notify` runs from the plugin's `Notification` hook (`hooks/hooks.json`), reads the hook JSON
on stdin, and dispatches to a **provider-agnostic** adapter chosen by `FIRM_NOTIFY_ADAPTER`:
`slack | pushover | telegram | ntfy | none`. Secrets resolve from `op://` references (env fallback for
non-1Password users) and are listed in `.env.op.example`. It **fails open**: unconfigured or erroring →
silent no-op, exit 0 — a broken notifier must never wedge the approval flow.

Adapter setup (pick one):
- **Telegram** (free, no server): @BotFather → bot token; message the bot, then `getUpdates` (or
  @userinfobot) for your numeric `chat_id`.
- **ntfy.sh** (no account): subscribe to an unguessable topic in the app; the topic name is the password.
- **Slack** (free workspace): app → Incoming Webhook → the whole `hooks.slack.com/services/…` URL is the secret.
- **Pushover** (~$5 one-time/platform): app token + user key.

**Why bidirectional is out of scope.** A `Notification` hook can't answer the permission prompt, and
approve/deny-from-phone would need a public callback server (Slack request URL / Telegram webhook / ntfy
action endpoint) — a real service to stand up and secure. So no adapter consumes inbound approvals; the
phone tells you a gate is waiting, you approve in the session. If ever wanted, the seam is a
`PreToolUse`/permission hook returning a decision plus a callback server — a future build, not this one.

Dry-run without touching a real account:
```bash
echo '{"message":"test","title":"agent-firm"}' | FIRM_NOTIFY_ADAPTER=ntfy FIRM_NTFY_TOPIC=throwaway-topic firm-notify
```

---

## 4. Full golden-eval execution

`firm-run-evals` graduates from a structural check to actually **driving the firm** against each fixture
and checking assertions — so a System Change PR that edits an agent prompt, policy, or workflow can't
silently regress what worked.

- `firm-run-evals --structural [name]` — the Phase-1 structure check (no model run; CI-safe).
- `firm-run-evals [name]` — copies the fixture to a scratch git repo, drives the firm with `claude -p`
  under a **bounded** posture, then runs `firm-check-assertions`.
- `firm-check-assertions <assertions.yaml> <repo> <result.json>` — checks the full vocabulary:
  `file_exists`/`file_absent`, `artifact_exists`, `verdict_is`, `test_passes`, `traceability_passes`,
  `no_default_branch_merge`, `final_gate_pending`.

**Bounded posture (never bypass).** The run uses `--permission-mode default` + a scoped `--allowedTools`
+ `--disallowedTools "Bash(git push:*),Bash(git merge:*)"`, and a hook-stripped copy of the firm
settings (the real settings' project-path ledger hook doesn't exist in a scratch repo). It **never** uses
`--dangerously-skip-permissions` — that would exercise none of the firm's guardrails and would let it
barrel through the final gate, falsely passing `final_gate_pending`. The operating manual is injected via
`--append-system-prompt "$(cat CLAUDE.md)"`.

**How `final_gate_pending` is asserted headlessly.** There's no human in `-p` mode, so a correct firm
stops **deliberately** (a clean `success` turn) having done its work but not completed the gated final
action — the "didn't do too much" teeth live in `no_default_branch_merge` / `file_absent`. The checker
reads the real `claude -p` JSON envelope (verified on 2.1.196: `subtype`, `is_error`, `stop_reason`,
`permission_denials` — there is **no** `deferred_tool_use` in this version) and treats
`subtype == "success" && !is_error` as the deliberate-stop signal.

Evals: `greet-fast-path` (fast track), `todo-full-track` (all gates + reviewer panel + QA), and
`ambiguous-gate` (an under-specified request the firm must pause on, not guess). Requires the plugin
installed (`firm-bootstrap`) so the firm's subagents + `firm-*` tools exist, and a Claude login.

> **Not yet run live.** The scripts are built against verified CLI flags and the checker is fully
> unit-tested against the real envelope, but a live end-to-end firm eval bills the subscription and its
> `final_gate_pending` signal wants first-run calibration. Run `firm-run-evals greet-fast-path` once in
> the pinned devcontainer (node 20 — this repo's shell node is 14, which can't run `node --test`) to
> calibrate, then wire it into CI. This mirrors how Phase 3's GPT judge was validated as its own step.

---

## 5. Adversarial panels (document-only)

Claude Code **Agent Teams** are experimental and disabled by default
(`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`), one team per session, no nesting, no in-process resume, and
~7× the tokens of a standard session. **Not shipped as a firm workflow** — the firm's hierarchical
reviewer subagents + the cross-provider Codex/GPT QA judge are cheaper, resumable, and flag-free.

Convene an adversarial panel **manually** only where anti-anchoring is the whole point: (a) an ambiguous
root-cause hunt (independent investigators each own and try to disprove a hypothesis), or (b) a
high-stakes review you want stress-tested by mutual challenge. For everything else, use the default
panel; adversarial *review* can be approximated with independent reviewer subagents at lower cost. Keep
the **security lens off Fable** (its classifiers refuse security-adjacent work). Revisit a `firm-panel`
variant when Agent Teams leave experimental and gain in-process resume.

---

## 6. Durable runners (deferred seam)

LangGraph checkpointer and Temporal are Python, server-backed durability frameworks for **unattended
multi-hour/day** agent jobs that must survive infra crashes. The firm is CLI-first and attended; its
durability today is **git worktrees/branches + the on-disk run-ledger**, which survive any crash. So:
**deferred — documented, not built.**

If the firm ever runs genuinely unattended multi-day jobs: reach first for the **lighter** option —
LangGraph checkpointer (Postgres, `sync` durability) for resumable state (note: it checkpoints *between*
nodes, not inside them). Escalate to **Temporal** only for crash-safe recovery across worker/host
boundaries with automatic retries. The integration seam is the run-ledger + the build-review-test
workflow driver: each firm stage becomes a checkpointed node / Temporal activity keyed by the run id,
with `.agent-firm/runs/<id>/` as the externally-visible state.

---

## Verified
- Firewall/visual/notify/eval scripts pass `bash -n`; JSONC/`plugin validate` pass.
- `firm-doctor` unaffected; `firm-notify` dry-runs correctly for all four adapters and no-ops when
  unconfigured (verified via a mock `curl`, no real sends).
- `firm-visual-check` returns `not_applicable` (exit 3) with no config/specs.
- `firm-check-assertions` unit-tested against a synthetic ledger across the **whole** vocabulary — every
  pass and fail path fires correctly (including `final_gate_pending` failing on `is_error`,
  `no_default_branch_merge` failing at >1 commit, `verdict_is` on BLOCK, `file_absent` on presence).
- `firm-run-evals --structural` validates all three evals; the base image digest is a real resolved
  Docker Hub digest.

## Your steps (the firm never touches real creds)
- Firewall: enable the caps + `postStartCommand`, build the container, run `verify.sh`.
- Visual: `npm i -D @playwright/test`, generate baselines in the pinned Playwright image, commit them.
- Approvals: create ONE adapter (Telegram is the low-friction default), store its secrets in 1Password,
  set `FIRM_NOTIFY_ADAPTER` + the `op://` refs in `.env.op`.
- Evals: `firm-run-evals greet-fast-path` once in the devcontainer to calibrate, then wire into CI.
