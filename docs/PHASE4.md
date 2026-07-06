# Phase 4 — Portability (plugin distribution · portable secrets · per-project profiles)

Part 1 packages the firm as a shared, versioned plugin. Part 2 (below the divider) makes each project
switch to the right **subscription accounts** and load its **secrets** with nothing sensitive in git.

---

# Phase 4 (part 1) — Versioned plugin distribution

Goal: one shared firm, many projects. The canonical repo (`~/agent-firm`) is the single source of
truth, published as a **versioned Claude Code plugin** via a local marketplace and installed at user
scope. Generalizable improvements flow in through System Change PRs, get a version bump, and propagate
to every project on `claude plugin update`.

## How it's packaged
- `.claude-plugin/marketplace.json` — makes this repo a local marketplace named `local`.
- `.claude-plugin/plugin.json` — the `agent-firm` plugin manifest (carries the `version`).
- **Auto-discovered components** (no manifest paths needed): `agents/` (the 7 roles), `commands/`
  (`/agent-firm:start`), `hooks/hooks.json` (the ledger hook), `bin/` (the `firm-*` tools join `$PATH`).
- **What a plugin can't ship:** a `CLAUDE.md` (so the operating manual is the `/agent-firm:start`
  command) and `permissions` (so `firm-install` merges the allow/ask/deny rules into a project's or
  your user `settings.json`).

## Install (per machine)
```bash
claude plugin marketplace add ~/agent-firm
claude plugin install agent-firm@local        # user scope = all projects
```
Per project, once: `firm-install` (grants the firm's permission policy). Then `claude` → `/agent-firm:start <goal>`.

## Update flow (propagate a generalizable improvement)
1. Land the change in `~/agent-firm` (ideally via `firm-propose-system-change` → review → commit).
2. Bump `version` in `.claude-plugin/plugin.json` (e.g. 0.2.0 → 0.2.1).
3. `claude plugin marketplace update local && claude plugin update agent-firm@local` (restart to apply).

Every project that updates picks up the change. Project-specific tweaks stay in that project's
`.claude/` and never propagate. A change can't reach other projects without a deliberate version bump.

## Per-project version pinning
Plugins install at user scope by default (one version everywhere). To pin a project to a specific
version, install at project scope and commit it:
```bash
claude plugin install agent-firm@local --scope project
```
This writes `extraKnownMarketplaces` + `enabledPlugins` into the repo's `.claude/settings.json`, so an
in-flight engagement can't be blindsided by a firm change until you choose to bump it.

## Verified (isolated install test)
- `claude plugin validate .` passes.
- Install loads all components: **Agents (7)**, the `start` command, the PreToolUse ledger hook.
- `firm-install` merges 57 permission rules idempotently.
- Update flow verified: version bump 0.2.0 → 0.2.1 propagated via `marketplace update` + `plugin update agent-firm@local`.
- Tested under an isolated `CLAUDE_CONFIG_DIR` so the global config wasn't touched during development.

---

# Phase 4 (part 2) — Portable secrets + per-project profiles

Goal: `cd` into any project and it is automatically on the **right Claude + ChatGPT subscription
accounts** with its **secrets loaded**, while git holds only portable config — `op://` references and
profile names, never a secret value. Exactly one credential is hand-carried to a new machine: a single
1Password service-account token.

## The invariant
Portable config travels in git (`.envrc.example`, `.env.op`, `bench/`, `.devcontainer/`, schemas).
Secret **values** never do. `.env.op` holds only `op://vault/item/field` **references**; 1Password's
`op` resolves them at `cd`-time via direnv, and nothing plaintext is written to disk.

## One-time setup (you do this — the firm never touches real credentials)
1. Install the tools: `brew install 1password-cli direnv` (op must be **>= 2.18.0** for service-account
   tokens), and add the direnv hook to your shell: `eval "$(direnv hook zsh)"` in `~/.zshrc`.
2. In 1Password, create a **shared** vault (e.g. `Firm`) and a **service account** scoped to it, then
   export its token from your shell profile (not any repo): `export OP_SERVICE_ACCOUNT_TOKEN="ops_..."`.
   Service accounts **cannot read your Private/Personal vault** — every firm secret must live in the
   shared vault or `op` fails.

## Per-profile account setup (once per account: `work`, `personal`, `client-acme`, …)
```bash
CLAUDE_CONFIG_DIR=~/.claude-work claude        # then /login  → then:  claude setup-token
#   store the printed token in op as  op://Firm/claude-work/credential
CODEX_HOME=~/.codex-work codex login           # logs that ChatGPT account into ~/.codex-work/auth.json
```
Config dirs live under `$HOME` (`~/.claude-<profile>/`, `~/.codex-<profile>/`) and are gitignored
(`.claude-*/`, `.codex-*/`) so they never commit even for a repo that sits under `$HOME`.

## THE macOS Claude caveat (the load-bearing honesty item)
On macOS, **`CLAUDE_CONFIG_DIR` does NOT switch the Claude subscription account.** The OAuth credential
lives in the encrypted login **Keychain** (`security find-generic-password -s "Claude Code-credentials"`),
a single shared entry; `CLAUDE_CONFIG_DIR` only relocates the credential *file* on Linux/Windows. So the
config dir isolates settings/agents/history/MCP (useful, all OSes) but authenticates as whichever account
last ran `/login`.

**The fix the firm uses:** `claude setup-token` prints a ~1-year subscription OAuth token; store it in op
and export a per-project `CLAUDE_CODE_OAUTH_TOKEN` (via `.env.op`). That token **outranks** the shared
Keychain, so the account switch becomes real per project. If you skip `setup-token`, every profile
silently shares one Claude account.

Test it: in project A run `claude` → `/status` (note the account); `cd` to project B (a different token)
→ `/status` should show account B, auth type **OAuth token** (subscription), not an API key. Negative
control: `export ANTHROPIC_API_KEY=sk-ant-…` → `/status` flips to metered API — proving the precedence
trap — then `unset` it.

## Codex switching (this one just works)
`CODEX_HOME` **does** switch the ChatGPT account — it points at a directory with its own `auth.json`.
Two caveats: Codex config **profiles** (`--profile`) only overlay model/settings and are barred from
changing auth (account switching is `CODEX_HOME` only), and an env `OPENAI_API_KEY`/`CODEX_API_KEY`
silently bills API even with an active ChatGPT login. The `.envrc` unsets both.

## Per-project files
`cp .envrc.example .envrc`, set `FIRM_PROFILE`, `cp .env.op.example .env.op` and edit the `op://` refs,
then `direnv allow`. `.env.op` is committed (references only); `.envrc` is machine-local (gitignored).
The `.envrc` uses **Pattern B** — one `op run --no-masking --env-file=.env.op -- direnv dump` resolves
every reference in a single call, loads them once, and lets subprocesses inherit; nothing plaintext hits
disk. (Never use `op inject -o .env` — that materializes secrets on disk. `--no-masking` is required or
`direnv dump` imports corrupted values.) `direnv allow` re-runs after **every** `.envrc` edit and once
per machine — that re-approval **is** the security boundary; don't script it away.

## Billing-trap reference (unset these in a subscription project)
| Provider | Env var that outranks the subscription | Effect |
|---|---|---|
| Claude | `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` | metered API billing, silently |
| ChatGPT/Codex | `OPENAI_API_KEY`, `CODEX_API_KEY` | metered API billing, silently |
| 1Password | `OP_CONNECT_HOST`, `OP_CONNECT_TOKEN` | override the service-account token |

`unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY CODEX_API_KEY OP_CONNECT_HOST OP_CONNECT_TOKEN`.
Worse in non-interactive mode (`claude -p`, `codex exec`): there's no prompt. The `.envrc` unsets them
and **`firm-doctor` fails closed** on a leak — but a key exported *after* direnv loads still bites, so
run `firm-doctor` **in the actual working shell**.

## firm-doctor (fail-closed)
`firm-doctor` (add `--probe` for live account probes) checks, in order: (1) **billing guard** — FAILs if
any metered-API key is exported in a subscription project; (2) op present/**>=2.18.0**/service-account
authenticated; (3) direnv present + shell hook + `.envrc` allowed; (4) git hygiene — `.env.op` holds
`op://` references only, secret/auth paths are gitignored, none tracked; (5) `op://` references resolve;
(6) Claude profile isolated + `CLAUDE_CODE_OAUTH_TOKEN` present (the macOS switch); (7) `CODEX_HOME`
isolated + its own `auth.json`; (8) codex + chezmoi sanity. **Exit 1 on any FAIL**, 0 on WARN-only.

## Second-machine bootstrap (chezmoi)
The only hand-carried secret is one service-account token. chezmoi owns **home-level glue only** —
`~/.zshrc` (with the direnv hook), the `chezmoi.toml.tmpl` with `[onepassword] mode="service"`, and a
`run_once_` provisioner that installs op/direnv/codex. It does **not** manage `~/.claude-*/` or
`~/.codex-*/` (live tokens) or per-project `.envrc` (those live in each project's repo and need a fresh
`direnv allow` per machine).
```bash
export OP_SERVICE_ACCOUNT_TOKEN="ops_..."                 # hand-carried, from a shared vault
unset OP_CONNECT_HOST OP_CONNECT_TOKEN
sh -c "$(curl -fsLS https://get.chezmoi.io)" -- init --apply https://github.com/joshualblau/dotfiles.git
git clone https://github.com/joshualblau/agent-firm.git ~/agent-firm && ~/agent-firm/bin/firm-bootstrap
# recreate each profile once (claude /login + setup-token → op ; CODEX_HOME=~/.codex-<p> codex login),
# then per project:  cp .envrc.example .envrc && cp .env.op.example .env.op → edit → direnv allow → firm-doctor
```

## Gotchas digest
- op service accounts can't read the **Private** vault — put everything in a shared vault.
- Pattern B needs `op run --no-masking`; never `op inject -o .env` (plaintext on disk).
- `direnv allow` re-approves after every edit and once per machine — it's the trust boundary. A file
  pulled in via `source_env` (`.envrc.local`) is **not** separately allow-checked, so keep it trusted.
- `auth.json` and the setup-token/service-account token are **passwords**; keep tokens out of every
  committed file (shell profile / 1Password only). The `.gitignore` covers the on-disk files.
- Codex account switching is `CODEX_HOME` only; `--profile` ≠ account, and there is no `CODEX_PROFILE`.
- 1Password developer docs moved `developer.1password.com` → `www.1password.dev` (301s).
- Codex's login shell may use a different toolchain (Node 14 seen in Phase 3) — run real QA in the
  pinned devcontainer even though `firm-doctor` confirms login presence.

## Verified
- `firm-doctor` billing guard: FAILs (exit 1) with a leaked `ANTHROPIC_API_KEY` in a subscription
  project; downgrades to WARN (exit 0) when no subscription context is present.
- `.env.op` scanner: FAILs on a plaintext value, PASSes on references-only.
- git hygiene: `firm-doctor` caught a real bug — inline `#` comments had silently disabled the `.envrc`,
  `.claude-*/`, and `.codex-*/` ignore rules (git only honors `#` at line start). Fixed; re-verified that
  `.env.op` is committable while `.envrc`, `.env.op.local`, and `.claude-*/` are ignored.
- Auth-storage finding (empirical): the Claude subscription credential is in the macOS login Keychain
  (`Claude Code-credentials`), so `CLAUDE_CONFIG_DIR` alone can't switch the account — hence the
  `CLAUDE_CODE_OAUTH_TOKEN` design; Codex auth is file-based (`~/.codex/auth.json`), so `CODEX_HOME`
  switches cleanly.

_The firm ships scaffolding + docs + `firm-doctor` only. You create the vault/service account, run
`claude setup-token` / `codex login`, and hold the real tokens; `firm-doctor` verifies afterward._
