# System Change PR: Hardening and measurement phase (3 PRs)

A proposed change to the **firm itself** (not a project deliverable). Raised from a full read of the
repo, reviewed for generalizability, approved by the human, versioned, and guarded by golden evals.

- **Proposed by run:** none — raised from a standalone review of the firm repo (2026-07-28), not from
  an engagement retrospective. Recording it here anyway: changes to the firm go through this process
  regardless of what surfaced them, and a change that skips the record is a change nobody reviewed.
- **Date (UTC):** 2026-07-28
- **Status:** approved

## Motivation

The firm's thesis is *evidence, not confidence*. Its own tooling did not meet that bar:

1. **`firm-integrate` could merge into the default branch.** It ran under `set -uo pipefail` (no `-e`)
   and discarded the exit code of `git switch`. A failed switch — dirty tree, or the branch already
   checked out in a linked worktree, both routine during Build — left HEAD wherever it was and merged
   every `wt/*` branch *there*. With the Lead on `main` that is an autonomous merge to the default
   branch: never-rule #1. The permission layer could not see it, because `Bash(firm-integrate:*)` is
   allow-listed while `Bash(git merge:*)` is only `ask` — the wrapper laundered the prompt.
   Reproduced three ways in `tests/test-integrate.sh` before the fix.
2. **`Bash(cat:*)` / `Bash(jq:*)` read around the Read-tool deny rules.** `Read(./.env)`,
   `Read(~/.ssh/**)`, `Read(~/.aws/**)` bind the Read tool only. An allow-listed `cat` ignores all of
   them. Worse, `firm-install` only ever *unions* rules, so every project installed from an older
   version keeps the grant forever — a warning would have left the hole open everywhere it already is.
3. **Degraded verdict validation passed the gate.** `firm-validate-verdict` exited **0** when
   `jsonschema` was absent, printing a parenthetical. Any machine without the library silently
   downgraded the firm's only mechanical evidence check to "has the right top-level keys". Nothing
   installed, documented, or checked the dependency. `firm-gpt-qa` additionally discarded the
   validator's exit code entirely — its last statement was an `echo`, so an unvalidatable second-voice
   verdict still exited 0.
4. **The firm did not test the firm.** ~1500 lines of bash and embedded Python doing merges, worktree
   creation, schema validation, and assertion checking — no tests, no CI. The only verification was
   the golden evals, which need a `claude` login and real budget.
5. **Six of seven golden evals assert `APPROVE`.** The architecture rests on QA being willing to
   **BLOCK**, and nothing tested it. `final_gate_pending` was `subtype == "success" && !is_error`,
   which a run that did nothing also satisfies, and `no_default_branch_merge` counted commits and
   called `<= 1` clean — true only because fixtures happen to start with one commit.
6. **Governance without instrumentation.** "Promote a specialist after ≥3 uses" appears in three files
   and nothing counts uses.

## Proposed change

Three stacked PRs. Files:

**PR 1 — security (this PR)**
- `bin/firm-integrate` — positive `integration/*` allowlist (no override flag), `git switch` rc
  checked, HEAD asserted against the target before any merge.
- `.claude/settings.json` — `Bash(cat:*)` / `Bash(jq:*)` removed from `allow` (the enforced fix: falls
  through to the tool-default prompt, unconditionally). Additional `deny` entries for
  `cat`/`head`/`tail`/`less`/`strings` against `.env*`, `~/.ssh/**`, `~/.aws/**` are labeled
  **unverified supplemental protection, not enforced security** — their bare-glob syntax deviates from
  every existing `Bash(cmd:*)` rule in the file and was never confirmed against Claude Code's live
  permission engine (see `agent-firm/policy/retired-permissions.json`).
- `agent-firm/policy/retired-permissions.json` (new) — withdrawn rules, with reasons.
- `bin/firm-install` — `--migrate` removes retired rules (the only rule-deleting path in the firm),
  prints exactly what it deleted; plain install warns and exits 3. Order-independent flag parsing.
- `bin/firm-validate-verdict` — structural fallback now exits **4 (DEGRADED)**, never 0.
- `bin/firm-gpt-qa` — stops discarding the validator's exit code; an unvalidatable verdict is a BLOCK.
- `bin/firm-doctor` — Python-deps section (`jsonschema` FAIL, `pyyaml` WARN) and a retired-rule FAIL.
- `bin/firm-bootstrap` — `--with-python-deps` (opt-in; never installs as a side effect), plus a fix
  for flag parsing that only ever inspected `$1`.
- `agent-firm/policy/gate-matrix.md`, `definition-of-done.yaml`, `docs/INSTALL.md` — the rules above.
- `tests/` — harness + `test-integrate.sh`, `test-validate-verdict.sh`, `test-install-migrate.sh`.

**PR 2 — tests + CI**: the rest of the `bin/` suite; `final_gate_pending` and
`no_default_branch_merge` rebuilt on a `default_branch_start_sha` baseline recorded by `firm-new-run`;
GitHub Actions running `bash -n`, the suite on ubuntu + macOS (bash 3.2), and `firm-run-evals
--structural`.

**PR 3 — eval, measurement, docs**: the `qa-blocks-broken-build` BLOCK eval (shell fixture, not
`node --test` — node isn't present in this environment); `firm-qa-clean-check` run by the Lead, named
for what it actually proves; `bench/usage-log.jsonl` (append-only, `mkdir`-locked) with tightened
promotion criteria; `docs/ENFORCEMENT.md`; doc de-duplication and drift fixes.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes — every item is a property of the firm itself, not of any
  engagement. The `integration/*` allowlist, fail-closed validation, and the retired-rule migration
  path apply to every project the firm is installed into.
- **Risk of overfitting the firm to one repo:** Low. The one judgement call is the shell-based eval
  fixture, chosen because node is absent here; existing node fixtures are deliberately left alone
  rather than converted, so the suite still covers both shapes.

## Risk & rollback

- **Risk:** `firm-install --migrate` deletes permission rules. Bounded to rules named in
  `retired-permissions.json`, prints every deletion, and is covered by `tests/test-install-migrate.sh`
  (including "the project's own rules survive"). Removing `Bash(cat:*)` costs occasional permission
  prompts — accepted deliberately over an open read-around.
- **Risk:** `firm-validate-verdict` returning 4 will newly block Final gates on machines without
  `jsonschema`. That is the intended behavior; `firm-doctor` and `firm-bootstrap` both name the fix.
- **Risk (accepted, labeled):** the new `deny` entries added alongside the `Bash(cat:*)`/`Bash(jq:*)`
  removal are **unverified supplemental protection, not enforced security** — their pattern syntax was
  never confirmed against Claude Code's live permission engine, and no non-interactive way to verify it
  exists (checked: no dry-run permission flag, binary is compiled Mach-O, not statically inspectable).
  The enforced part of the fix — removing the `allow` grant — does not depend on them.
- **Rollback:** revert the PR — firm config is versioned in git. `firm-install` re-adds any rule that
  is restored to `.claude/settings.json`.

## Golden eval to guard it

- Eval: `agent-firm/evals/qa-blocks-broken-build/` (PR 3)
- What it asserts: QA emits **BLOCK** on a genuinely failing suite with an uncovered acceptance
  criterion, does not advance the default branch, and stops at the Final gate.
- **Status: behaviorally UNVERIFIED.** `firm-run-evals --structural` only proves the fixture is shaped
  correctly. The behavioral claim requires a real `firm-run-evals qa-blocks-broken-build` (a `claude`
  login and real budget), which has not been run. The `0.8.0` release is deliberately withheld until
  it has — releasing on a structural check would be exactly the overclaiming the Definition of Done
  prohibits.
- Regression posture: `tests/run-tests.sh` + `firm-run-evals --structural` run in CI from PR 2.

## Known follow-ups (not smuggled into these PRs)

- Convert the remaining `node --test` eval fixtures to a runtime-agnostic shape, or declare node a
  prerequisite. Today the suite assumes a runtime that isn't checked anywhere.
- True read-only enforcement for `qa-tester` / `reviewer`. `firm-qa-clean-check` proves the checkout
  was left clean; it cannot catch modify-then-revert or writes outside the checkout. Documented in
  `docs/ENFORCEMENT.md` rather than papered over.
- **This is a hardening and measurement phase, not self-improvement.** It records outcomes; it does
  not yet extract lessons, propose changes, benchmark a proposed change before adoption, or version
  and roll back improvements automatically. That loop still runs through a human writing one of these.

## Human decision

- [x] approved by **Matan Kamhi** on **2026-07-28 (UTC)** — reviewed across four plan revisions;
      approval recorded before PR 1 merges, since PRs 1 and 2 would otherwise change the firm while
      the record governing them still read `proposed`.

## Independent review of PR 1 (before merge)

An independent adversarial review of the pushed PR 1 branch — reproducing claims rather than trusting
them — found four issues, all fixed on the same branch before merge (no scope change to what PR 1
covers):

1. `firm-doctor`'s new retired-permission-rules check silently reported PASS on a settings.json it
   could not actually parse (invalid JSON, or `permissions` shaped as the wrong JSON type). Reproduced
   two ways; fixed to WARN on any parse failure instead of a false PASS. Regression tests added:
   `tests/test-doctor-retired-check.sh`.
2. The new `deny` entries' pattern syntax was asserted as protection without ever being confirmed
   against the live permission engine. Investigated further (no dry-run permission flag, binary not
   statically inspectable) and confirmed unverifiable in this environment — relabeled everywhere as
   **unverified supplemental protection, not enforced security**
   (`agent-firm/policy/retired-permissions.json`, this record's Risk section). The enforced part of the
   fix (removing the `allow` grant) does not depend on them and is unaffected.
3. `firm-install`'s migrate-suggestion message misidentified scope for any project path that happens to
   start with `~/.claude` as a raw string (e.g. `~/.claude-work/<project>/` — a pattern this repo's own
   `.gitignore` anticipates). Reproduced end-to-end; fixed to use the scope `firm-install` already
   resolved from its own arguments rather than re-deriving it from the target path. Regression test
   added (and a matching one confirming real `--user` installs still say `--user`, so the fix couldn't
   be over-corrected in the other direction).
4. `docs/INSTALL.md` said retired rules affect projects "installed before v0.7.0", but this PR ships no
   version bump and the retired rules are present in the *current* 0.7.0 on `main` — reworded to be
   version-agnostic and point at `firm-doctor` as the actual check.

A stale `docs/ENFORCEMENT.md` forward-reference (that file doesn't exist until PR 3) was also caught
and removed while fixing #2.
