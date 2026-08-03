# Runbook — enabling real (server-side) protection on `main`

**Status: NOT executed. The firm never runs this file.** Every call below is an external write to
GitHub's configuration, and two of them cost money or change account state — human-only actions
under `agent-firm/policy/action-scopes.yaml`. This document exists so the human can do it in one
sitting, and so nobody mistakes the client-side gate for this.

## Why you would run this — what the client-side gate cannot do

`bin/firm-merge-guard` (the merge-authority gate wired into the `PreToolUse` hooks) is
**client-side and bypassable** by anyone with repo write access: edit the script, delete the hook
entry from `.claude/settings.json` or `hooks/hooks.json`, set `git config user.email` to a listed
value, or run `git` in a terminal outside the AI tool. It is **not a security boundary**, it is
**not branch protection**, and it **cannot** provide a "required PR review" — **only GitHub can**,
which is what this runbook is for. What the gate actually does is stop an *AI agent* from
performing an unauthorised merge or push. Those are different guarantees; see
[ENFORCEMENT.md](ENFORCEMENT.md) for both rows.

Of the three asks, this is the split:

| Ask | Client-side gate | Server-side (this runbook) |
|---|---|---|
| Block an AI agent merging to `main` | yes, fails closed | yes |
| Block an AI agent pushing | yes, plus `Bash(git push:*)` is categorically denied in `.claude/settings.json` | yes |
| **Required PR review** | **no — impossible client-side** | **yes, this is the only way** |

## Step 0 — measured current state (re-run this before you start)

```bash
OWNER=joshualblau REPO=agent-firm

# The unambiguous check. Readable by any collaborator, no admin needed.
gh api "repos/$OWNER/$REPO/branches/main" --jq '.protected'      # => false  (today)

# Is the repo private, and is it owned by a personal account or an org?
gh api "repos/$OWNER/$REPO" --jq '{private, owner_type: .owner.type, default_branch}'
# => {"private":true,"owner_type":"User","default_branch":"main"}

# Are you an admin of it? You need admin to configure protection.
gh api "repos/$OWNER/$REPO" --jq '.permissions'
```

Measured on 2026-08-03 from the `younglionsolutions` account:

- `.protected` -> **`false`** — no protection in force.
- `repos/$OWNER/$REPO/branches/main/protection` -> **404**. Do **not** read that 404 as proof of
  anything: GitHub returns 404 on that endpoint both when protection is absent **and** when the
  caller is not an admin, and `.permissions` showed `admin: false` for this account. `.protected`
  above is the check that actually distinguishes the two cases.
- `repos/$OWNER/$REPO/rulesets` -> **403 `Upgrade to GitHub Pro or make this repository public to
  enable this feature.`** That is GitHub telling you the plan gate directly.

## Step 1 — the prerequisite you cannot skip

Protected branches and rulesets on a **private** repository owned by a **personal account** require
**GitHub Pro**. On the Free plan they are available only on **public** repositories. So you have
exactly three routes:

| Route | Cost | Consequence |
|---|---|---|
| Buy **GitHub Pro** for the owning account | ~$4/month, ~$48/year at the time of writing — **check the current price**, do not trust this number | Keeps the repo private, unlocks protection + rulesets |
| Make the repo **public** | free | Rulesets and protected branches work; the code becomes world-readable |
| Transfer to a free **organization** | free | Org-owned repos also unlock per-user/team push restrictions (see Step 3) |

Also: **the owner must run the calls.** The account currently authenticated in `gh`
(`younglionsolutions`) has `admin: false` on this repo, so every call below would 404/403 for it.
Run `gh auth switch` (or `gh auth login`) as the repository owner first, and confirm with
`gh api user --jq .login`.

## Step 2 — classic branch protection (the smaller, better-documented API)

Requires admin. Replace nothing but `OWNER`/`REPO` if you copy this verbatim.

```bash
OWNER=joshualblau REPO=agent-firm

gh api -X PUT "repos/$OWNER/$REPO/branches/main/protection" \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["test (ubuntu-latest)", "test (macos-latest)"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": true,
  "block_creations": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
```

Three things about that payload, stated plainly because getting them wrong wastes a sitting:

1. **`"restrictions": null` is not laziness.** Restricting *which users* may push is, on the classic
   API, **organization-only** — user/team/app push restrictions are not available for a repo owned
   by a personal account. This is the one part of the ask that this route cannot satisfy as written.
   On a personal repo, "who may push" is controlled by **collaborator access**, not by protection:

   ```bash
   gh api "repos/$OWNER/$REPO/collaborators" --jq '.[] | {login, push: .permissions.push}'
   gh api -X DELETE "repos/$OWNER/$REPO/collaborators/<login>"      # removes their write access
   ```

   With `required_pull_request_reviews` set, a collaborator with write access still cannot push
   *directly* to `main` — they must open a PR and get an approval — which is the effect you want.
   `enforce_admins: true` is what stops the owner (and any admin) bypassing it too; drop it only if
   you want an escape hatch, and know that you have then re-opened the hole.
2. **`contexts` must match your check-run names exactly**, or the branch becomes unmergeable
   (waiting forever for a check that never reports). Get the real names from a recent run first:

   ```bash
   gh api "repos/$OWNER/$REPO/commits/main/check-runs" --jq '.check_runs[].name'
   ```

   If that returns nothing yet, set `"required_status_checks": null` for now and add it later.
3. `--input -` with a heredoc is used rather than a pile of `-f` flags because this payload has
   nested objects, which `-f` cannot express.

### Read this before you run Step 2: who can actually approve your PRs?

`required_approving_review_count: 1` **plus** `enforce_admins: true` on a two-collaborator repo has
a consequence the payload does not advertise, and it decides whether the "required PR review" ask is
really met or only met on paper.

Measured facts about this repo, not assumptions:

```bash
gh api "repos/$OWNER/$REPO/collaborators" --jq '.[] | {login, push: .permissions.push}'
gh api user --jq .login          # -> the account the AI's `gh` is authenticated as
```

At the time of writing the collaborators are **`joshualblau`** (owner) and
**`younglionsolutions`** (`permissions.push: true`), and `younglionsolutions` is *the identity the
AI operates as*. GitHub does not let a PR author approve their own PR. So with `count: 1` and
`enforce_admins: true`:

- the owner cannot merge his own PR without an approving review, and
- the **only** account available to give that review is the AI's.

That satisfies the ask in form while making the AI's own account the sole possible approver, and it
simultaneously locks the human out of merging solo. Three real options, pick deliberately:

| Option | Payload | What you get | What it costs |
|---|---|---|---|
| **(a) Add a second HUMAN reviewer** | keep `count: 1`, `enforce_admins: true`; invite a human collaborator and keep the AI's account out of the review path | The ask as intended: a human reviews, admins included | Needs a second human who will actually review |
| **(b) No review count, PR still required** | `"required_pull_request_reviews": {"required_approving_review_count": 0, "dismiss_stale_reviews": true, "require_code_owner_reviews": false}`, `enforce_admins: true` | Direct pushes to `main` are blocked for everyone including admins; changes must go through a PR. **No fake review is invented** | You can self-merge your own PR, so this is "no direct push", not "reviewed" |
| **(c) Keep `count: 1`, drop admin enforcement** | `count: 1`, `enforce_admins: false` | Owner keeps a solo path | Re-opens the hole: an admin can push straight to `main`, so the control no longer binds the account most able to break things |

**Recommended: (b) now, (a) when a second human exists.** (b) is the honest version of the ask that
one person can operate today; (c) is the only one that quietly gives back what you just bought.

One more lever, worth naming because it is the *actual* answer to "restrict who may push": the AI's
`gh` identity has write access to this repo **today**. Removing that collaborator removes the push
capability entirely, which no branch-protection setting on a personal-account repo can do:

```bash
gh api -X DELETE "repos/$OWNER/$REPO/collaborators/younglionsolutions"
```

## Step 3 — or a ruleset (the newer API; org repos get per-actor bypass)

Rulesets are the modern equivalent and are configured per repository. Same plan gate.

```bash
OWNER=joshualblau REPO=agent-firm

gh api -X POST "repos/$OWNER/$REPO/rulesets" --input - <<'JSON'
{
  "name": "protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "rules": [
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true
      }
    },
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ],
  "bypass_actors": []
}
JSON
```

- `deletion` blocks branch deletion; `non_fast_forward` blocks force-push. Those two rules are the
  "block force-push and deletion" half of the ask.
- `bypass_actors: []` means nobody bypasses, including you. If you want the repository-admin role to
  be able to bypass, use `[{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]`
  — and note that **bypass by an individual user account is not expressible**; ruleset bypass actors
  are roles, teams, apps and deploy keys. Per-user granularity needs an **organization**, which is
  the honest answer to "restrict who may push to *these two accounts*".

## Step 4 — verify. This is the step that distinguishes success from the ambiguous 404

**Which verification belongs to which route.** `.protected` is documented by GitHub against
*classic branch protection*. It is **not documented to reflect rulesets**, so if you took the Step 3
ruleset route, do not treat `.protected: false` as failure — check the ruleset endpoints instead
(1b/3 below). Using the wrong check here produces a false alarm on a correct configuration, which is
worse than no check at all.

```bash
OWNER=joshualblau REPO=agent-firm

# 1. CLASSIC route (Step 2) — the unambiguous boolean, works even without admin.
gh api "repos/$OWNER/$REPO/branches/main" --jq '.protected'
#    false = no classic protection in force   |   true = classic protection is active
#    Verified on this repo: currently `false`. Do NOT use this to verify a RULESET.

# 1b. RULESET route (Step 3) — ask what rules apply to the branch. Needs no admin, and unlike
#     `.protected` this endpoint is documented to answer for rulesets.
gh api "repos/$OWNER/$REPO/rules/branches/main" --jq '[.[] | .type]'
#    expect a non-empty list containing "pull_request", "deletion", "non_fast_forward"
#    []  = no ruleset applies to main (whatever `.protected` says)

# 2. If (and only if) you are an admin, read the classic detail back:
gh api "repos/$OWNER/$REPO/branches/main/protection" \
  --jq '{reviews: .required_pull_request_reviews.required_approving_review_count,
         admins: .enforce_admins.enabled,
         force_push: .allow_force_pushes.enabled,
         deletion: .allow_deletions.enabled}'
#    expect: reviews>=1, admins=true, force_push=false, deletion=false

# 3. Rulesets (empty list = none active):
gh api "repos/$OWNER/$REPO/rulesets" --jq '.[] | {name, enforcement, target}'

# 4. The end-to-end proof, which no API read can substitute for: try to push a throwaway commit
#    to main from a clone and confirm the server rejects it.
#    Expect: "protected branch hook declined" / "Changes must be made through a pull request".
```

If you took the **classic** route (Step 2) and step 1 still says `false` after the PUT appeared to
succeed, the call did not do what you think — re-read its response body rather than assuming, and
check you were authenticated as an admin of the repo.

If you took the **ruleset** route (Step 3), judge it by **1b** and **3**, not by step 1: `.protected`
is not documented to reflect rulesets, so a `false` there alongside a non-empty `rules/branches/main`
means your ruleset is active and the boolean simply does not speak to it. Note that `rulesets` and
`rules/branches/main` are both behind the same plan gate as Step 3 itself — a 403 there means the
ruleset route was never available, not that it failed.

## Rollback

```bash
gh api -X DELETE "repos/$OWNER/$REPO/branches/main/protection"        # classic
gh api "repos/$OWNER/$REPO/rulesets" --jq '.[].id'                    # find the id
gh api -X DELETE "repos/$OWNER/$REPO/rulesets/<id>"                   # ruleset
```

## What is still true after you finish

Server-side protection and the client-side gate are complementary, not redundant. Protection stops
*everyone*, including the AI, at the server — but only for the operations it covers, and only on the
branches it names. The client-side gate stops the AI *earlier* and covers local operations GitHub
never sees (a local `git merge` into `main` that is never pushed). Neither replaces the other, and
the client-side one remains removable by anyone with write access. That is its ceiling, stated once
more so no reader of this file leaves with the wrong impression.
