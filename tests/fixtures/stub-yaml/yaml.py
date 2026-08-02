"""A tiny YAML-SUBSET parser standing in for pyyaml -- a LAST RESORT, not a preference.

bin/firm-check-assertions and bin/firm-traceability-check each have two parse paths, "a YAML parser
is importable" and "it is not". On a host with no pyyaml the first path is unreachable, so this
module makes `import yaml` succeed and lets that branch be exercised anyway. Its counterpart is the
one-line `raise ImportError` yaml.py the harnesses generate for the opposite branch.

IT MUST NOT SHADOW A REAL PYYAML. It used to be PREPENDED to PYTHONPATH unconditionally, which hid
the genuine library on every host that had one -- CI included, where pyyaml==6.0.3 is pinned and
installed -- so the exact-parser path was in fact exercised on no machine anywhere, by anyone. The
harnesses (tests/test-check-assertions-parsing.sh, tests/test-traceability-check.sh) now probe for a
real pyyaml first and fall back here only when that import genuinely fails.

Its behaviour is pinned by "the stub double supports exactly what it claims" in
tests/test-check-assertions-parsing.sh, so this list stays a description rather than a wish.

SUPPORTED
  * top-level `key: value` -- a quoted value has one matching outer pair of quotes stripped and
    keeps any inner ones ("sh -c 'exit 0'" survives intact); `true`/`false` and integers are
    converted; everything else stays a string.
  * `key:` with nothing after it, followed by INDENTED single-line `- ...` entries. An entry is
    either a bare scalar or exactly one `k: v` pair. A `key:` with no entries under it yields `[]`
    (real pyyaml yields None -- one of the known divergences below).
  * comments and blank lines anywhere.
  * a document containing no key-ish and no `-`-ish line at all: returned as one joined string,
    which is how the callers' "top level is not a mapping" branch gets reached.
  * an empty document: None.

RAISES YAMLError -- and only some of these are actually malformed YAML:
  * a nested mapping under a list item (`- id: AC-001` / `  statement: ...`). That is the shape a
    REAL agent-firm 01-acceptance-criteria.yaml uses, so this module CANNOT parse one.
  * a folded or literal block scalar (`description: >`, `description: |`) and its continuation
    lines. That is the shape agent-firm/evals/*/assertions.yaml uses, so it cannot parse one of
    those either. (Both of these were previously claimed as supported. They never were.)
  * a zero-indent block sequence (`key:` then `- item` at column 0) -- valid YAML, refused here.
  * a top-level sequence (`- id: AC-001` as the first line) -- valid YAML, refused here.
  * any indented line that is not `- ...` under an open `key:`.

NOT PARSED, BUT NOT REFUSED EITHER
  * flow style: `criteria: [{id: AC-001}]` comes back as the plain STRING "[{id: AC-001}]". It
    neither raises nor yields a list, so flow-style cases belong on the regex-fallback path.

No magic marker anywhere: the invalid fixtures in those tests are rejected because the line really
is unparseable TO THIS MODULE, not because it is labelled invalid. Which is also the caveat --
"this module refused it" is not the same claim as "pyyaml would refuse it", and for the four
valid-YAML shapes listed above it is provably a different claim.
"""
import re


class YAMLError(Exception):
    pass


def _scalar(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    low = v.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if re.match(r'^-?\d+$', v):
        return int(v)
    return v


def safe_load(text):
    if hasattr(text, "read"):
        text = text.read()
    if isinstance(text, bytes):
        text = text.decode()
    lines = [l for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]
    if not lines:
        return None
    # A plain scalar document (prose): nothing looks like a mapping key or a list item.
    if not any(re.match(r'^\s*[A-Za-z_][\w .-]*\s*:', l) or l.strip().startswith("-") for l in lines):
        return " ".join(l.strip() for l in lines)
    doc = {}
    cur = None
    for l in lines:
        indent = len(l) - len(l.lstrip())
        s = l.strip()
        if indent == 0:
            m = re.match(r'^([A-Za-z_][\w-]*)\s*:\s*(.*)$', l)
            if not m:
                raise YAMLError("could not parse top-level line: %r" % l)
            k, v = m.group(1), m.group(2).strip()
            if v == "" or v == ">":
                doc[k] = [] if v == "" else ""
                cur = k if v == "" else None
            else:
                doc[k] = _scalar(v)
                cur = None
        else:
            if cur is None:
                raise YAMLError("unexpected indented line: %r" % l)
            if not s.startswith("-"):
                raise YAMLError("mapping values are not allowed here: %r" % l)
            item = s[1:].strip()
            m = re.match(r'^([A-Za-z_][\w-]*)\s*:\s*(.+)$', item)
            doc[cur].append({m.group(1): _scalar(m.group(2))} if m else _scalar(item))
    return doc
