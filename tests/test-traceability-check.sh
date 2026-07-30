#!/usr/bin/env bash
# tests/test-traceability-check.sh — cross-references acceptance criteria against QA verdict coverage.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TC="$BIN/firm-traceability-check"

# Hide pyyaml the same way test-validate-verdict.sh does, to exercise the regex fallback without
# needing pyyaml actually absent on this machine.
NOSCHEMA="$(mktemp -d "${TMPDIR:-/tmp}/firm-tc-noyaml.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $NOSCHEMA"
printf 'raise ImportError("hidden for the traceability regex-fallback test")\n' > "$NOSCHEMA/yaml.py"
without_yaml() { ( PYTHONPATH="$NOSCHEMA${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

mk_ledger() {
  # mk_ledger <dir> <ac-yaml-content> <verdict-json-content>
  mkdir -p "$1"
  printf '%s' "$2" > "$1/01-acceptance-criteria.yaml"
  printf '%s' "$3" > "$1/08-qa-verdict.json"
}

# ---------------------------------------------------------------------------
t_case "usage / missing inputs"
d="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $d"
assert_rc "no run dir, no CURRENT_RUN -> exit 2" 2 sh -c "cd '$d' && '$TC'"

led1="$d/led1"; mkdir -p "$led1"
assert_rc "missing 01-acceptance-criteria.yaml -> exit 2" 2 "$TC" "$led1"

mkdir -p "$d/led2"; printf 'criteria: []\n' > "$d/led2/01-acceptance-criteria.yaml"
assert_rc "missing 08-qa-verdict.json -> exit 2" 2 "$TC" "$d/led2"

# ---------------------------------------------------------------------------
t_case "full pass: every criterion covered"
led3="$d/led3"
mk_ledger "$led3" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "test1"},
    {"id": "AC-002", "covered": "yes", "evidence": "test2"}
  ]}'
assert_rc "PASS" 0 "$TC" "$led3"
assert_output "says PASS" "TRACEABILITY: PASS" "$TC" "$led3"

t_case "an uncovered criterion FAILs"
led4="$d/led4"
mk_ledger "$led4" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "test1"}
  ]}'
assert_rc "FAIL" 1 "$TC" "$led4"
assert_output "names the uncovered id" "AC-002: NOT in verdict coverage" "$TC" "$led4"

t_case "covered:no with NO justification FAILs"
led5="$d/led5"
mk_ledger "$led5" \
  'criteria:
  - id: AC-001' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "no", "evidence": ""}
  ]}'
assert_rc "FAIL" 1 "$TC" "$led5"
assert_output "names why" "covered=no with no justification" "$TC" "$led5"

t_case "covered:no WITH a justification is accepted (justified, not uncovered)"
led6="$d/led6"
mk_ledger "$led6" \
  'criteria:
  - id: AC-001' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "no", "evidence": "waived: out of scope per intake, see 00-intake.md"}
  ]}'
assert_rc "PASS" 0 "$TC" "$led6"

# ---------------------------------------------------------------------------
t_case "defaults to CURRENT_RUN when no run_dir argument is given"
d2="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $d2"
led7="$d2/.agent-firm/runs/r1"
mk_ledger "$led7" 'criteria:
  - id: AC-001' '{"acceptance_criteria_coverage": [{"id": "AC-001", "covered": "yes", "evidence": "t"}]}'
mkdir -p "$d2/.agent-firm"
printf '%s\n' ".agent-firm/runs/r1" > "$d2/.agent-firm/CURRENT_RUN"
assert_rc "PASS via CURRENT_RUN, no explicit arg" 0 sh -c "cd '$d2' && '$TC'"

# ---------------------------------------------------------------------------
t_case "fail-closed: criteria present but no ids parseable, WITHOUT pyyaml"
led8="$d/led8"
# No `id:` keys at all -- pyyaml would still parse this fine as a list of strings with no ids, and the
# regex fallback (pyyaml hidden) genuinely cannot find any `id:` pattern either. This is the case the
# script explicitly refuses to pass vacuously.
mk_ledger "$led8" \
  'criteria:
  - "AC-001 description with no id key"
  - "AC-002 description with no id key"' \
  '{"acceptance_criteria_coverage": []}'
assert_rc "CANNOT VERIFY -> exit 1, not a silent pass" 1 without_yaml "$TC" "$led8"
assert_output "says CANNOT VERIFY" "CANNOT VERIFY" without_yaml "$TC" "$led8"

t_case "regex fallback (pyyaml hidden) still correctly parses BLOCK-style ids"
led9="$d/led9"
mk_ledger "$led9" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "yes", "evidence": "t2"}
  ]}'
assert_rc "PASS without pyyaml, via the regex fallback" 0 without_yaml "$TC" "$led9"

t_case "regex fallback (pyyaml hidden) still correctly parses FLOW-style ids"
led10="$d/led10"
mk_ledger "$led10" \
  'criteria: [{id: AC-001, type: functional}, {id: AC-002, type: security_privacy}]' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "yes", "evidence": "t2"}
  ]}'
assert_rc "PASS without pyyaml, flow-style ids via regex" 0 without_yaml "$TC" "$led10"

t_summary
