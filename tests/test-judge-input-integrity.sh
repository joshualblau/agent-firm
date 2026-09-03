#!/usr/bin/env bash
# The judge must never be handed evidence this wrapper has already certified as well-formed and then
# corrupted. Guards the 2026-09-02 defect found by a cross-provider judge on run
# 20260902T064517Z-link-audit-tool.
#
# THE DEFECT. bin/firm-reviewer-common validates run.jsonl as well-formed JSONL immediately before
# snapshotting it, then wrote the judge's copy through a TEXTUAL redact() and never re-read its own
# output. A ledger line records a shell command, so Python source arrives as a JSON string in which
# `\n` is two literal characters. Given
#
#     ...current_nodeid = None\n\n\n@pytest.hookimpl(wrapper=True)...
#
# the email substitution matched `n@pytest.hookimpl` -- local part `n`, domain `pytest.hookimpl` --
# where that `n` is the escape's second character. Substituting ate it and left a dangling backslash.
# A PYTHON DECORATOR AFTER A NEWLINE WAS READ AS AN EMAIL ADDRESS. The judge reported run.jsonl
# malformed at lines 116/128/462/573/574/647/865, was correct, and correctly refused to approve on
# unvalidatable input -- while nothing on the primary side saw anything wrong.
#
# WHAT THIS FILE PINS, and why each case exists rather than just the obvious one:
#   1. the observed trigger survives                -- the bug that was reported
#   2. the real ledger shape survives               -- at scale, not just a hand-built line
#   3. secrets are STILL redacted, incl. in keys    -- the fix must not buy syntax with disclosure
#   4. the post-redaction invariant BITES           -- catches the NEXT corrupting transform
#   5. structure is actually parsed, not regexed    -- a fix that merely tightened the pattern fails
#
# Case 3 is not decoration. Structure splits `key: value` in half, and the textual rules are
# `key[:=]value` shaped: parsing {"password":"hunter2"} yields two separate strings and NEITHER
# matches alone. The first cut of the fix regressed disclosure exactly there and this case caught it
# before it shipped.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$BIN/firm-reviewer-common"

t_case "the judge's copy of structured evidence parses whenever the source did"
assert_ok "observed trigger, real ledger shape, and the JSON/JSONL split" t_python - "$WRAPPER" <<'PY'
import ast, json, re, sys

wrapper = sys.argv[1]
text = open(wrapper, encoding="utf-8").read()
src = re.search(r"<<'PY'\n(.*)\nPY", text, re.S).group(1)
tree = ast.parse(src)

ns = {"re": re, "json": json}
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id in ("REDACTIONS", "SECRET_KEY_NAMES")
            for t in node.targets):
        exec(compile(ast.Module([node], []), "<wrapper>", "exec"), ns)
wanted = ("json_bytes", "redact_text", "redact", "redact_json_document", "parsed_json_shape")
seen = {}
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name in wanted and node.name not in seen:
        seen[node.name] = node
missing = [n for n in wanted if n not in seen]
assert not missing, f"wrapper no longer defines {missing}; the structured redaction path is gone"
for name in wanted:
    exec(compile(ast.Module([seen[name]], []), "<wrapper>", "exec"), ns)

shape_of, redact_doc = ns["parsed_json_shape"], ns["redact_json_document"]


def controlled_bytes(raw):
    """The add_payload structured path, as shipped."""
    shape, parsed = shape_of(raw)
    if shape == "json":
        return shape, ns["json_bytes"](redact_doc(parsed))
    if shape == "jsonl":
        return shape, ("\n".join(
            json.dumps(redact_doc(r), separators=(",", ":"), sort_keys=True)
            for r in parsed) + "\n").encode("utf-8")
    return shape, ns["redact"](raw).encode("utf-8")


# 1. THE OBSERVED TRIGGER, verbatim.
trigger = json.dumps({"event": "bash",
                      "cmd": "x = None\n\n\n@pytest.hookimpl(wrapper=True)\ndef f(): pass"})
shape, out = controlled_bytes((trigger + "\n").encode("utf-8"))
assert shape == "jsonl", shape
record = json.loads(out.decode("utf-8").strip())   # raises if the escape was eaten
assert "@pytest.hookimpl" in record["cmd"], record

# The same content through the TEXT path is still broken -- proving this case is load-bearing and
# would fail against the pre-fix wrapper rather than passing for an unrelated reason.
broken = ns["redact"]((trigger + "\n").encode("utf-8"))
try:
    json.loads(broken.strip())
    raise AssertionError("textual redaction no longer corrupts the trigger; this case cannot bite")
except json.JSONDecodeError:
    pass

# 2. A REALISTIC LEDGER, not one hand-built line: several records, decorators, emails, escapes.
records = [
    {"ts": "2026-09-02T00:00:00Z", "event": "run_started", "run_id": "r"},
    {"event": "bash", "cmd": "cat <<'E'\n@dataclass\nclass A:\n    x: int\nE"},
    {"event": "bash", "cmd": "grep -n '@pytest.fixture' tests/conftest.py\nmail a@b.example"},
    {"event": "note", "actor": "Someone <someone@example.com>"},
]
raw = ("\n".join(json.dumps(r) for r in records) + "\n").encode("utf-8")
shape, out = controlled_bytes(raw)
assert shape == "jsonl", shape
lines = [l for l in out.decode("utf-8").splitlines() if l.strip()]
assert len(lines) == len(records), (len(lines), len(records))
for line in lines:
    json.loads(line)          # every line must parse
assert "@dataclass" in out.decode("utf-8")
assert "@pytest.fixture" in out.decode("utf-8")

# 3. A PRETTY-PRINTED JSON document takes the json path. It must be pretty-printed to get there:
# a compact single-line document is ALSO valid JSONL, and JSONL is tried first on purpose, because
# json_bytes() writes indent=2 and would otherwise rewrite a one-record run.jsonl as multi-line
# pretty JSON -- still valid JSON, no longer valid JSONL, and invisible to the shape-to-shape
# invariant. This case pins the fall-through: lines that do not parse individually reach `json`.
doc = {"a": {"b": ["x", {"c": "line\n@decorator"}]}}
shape, out = controlled_bytes((json.dumps(doc, indent=2) + "\n").encode("utf-8"))
assert shape == "json", shape
assert json.loads(out.decode("utf-8"))["a"]["b"][1]["c"].endswith("@decorator")

# ...and the converse, which is the property that ordering exists to protect: a ONE-RECORD JSONL
# file keeps its single line rather than being pretty-printed into multiple.
one = (json.dumps({"event": "only", "cmd": "x\n@decorator"}) + "\n").encode("utf-8")
shape, out = controlled_bytes(one)
assert shape == "jsonl", f"a one-record ledger classified {shape}; it would be pretty-printed"
assert len([l for l in out.decode("utf-8").splitlines() if l.strip()]) == 1, out

# 4. Unstructured evidence still uses the TEXT path -- the fix must not turn every log into JSON.
shape, out = controlled_bytes(b"2026-09-02 INFO starting\nnot json at all\n")
assert shape is None, shape
print("OK trigger, ledger, json, and text paths")
PY

t_case "the fix does not buy syntax at the cost of disclosure"
assert_ok "secrets in values, nested, and in KEYS are still redacted" t_python - "$WRAPPER" <<'PY'
import ast, json, re, sys

wrapper = sys.argv[1]
src = re.search(r"<<'PY'\n(.*)\nPY", open(wrapper, encoding="utf-8").read(), re.S).group(1)
tree = ast.parse(src)
ns = {"re": re, "json": json}
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id in ("REDACTIONS", "SECRET_KEY_NAMES")
            for t in node.targets):
        exec(compile(ast.Module([node], []), "<wrapper>", "exec"), ns)
for name in ("json_bytes", "redact_text", "redact", "redact_json_document", "parsed_json_shape"):
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            exec(compile(ast.Module([node], []), "<wrapper>", "exec"), ns)
            break

redact_doc, json_bytes = ns["redact_json_document"], ns["json_bytes"]

# THE REGRESSION THIS CASE EXISTS FOR. Textual redaction caught `password: hunter2` because the key
# and value sat in one string. Structure separates them, and neither half matches the key[:=]value
# patterns alone -- so a naive structural fix silently stops redacting exactly the pairs the firm
# most cares about. Secret-NAMED keys must redact their whole value.
doc = {
    "password": "hunter2-actual-secret",
    "nested": [{"api_key": "AKIA-must-not-leak"}, {"deep": {"access_token": "ghp-must-not-leak"}}],
    "authorization": "Bearer must-not-leak",
    "note": "write to someone@example.com please",
    "token=INLINE_MUST_GO": "value",
    "harmless": "keep me",
}
blob = json_bytes(redact_doc(doc)).decode("utf-8")
for secret in ("hunter2-actual-secret", "AKIA-must-not-leak", "ghp-must-not-leak",
               "Bearer must-not-leak", "someone@example.com", "token=INLINE_MUST_GO"):
    assert secret not in blob, f"DISCLOSURE: {secret!r} survived redaction"
assert "keep me" in blob, "redaction destroyed non-secret content"

# A secret whose value CONTAINS SPACES. The textual rule stopped at `[^\s,;]+`, so it leaked the
# tail; keying on the field name does not. This is the fix being strictly stronger, pinned.
spaced = json_bytes(redact_doc({"secret": "two words leak"})).decode("utf-8")
assert "two words leak" not in spaced and "words" not in spaced, spaced
print("OK no disclosure, and stronger than the textual rule it replaced")
PY

t_case "it bites: a transform that corrupts structured evidence must stop, not ship"
assert_ok "the post-redaction invariant rejects a corrupting transform" t_python - "$WRAPPER" <<'PY'
import ast, json, re, sys

wrapper = sys.argv[1]
src = re.search(r"<<'PY'\n(.*)\nPY", open(wrapper, encoding="utf-8").read(), re.S).group(1)
tree = ast.parse(src)
ns = {"re": re, "json": json}
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "parsed_json_shape":
        exec(compile(ast.Module([node], []), "<wrapper>", "exec"), ns)
        break
shape_of = ns["parsed_json_shape"]

# The invariant as the wrapper states it: if the SOURCE parsed, the CONTROLLED COPY must parse.
# Model a corrupting transform and assert the comparison the wrapper makes would refuse it.
source = (json.dumps({"cmd": "x\n@decorator"}) + "\n").encode("utf-8")
before, _ = shape_of(source)
assert before == "jsonl", before

corrupted = b'{"cmd": "x\\n\\[REDACTED](y)"}\n'      # exactly the pre-fix failure shape
after, _ = shape_of(corrupted)
assert after != before, "a dangling-escape copy still parses; the invariant cannot detect it"

# ...and the invariant must NOT fire on a legitimate redaction that preserves shape, or it would
# block every run. A guard that always trips is not a guard.
clean = (json.dumps({"cmd": "x\n@decorator", "token": "[REDACTED]"}) + "\n").encode("utf-8")
assert shape_of(clean)[0] == before, "the invariant fires on a well-formed redacted copy"

# The wrapper must actually PERFORM this comparison, not merely define the helper. Pin the call
# site: a future edit that drops the check leaves the helper defined and the guard gone.
body = re.search(r"<<'PY'\n(.*)\nPY", open(wrapper, encoding="utf-8").read(), re.S).group(1)
assert "redaction corrupted structured judge input" in body, \
    "the fail-closed invariant's stop() is gone from the wrapper"
assert body.count("parsed_json_shape(controlled)") == 1, \
    "the controlled copy is no longer re-parsed after redaction"
print("OK invariant detects corruption, tolerates clean redaction, and is wired in")
PY

t_case "structure is parsed, not pattern-matched"
assert_ok "a fix that only tightened the regex would not satisfy this file" t_python - "$WRAPPER" <<'PY'
import re, sys

body = re.search(r"<<'PY'\n(.*)\nPY", open(sys.argv[1], encoding="utf-8").read(), re.S).group(1)

# The manifest must distinguish a parsed file from a pattern-substituted one, so a reader can tell
# which files were only regexed. Pinning the vocabulary keeps that distinction real.
for token in ('"redacted_json"', '"redacted_jsonl"', '"redacted_utf8"'):
    assert token in body, f"manifest transform vocabulary lost {token}"

# The structured path must exist and be reached from the payload writer.
assert "def redact_json_document" in body, "structural redaction is gone"
assert "def parsed_json_shape" in body, "shape detection is gone"
assert "SECRET_KEY_NAMES" in body, "secret-named-key redaction is gone (disclosure regression)"
print("OK structural path present and manifest vocabulary intact")
PY

t_summary
