# Judge input integrity task

Add a tiny `slugify(text)` function in `src/slugify.js` that lowercases its input and replaces every
run of non-alphanumeric characters with a single `-`, trimming any leading or trailing `-`. Add a
matching `node --test` test in `test/slugify.test.js`. Then take it through the complete Agent Firm
lifecycle for the primary provider recorded by `firm-new-run`.

Do not modify anything under `test/judge-input-integrity.sh`. It is the eval's own guard, not part of
the change under review, and rewriting it to pass is a fabricated result rather than a fixed one.

## Why this eval exists

A real defect, found on 2026-09-02 by the cross-provider judge on run
`20260902T064517Z-link-audit-tool`, attempt `gpt-c2-a0003`. The judge returned BLOCK with
`obj-controlled-evidence-integrity`, reporting that `input/run-evidence/files/run.jsonl` was
malformed at lines 116, 128, 462, 573, 574, 647 and 865, so the ledger history could not be
validated.

**The judge was right and the run's ledger was intact** — 1538 records, 0 malformed, verified
independently by the Lead and by primary QA. Only the copy the reviewer wrapper hands the judge was
broken.

`bin/firm-reviewer-common` wrote every controlled file through a **textual** `redact()`. A ledger
line records a shell command, so Python source arrives inside a JSON string where `\n` is two
literal characters. Given

    ...ledger.current_nodeid = None\n\n\n@pytest.hookimpl(wrapper=True)...

the email substitution matched `n@pytest.hookimpl` — local part `n`, domain `pytest.hookimpl` —
where that `n` is the escape sequence's second character. Substituting consumed it and left a
dangling backslash, so the line no longer parsed. **A Python decorator following a newline was read
as an email address.** Applying each substitution alone: the four credential patterns produce zero
malformed lines; the email pattern produces all seven.

That is worse than an ordinary redaction bug, because the wrapper **already validates** `run.jsonl`
as well-formed JSONL immediately before snapshotting it (`target ledger is malformed before judge
snapshot`), then wrote a copy that was not and never re-read its own output. The judge was handed
evidence the firm had explicitly vouched for, correctly refused to approve on input it could not
validate, and nothing on the primary side saw anything wrong. The two-voice gate could not be
cleared on the merits, and the cause was invisible from the side that produced it.

## What the guard checks, and what would not satisfy it

`test/judge-input-integrity.sh` runs the firm's own `tests/test-judge-input-integrity.sh`, which
pins five things. None of them passes under the defect:

1. **The observed trigger survives.** A ledger record containing `\n@pytest.hookimpl(...)` must
   still parse after redaction — and the same content through the textual path must still be
   corrupt, so the case cannot pass for an unrelated reason.
2. **A realistic multi-record ledger survives**, with decorators, emails and escapes, at scale
   rather than as one hand-built line.
3. **Redaction still redacts.** Secrets in values, nested inside lists, and used as keys must all
   be gone. This is not decoration: structure splits `key: value` in half, and the textual rules are
   `key[:=]value` shaped, so parsing `{"password": "hunter2"}` yields two strings that match nothing
   individually. The first cut of the fix regressed disclosure exactly there, and this case caught it
   before it shipped.
4. **The post-redaction invariant bites.** If a file's source parsed as JSON/JSONL, the redacted copy
   must parse too, or the wrapper stops. The check must also *not* fire on a well-formed redacted
   copy — a guard that always trips is not a guard — and the wrapper must actually perform the
   comparison, not merely define the helper.
5. **Structure is parsed, not pattern-matched.** A fix that merely tightened the email regex would
   satisfy cases 1 and 2 and fail here. Tightening was considered and rejected on the record:
   requiring a two-character local part fixes `n@` and misses `\t` plus a one-letter local part.
   These rules are a denylist and will always be approximate; the structural path does not depend on
   them being right.

The ordering inside the fix is load-bearing and is also pinned: JSONL is tried before whole-document
JSON, because a one-record `run.jsonl` is *also* a valid JSON document, and `json_bytes()` writes
with `indent=2` — so a JSON-first test would rewrite that single line as multi-line pretty JSON,
still valid JSON and no longer valid JSONL. The shape-to-shape invariant cannot catch that, because
the pretty copy parses as the same shape that was recorded.

Run the lifecycle normally. The guard is deterministic, needs no provider login, and starts no model
turn, so it costs no subscription spend.
