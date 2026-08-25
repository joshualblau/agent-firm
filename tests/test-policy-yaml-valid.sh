#!/usr/bin/env bash
# tests/test-policy-yaml-valid.sh — every agent-firm/policy/*.yaml (and templates/*.yaml) file must
# actually parse as YAML.
#
# Why this exists: agent-firm/policy/definition-of-done.yaml shipped in PR1 with a genuine YAML syntax
# error (a bare colon-space inside a multi-line plain scalar list item — "satisfy this item: install
# the prerequisite...", which YAML parses as an attempted mapping key inside a sequence). It sat broken
# on merged main through PR2 because nothing ever parses that file programmatically — it's read by a
# human/the Lead as prose, not consumed by any script the way bench/registry.yaml or
# 01-acceptance-criteria.yaml are. Found and fixed while editing the same file for PR3; this test is
# the generic guard so the NEXT similar edit (to any policy YAML, not just this one file) fails loudly
# in CI instead of sitting silently broken again.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

t_case "every agent-firm/policy/*.yaml file parses as valid YAML"
for f in "$FIRM_ROOT"/agent-firm/policy/*.yaml; do
  [ -f "$f" ] || continue
  assert_ok "$(basename "$f") is valid YAML" t_python -c "import yaml; yaml.safe_load(open('$f'))"
done

t_case "every agent-firm/templates/*.yaml file parses as valid YAML"
for f in "$FIRM_ROOT"/agent-firm/templates/*.yaml; do
  [ -f "$f" ] || continue
  assert_ok "$(basename "$f") is valid YAML" t_python -c "import yaml; yaml.safe_load(open('$f'))"
done

t_case "regression pin: definition-of-done.yaml specifically has no bare colon-space mid-scalar"
# Belt-and-braces beyond "it parses": the exact hazard class (a plain scalar list item containing
# ": " outside a `>-`/`|-` block scalar) can reappear even in an otherwise-parseable file if a future
# edit adds a NEW multi-line item without the same care. Scan for it directly.
assert_ok "no unguarded colon-space in a plain scalar list item" t_python -c "
import re
path = '$FIRM_ROOT/agent-firm/policy/definition-of-done.yaml'
lines = open(path).read().splitlines()
bad = []
in_block_scalar = False
for i, line in enumerate(lines, 1):
    stripped = line.rstrip()
    if re.match(r'^\s*-\s*[>|]-?\s*\$', stripped):
        in_block_scalar = True
        continue
    if in_block_scalar:
        if not re.match(r'^\s{4,}\S', stripped) or re.match(r'^\s*-\s', stripped):
            in_block_scalar = False
        else:
            continue  # inside a block scalar: colons are safe, skip
    m = re.match(r'^\s*-\s+(.*)', stripped)  # first line of a plain-scalar item
    c = re.match(r'^    (.*)', stripped)     # a continuation line
    content = m.group(1) if m else (c.group(1) if c else None)
    if content and ': ' in content:
        bad.append((i, line))
assert not bad, f'colon-space found outside a block scalar: {bad}'
"

t_case "the actual high-risk policy satisfies its actual closed-world schema"
assert_ok "canonical high-risk policy validates" t_python - "$FIRM_ROOT" <<'PY'
import json,jsonschema,sys,yaml
root=sys.argv[1]
defs=json.load(open(root+"/agent-firm/schemas/traceability.schema.json"))["$defs"]
schema={"$schema":"https://json-schema.org/draft/2020-12/schema","$ref":"#/$defs/highRiskPolicy","$defs":defs}
policy=yaml.safe_load(open(root+"/agent-firm/policy/high-risk-paths.yaml"))
jsonschema.validate(policy,schema)
PY

t_case "removing any required category or individual pattern fails the real schema"
assert_ok "every category/pattern deletion and unknown addition is rejected" t_python - "$FIRM_ROOT" <<'PY'
import copy,json,jsonschema,sys,yaml
root=sys.argv[1]
defs=json.load(open(root+"/agent-firm/schemas/traceability.schema.json"))["$defs"]
schema={"$schema":"https://json-schema.org/draft/2020-12/schema","$ref":"#/$defs/highRiskPolicy","$defs":defs}
policy=yaml.safe_load(open(root+"/agent-firm/policy/high-risk-paths.yaml"))
def rejected(value):
    try: jsonschema.validate(value,schema)
    except jsonschema.ValidationError: return True
    return False
for category,patterns in policy["categories"].items():
    changed=copy.deepcopy(policy); del changed["categories"][category]
    assert rejected(changed),("deleted category passed",category)
    for index,pattern in enumerate(patterns):
        changed=copy.deepcopy(policy); del changed["categories"][category][index]
        assert rejected(changed),("deleted pattern passed",category,pattern)
changed=copy.deepcopy(policy); changed["categories"]["unknown"]=["**"]
assert rejected(changed),"unknown category passed"
changed=copy.deepcopy(policy); changed["categories"][next(iter(changed["categories"]))].append("**/invented/**")
assert rejected(changed),"unknown pattern passed"
PY

t_summary
