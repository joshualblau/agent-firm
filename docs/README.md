# docs/ index

Two different kinds of document live here — know which one you're reading.

## Reference (current behavior — start here)
- [INSTALL.md](INSTALL.md) — setup, including on a new device; the mandatory dual-CLI and Python
  prerequisites; compensating provider recovery; recoverable SemVer/version refresh; single-hook
  migration; isolated loader and rollback evidence.
- [WIRING.md](WIRING.md) — one-time runbook for accounts/secrets/hardening (1Password, per-project
  profiles, egress firewall, visual baselines, phone approvals, eval calibration).
- [INTERACTIVE-TEST.md](INTERACTIVE-TEST.md) — drive the firm with a real Claude or Codex session and
  watch the lifecycle engage, end to end; it also states what the smoke does not prove and which
  exact-SHA loader/rollback evidence remains separately gated.
- [ENFORCEMENT.md](ENFORCEMENT.md) — the repo's load-bearing claimed invariants and what actually
  enforces each: tool scope, permission rule, sandbox, a script, or prompt instructions alone. The
  table is hand-maintained, so treat it as the best current map rather than a complete inventory — an
  invariant with no row there is tier 4 (prompt-only) until someone shows otherwise.

For the operating model itself (lifecycle, gates, roles, policies), read the shared
[lifecycle contract](../agent-firm/contracts/lifecycle.md),
[role contracts](../agent-firm/contracts/roles/), and
[agent-firm/policy/*](../agent-firm/policy/) directly — this directory doesn't carry a second copy.

## History (dated build journal — NOT reference documentation)
`PHASE0.md` through `PHASE5.md` each record what shipped in that phase and why, at the time it
shipped. Every one carries a banner saying so. They are useful for understanding *why* something is
shaped the way it is, or for archaeology on a specific decision — never for "what does this do today."
For that, read the actual code and the reference docs above.

The same is true of `system-changes/*.md` at the repo root: each is a dated record of one approved
change to the firm itself, not a living document.
