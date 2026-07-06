# Install & bootstrap the firm (any device)

The firm ships as a **versioned Claude Code plugin** (`agent-firm`) served from a **local marketplace**
(`local`) that is this repo. Install it once per machine at user scope, and every project on that
machine can use it.

## TL;DR (machine that already has this repo)
```bash
~/agent-firm/bin/firm-bootstrap          # registers the marketplace + installs the plugin (idempotent)
```
Then, per project (once):
```bash
cd <your project>
firm-install                             # merges the firm's permission rules into .claude/settings.json
```
**Optional — per-project subscription profile + secrets** (full step-by-step in [WIRING.md](WIRING.md);
see [PHASE4.md](PHASE4.md) part 2 for the rationale + the macOS Keychain caveat):
```bash
cp ~/agent-firm/.envrc.example .envrc    # set FIRM_PROFILE (which account this repo uses)
cp ~/agent-firm/.env.op.example .env.op  # edit the op:// references (commit this — references only)
direnv allow                             # loads the profile + secrets on cd
firm-doctor                              # fail-closed: no API-key leak, profiles isolated, op+direnv wired
```
Start an engagement:
```bash
claude
# inside the session:
/agent-firm:start <your goal>
```
Restart any already-running `claude` session so it loads the plugin.

## Manual steps (what firm-bootstrap does)
```bash
claude plugin marketplace add <path-to-this-repo>     # e.g. ~/agent-firm
claude plugin install agent-firm@local         # user scope = all projects
```

## On a NEW device (first get the repo there)
The plugin is served from this repo, so the repo must exist on the new machine first.

1. **Clone the repo** (private — you'll need `gh auth login` or a GitHub credential on the new device first):
   ```bash
   git clone https://github.com/joshualblau/agent-firm.git ~/agent-firm
   ```
   (Or copy `~/agent-firm` over via rsync/scp; or, later, chezmoi-managed dotfiles.)
2. **Run the bootstrap:**
   ```bash
   ~/agent-firm/bin/firm-bootstrap
   ```
3. Per project: `firm-install`, then `claude` → `/agent-firm:start`.

For a full second-machine bootstrap that also carries your profiles/secrets (chezmoi for home glue +
one hand-carried 1Password service-account token), see [PHASE4.md](PHASE4.md) part 2.

## Update to a newer firm version (propagate an improvement)
After the canonical repo changes and its `version` is bumped:
```bash
git -C ~/agent-firm pull                                    # if using a remote
claude plugin marketplace update local
claude plugin update agent-firm@local                # restart to apply
```
`firm-bootstrap` also updates in place if the plugin is already installed.

## Per-project version pinning (optional)
Default install is user scope (one version everywhere). To pin a project:
```bash
cd <project>
claude plugin install agent-firm@local --scope project   # writes enabledPlugins into .claude/settings.json (commit it)
```

## Verify / troubleshoot
```bash
claude plugin list                       # should show agent-firm@local — ✔ enabled
claude plugin details agent-firm@local    # Agents (7), the start command, the ledger hook
claude plugin validate ~/agent-firm      # manifest check
```
- Components don't appear → restart the `claude` session (plugins load at session start).
- `firm-*` commands "not found" → the plugin's `bin/` joins PATH only while the plugin is enabled; confirm it's installed + the session was restarted.
- Unrelated MCP startup errors → `claude --strict-mcp-config` runs with no MCP servers (the firm needs none).

## Uninstall
```bash
claude plugin uninstall agent-firm@local
claude plugin marketplace remove local
```
