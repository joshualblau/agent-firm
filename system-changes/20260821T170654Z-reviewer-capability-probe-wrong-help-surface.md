# System Change PR: reviewer capability probe interrogates the wrong help surface

A proposed change to the **firm itself** (not a project deliverable).

- **Proposed by run:** `20260821T034506Z-kehillat-ahuza-site` (Claude-primary, website engagement)
- **Date (UTC):** 2026-08-21
- **Status:** approved

## Motivation

The cross-provider second voice could not run at all during the `kehillat-ahuza-site` engagement.
`firm-gpt-qa` returned **exit 3, `unsupported_capability`**, naming five missing controls:
`--ignore-user-config`, `--ignore-rules`, `--ephemeral`, `--output-schema`,
`--output-last-message`.

That diagnosis is **wrong**, and the wrongness is the point of this proposal.

`bin/firm-reviewer-common` performs capability discovery by running the provider executable's
**top-level** help:

```python
discovery_command = [executable, "--help"]        # firm-reviewer-common:864
...
required_flags = ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--sandbox",
                  "--ask-for-approval", "--model", "--output-schema", "--output-last-message"]
missing = [flag for flag in required_flags if flag not in help_text]
```

It then invokes the provider through a **subcommand**:

```python
executable, "exec", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
"--ephemeral", "-s", "read-only", "-a", "never", "-m", model, ...   # firm-reviewer-common:945
```

Measured against `codex-cli 0.149.0`:

| flag | in `codex --help` | in `codex exec --help` |
|---|---|---|
| `--ignore-user-config` | no | **yes** |
| `--ignore-rules` | no | **yes** |
| `--ephemeral` | no | **yes** |
| `--output-schema` | no | **yes** |
| `--output-last-message` | no | **yes** |
| `--sandbox` | **yes** | **yes** |
| `--model` | **yes** | **yes** |
| `--ask-for-approval` | **yes** | no |

**Neither surface alone contains all eight**, so the probe cannot pass against any Codex version.
The capability is present and the invocation would work; the readiness check simply asks the wrong
question.

Three properties make this worse than an ordinary bug:

1. **It fails closed into silence.** Exit 3 is the *trusted* "provider unavailable" path. The Lead is
   instructed to treat it as an environmental fact and seek a human waiver — so a firm defect is
   laundered into a routine waiver request, run after run.
2. **It suppresses exactly the check that exists to catch what one provider misses.** On a run
   touching auth, permissions, crypto or PII the judge is *required*; this defect makes "required"
   unenforceable while reporting that the requirement was legitimately unmet.
3. **The false diagnosis is actionable and wasteful.** In this engagement it produced a real
   `brew upgrade codex` (0.145.0 → 0.149.0) that could not have helped, because the probe was never
   testing what its message claimed.

The Codex-primary direction is presumed to have the same shape for `firm-claude-qa`; its required
list (`--safe-mode`, `--system-prompt`, `--strict-mcp-config`, `--no-session-persistence`,
`--model`, `--effort`, `--output-format`, `--json-schema`, `--tools`, `--disallowedTools`) must be
verified against the surface that CLI is actually invoked through, not assumed correct.

## Proposed change

- Files: `bin/firm-reviewer-common`, plus a golden eval under `agent-firm/evals/`.
- Summary:
  1. Discover capabilities against the **union of the help surfaces the wrapper actually invokes** —
     for `gpt`, both `codex --help` and `codex exec --help`. Keep both probes bounded by the existing
     `discovery_timeout` and keep a non-zero exit from either one a BLOCK, as today.
  2. Assert the discovered surface set and the invocation path **cannot drift apart**: every flag in
     the `required_flags` list must be one the wrapper actually passes, and every flag the wrapper
     passes must be covered by discovery. A future edit that adds a flag to the invocation without
     adding it to discovery should fail a test, not a production run.
  3. Make the failure message name **which surface** was searched, so a future false negative is
     diagnosable in one read instead of by source inspection.
  4. Apply the same treatment to the `claude` branch after verifying its real invocation surface.

Deliberately **not** proposed: relaxing the probe, or removing it. A readiness check that fails
closed is correct; this one just checks the wrong thing. Widening it to "assume available" would
trade a false negative for a false positive on the exact gate that protects PII-touching runs.

## Generalizability check (reviewer)

- **Applies beyond this project?** Yes, entirely. Nothing here is specific to a website, to Hebrew,
  or to the Ahuza engagement. It affects the cross-provider second voice on **every** run of the
  firm, in both provider directions.
- **Risk of overfitting the firm to one repo:** None identified. The change is to the firm's own
  provider-readiness logic; the originating project is only where the defect became visible. The
  fix must be validated against provider CLI behaviour, not against this repository.

## Risk & rollback

- **Risk:** low-to-moderate. Probing two surfaces doubles a bounded discovery step (measured at
  ~21ms for one surface in this engagement). The genuine risk is the opposite of today's: a probe
  that is too permissive would let an incapable CLI through to a failed invocation. Mitigated by
  keeping the union strict — every required flag must be found in *some* invoked surface — and by
  the drift assertion in item 2.
- **A second, larger risk this proposal surfaces but does not resolve:** every prior run of this
  firm that recorded a `trusted_reason: unsupported_capability` second-voice waiver may have been
  waiving a bug rather than an environment. Those runs' two-voice dispositions should be re-examined
  once this is fixed. That is a records question, not a code question, and belongs to whoever owns
  those runs.
- **Rollback:** revert this PR; firm config is versioned in git.

## Golden eval to guard it

- **Eval:** `agent-firm/evals/reviewer-capability-discovery/` (to be added)
- **What it asserts:**
  1. Against a stub executable whose required flags are split across top-level and subcommand help
     exactly as `codex` splits them, discovery **succeeds** — this is the regression that would have
     caught the present defect.
  2. Against a stub genuinely missing a required flag from every surface, discovery still returns
     **exit 3 `unsupported_capability`** — the fail-closed behaviour is preserved, not traded away.
  3. The `required_flags` list and the flags in the real invocation are consistent in both
     directions, so the two cannot silently diverge again.
- [ ] Golden evals pass (`firm-run-evals`) — run BEFORE and AFTER the edit; attach both outputs.

## Human decision

- [x] approved by josh@heightslabs.com on 2026-08-21 (UTC)   |   [ ] rejected — reason:

## Evidence from the originating run

- Ledger: `firm_tooling_defect_found` in run `20260821T034506Z-kehillat-ahuza-site`.
- Second-voice attempts, all bound to real candidates: `gpt-c1-a0006`, `gpt-c1-a0009` (generation 1,
  candidate `7fb560c`), `gpt-c2-a0002`, `gpt-c2-a0003` (generation 2, candidate `f5c34d2`) — every
  one exit 3 `unsupported_capability`, before and after the Codex upgrade.
- Flag/surface table above measured directly against `codex-cli 0.149.0` on the P2 row
  (macOS 26.5.1, Darwin 25.5.0, arm64, CPython 3.9.6).
- The originating run is **held open and unfinalized** pending a genuine second opinion: the human
  declined the waiver at its Final gate specifically to obtain one.
