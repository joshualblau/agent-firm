# System Change PR: worktree by default, and a branch/PR scope that replaces the blanket push gate

A change to the **firm itself** (not a project deliverable).

- **Proposed by run:** operator instruction, 2026-08-25, during the PR #6 reconciliation
- **Status:** approved for implementation by the repository owner on 2026-09-02; implemented in
  Agent Firm 0.9.0 on a dedicated topic branch, pending review and merge
- **Scope:** the operator asked for this as the behaviour for **all projects**, not only this
  repository. That means two artifacts: this firm-scoped change, and a user-level default. See
  "Two homes" below.
- **Files implicated:** `agent-firm/policy/action-scopes.yaml`, `agent-firm/contracts/lifecycle.md`,
  `bin/firm-new-worktree`, `bin/firm-merge-guard`, `.claude/settings.json`, and the user-level
  `~/.claude/` configuration for the all-projects half.

## Motivation

Two problems, both observed live in the engagement that prompted this.

**1 · Work in the shared checkout collides.** This engagement repeatedly had a reviewer, primary QA
and the Lead operating on the same working tree at once. The roles handled it — the correctness lens
noticed the hazard unprompted and moved to an isolated clone, and the security lens self-reported
creating a stray untracked file in the repo root, correctly noting that `fast_compute` reads
untracked files and could have perturbed a concurrent role's `--fast` scoping. That is two near
misses caught by the diligence of individual roles rather than by the design. Worktrees already exist
(`bin/firm-new-worktree`) and are already used for implementer work orders; the gap is that they are
not the *default* for every role that touches files.

**2 · The push gate is too blunt, and it blocks the wrong thing.** `action-scopes.yaml` currently
says `push: human_gate` — all pushes, to any ref. In practice the only irreversible, outward-facing
action that warrants a gate is one that affects the **remote default branch**. Pushing a topic branch
and opening a PR is *how work becomes reviewable*; gating it makes the reviewable path the expensive
one and leaves "merge locally and push main" as the cheap one. That is the wrong incentive, and it is
backwards from the intent.

## Proposed change

### A · Worktree by default

Every role that writes files works in a git worktree dedicated to that role and stage, not in the
shared checkout. Read-only roles may read the shared checkout. The worktree is created at role start
and removed when the work lands.

### B · Replace the blanket push gate with a default-branch scope

```yaml
local_repository:
  read: allowed
  write: within_worktree
  commit: allowed_in_worktree        # was: ask
  push_topic_branch: allowed          # NEW — non-default branches only
  push_default_branch: prohibited     # NEW — never, not even with a gate
  merge_to_default_branch: prohibited # remote; local merge stays a human gate
external_systems:
  pr_create_or_edit: allowed          # was: pr_or_issue_creation: human_gate
```

**What stays prohibited, and this is the whole of it:** pushing the remote default branch, merging
into it remotely, or otherwise altering it directly — including force-pushes, branch deletion, and
protection changes. Everything else about a topic branch is ordinary work.

### C · The default lifecycle for a change

1. Work happens in a worktree.
2. When the work is done, the branch is pushed and a **PR is opened recording the change** — the PR
   body is the record, not a separate document.
3. When the PR is merged, the branch is deleted and the worktree is cleaned.

Step 3 is a real requirement, not tidiness: this engagement finished with **12 worktrees** still
registered, and twice had to rescue evidence from a session-scoped scratchpad because a work order
forbade writing into the run directory. Cleanup that is nobody's job does not happen.

## Two homes, because the operator asked for all projects

- **This file** governs the firm: `action-scopes.yaml`, the lifecycle contract, and the repo's
  `.claude/settings.json`.
- **A user-level default** governs every other project. That belongs in `~/.claude/` — a rule stating
  the worktree/branch/PR default, plus `permissions` entries that allow topic-branch pushes and PR
  operations while denying anything that writes the remote default branch.

They must not drift. The firm's copy should state that the user-level default is the source for
non-firm repositories, rather than duplicating its text.

## What this does NOT change

- Local merge to the default branch remains a **human gate**. This change is about the *remote*.
- `firm-merge-guard`'s identity allowlist is unchanged. Its ceiling is unchanged and still honestly
  rated: it is client-side and bypassable, and it is not branch protection.
- Nothing here weakens the Final gate, the two-voice rule, or the traceability requirements.

## Risks

- **A permissive `push_topic_branch` is only as safe as the default-branch prohibition is precise.**
  `git push origin HEAD:main`, `git push --mirror`, `git push --all`, and a refspec that resolves to
  the default branch must all be caught. A rule matching only the literal string `push origin main`
  is a check that cannot fail in the sense this repo keeps finding. The prohibition must be
  implemented against the *resolved destination ref*, not the command text.
- **PR creation is outward-facing.** Allowing it means an agent can publish. That is the intent, but
  it should be stated plainly rather than arriving as a side effect of relaxing the push gate.
- Worktree-by-default costs disk and setup time per role, and `firm-new-worktree` currently allocates
  a port and database name per worktree — that may need revisiting for read-mostly roles.

## Evidence from this engagement

- Concurrent-role collisions: the correctness lens moved to an isolated clone unprompted; the
  security lens self-reported a stray repo-root file and named `fast_compute` as the exposure.
- The blunt push gate: the Lead was blocked from pushing a **verified, human-approved** merge whose
  tree was byte-identical to the approved candidate and whose full suite passed 5336/0, while nothing
  structurally prevented the far riskier local-merge-then-push path.
- Cleanup that is nobody's job: 12 worktrees still registered at the end of the engagement.

## Regression gate

`firm-run-evals` before and after. Note the eval fixture's own `firm-new-run` behaviour is sensitive
to `init.defaultBranch`, fixed in this repo during the engagement — re-run rather than assume.

## Implementation record

- The canonical policy distinguishes topic-branch publication from direct default-branch writes.
- `firm-merge-guard` resolves the remote-advertised symbolic `HEAD` with bounded
  `git ls-remote --symref` and every explicit push destination before permitting a topic push. It
  does not trust the locally mutable `refs/remotes/<remote>/HEAD` cache. Default writes/deletes are
  prohibited even for allow-listed identities; multiple, unsupported, or ambiguous push shapes fail
  closed so remote discovery cannot overrun the hook timeout.
- Both provider adapters require dedicated worktrees for repository-writing roles while preserving
  the central run-artifact namespace.
- The release is versioned as 0.9.0 so a cachebuster alone cannot masquerade as policy adoption.
- PR create/edit is ordinary delivery work; PR merge and direct default-branch mutation remain human
  decisions.
- This branch changes the Agent Firm repository/plugin only. The separate user-level
  `~/.claude/settings.json` still contains a broad `Bash(gh:*)` ask that shadows its specific PR
  allows under Claude Code's Deny → Ask → Allow precedence; reconciling that user-level file is an
  explicitly disclosed follow-up, not an unrecorded side effect of plugin installation.
