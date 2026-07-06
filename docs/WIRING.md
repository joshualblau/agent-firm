# Wiring the firm (accounts, secrets, hardening)

The firm ships as scaffolding + tooling + docs. This runbook is the one-time wiring **you** do to make it
live on a machine — the steps that involve entering a password/token or creating an account are yours by
design (the firm never touches real credentials; it only references them via `op://`).

Order matters — later steps depend on earlier ones. Replace `work` with your profile name (`work`,
`personal`, `client-acme`, …). You can start with a single profile.

**Minimum to be operational:** A → B → C (one profile) → D. Sections E–H are optional, per-need.
Run `firm-doctor` after any step — it fail-closed-checks the whole setup and tells you exactly what's off.

---

## A. Prerequisites (once per machine)

```bash
# You already have: claude, codex. Add the rest:
brew install 1password-cli direnv        # op must be >= 2.18 for service-account tokens
brew install --cask docker               # only if you want the sandbox/firewall + visual baselines

# direnv shell hook (so .envrc auto-loads on cd):
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc && source ~/.zshrc

# Make sure NO metered-API keys leak into subscription work (they silently switch you to metered billing):
grep -E 'ANTHROPIC_API_KEY|OPENAI_API_KEY|CODEX_API_KEY|ANTHROPIC_AUTH_TOKEN' ~/.zshrc ~/.zprofile 2>/dev/null
# Remove any that are set. firm-doctor also fails closed on these.

# Install the firm as a plugin (if not already):
~/agent-firm/bin/firm-bootstrap
```

## B. 1Password backbone (once) — *you do the account steps*

1. In the 1Password app, create a **shared** vault named `Firm`. (Not your Private vault — service
   accounts cannot read Private.)
2. Create a **service account** scoped to `Firm` (1Password app → Developer → Service Accounts, or
   `op service-account create`). Copy its token.
3. Put the token in your shell profile (it is the one hand-carried secret on a new machine):
   ```bash
   echo 'export OP_SERVICE_ACCOUNT_TOKEN="ops_...paste..."' >> ~/.zprofile
   echo 'unset OP_CONNECT_HOST OP_CONNECT_TOKEN' >> ~/.zprofile   # these would override the service account
   source ~/.zprofile
   op whoami        # confirm it authenticates
   ```

## C. Per-profile accounts (once per profile) — *you do the logins*

For each subscription account you want to switch between:

```bash
# --- Claude (the OAuth token is what actually switches the account on macOS; the config dir alone does not) ---
CLAUDE_CONFIG_DIR=~/.claude-work claude               # inside: /login to the account you want
CLAUDE_CONFIG_DIR=~/.claude-work claude setup-token   # prints a ~1-year token — copy it
# Store that token in the Firm vault as item "claude-work", field "credential":
op item create --category "API Credential" --vault Firm --title claude-work "credential=<paste-token>"

# --- Codex / ChatGPT (CODEX_HOME switches this account cleanly; --profile does NOT) ---
CODEX_HOME=~/.codex-work codex login                  # logs that ChatGPT account into ~/.codex-work/auth.json
```

## D. Per-project profile + secrets (once per project)

```bash
cd <your project>
firm-install                                     # merge the firm's allow/ask/deny into .claude/settings.json

cp ~/agent-firm/.envrc.example .envrc            # edit: set FIRM_PROFILE="work"
cp ~/agent-firm/.env.op.example .env.op          # edit: CLAUDE_CODE_OAUTH_TOKEN -> op://Firm/claude-work/credential
direnv allow                                     # loads the profile + resolves secrets on cd

firm-doctor                                      # fail-closed: no key leak, profiles isolated, op+direnv+refs OK
```

`.env.op` is committed (references only — no values); `.envrc` stays machine-local (gitignored).
`firm-doctor` must show **0 FAIL** before you run an engagement.

---

## E. Egress firewall (opt-in hardening — needs Docker)

```bash
# In <project>/.devcontainer/devcontainer.json, uncomment the two cap-add lines and the postStartCommand:
#   "--cap-add=NET_ADMIN", "--cap-add=NET_RAW"
#   "postStartCommand": "sudo /workspace/.devcontainer/egress-firewall.sh"
# If you use the ChatGPT/Codex endpoints INSIDE the container, first pick a CDN mitigation in
# .devcontainer/egress-allowlist.conf (rotating Cloudflare IPs — see docs/PHASE5.md §1).

# Open the project in the devcontainer (VS Code "Reopen in Container", or `devcontainer up`).
# It fails safe: if the firewall can't build, the container refuses to boot. Then confirm:
bash .devcontainer/verify.sh     # expect: "example.com blocked" + "api.anthropic.com reachable"
```

## F. Visual regression (per UI project)

```bash
cd <ui project>
npm i -D @playwright/test                          # NOT the bare `playwright` library
cp -R ~/agent-firm/agent-firm/templates/visual/{playwright.config.ts,tests} .
# Edit tests/visual.spec.ts for your app's URL/selectors.

# Generate baselines in the pinned Playwright image (baselines are per browser+OS):
docker run --rm -it -v "$PWD:/work" -w /work mcr.microsoft.com/playwright:v1.61.0-noble \
  npx playwright test --update-snapshots=changed
git add tests/__screenshots__ && git commit -m "visual baselines"
```

After this, `qa-tester` runs `firm-visual-check` automatically and BLOCKs on any diff. Update baselines
later only via `firm-visual-baseline` (human-reviewed) — QA never rewrites them.

## G. Remote approval alerts to your phone (pick one adapter)

Telegram is the low-friction default (free, no server):

```bash
# 1. In Telegram: message @BotFather → /newbot → copy the bot token.
# 2. Message your new bot once, then get your numeric chat_id:
curl -s "https://api.telegram.org/bot<token>/getUpdates" | jq '.result[0].message.chat.id'
# 3. Store both in the Firm vault:
op item create --category "API Credential" --vault Firm --title telegram \
  "bot-token=<token>" "chat-id=<chat_id>"
```

Then in the project's `.env.op` (already stubbed in the example), uncomment:

```bash
export FIRM_NOTIFY_ADAPTER="telegram"
export FIRM_TELEGRAM_TOKEN_REF="op://Firm/telegram/bot-token"
export FIRM_TELEGRAM_CHAT_REF="op://Firm/telegram/chat-id"
```

```bash
direnv allow
# Dry-run (sends a real test message to your phone):
echo '{"message":"wiring test","title":"agent-firm"}' | firm-notify
```

Slack / Pushover / ntfy work the same way (see `docs/PHASE5.md §3`). It is **notify-only** — the phone
alert tells you a gate is waiting; you still approve in the session.

## H. Calibrate the golden evals (once)

```bash
# In a node-20 environment (the devcontainer — a host shell on node 14 cannot run `node --test`):
firm-run-evals greet-fast-path
# This is the first live firm run; it bills your subscription. Confirm greet-fast-path PASSes,
# then wire `firm-run-evals` into CI as the System-Change regression gate.
```

---

## Second machine

A–C repeat (plus `chezmoi` for home glue — see `docs/PHASE4.md`, "Second-machine bootstrap"). The only
hand-carried secret is the one `OP_SERVICE_ACCOUNT_TOKEN`. Per project you re-clone, `cp` the two files,
edit `FIRM_PROFILE`, and `direnv allow`. Then `firm-doctor` to verify.

See also: `docs/INSTALL.md` (plugin install), `docs/PHASE4.md` (profiles/secrets rationale + the macOS
Keychain caveat), `docs/PHASE5.md` (firewall/visual/approvals/evals details).
