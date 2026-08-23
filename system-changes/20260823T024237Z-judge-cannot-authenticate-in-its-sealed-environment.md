# System Change PR: the judge cannot authenticate in its sealed environment

A proposed change to the **firm itself** (not a project deliverable).

- **Proposed by run:** `20260821T205151Z-readiness-probe-shapes`; discovered by its implementer while
  fixing the readiness probes
- **Date (UTC):** 2026-08-23
- **Status:** approved
- **This is the one that actually blocks the cross-provider second voice.** Changes #1 and #2 were
  each real and each necessary, but neither could ever have restored the judge on its own.

## Motivation

`bin/firm-reviewer-common:1064-1077` builds the judge's environment by discarding almost everything
and pointing every configuration variable at freshly created empty directories:

```python
"HOME": str(config_root),
"XDG_CONFIG_HOME": str(config_root / "xdg"),
"CODEX_HOME": str(config_root / "codex"),
"CLAUDE_CONFIG_DIR": str(config_root / "claude"),
```

Only `PATH`, `LANG`/`LC_*`, `SYSTEMROOT` and the firm's own `STUB_`/`FIRM_TEST_` variables survive.
**Nothing anywhere in the file seeds a credential into those directories.** So the provider CLI
starts with no authentication, correctly reports that it is not logged in, and — now that change #2
makes readiness classify honestly — the wrapper returns a *trusted* exit 3, `reason: authentication`.

This is not a coding slip. The isolation is deliberate and valuable: `config_root` is what keeps the
judge away from the operator's agent configuration, hooks, plugins, MCP servers and session history,
and the behaviour sentinel exists partly to detect escapes from it. **Loosening it is a security
decision, which is why the implementer that found it refused to change it unilaterally and why this
needs its own approved change.**

### Measured behaviour (P2 row; codex-cli 0.149.0, Claude Code 2.1.238)

The two providers fail for entirely different reasons, and the fix is not symmetric.

**Codex — credential is a file, and a minimal passthrough works.**

| environment | `codex login status` |
|---|---|
| ambient | rc 0, `Logged in using ChatGPT` |
| sealed `HOME`, sealed `CODEX_HOME` | rc 1, `Not logged in` |
| **sealed `HOME`, real `CODEX_HOME`** | **rc 0, `Logged in using ChatGPT`** |

The credential is `~/.codex/auth.json`, a mode-`600` file. Pointing `CODEX_HOME` at the real
directory restores authentication **with `HOME` still sealed** — a genuinely minimal passthrough.
Note it also exposes `history.jsonl` and global state in the same directory, so "point at the real
`CODEX_HOME`" is not the same as "pass one credential file".

**Claude — credential is in the macOS keychain, and the config variable is the gate.**

| environment | `loggedIn` |
|---|---|
| ambient | `true` |
| `CLAUDE_CONFIG_DIR` **unset**, real `HOME` | `true` |
| `CLAUDE_CONFIG_DIR` set to its own real default `~/.claude` | **`false`** |
| sealed `HOME`, `CLAUDE_CONFIG_DIR` unset | error: config file not found |
| sealed `HOME` + a copy of `.claude.json`, `CLAUDE_CONFIG_DIR` unset | `false` |
| sealed `HOME` + `CLAUDE_CONFIG_DIR` containing a copy of `.claude.json` | `false` |

**Setting `CLAUDE_CONFIG_DIR` at all makes Claude Code report logged out, even when it is set to the
exact path it would have used anyway.** There is no `.credentials.json` on disk; the credential lives
in the macOS keychain under `Claude Code-credentials`. Copying the config file into a sealed home does
not restore authentication, so the config file is not sufficient and something further gates the
keychain lookup. **This half is measured but not explained, and the implementer will need to
establish the actual mechanism rather than guess at it.**

## Proposed change

- Files: `bin/firm-reviewer-common` (phase environment), plus tests and a golden eval.
- The design question this opens, and which the reviewer and the human should answer explicitly:
  **what may a judge inherit?**

Three candidate postures, to be evaluated rather than assumed:

1. **Credential-scoped passthrough.** Pass exactly what authentication requires and nothing else —
   for codex, a read-only view of the credential rather than the whole `CODEX_HOME` if that can be
   made to work; for claude, whatever the investigation shows is minimally necessary. Keeps the
   isolation's intent while making the judge usable. **Preferred starting point.**
2. **Explicit operator opt-in.** The judge runs sealed by default and inherits credentials only when
   the operator states it, per run or per configuration, with the inheritance recorded in the ledger
   so an audit can see which runs had a judge that could actually authenticate. Slower to use,
   strongest provenance.
3. **Documented refusal.** Decide that the judge is not permitted to hold operator credentials at
   all, and that the cross-provider second voice therefore requires a separately provisioned account
   or an API key. This is a legitimate answer — it says the firm's independent review is a resourced
   capability, not a free one — but it must then be stated plainly, because today the firm claims a
   required second voice it structurally cannot obtain.

Whatever posture is chosen:

- **The isolation's other guarantees must not be collateral damage.** Agent configuration, hooks,
  plugins, MCP servers, session history and the operator's project files must remain out of the
  judge's reach. A passthrough that restores authentication by handing over the whole home directory
  fails this test even if the judge then runs.
- **Record what was inherited.** The attempt record should state which credential surfaces were
  exposed, so a run's provenance shows whether its judge was sealed or credentialed.
- **Fail closed.** If the chosen passthrough is unavailable or refused, the outcome must remain a
  trusted, correctly classified unavailable — not a silent fallback to an unauthenticated judge whose
  refusal looks like a verdict.

## Generalizability check (reviewer)

- **Applies beyond this project?** Entirely. It governs whether any run of this firm, in either
  provider direction, can obtain the second voice the policy calls required for auth / permissions /
  crypto / PII work.
- **Risk of overfitting:** high, and worth naming. The Claude finding is macOS-keychain-specific and
  the Codex finding is file-specific; both vendors will change. The durable artifact is the posture
  and the recorded provenance, not today's variable names.

## Risk & rollback

- **Risk: the highest of the four changes in this family**, and in the opposite direction from the
  others. Those three risked *suppressing* review; this one risks *widening what a judge can see*.
  A judge is a model invocation with a contract, not a trusted process, and the isolation is what
  currently bounds it.
- **Second-order:** once the judge authenticates, its verdicts become load-bearing for the first
  time. Everything downstream of this gate — the judge invocation, output-schema handling, verdict
  parsing, the four-shape envelope extraction on the claude branch — has never executed against a
  live provider. Expect defects there, and expect the first real cross-provider verdict to need
  scrutiny rather than trust.
- **Rollback:** revert this PR; firm config is versioned in git. Note that rollback restores a firm
  whose second voice cannot run, which is where this started.

## Golden eval to guard it

- **Eval:** `agent-firm/evals/judge-credential-boundary/` (to be added)
- **What it asserts:**
  1. With the chosen posture, an authenticated host produces a judge that **reaches the judge phase**
     rather than stopping at readiness.
  2. The isolation still holds for everything else: a canary file in the operator's agent config,
     hooks, plugins, MCP configuration and session history is **not** readable from the judge
     environment. This is the assertion that keeps the fix honest.
  3. With the passthrough unavailable, the outcome is a trusted, correctly classified unavailable —
     never an unauthenticated judge whose output is mistaken for a verdict.
  4. The attempt record states which credential surfaces were exposed.
- [ ] Golden evals pass (`firm-run-evals`) — BEFORE and AFTER. Same caveat as its siblings: the
      behavioural baseline is already red on unmodified `main`, so the structural pass and the firm
      test suite carry the regression gate.

## Human decision

- [x] approved by josh@heightslabs.com on 2026-08-23 (UTC)   |   [ ] rejected — reason:
- **Posture chosen: 1, credential-scoped — start minimal and WIDEN until the judge actually runs in
  both directions.** The operator's explicit direction: an asymmetric answer per provider direction is
  acceptable; a judge that runs matters more than a judge that stays sealed; the judge is bounded by its
  role contract. Keep the cheap guards that do not impede this — record what was inherited, and keep a
  canary on surfaces authentication does not require — but do not let them block widening.

## Evidence

- Environment construction: `bin/firm-reviewer-common:1064-1077`; inherited-variable allowlist at
  `:1056-1060`; the empty config subdirectories created at `:1076-1077`.
- All measurements above taken directly on the P2 row. The codex passthrough result and the
  `CLAUDE_CONFIG_DIR`-is-the-gate result are each reproducible in one command.
- Downstream state: run `20260821T205151Z-readiness-probe-shapes` reaches
  `trusted structured authentication readiness is unavailable: authentication (exit 3)` in both
  provider directions, which is change #2 working correctly and reporting this defect accurately.
- The human declined a second-voice waiver on change #2 specifically so that a genuine cross-provider
  verdict would be obtained, which is what makes this the next change rather than a later one.
