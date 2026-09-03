# System Change PR: the merge guard blocks heredocs that bash accepts, on a false premise

A proposed change to the **firm itself** (not a project deliverable). Raised from a retrospective,
reviewed for generalizability, approved by the human, versioned, and guarded by a golden eval.

- **Proposed by run:** `20260902T064517Z-link-audit-tool`
- **Date (UTC):** 2026-09-03
- **Status:** proposed — **NOT implemented; this one needs a decision before code**

## Motivation

During run `20260902T064517Z-link-audit-tool` the guard refused a legitimate command **five separate
times**, each time with:

```
firm-merge-guard: CANNOT EVALUATE — could not tokenise the command line (No closing quotation)
  Blocking: the command reached the classifier but could not be parsed to a decision.
```

Every occurrence was a heredoc whose *body* contained an apostrophe or an unbalanced quote — writing
a `.gitignore`, a README, a Python probe. The workaround each time was to route the write through a
file-writing tool instead. That is a standing tax on a common, safe idiom, and it pushed real work
off the shell path for no security benefit.

### The premise in the code is false

`bin/firm-merge-guard`, at the tokenise failure:

```python
except ValueError as e:
    # Unbalanced quote: a real shell would fail too, but we must not guess. Fail closed.
    raise Cannot("could not tokenise the command line (%s)" % e)
```

**A real shell would not fail.** Bash runs this without complaint:

```sh
cat > f <<'EOF'
the tool cannot know the server's setting
EOF
```

`shlex` has no concept of a heredoc, so it sees one apostrophe and reports "No closing quotation".
The line is well-formed shell; only the tokeniser thinks otherwise. **Failing closed is the right
behaviour when the guard cannot decide — but the stated justification for tolerating it is wrong,
and being wrong is why the cost was accepted without examination.**

Reproduced live on 2026-09-03: the guard blocked the very probe command written to characterise the
bug, which is as direct a demonstration as the defect allows.

## What today's behaviour actually is (measured — and I got this wrong twice first)

This section was written twice from assumption and corrected twice by probing. Recording that,
because the corrections change the recommendation.

**Wrong claim #1:** "shlex tokenises the whole line, so heredoc body words land in the command
stream and are scanned." Measured: `cat > f <<EOF / git push origin main / EOF` is **not** gated.
The body words are absorbed into the `cat` segment, so the segment's program is `cat` and no gated
surface matches.

**Wrong claim #2 (mine, in an earlier draft):** that this constituted an undeclared bypass. It does
not. The guard's own documented scope says heredoc bodies are scanned **when any segment of the
introducing line is a shell**:

> · a heredoc body when ANY segment of the introducing line is a shell — so both
>   `bash <<'EOF' ... EOF` and `cat <<'EOF' | bash` are scanned

Probed, and it holds exactly as written:

| command | gated? | matches docs |
|---|---|---|
| `git push origin main` | gated | control |
| `cat > f <<EOF` / `git push` / `EOF` | not gated | yes — no shell segment |
| `bash <<EOF` / `git push` / `EOF` | **gated** | yes — shell segment |
| `bash <<< 'git push origin main'` | gated | yes — here-string |
| `echo 'git push origin main' \| bash` | not gated | yes — **declared gap** (run-time assembly) |

Note `rc` alone cannot answer this: on an allow-listed identity a *detected* `git push` still exits
0. The distinguishing signal is whether the guard emits its "permitted — matched surface" line at
all. My first probe used `rc` and produced a confident, wrong answer.

**So the sink classification I was about to propose as "option B" is already the design, and it is
better than what I credited it with.** The only defect is the tokeniser crash.

## The design question this needs a decision on

The scope rule is already right. What is broken is only that `shlex` cannot tokenise a line whose
heredoc body contains an unbalanced quote, so the line never reaches classification at all.

The fix is therefore narrower than first proposed: **extract heredoc bodies before tokenising the
command skeleton, then apply the EXISTING rule** — scan an extracted body iff a segment of the
introducing line is a shell, exactly as documented today. No new trust surface, no sink allowlist;
the sink logic already exists and is tested.

It is still a change to how a security control reads its input, which is why it is not landed here.
Two things it must not do, and which the eval below is written to catch:

1. **Stop scanning shell-fed bodies.** `bash <<'EOF' … git push … EOF` must remain gated, including
   when the body's quotes are unbalanced — the exact case that currently cannot be parsed.
2. **Turn an unparseable line into a silent permit.** If extraction fails, the answer is still
   `Cannot`, i.e. block. A tokeniser change is the most natural place in this program to introduce a
   fail-open, and it must not.

**I have landed option C only** (comment + message). The extraction is left for a decision by
someone with the design context, because "I am confident this rewrite of a security control's
tokeniser is safe" is precisely the sort of claim this engagement's retrospective is about not
making unverified — and I made two unverified claims in this very document before probing.

## Proposed change

- Files: `bin/firm-merge-guard`, plus a new `tests/test-merge-guard-heredoc.sh` and an eval if the
  extraction is accepted.

**Landed now (option C, safe):**
1. The false claim is corrected in place, with the counter-example, so the next reader does not
   re-derive it.
2. The operator message names the cause and the remedy. It previously said only that the command
   "could not be parsed to a decision", which does not tell you that a heredoc quote is the reason or
   what to do about it.

**Pending decision:** the extraction itself, keeping today's shell-segment scope rule.

## Generalizability check (reviewer)

- **Applies beyond this project? YES.** Nothing about the trigger is project-specific — it is any
  heredoc containing an apostrophe, which includes most English prose and most Python. It fired five
  times in one engagement.
- **Risk of overfitting:** none for C. Low for the extraction, because it changes only WHERE the
  body text is read from, not WHICH bodies are scanned — the shell-segment rule that decides that is
  already in place, documented, and asserted.

## Risk & rollback

- **C (landed):** comment and message only; no behavioural change. Rollback: revert.
- **Extraction:** medium, and concentrated in one place. It changes how a security control reads its
  input, and a tokeniser is the most natural place in this program to introduce a fail-open. The
  mitigations are the two must-nots above plus the eval; the scope rule itself is untouched.
- Rollback for either: revert this PR — `bin/` is versioned in git.

## Golden eval to guard it

- Eval: `agent-firm/evals/merge-guard-heredoc/` — **only if the extraction is accepted.**
- What it must assert:
  1. `cat > f <<'EOF'` with an apostrophe in the body is **permitted** (the reported defect).
  2. `bash <<'EOF' … git push origin main … EOF` is **still gated** — the property that must not
     regress, and the one the extraction is most likely to break.
  3. The same shell-fed body with **unbalanced quotes** is still gated. This is the case that does
     not exist today (it is `Cannot`), so it is the case where a fix could quietly become a permit.
  4. A body fed to a NON-shell sink stays ungated, so the existing scope rule is unchanged rather
     than widened — the fix must not turn prose mentioning `git push` into a refusal.
  5. Extraction failure still yields `Cannot`, never a permit.
- [ ] Golden evals pass (`firm-run-evals`) — attach the run output.

## Evidence

- Five live occurrences in run `20260902T064517Z-link-audit-tool`; the guard also blocked the probe
  written to characterise the bug, on 2026-09-03.
- Retrospective: `.agent-firm/runs/20260902T064517Z-link-audit-tool/11-retrospective.md`,
  "Firm-level defects observed".
- Measured today: a balanced heredoc body IS tokenised into the command stream (so bodies are
  already scanned); an unbalanced one raises `ValueError` from `shlex` and becomes `Cannot`.

## Human decision

- [ ] approved by ____ on ____ (UTC)   |   [ ] rejected — reason:
- [ ] **which option:** EXTRACT (heredoc bodies, keeping today's shell-segment rule) / C only (landed)
