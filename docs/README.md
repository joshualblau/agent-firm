# docs/ index

Two different kinds of document live here — know which one you're reading.

## Reference (current behavior — start here)
- [INSTALL.md](INSTALL.md) — setup, including on a new device; the Python (`jsonschema`/`pyyaml`)
  prerequisite; migrating a project past a retired permission rule.
- [WIRING.md](WIRING.md) — one-time runbook for accounts/secrets/hardening (1Password, per-project
  profiles, egress firewall, visual baselines, phone approvals, eval calibration).
- [INTERACTIVE-TEST.md](INTERACTIVE-TEST.md) — drive the firm with a real Claude session and watch the
  lifecycle engage, end to end.
- [ENFORCEMENT.md](ENFORCEMENT.md) — every claimed invariant in this repo, and what actually enforces
  it: tool scope, permission rule, sandbox, a script, or prompt instructions alone.

For the operating model itself (lifecycle, gates, roles, policies), read
[CLAUDE.md](../CLAUDE.md) and [agent-firm/policy/*](../agent-firm/policy/) directly — this directory
doesn't carry a second copy of those.

## History (dated build journal — NOT reference documentation)
`PHASE0.md` through `PHASE5.md` each record what shipped in that phase and why, at the time it
shipped. Every one carries a banner saying so. They are useful for understanding *why* something is
shaped the way it is, or for archaeology on a specific decision — never for "what does this do today."
For that, read the actual code and the reference docs above.

The same is true of `system-changes/*.md` at the repo root: each is a dated record of one approved
change to the firm itself, not a living document.
