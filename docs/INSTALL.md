# Install & bootstrap the firm (any device)

The firm ships as a **versioned Claude Code plugin** (`agent-firm`) served from a **local marketplace**
(`heights-labs`) that is this repo. Install it once per machine at user scope, and every project on that
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
claude plugin install agent-firm@heights-labs         # user scope = all projects
```

## On a NEW device (first get the repo there)
The plugin is served from this repo, so the repo must exist on the new machine first.

1. **Get the repo onto the device** — one of:
   - `git clone <your-remote> ~/agent-firm` (needs a git remote — not set up yet; see below), or
   - copy `~/agent-firm` over (rsync/scp/USB), or
   - (later) `chezmoi`-managed dotfiles, the rest of Phase 4.
2. **Run the bootstrap:**
   ```bash
   ~/agent-firm/bin/firm-bootstrap
   ```
3. Per project: `firm-install`, then `claude` → `/agent-firm:start`.

> No git remote is configured yet, so cross-device sync needs one. Ask me to "set up a remote for the
> firm" and I'll wire it up (you'll push), after which step 1 is just `git clone`.

## Update to a newer firm version (propagate an improvement)
After the canonical repo changes and its `version` is bumped:
```bash
git -C ~/agent-firm pull                                    # if using a remote
claude plugin marketplace update heights-labs
claude plugin update agent-firm@heights-labs                # restart to apply
```
`firm-bootstrap` also updates in place if the plugin is already installed.

## Per-project version pinning (optional)
Default install is user scope (one version everywhere). To pin a project:
```bash
cd <project>
claude plugin install agent-firm@heights-labs --scope project   # writes enabledPlugins into .claude/settings.json (commit it)
```

## Verify / troubleshoot
```bash
claude plugin list                       # should show agent-firm@heights-labs — ✔ enabled
claude plugin details agent-firm@heights-labs    # Agents (7), the start command, the ledger hook
claude plugin validate ~/agent-firm      # manifest check
```
- Components don't appear → restart the `claude` session (plugins load at session start).
- `firm-*` commands "not found" → the plugin's `bin/` joins PATH only while the plugin is enabled; confirm it's installed + the session was restarted.
- Unrelated MCP startup errors → `claude --strict-mcp-config` runs with no MCP servers (the firm needs none).

## Uninstall
```bash
claude plugin uninstall agent-firm@heights-labs
claude plugin marketplace remove heights-labs
```
