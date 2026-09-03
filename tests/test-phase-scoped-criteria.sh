#!/usr/bin/env bash
# A run that delivers ONE PHASE of a multi-run build must be able to say so in its acceptance
# criteria, and must not be able to narrow its own criteria silently.
#
# THE DEFECT THIS PINS. On run 20260902T064517Z-link-audit-tool, Intake wrote 66 engagement-wide
# criteria -- and flagged at the time that binding ids to runs was the Architect's call. The
# Architect then decomposed the build into six phases, each its own bounded run, and nobody narrowed
# the run's criteria file. firm-traceability-check validates the QA verdict's coverage and the
# traceability matrix in BOTH directions against that file, so the mismatch was fatal -- and it
# surfaced at the FINAL GATE, after every stage had already run against the wrong set. The
# alternative on offer at that point was 50 waive_uncovered records for work nobody had claimed to
# start, which would have recorded "not yet begun" as "waived".
#
# The Lead scoped the file by hand and added `phase` / `engagement_criteria` keys the schema did not
# have -- so the file stopped validating, and nothing noticed, because firm-traceability-check does
# not validate that file against this schema. This test exists so both halves stay closed: the
# scoping is expressible, and it is not expressible in a way that hides what was dropped.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCHEMA="$FIRM_ROOT/agent-firm/schemas/acceptance-criteria.schema.json"
TEMPLATE="$FIRM_ROOT/agent-firm/templates/01-acceptance-criteria.yaml"

t_case "phase scoping is expressible, and says what it was scoped from"
assert_ok "scoped, unscoped, and incomplete-scoping shapes are judged correctly" t_python - "$SCHEMA" <<'PY'
import json, sys, jsonschema

schema = json.load(open(sys.argv[1]))

base = {
    "task_slug": "demo",
    "track": "full_track",
    "criteria": [{"id": "AC-001", "type": "functional", "statement": "x",
                  "verification": "automated_test"}],
    "explicitly_out_of_scope": [],
    "test_evidence_required": ["unit"],
}


def ok(doc, label):
    jsonschema.validate(doc, schema)
    print(f"  valid   {label}")


def refused(doc, label):
    try:
        jsonschema.validate(doc, schema)
    except jsonschema.ValidationError:
        print(f"  refused {label}")
        return
    raise AssertionError(f"schema accepted what it must refuse: {label}")


# The ordinary case must be untouched: most runs are not phased.
ok(base, "unscoped run (no phase keys)")

# A phased run can say which phase it is and where the rest lives.
ok({**base, "phase": "1a", "engagement_criteria": "01-acceptance-criteria.engagement.yaml"},
   "phase + engagement_criteria")

# THE LOAD-BEARING REFUSAL. A file that names a phase but not the master it came from is
# indistinguishable from a run that quietly dropped criteria it did not want to be judged on.
refused({**base, "phase": "1a"}, "phase WITHOUT engagement_criteria")

# Empty strings are not an escape hatch from that requirement.
refused({**base, "phase": "", "engagement_criteria": "x.yaml"}, "empty phase")
refused({**base, "phase": "1a", "engagement_criteria": ""}, "empty engagement_criteria")

# The schema stays closed: a typo near these keys must not be silently accepted.
refused({**base, "phases": "1a"}, "misspelled key (phases)")
refused({**base, "phase": "1a", "engagement_criteria": "x.yaml", "engagement": "y"},
        "unknown extra key alongside valid scoping")
print("OK scoping expressible; incomplete scoping refused")
PY

t_case "the template documents the keys without setting them"
assert_ok "template stays unscoped by default and explains when to scope" t_python - "$SCHEMA" "$TEMPLATE" <<'PY'
import sys, yaml, json, jsonschema

schema = json.load(open(sys.argv[1]))
raw = open(sys.argv[2], encoding="utf-8").read()
doc = yaml.safe_load(raw)

# Most runs are NOT phased, so the template must not ship the keys live -- a template that sets
# phase would make every run claim to be one slice of something.
assert "phase" not in doc, "template sets `phase` live; it must be commented guidance only"
assert "engagement_criteria" not in doc, "template sets `engagement_criteria` live"

# ...but it must TELL the author the keys exist and when they matter. The whole defect was an
# author who had no reason to know scoping was a thing until the Final gate refused the run.
for needed in ("phase:", "engagement_criteria:", "greenfield", "FINAL GATE"):
    assert needed in raw, f"template no longer explains scoping: missing {needed!r}"

# The template's own skeleton must still be schema-valid once filled in with a task_slug, or the
# first thing every Intake Analyst does is fight the schema.
doc["task_slug"] = "demo"
doc["criteria"][0]["statement"] = "x"
jsonschema.validate(doc, schema)
print("OK template unscoped by default, documents the keys, and validates when filled")
PY

t_case "the intake contract tells the analyst to raise phasing at the gate"
assert_ok "the rule is in the role contract, not only in the template" t_python - "$FIRM_ROOT" <<'PY'
import pathlib, sys

contract = pathlib.Path(sys.argv[1], "agent-firm/contracts/roles/intake-analyst.md").read_text()
# The analyst is the one who cannot know the phases yet, which is exactly why the flag has to be
# raised as an open decision rather than left for a later stage to discover.
for needed in ("phase", "engagement_criteria", "FINAL GATE", "Requirements gate"):
    assert needed in contract, f"intake contract does not carry the scoping rule: missing {needed!r}"
print("OK intake contract carries the rule")
PY

t_summary
