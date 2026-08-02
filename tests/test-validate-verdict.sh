#!/usr/bin/env bash
# tests/test-validate-verdict.sh — the verdict validator must distinguish three states, not two.
#
#   0 VALID     schema-validated
#   1 INVALID   malformed / missing keys / bad verdict value
#   4 DEGRADED  structurally plausible but NOT schema-validated (jsonschema absent)
#
# 4 used to be 0. That meant any machine without `jsonschema` quietly downgraded the firm's only
# mechanical evidence check to a key-presence test, and the Final gate cleared on it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VALIDATE="$BIN/firm-validate-verdict"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-verdict.XXXXXX")"
t_track "$WORK"

# A complete, schema-conforming verdict.
cat > "$WORK/good.json" <<'JSON'
{
  "verdict": "APPROVE",
  "commit_sha": "abc1234",
  "environment": "test",
  "commands_run": [{"cmd": "sh test/run-tests.sh", "exit_code": 0, "duration_s": 1.5, "artifact": "09-test-evidence/unit.log"}],
  "unit":        {"status": "pass", "evidence": "09-test-evidence/unit.log"},
  "integration": {"status": "not_applicable", "evidence": "no integration suite"},
  "e2e":         {"status": "not_applicable", "evidence": "no e2e suite"},
  "visual":      {"status": "not_applicable", "evidence": "no rendered UI"},
  "acceptance_criteria_coverage": [{"id": "AC-001", "covered": "yes", "evidence": "test/run-tests.sh"}],
  "untested_risks": ["concurrency untested"],
  "blockers": [],
  "warnings": [],
  "artifacts": ["09-test-evidence/unit.log"],
  "summary": "All criteria covered by passing evidence."
}
JSON

printf '{ this is not json' > "$WORK/malformed.json"

# Structurally complete except `verdict`, which is the one field the fallback must still police.
python3 - "$WORK" <<'PY'
import json, os, sys
w = sys.argv[1]
d = json.load(open(os.path.join(w, "good.json")))
missing = dict(d); missing.pop("untested_risks")
json.dump(missing, open(os.path.join(w, "missing-key.json"), "w"))
bad = dict(d); bad["verdict"] = "LGTM"
json.dump(bad, open(os.path.join(w, "bad-verdict.json"), "w"))
blocked = dict(d); blocked["verdict"] = "BLOCK"
json.dump(blocked, open(os.path.join(w, "block.json"), "w"))
PY

# Hide `jsonschema` from a child python without uninstalling it: a stub package earlier on the path
# raising ImportError is what the fallback branch actually keys on.
NOSCHEMA="$WORK/noschema"
mkdir -p "$NOSCHEMA"
printf 'raise ImportError("hidden for the degraded-path test")\n' > "$NOSCHEMA/jsonschema.py"
without_jsonschema() { ( PYTHONPATH="$NOSCHEMA${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

# ---------------------------------------------------------------------------
t_case "with jsonschema available (the declared prerequisite)"
assert_ok "precondition: jsonschema really is importable here" python3 -c "import jsonschema"
assert_rc "a conforming APPROVE verdict validates"  0 "$VALIDATE" "$WORK/good.json"
assert_rc "a conforming BLOCK verdict validates"    0 "$VALIDATE" "$WORK/block.json"
assert_output "says it used the schema" "jsonschema"  "$VALIDATE" "$WORK/good.json"

assert_rc "malformed JSON is INVALID"              1 "$VALIDATE" "$WORK/malformed.json"
assert_rc "a missing required key is INVALID"      1 "$VALIDATE" "$WORK/missing-key.json"
assert_rc "an out-of-enum verdict is INVALID"      1 "$VALIDATE" "$WORK/bad-verdict.json"

# ---------------------------------------------------------------------------
t_case "without jsonschema — degraded, and never a silent pass"
assert_rc "precondition: jsonschema is hidden" 1 without_jsonschema python3 -c "import jsonschema"

assert_rc "a good verdict is DEGRADED, not VALID"  4 without_jsonschema "$VALIDATE" "$WORK/good.json"
assert_output "says DEGRADED"       "DEGRADED"      without_jsonschema "$VALIDATE" "$WORK/good.json"
assert_output "names the fix"       "pip install"   without_jsonschema "$VALIDATE" "$WORK/good.json"
assert_output "says it fails the gate" "Final gate" without_jsonschema "$VALIDATE" "$WORK/good.json"

# The fallback still has to catch real corruption — degraded must not mean blind.
assert_rc "malformed JSON is still INVALID"        1 without_jsonschema "$VALIDATE" "$WORK/malformed.json"
assert_rc "a missing key is still INVALID"         1 without_jsonschema "$VALIDATE" "$WORK/missing-key.json"
assert_rc "a bad verdict value is still INVALID"   1 without_jsonschema "$VALIDATE" "$WORK/bad-verdict.json"

# ---------------------------------------------------------------------------
t_case "usage"
assert_rc "no argument is a usage error" 2 "$VALIDATE"

t_summary
