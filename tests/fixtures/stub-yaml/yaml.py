"""A minimal YAML-subset parser used ONLY as a test double for pyyaml.

Put on PYTHONPATH by tests/test-check-assertions-parsing.sh and tests/test-traceability-check.sh so
the "pyyaml is installed" branch of bin/firm-check-assertions and bin/firm-traceability-check can be
exercised on any host, including one where pyyaml genuinely is not installed. Its counterpart is the
one-line `raise ImportError` yaml.py those tests generate for the opposite branch.

Not pyyaml, and not a general YAML parser. It handles exactly the shapes assertions.yaml and
01-acceptance-criteria.yaml use -- top-level `key: value`, and `key:` followed by an indented `- ...`
list -- and RAISES YAMLError on anything outside that, which is genuinely what a strict parser does
with a malformed document. No magic marker: the invalid fixtures in those tests are rejected because
the line really is invalid there, not because it is labelled invalid. Flow style (`[{id: AC-001}]`)
is NOT supported and comes back as a plain string, so keep flow-style cases on the regex-fallback
path where they belong.
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
