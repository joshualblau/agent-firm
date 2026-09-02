# System Change PR: judge-input redaction corrupts the JSON it was asked to preserve

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260902T064517Z-link-audit-tool`
- **Date (UTC):** 2026-09-02
- **Status:** proposed

## Motivation

The cross-provider judge BLOCKED with, among other objections, `obj-controlled-evidence-integrity`:

> `input/run-evidence/files/run.jsonl` has malformed JSON at lines 116, 128, 462, 573, 574, 647,
> and 865 … the exact current-SHA diff, accepted-set completeness, target-ledger history, and
> implementation handoff cannot be validated.

**The judge was right, and the run's ledger was fine.** The Lead and primary QA each independently
parsed the real `run.jsonl`: 1538 records, 0 malformed. The corruption exists only in the copy the
wrapper hands the judge.

### Root cause — measured, not inferred

`bin/firm-reviewer-common`'s `redact()` closure applies five regex substitutions to the *raw text*
of every controlled file (`transform="redacted_utf8"`). The fifth is an email matcher:

```python
(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", "[REDACTED_ACCOUNT]")
```

`run.jsonl` is JSONL, so a logged shell command containing Python source appears as a JSON string
with **escape sequences as two literal characters**. Given `…None\n\n\n@pytest.hookimpl(wrapper=True)…`
the regex matches **`n@pytest.hookimpl`** — local part `n`, domain `pytest.hookimpl` — where that
`n` is the second character of the `\n` escape. The substitution consumes it:

```
before:  ledger.current_nodeid = None\n\n\n@pytest.hookimpl(wrapper=True)
after:   ledger.current_nodeid = None\n\n\[REDACTED_ACCOUNT](wrapper=True)
                                        ^^ dangling backslash -> Invalid \escape
```

**A Python decorator preceded by a newline is read as an email address.** Reproduced against the
run's real ledger: source 0 malformed lines → judge's copy **7 malformed lines, at exactly the
line numbers the judge reported**. Attribution by applying each substitution alone: substitutions
#1–#4 produce 0 malformed lines; #5 produces all 7.

### Why this is worse than a redaction bug

`bin/firm-reviewer-common` **validates the ledger immediately before snapshotting it**:

```python
ledger_records = [json.loads(line) for line in ledger_source.read_text(...).splitlines() if line]
...
stop(f"target ledger is malformed before judge snapshot: {exc}", 1)
```

So the wrapper certifies the file as well-formed JSONL, then writes a copy that is not, and never
re-checks. The judge is handed evidence the firm has already vouched for, finds it corrupt, and
correctly refuses to approve on unvalidatable input. **The two-voice gate cannot be cleared on the
merits, and the failure is silent from the primary side** — nothing on the Claude side ever sees a
malformed file.

This is not specific to this engagement. Any run whose ledger logs Python source — decorators are
the common trigger, and `@` appears in far more than decorators — produces the same corruption. The
firm's own repository is a Python codebase.

## Proposed change

- Files: `bin/firm-reviewer-common`, `tests/test-reviewer-hermeticity.sh` (or a new
  `tests/test-judge-input-integrity.sh`), `agent-firm/evals/judge-input-integrity/`

**1. Redact JSON and JSONL structurally, not textually.** For an origin whose source parses as JSON
or JSONL, parse it, apply the substitutions to **string values only**, and re-serialize. Syntax is
then preserved by construction, and a key can never be truncated into its neighbour. Keep the
existing text path for genuinely unstructured evidence (logs, transcripts, Markdown).

**2. Add a fail-closed post-redaction invariant, which is the part that generalises.** State it as:

> If a controlled file's source parsed as JSON/JSONL, its redacted copy must parse as JSON/JSONL.
> Otherwise `stop(...)` — do not hand the judge evidence the wrapper cannot itself re-read.

Change #1 fixes the bug that was found. Change #2 catches the next one, including in the text path
and in file types nobody has thought about yet. **The defect here was not that redaction was wrong;
it was that nothing checked redaction's output**, and a corrupting transform is indistinguishable
from a working one until a judge trips over it.

**3. Record the transform in the manifest as lossy-or-structural.** The manifest already carries
`transform`; extend the value set so `redacted_json` is distinguishable from `redacted_utf8`, and a
reader can tell which files were parsed rather than pattern-substituted.

**Deliberately NOT proposed:** widening or weakening the email pattern. Requiring the local part to
be ≥2 characters would fix `n@…` and miss `\t` + a one-letter local part; anchoring differently
trades one false positive for another. The redaction rules are a denylist and will always be
approximate — the structural fix and the invariant do not depend on getting them right.

## Generalizability check (reviewer)

- **Applies beyond this project? YES.** The corrupting input is the firm's own `run.jsonl`, produced
  by the firm's own ledger, on any run whose logged commands contain `@` after an escape sequence.
  Nothing about it is specific to the link-audit tool. The trigger observed here — a `@pytest`
  decorator inside a logged heredoc — will occur in any Python engagement, including work on the
  firm itself.
- **Risk of overfitting:** low. The invariant is stated over "source parsed / copy must parse", not
  over any pattern, file, or project. The structural path keys off what the file *is*, not what run
  produced it.
- **Scales with ledger size:** the more the ledger records, the more likely a match. This gets worse
  over a run, and worse over the life of the firm.

## Risk & rollback

- **Risk (low):** structural redaction changes the byte content of the judge's copy for JSON inputs —
  re-serialization normalises whitespace and key order unless `sort_keys=False` and separators are
  pinned. The manifest records `controlled_sha256` and `controlled_bytes`, so any change is visible;
  the eval must assert the copy still contains no unredacted secret material.
- **Risk (low):** a file that parses as JSON but is *intended* as opaque text would now be
  re-serialized. Mitigated by keying on the origin's actual parse result, and by the invariant
  applying only when the source itself parsed.
- **Rollback:** revert this PR — firm config and `bin/` are versioned in git.

## Golden eval to guard it

- Eval: `agent-firm/evals/judge-input-integrity/`
- What it asserts:
  1. A ledger line containing `\n@pytest.hookimpl(...)` — the exact observed trigger — survives
     redaction as parseable JSON.
  2. A real secret in a JSON **string value** is still redacted (the fix must not buy syntax at the
     cost of disclosure).
  3. A secret in a JSON **key** is still redacted.
  4. The post-redaction invariant **bites**: a deliberately corrupting substitution injected into
     the transform causes `stop(...)`, not a silent hand-off. Without this case the eval would pass
     on a fix that merely avoided today's regex.
- [ ] Golden evals pass (`firm-run-evals`) — attach the run output.

## Evidence

- Reproduction: `repro_redact.py` (in the proposing run's scratchpad) — applies the verbatim
  `redact()` substitutions to the real ledger. Source: 0 malformed. Copy: 7 malformed, at lines
  116, 128, 462, 573, 574, 647, 865 — matching the judge's report exactly.
- Judge verdict: `.agent-firm/runs/20260902T064517Z-link-audit-tool/08-qa-verdict.gpt.json`,
  objection `obj-controlled-evidence-integrity`, attempt `gpt-c2-a0003`.
- Disposition and firm position:
  `.agent-firm/runs/20260902T064517Z-link-audit-tool/two-voice/objection-analysis.md`.
- Retrospective: `.agent-firm/runs/20260902T064517Z-link-audit-tool/11-retrospective.md`,
  "Firm-level defects observed".

## Human decision

- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
