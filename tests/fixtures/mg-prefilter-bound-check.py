#!/usr/bin/env python3
"""Assert the SEC-19 length bound is present, single-sourced and FIRST in BOTH prefilters.

A separate file rather than a `python3 -c` inline in tests/test-merge-guard.sh: the patterns this
has to match are made of `$`, `{`, `}`, backslashes and both kinds of quote, and every one of those
is also special to the double-quoted shell string an inline assertion would live in. Escaping them
through two layers is how an assertion quietly stops matching what it claims to match — which is the
exact defect class this suite keeps closing. Here the source text is data, not shell.

Usage: mg-prefilter-bound-check.py <path-to-firm-merge-guard>
Exits 0 and prints the bound, or raises AssertionError.

WHAT EACH CHECK BUYS
  · declared     — the constant exists at all. Without it every behaviour row is vacuous, because a
                   missing constant makes the bash test read `${MG_MAX_PREFILTER_BYTES:-0}` -> 0,
                   i.e. "normalise nothing, CHECK everything": still fail-closed, but unbounded in
                   the other direction and no longer the thing the rows claim to test.
  · one source   — the jq program is handed the SAME constant with --argjson, so the bash-side and
                   jq-side bounds cannot drift. Two hard-coded numbers is the shape that produced
                   the pass-3 divergence the prefilter-agreement case exists for.
  · FIRST        — position is the whole property. A bound placed after the deletions it exists to
                   avoid gives identical verdicts on every corpus row while still costing the 99.8 s
                   it was added to prevent, so behaviour alone cannot catch it.
"""
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()

DOLLAR, BS, SQ, DQ = chr(36), chr(92), chr(39), chr(34)

# ---- the constant --------------------------------------------------------------------------
const = re.search(r"^MG_MAX_PREFILTER_BYTES=(\d+)$", src, re.M)
assert const, "MG_MAX_PREFILTER_BYTES is not declared in the guard"

# ---- the bash prefilter --------------------------------------------------------------------
fn = re.search(r"^_mg_may_match\(\) \{\n(.*?)^\}$", src, re.S | re.M)
assert fn, "could not extract _mg_may_match from the guard"
body = fn.group(1)
assert "MG_MAX_PREFILTER_BYTES" in body, "_mg_may_match does not consult the bound:\n" + body

# A length test on the ARGUMENT (`${#1}`), not on some already-normalised copy — normalising first
# and measuring afterwards would bound nothing.
len_test = DOLLAR + "{#1}"
assert len_test in body, (
    "the bash bound is not a length test on the raw argument (%r not found):\n%s" % (len_test, body))
line_with_bound = [l for l in body.splitlines() if "MG_MAX_PREFILTER_BYTES" in l]
assert any(len_test in l for l in line_with_bound), (
    "the length test and the bound are on different lines, so they may not be the same test:\n" + body)

# POSITION: the bound must be the first executable statement, ahead of the raw-argument glob and
# every parameter-expansion deletion.
stmts = [l.strip() for l in body.splitlines()
         if l.strip() and not l.strip().startswith("#") and l.strip() != "local s"]
assert stmts, "no executable statements found in _mg_may_match"
assert "MG_MAX_PREFILTER_BYTES" in stmts[0], (
    "the length bound must run BEFORE the pattern work it exists to avoid; the first statement was:\n"
    "  %s" % stmts[0])

# ---- the jq prefilter ------------------------------------------------------------------------
argjson = "--argjson cap " + DQ + DOLLAR + "MG_MAX_PREFILTER_BYTES" + DQ
assert argjson in src, "the jq prefilter is not handed the same constant (%r not found)" % argjson
jq = re.search(r"\| jq -r " + re.escape(argjson) + r" '\n(.*?)'\s*2>/dev/null", src, re.S)
assert jq, "could not extract the jq prefilter program (with its --argjson cap)"
prog = jq.group(1)
cap_test = r"\.tool_input\.command \| length\) > " + re.escape(DOLLAR) + "cap"
assert re.search(cap_test, prog), (
    "the jq prefilter does not bound the length of the command it extracts:\n" + prog)
assert "gsub" in prog, "the jq prefilter has no gsub left to bound — did the normalisation move?"
assert prog.index(DOLLAR + "cap") < prog.index("gsub"), (
    "the jq bound is applied AFTER a gsub, so it does not bound that gsub:\n" + prog)

print("ok", const.group(1))
