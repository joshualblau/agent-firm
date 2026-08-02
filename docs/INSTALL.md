# Install & bootstrap the firm (any device)

The firm ships as a **versioned Claude Code plugin** (`agent-firm`) served from a **local marketplace**
(`local`) that is this repo. Install it once per machine at user scope, and every project on that
machine can use it.

## Prerequisites

Beyond the `claude` CLI and `git`, the firm needs two Python packages:

```bash
python3 -m pip install --user jsonschema pyyaml
```

- **`jsonschema` is required.** Without it `firm-validate-verdict` cannot schema-check a QA verdict
  and exits **4 (DEGRADED)**, which does not satisfy the Final gate — an unverifiable verdict is not
  evidence. `firm-doctor` FAILs while it's missing.
- **`pyyaml` is required to work ON the firm, and non-fatal (but degrading) to work WITH it.** It used
  to be described as merely "advisory"; that stopped being true when the regression suite landed —
  `tests/test-policy-yaml-valid.sh` needs it, so the suite cannot pass without it, and CI installs it.
  In a *work project* the firm still runs without it: the acceptance-criteria and eval-assertion
  parsers fall back to regex. But that fallback is looser and **fails closed**:
  `firm-traceability-check` reports `CANNOT VERIFY` and exits non-zero on criteria files pyyaml would
  have parsed exactly. `firm-doctor` WARNs (not FAILs) while it's missing.

`firm-bootstrap` reports what's missing and prints this command; pass `--with-python-deps` to have it
run the install for you. It never installs packages as a side effect — changing your machine should
be something you asked for.

## TL;DR (machine that already has this repo)
```bash
~/agent-firm/bin/firm-bootstrap          # marketplace + plugin + shell PATH links (idempotent)
~/agent-firm/bin/firm-bootstrap --with-python-deps   # ...and install the Python prerequisites
```
Then, per project (once):
```bash
cd <your project>
firm-install                             # merges the firm's permission rules into .claude/settings.json
```

**Migrating a project installed before this fix:** `firm-install` only ever *adds* rules, so a project
set up before the fix that retired `Bash(cat:*)` / `Bash(jq:*)` (they read straight around the
`Read(./.env)` / `Read(~/.ssh/**)` deny rules) still grants them — no version number reliably tells you
which side of the fix a given install is on, so check directly: `firm-doctor` FAILs while a retired rule
is present, and plain `firm-install` warns and exits 3. Clear them with:
```bash
firm-install --migrate                   # removes retired rules, prints exactly what it deleted
firm-install --user --migrate            # same, for user-scope settings
```
See `agent-firm/policy/retired-permissions.json` for the full list of retired rules and why.

**What `--migrate` is allowed to delete.** Deletion is the one destructive thing `firm-install` does,
so it is fenced in rather than trusted:

- **Scope-honouring.** Each entry in `retired-permissions.json` declares a `scope` naming the
  permission list(s) it may be deleted from, and `--migrate` removes the rule *only from those*. Both
  current entries declare `["allow", "ask"]` — deliberately, not redundantly: `allow` and `ask` are
  interchangeable places for the same grant to sit, so a rule that drifted from `allow` into `ask` is
  the same withdrawn grant and must still be cleaned up. An entry that named only `allow` would leave
  that drifted copy in place. A `scope` this entry does *not* name is never touched.
- **It refuses to delete from `deny` — exit 4.** If a retired entry ever names `deny`, `firm-install`
  stops and changes nothing. Removing a deny rule *widens* what the agent may do; a cleanup path that
  can quietly do that is a privilege escalation with a tidy name. Fixing it means editing the policy
  file deliberately, not passing a flag.
- **Exit 5 if the policy file exists but can't be read or parsed.** Not a silent no-op "success" — a
  migration that cannot see the list of what to retire has not verified anything. A policy file that is
  *absent altogether* is a different case: that is non-fatal, and the install proceeds as union-only
  while printing that there was nothing to migrate. (`firm-doctor` FAILs on the missing file; that is
  where absence is caught.)
- **Atomic write + backup.** The new settings are written to a temp file and `rename`d into place, so
  an interrupted run cannot leave a truncated `settings.json`, and the previous contents are kept as a
  timestamped backup. The backup is created `O_CREAT|O_EXCL|O_NOFOLLOW` at mode `0600`: a name already
  sitting at `settings.json.<stamp>.bak` — including a **dangling symlink** planted by someone who can
  write the `.claude/` directory but not the file — is never followed and never overwritten; the run
  moves to the next `-N` suffix, and refuses (exit 6) rather than force one. A **newly created**
  `settings.json` is `0600` regardless of your umask, because it is a permission policy and a
  permissive umask would otherwise make it group/world-writable. An **existing** file keeps its own
  mode.

`firm-install` exit codes: **0** applied (or already current) · **2** bad arguments · **3** a retired
rule is present, re-run with `--migrate` · **4** refused: `retired-permissions.json` has a malformed
entry, or an entry whose `scope` is missing, names an unknown list, or names `deny` · **5**
`retired-permissions.json` exists but is unreadable or unparseable · **6** refused: no free backup
name next to the settings file. Exits 4, 5 and 6 all write nothing.

### How `firm-*` gets on your shell PATH
A Claude Code plugin's `bin/` joins `$PATH` **only inside a `claude` session** — so `firm-install`,
which you run from your own terminal, would otherwise be "command not found". `firm-bootstrap` fixes
this by calling `firm-link`, which symlinks every `firm-*` tool into `~/.local/bin`:
```bash
firm-link                                # symlink firm-* into ~/.local/bin (or $FIRM_BIN_DIR)
firm-link --dir /usr/local/bin           # ...somewhere else
firm-link --uninstall                    # remove the symlinks (and the PATH block, if any)
```
The links point at **this repo**, so `git pull` propagates immediately — no re-linking. If the target
directory isn't on your `PATH`, `firm-link` appends a marked block to your shell rc (`~/.zshrc` for
zsh); open a new shell to pick it up. Set `FIRM_SKIP_LINK=1` to make `firm-bootstrap` skip this step.
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
~/agent-firm/bin/firm-link                     # firm-* onto your SHELL PATH (see above)
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
- `firm-*` "not found" **in your terminal** → run `firm-link` (the plugin's `bin/` is only on PATH
  inside a `claude` session). Then open a new shell, or `export PATH="$HOME/.local/bin:$PATH"`.
- `firm-*` "not found" **inside a claude session** → confirm the plugin is installed and the session
  was restarted (`claude plugin list`).
- A `firm-*` tool can't find its policies/templates → you have a stale hand-made symlink or copy from
  before `firm-link`; re-run `firm-link` to repoint it at the repo.
- Unrelated MCP startup errors → `claude --strict-mcp-config` runs with no MCP servers (the firm needs none).

## Uninstall
```bash
~/agent-firm/bin/firm-link --uninstall    # remove the shell PATH symlinks + rc block
claude plugin uninstall agent-firm@local
claude plugin marketplace remove local
```
