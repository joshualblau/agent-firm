# Phase 4 (part 1) — Versioned plugin distribution

Goal: one shared firm, many projects. The canonical repo (`~/agent-firm`) is the single source of
truth, published as a **versioned Claude Code plugin** via a local marketplace and installed at user
scope. Generalizable improvements flow in through System Change PRs, get a version bump, and propagate
to every project on `claude plugin update`.

## How it's packaged
- `.claude-plugin/marketplace.json` — makes this repo a local marketplace named `heights-labs`.
- `.claude-plugin/plugin.json` — the `agent-firm` plugin manifest (carries the `version`).
- **Auto-discovered components** (no manifest paths needed): `agents/` (the 7 roles), `commands/`
  (`/agent-firm:start`), `hooks/hooks.json` (the ledger hook), `bin/` (the `firm-*` tools join `$PATH`).
- **What a plugin can't ship:** a `CLAUDE.md` (so the operating manual is the `/agent-firm:start`
  command) and `permissions` (so `firm-install` merges the allow/ask/deny rules into a project's or
  your user `settings.json`).

## Install (per machine)
```bash
claude plugin marketplace add ~/agent-firm
claude plugin install agent-firm@heights-labs        # user scope = all projects
```
Per project, once: `firm-install` (grants the firm's permission policy). Then `claude` → `/agent-firm:start <goal>`.

## Update flow (propagate a generalizable improvement)
1. Land the change in `~/agent-firm` (ideally via `firm-propose-system-change` → review → commit).
2. Bump `version` in `.claude-plugin/plugin.json` (e.g. 0.2.0 → 0.2.1).
3. `claude plugin marketplace update heights-labs && claude plugin update agent-firm` (restart to apply).

Every project that updates picks up the change. Project-specific tweaks stay in that project's
`.claude/` and never propagate. A change can't reach other projects without a deliberate version bump.

## Per-project version pinning
Plugins install at user scope by default (one version everywhere). To pin a project to a specific
version, install at project scope and commit it:
```bash
claude plugin install agent-firm@heights-labs --scope project
```
This writes `extraKnownMarketplaces` + `enabledPlugins` into the repo's `.claude/settings.json`, so an
in-flight engagement can't be blindsided by a firm change until you choose to bump it.

## Verified (isolated install test)
- `claude plugin validate .` passes.
- Install loads all components: **Agents (7)**, the `start` command, the PreToolUse ledger hook.
- `firm-install` merges 57 permission rules idempotently.
- Tested under an isolated `CLAUDE_CONFIG_DIR` so the global config wasn't touched during development.

## Not yet (rest of Phase 4)
- Multi-profile secrets/auth (`op` + direnv, per-project `CLAUDE_CONFIG_DIR` + `CODEX_HOME`).
- Second-machine bootstrap (chezmoi for home glue) — though `claude plugin marketplace add` against a
  cloned repo already gets the firm onto a new machine.
