# The `evidence_produced` producer contract

**Audience:** any role that publishes an artifact to a run ledger — today primary QA
(`roles/qa-tester.md`), tomorrow whoever else. This is the role-agnostic reference; a role contract
links here rather than restating the shape, so the two cannot drift apart independently.

**What this file is for:** you should be able to construct and run a publishing call that succeeds
using only this file. You should not need to read `bin/firm-ledger-log`'s source. If you find
yourself reading that source to answer a question this file should have answered, that is a defect
in this file — say so.

Everything below is the *current* protocol. A run that already published evidence under the older
rules keeps its own history readable and appendable unchanged; see "Legacy runs" at the end.

---

## 1. The record: twelve keys, exactly

The writer matches the current shape **exactly**. Twelve keys, no more and no fewer. An extra key is
not a tolerated extension and a missing key is not a lenient near-miss — either one makes the
record `invalid evidence publication fields`.

<!-- EVIDENCE_FIELDS:BEGIN
     The golden eval agent-firm/evals/evidence-producer-contract-sync/ reads the FIRST COLUMN of
     every table row between this marker and EVIDENCE_FIELDS:END, and asserts the resulting set is
     identical to bin/firm-ledger-log's live EVIDENCE_CURRENT_FIELDS. Adding, renaming or removing a
     field here without the writer agreeing (or vice versa) fails that eval by name. Keep every
     field in a first column cell of its own, written as `inline code`. -->

### 1.1 The four common fields — the writer supplies these, you do not

| key | who sets it | note |
|---|---|---|
| `ts` | the writer | UTC timestamp of the append |
| `event` | the writer | from the event name argument: `evidence_produced` |
| `event_id` | the writer | auto-generated, or yours via `--event-id` (see §2.2) |
| `run_id` | the writer | from the resolved `--run` target |

**Do not pass any of these as a `key=value` argument.** Ordinary mode refuses the four common fields
and the four native-only fields (`contract`, `authority`, `activation`, `activation_justification`)
as caller-supplied keys: `reserved field cannot be overridden: <key>`.

### 1.2 The eight producer-supplied fields — you set all eight

| key | value grammar | meaning |
|---|---|---|
| `sha` | exactly 40 lowercase hex chars | the live QA candidate SHA. Full, never abbreviated. |
| `generation` | `[1-9][0-9]*` | the live QA candidate generation. No `0`, no leading zeros. |
| `path` | run-relative canonical path (§1.3) | where the artifact lives, relative to the run directory |
| `sha256` | exactly 64 lowercase hex chars | SHA-256 of the artifact's bytes |
| `bytes` | `0` or `[1-9][0-9]*` | the artifact's exact byte count |
| `stage` | `/`-joined parts, each `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, whole value ≤ 256 chars | the stage instance, e.g. `qa/Q-01` |
| `role` | `[a-z][a-z0-9-]{0,63}` | the role, e.g. `qa-tester` |
| `role_start_event_id` | `evt-` + 1–128 chars of `[A-Za-z0-9._:-]` | the `event_id` of *your own* open `native_role_start` |

<!-- EVIDENCE_FIELDS:END -->

`sha`, `generation`, `path`, `sha256`, `bytes` are the five the older shape also had. `stage`,
`role`, `role_start_event_id` are the three that exist **only** in the current shape — their
presence on a row is the observable proof a run has entered the closed protocol.

### 1.3 What counts as a valid `path`

Run-relative and canonical. Each component must match `[A-Za-z0-9][A-Za-z0-9._-]{0,127}` and the
whole string must be ≤ 512 printable characters. That means: **no** leading `/`, no `.` or `..`
components, no trailing slash, no `./` prefix, no spaces, no component starting with a dot, and the
string must be byte-identical to its own normalized form. `09-test-evidence/coverage.json` is fine;
`./09-test-evidence/coverage.json`, `09-test-evidence//coverage.json` and
`/abs/09-test-evidence/coverage.json` are all refused as `unsafe relative path` or
`non-canonical relative path`.

Unlike the seal record, an evidence `path` is **not** required to sit under `09-test-evidence/` —
any canonical run-relative path is accepted. Putting evidence under `09-test-evidence/` is
convention, not enforcement.

---

## 2. The invocation

### 2.1 Copy this

```sh
firm-ledger-log --run "$RUN_DIR" --strict evidence_produced \
  sha="$CANDIDATE_SHA" \
  generation="$GENERATION" \
  path="$RUN_RELATIVE_PATH" \
  sha256="$(shasum -a 256 "$RUN_DIR/$RUN_RELATIVE_PATH" | awk '{print $1}')" \
  bytes="$(wc -c < "$RUN_DIR/$RUN_RELATIVE_PATH" | tr -d ' ')" \
  stage="$STAGE_INSTANCE" \
  role="$ROLE" \
  role_start_event_id="$MY_ROLE_START_EVENT_ID"
```

This is **ordinary mode** — plain `key=value` arguments. It is executable as written; nothing here
needs reconstructing from a field list.

**You do not need native mode (`--role-start`) to publish evidence.** `stage` and `role` are
reserved *producer* field names, but ordinary mode only refuses the common fields and the
native-only fields as caller-supplied keys, and `stage`/`role` are in neither of those two sets. So
passing them as ordinary `key=value` arguments is accepted exactly as shown.

### 2.2 Flags

- `--run <run-dir>` — the target run directory. Pass it explicitly. Without it the tool reads
  `.agent-firm/CURRENT_RUN` from the current working directory, which is ambient state another run
  may own.
- `--strict` — **required in practice.** Without it, every failure in §3 exits **0** and writes
  **no row**. See §4.
- `--event-id <id>` — optional; supply your own `evt-…` id (grammar as in §1.2's
  `role_start_event_id` row) when a later artifact has to cite this exact publication.
- `--print-event-id` — optional; prints the resulting `event_id` on stdout so you can capture it.

### 2.3 Deriving the values you do not invent

- `sha` and `generation` come from `09-test-evidence/qa-candidate.json`
  (`candidate_sha`, `generation`). Do not compute them yourself and do not use an abbreviated SHA.
- `role_start_event_id` is the `event_id` of the `native_role_start` record that opened *your*
  current role window. It is in the run ledger; it is not something you mint.
- `sha256` and `bytes` must be measured from the artifact bytes on disk **after** the artifact is
  final. Compute, then publish; do not publish and then touch the file.

---

## 3. Preconditions — what the writer checks beyond the field names

A correct twelve-key record is necessary and not sufficient. All of the following are enforced.

> **Read this before §3.1: every failure below prints the same thing.** Under `--strict`, a
> publication refused for *any* reason in this section exits 1 having printed exactly one line:
>
> ```
> firm-ledger-log: invalid evidence publication
> ```
>
> There is no diagnostic distinguishing a stale candidate from a `0664` artifact from a closed role
> window from a duplicate. The internal reason names quoted below are for *your* diagnosis — they
> are not printed. Verified by running each case: §3.2, §3.4, §3.5 and §3.6 all produce that
> identical line. So when a publication is refused, work the checklist in §6 rather than reading
> the message.

### 3.1 Run state that must already exist

- `run-metadata.json` must exist in the run directory, be readable, and be well-formed as
  `firm-new-run` wrote it. Its file mode must be **`0600` or `0644`** — note that, unlike the two
  files below, `0400` is *not* accepted for this one.
- `09-test-evidence/qa-candidate.json` must exist, be readable, be well-formed as the QA checkout
  wrote it, and be mode `0400`, `0600` or `0644`.
- `run.jsonl` (the ledger) must exist and be mode **`0600`**.

If either JSON file is missing, unreadable, or fails its own internal consistency checks (run id
match, base-SHA agreement, repository-root and git-common-dir agreement), publication is refused —
internally as `current evidence identity unavailable`, on your terminal as the one generic line. Do
not repair these by hand; regenerate them with the tool that owns them.

### 3.2 Candidate binding

`sha` must equal the live candidate SHA and `generation` must equal the live generation, both read
from `09-test-evidence/qa-candidate.json` at publication time. A mismatch is internally
`stale evidence target`. This is re-checked immediately before the append, so a candidate that rolls
over mid-publication aborts the write rather than recording a stale claim.

### 3.3 Artifact identity

The artifact must exist at the stated run-relative `path`, and its measured byte count and lowercase
SHA-256 must match the published `bytes` and `sha256` **exactly** (internally
`evidence artifact identity mismatch`).

### 3.4 Artifact and path safety — the ones that actually bite

Every one of these is checked on the artifact itself:

- **regular file** — not a directory, socket, fifo or device;
- **`st_nlink == 1`** — a hard link is refused;
- **owned by the invoking uid**;
- **mode exactly one of `0400`, `0600`, `0644`**;
- **size ≤ 64 MiB** (`67108864` bytes);
- **no symlink on any path component** — the open is `O_NOFOLLOW` at every level;
- every **intermediate directory** between the run root and the artifact must be a real directory,
  owned by the invoking uid, and **not group- or other-writable** (`mode & 0o022 == 0`).

> **The `0664` trap.** A file created under the common `umask 002` lands at mode `0664`, which is
> group-writable and therefore **not** in the accepted set. It is refused. This is the single most
> likely reason a well-formed publication fails for an ordinary producer, and nothing in the output
> says so — you get the generic line from the box above and no mention of the mode. Run
> `chmod 0644 <artifact>` before publishing, or write the artifact under `umask 022`. The same trap
> applies to the *directories* you create for it: `mkdir` under `umask 002` gives `0775`, which is
> group-writable and is refused the same way, with the same silence about why.

### 3.5 The role window must be open

`role_start_event_id` must name a record in this run's ledger such that:

- exactly one record carries that `event_id` (internally `evidence role start is not unique`);
- that record classifies as a **`native_role_start`**, and its `stage` and `role` equal the `stage`
  and `role` you are publishing (internally `evidence role start mismatch`);
- **no** record in the ledger references that same `role_start_event_id` with an event name ending
  in `_completed` — publishing after your own role's completion event is internally
  `evidence role window is closed`;
- your record's `ts` is **not earlier** than the role-start's `ts` (internally
  `evidence timestamp precedes role start`).

Practical consequence: publish evidence **while your role window is open**, before whatever event
closes it. There is no way to reopen a closed window to attach a forgotten artifact.

### 3.6 Duplicate publication is refused — and this is a retry hazard

If the ledger already contains an `evidence_produced` row with the **same `path` *and* same `sha`
*and* same `generation`**, the new publication is refused (internally
`duplicate evidence artifact publication`).

Read that as a retry rule: **a retry after a partial or failed publication cannot simply re-run the
same command.** If the first attempt actually landed a row, the identical retry is refused as a
duplicate. If it did not land a row, the retry is fine. So before retrying, *look at the ledger* and
find out which happened. Where a genuine re-publication of the same path is required, it needs a new
candidate generation — the duplicate key is the `(path, sha, generation)` triple, and `generation`
is the only part of it a re-run legitimately changes.

### 3.7 One append at a time

The publication takes the run's ledger lock and re-verifies the entire precondition set immediately
before committing. Concurrent publications to the same run serialize; they do not interleave.

---

## 4. `--strict` is what makes a failure visible

Ordinary logging is best-effort by design: without `--strict`, a refused publication **exits 0 and
writes no ledger row**. Exit status alone therefore does not tell you a record was written.

Always publish with `--strict`, and confirm the row is in `run.jsonl` afterwards. Role contracts
carry the same directive in their own words; see `roles/qa-tester.md`.

One failure class announces itself on stderr even without `--strict`, because it is a property of
the ledger rather than of your arguments: `existing ledger content is unclassifiable`, meaning
nothing can be appended to that run by anyone again. The exit status is still 0.

---

## 5. Legacy runs

A run that had **already** published evidence under the previous rules — and shows no seal signal,
no final-evidence bundle, and a well-formed `run_started` first row — is recognized as genuine
legacy history. Its existing rows stay readable and it stays appendable, with no rewrite and no
migration. Nothing in this contract asks anyone to touch such a run.

That recognition is anchored on *published history*, not on missing metadata. A live run that has
published nothing yet is held to the current twelve-key shape for its very first publication, even
if it otherwise looks sparse. There is no opt-out into the old shape.

---

## 6. Checklist before you publish

1. Artifact is final, and is a regular file, `0644` (or `0400`/`0600`), ≤ 64 MiB, no hard link.
2. Every directory above it under the run is yours and not group/other-writable.
3. `sha256` and `bytes` measured from that exact file, now.
4. `sha` and `generation` copied from `09-test-evidence/qa-candidate.json`.
5. `stage`/`role` match your open `native_role_start`; `role_start_event_id` is its `event_id`.
6. No existing row with this `(path, sha, generation)`.
7. `--run` explicit, `--strict` present.
8. After the call: the row is in `run.jsonl`.
