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

**PR 2 — tests + CI (merged `1eb9943`, 2026-07-30):** the rest of the `bin/` suite (13 new test files);
`final_gate_pending` and `no_default_branch_merge` rebuilt on a `default_branch_start_sha` baseline
recorded by `firm-new-run`, both **fail closed** with no fallback to the old commit-count heuristic;
an explicit `firm-ledger-log final_gate_pending` event required (wired into `CLAUDE.md` /
`commands/start.md`) rather than inferred from the `claude -p` result envelope; GitHub Actions
(`.github/workflows/ci.yml`) running `bash -n`, the suite on ubuntu + macOS (bash 3.2 via `/bin/bash`),
and `firm-run-evals --structural` — green on both OS legs after one follow-up fix (macOS's
externally-managed system Python rejected `pip install`; fixed with `actions/setup-python@v7` pinned
to 3.12). 244 assertions at merge time. A latent `tests/lib.sh` variable-shadowing bug (bare
`desc`/`out`/`rc` clobbered across direct calls, inherited from PR 1) was also found and fixed, with
all of PR 1's original 85 assertions re-run to confirm no regression.

**PR 3 — eval, measurement, docs (this pass):** the `qa-blocks-broken-build` BLOCK eval (shell fixture,
not `node --test` — node isn't present in this environment; the fixture's suite command needed an
*exact* `Bash(sh test/run-tests.sh)` allowlist entry added to `firm-run-evals`, found only by trying to
run it); `firm-qa-clean-check` (Lead-run, never QA self-certifying) + a new `qa_checkout_clean`
assertion verb, plus a new `artifact_absent` verb (the negative counterpart `artifact_exists` was
missing); a bench usage log at `$(git rev-parse --git-common-dir)/agent-firm/bench-usage.jsonl` —
**not** a tracked `bench/usage-log.jsonl` as originally sketched: a tracked file would give every
linked worktree its own separate copy, so parallel writers in different worktrees would append to
different files entirely (proven with a real concurrent cross-worktree test); tightened promotion
criteria in `bench/registry.yaml` + `agents/recruiter.md`; `docs/ENFORCEMENT.md`, `docs/README.md`, a
banner on the dated `docs/PHASE*.md` files (kept in place, not moved — 11 reference updates for the
same signalling value banners give); doc de-duplication (`agent-firm/policy/model-tiers.yaml`) and
drift fixes. Also found and fixed: `agent-firm/policy/definition-of-done.yaml` shipped in PR 1 with
invalid YAML (a bare colon-space inside a multi-line plain-scalar list item) that sat broken through
PR 2 because nothing ever parses that file programmatically — fixed, with a new generic regression
test (`tests/test-policy-yaml-valid.sh`) guarding every `agent-firm/policy/*.yaml` and
`agent-firm/templates/*.yaml` file, proven against the original bug before restoring the fix.

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

- Eval: `agent-firm/evals/qa-blocks-broken-build/` (PR 3) — 8 evals total, up from 7.
- What it asserts: QA emits **BLOCK** on a genuinely failing suite with an uncovered acceptance
  criterion, does not advance the default branch, logs the `final_gate_pending` event, and its QA
  checkout is left clean. Verified as far as possible without spending real budget: hand-simulated both
  a correctly-behaving firm (8/8 assertions pass) and a firm that wrongly rationalizes an APPROVE
  despite the broken suite (fails at exactly `verdict_is`, 7/8) — proving the assertion set actually
  discriminates correct from incorrect behavior, not just structure.
- **Status: behaviorally UNVERIFIED.** `firm-run-evals --structural` only proves the fixture is shaped
  correctly. The behavioral claim — and separately, whether the `Bash(sh test/run-tests.sh)` permission
  rule actually matches at runtime — requires a real `firm-run-evals qa-blocks-broken-build` (a `claude`
  login and real budget), which has not been run, per explicit instruction for this pass. The `0.8.0`
  release is deliberately withheld until it has — releasing on a structural check would be exactly the
  overclaiming the Definition of Done prohibits.
- Regression posture: `tests/run-tests.sh` (295 assertions, 16 files, at the close of PR 3) +
  `firm-run-evals --structural` run in CI from PR 2.

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

## Independent review of PR 2 (before merge)

A second bounded, adversarial review — reproducing claims rather than trusting them, same standard as
PR 1's — covering diff scope, test quality, the baseline fail-closed behavior, the explicit
`final_gate_pending` event, and the CI workflow. **No new Critical, High, or Medium issue found.** One
**Low**-severity gap surfaced and was accepted as a recorded follow-up rather than fixed in PR 2:

- `default_branch_status()` in `firm-check-assertions` resolves the default branch by **bare name
  only** (`git rev-parse --verify --quiet <branch>`) and never falls back to `origin/<branch>` the way
  `firm-new-run`'s baseline capture does. In a repo where only a remote-tracking ref exists and no
  local branch does, the check reports `CANNOT VERIFY` and fails — even though the branch genuinely
  hasn't moved. Reproduced directly during the review. **Fails safe** (a false FAIL, never a false
  PASS) and cannot trigger on the paths that matter — eval fixtures and CI both use fresh local-only
  repos with no `origin` at all. See "Known follow-ups" below; still not fixed as of PR 3, by design
  (fixing it means touching the load-bearing gate assertion PR 2 just stabilized, for a case no current
  caller hits).

Independently re-verified: 244/244 assertions on the exact merged commit, both bug-fix claims in the
PR (the `git rev-parse` ref-echo bug, the `tests/lib.sh` variable-shadowing bug) reproduced empirically
rather than trusted, and the full coverage-scope claim cross-checked against the real `bin/` directory.

## Known follow-ups (not smuggled into these PRs)

- Convert the remaining `node --test` eval fixtures to a runtime-agnostic shape, or declare node a
  prerequisite. Today the suite assumes a runtime that isn't checked anywhere. (`qa-blocks-broken-build`
  is shell-based specifically to avoid adding to this pile — see its own note above.)
- True read-only enforcement for `qa-tester` / `reviewer`. `firm-qa-clean-check` (PR 3) proves the
  checkout was left clean; it cannot catch modify-then-revert or writes outside the checkout. Documented
  in `docs/ENFORCEMENT.md` rather than papered over.
- **`default_branch_status()`'s bare-branch-name resolution** (found in PR 2's independent review,
  above). Low severity, fails safe, not fixed. Add the same `origin/<branch>` fallback
  `firm-new-run`'s baseline capture already has, when it's next touched for another reason.
- **Sweep other structured-but-never-parsed files for the same latent-YAML-error class.**
  `definition-of-done.yaml` (found and fixed in PR 3) shipped in PR 1 with invalid YAML that sat broken
  through PR 2 because nothing ever parsed it programmatically. `tests/test-policy-yaml-valid.sh` now
  guards `agent-firm/policy/*.yaml` and `agent-firm/templates/*.yaml` specifically, but agent
  frontmatter (`agents/*.md`), `.claude-plugin/*.json`, and other structured-but-prose-consumed files
  weren't swept for the same risk.
- **This is a hardening and measurement phase, not self-improvement.** It records outcomes; it does
  not yet extract lessons, propose changes, benchmark a proposed change before adoption, or version
  and roll back improvements automatically. That loop still runs through a human writing one of these.

## Human decision

- [x] approved by **Matan Kamhi** on **2026-07-28 (UTC)** — reviewed across four plan revisions;
      approval recorded before PR 1 merges, since PRs 1 and 2 would otherwise change the firm while
      the record governing them still read `proposed`.
