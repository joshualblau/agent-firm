#!/usr/bin/env bash
# tests/test-traceability-check.sh — cross-references acceptance criteria against QA verdict coverage.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TC="$BIN/firm-traceability-check"

# Hide pyyaml the same way test-validate-verdict.sh does, to exercise the regex fallback without
# needing pyyaml actually absent on this machine.
NOSCHEMA="$(mktemp -d "${TMPDIR:-/tmp}/firm-tc-noyaml.XXXXXX")"; t_track "$NOSCHEMA"
printf 'raise ImportError("hidden for the traceability regex-fallback test")\n' > "$NOSCHEMA/yaml.py"
without_yaml() { ( PYTHONPATH="$NOSCHEMA${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

# ...and the opposite: force the "a YAML parser IS importable" branch even on a host without pyyaml,
# preferring the REAL pyyaml wherever the host has one and falling back to the shared minimal double
# (tests/fixtures/stub-yaml/yaml.py) only where it does not.
#
# The double used to be PREPENDED unconditionally, which SHADOWED a real pyyaml everywhere one
# existed — CI included, where pyyaml==6.0.3 is installed — so the genuine exact-parser path was
# exercised on no machine anywhere. It parses only the block-style subset these fixtures use and
# raises on anything else, and it measurably disagrees with pyyaml (see its docstring), so it is a
# last resort rather than the default. tests/test-check-assertions-parsing.sh holds the assertion
# that this preference is actually honoured.
STUBYAML="$TESTS_DIR/fixtures/stub-yaml"
if python3 -c 'import yaml' >/dev/null 2>&1; then
  YAML_KIND=real
  with_yaml_parser() { ( "$@" ); }
else
  YAML_KIND=stub
  with_yaml_parser() { ( PYTHONPATH="$STUBYAML${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }
fi
printf '    (parser-present branch runs against: %s)\n' "$YAML_KIND"

t_case "preconditions: the two parser branches really differ"
assert_ok "the parser-present branch can import a working safe_load" \
  with_yaml_parser python3 -c "import yaml; assert yaml.safe_load('a: 1') == {'a': 1}"
assert_fail "and the pyyaml-hidden branch cannot import yaml at all" without_yaml python3 -c "import yaml"

mk_ledger() {
  # mk_ledger <dir> <ac-yaml-content> <verdict-json-content>
  mkdir -p "$1"
  printf '%s' "$2" > "$1/01-acceptance-criteria.yaml"
  printf '%s' "$3" > "$1/08-qa-verdict.json"
}

# ---------------------------------------------------------------------------
t_case "usage / missing inputs"
d="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; t_track "$d"
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
d2="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; t_track "$d2"
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

# ---------------------------------------------------------------------------
# covered: partial — the schema has always allowed it (agent-firm/schemas/qa-verdict.schema.json
# enum yes|no|partial) but this script only ever looked at `no`, so a verdict where EVERY criterion
# was `partial` printed "PASS — every criterion is covered or justified" and exited 0.
#
# Semantics now: partial + justification is ALLOWED (exit 0, same bar as a justified `no` — making
# it stricter would just push authors to downgrade `partial` to `no`, which is less coverage) but is
# never reported as PASS; partial with NO justification FAILs.

# assert_not_output <desc> <needle> <cmd...> — stdout+stderr must NOT contain <needle>.
assert_not_output() {
  local desc="$1" needle="$2" out; shift 2
  out="$("$@" 2>&1)"
  case "$out" in
    *"$needle"*) _t_no "$desc" "unexpectedly found '$needle' in: $(_t_ctx "$out")" ;;
    *) _t_ok "$desc" ;;
  esac
}

t_case "covered:partial with a justification does NOT report PASS (exit 0, headline INCOMPLETE)"
led11="$d/led11"
mk_ledger "$led11" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "test1"},
    {"id": "AC-002", "covered": "partial", "evidence": "happy path only; error branch untested"}
  ]}'
assert_rc "exit 0 — a justified gap is allowed, like a justified waiver" 0 "$TC" "$led11"
assert_not_output "must NOT claim PASS" "TRACEABILITY: PASS" "$TC" "$led11"
assert_output "headline says INCOMPLETE" "TRACEABILITY: INCOMPLETE" "$TC" "$led11"
assert_output "surfaces the partial criterion by id" "AC-002: PARTIAL" "$TC" "$led11"
assert_output "quotes the justification" "error branch untested" "$TC" "$led11"
assert_output "counts truthfully" "1/2 criteria fully covered" "$TC" "$led11"
assert_output "breakdown line names the partial" "1 partial" "$TC" "$led11"

t_case "EVERY criterion partial: still not a PASS (the exact fail-open being fixed)"
led12="$d/led12"
mk_ledger "$led12" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "partial", "evidence": "unit only"},
    {"id": "AC-002", "covered": "partial", "evidence": "unit only"}
  ]}'
assert_not_output "no PASS headline" "TRACEABILITY: PASS" "$TC" "$led12"
assert_not_output "does not claim every criterion is covered" "every criterion is covered" "$TC" "$led12"
assert_output "reports 0 fully covered" "0/2 criteria fully covered" "$TC" "$led12"

t_case "covered:partial with NO justification FAILs (same bar as covered:no)"
led13="$d/led13"
mk_ledger "$led13" \
  'criteria:
  - id: AC-001' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "partial", "evidence": ""}
  ]}'
assert_rc "FAIL" 1 "$TC" "$led13"
assert_output "names why" "covered=partial with no justification" "$TC" "$led13"

t_case "covered:partial with the evidence key MISSING entirely FAILs"
led14="$d/led14"
mk_ledger "$led14" \
  'criteria:
  - id: AC-001' \
  '{"acceptance_criteria_coverage": [{"id": "AC-001", "covered": "partial"}]}'
assert_rc "FAIL" 1 "$TC" "$led14"
assert_output "names why" "covered=partial with no justification" "$TC" "$led14"

t_case "covered:partial is caught on the pyyaml-less path too (both axes vary: parser AND coverage)"
# The id list comes from the regex fallback here, the coverage value from the verdict — this case
# would pass vacuously if only one of the two axes were exercised.
led15="$d/led15"
mk_ledger "$led15" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "partial", "evidence": ""}
  ]}'
assert_rc "FAIL without pyyaml" 1 without_yaml "$TC" "$led15"
assert_output "names the unjustified partial" "covered=partial with no justification" without_yaml "$TC" "$led15"

t_case "a justified waiver (covered:no + evidence) still exits 0, but is now visible as a GAP"
led16="$d/led16"
mk_ledger "$led16" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "no", "evidence": "waived at the Requirements gate"}
  ]}'
assert_rc "exit 0 (unchanged)" 0 "$TC" "$led16"
assert_output "shown as a waived gap" "AC-002: NOT COVERED (waived)" "$TC" "$led16"
assert_not_output "no longer prints a bare PASS over a waiver" "TRACEABILITY: PASS" "$TC" "$led16"

t_case "a coverage value outside the schema enum cannot be interpreted -> FAIL, not ignored"
led17="$d/led17"
mk_ledger "$led17" \
  'criteria:
  - id: AC-001' \
  '{"acceptance_criteria_coverage": [{"id": "AC-001", "covered": "mostly", "evidence": "e"}]}'
assert_rc "FAIL" 1 "$TC" "$led17"
assert_output "names the bad value" "is not one of yes/no/partial" "$TC" "$led17"

t_case "a coverage entry with no covered value at all -> FAIL"
led18="$d/led18"
mk_ledger "$led18" \
  'criteria:
  - id: AC-001' \
  '{"acceptance_criteria_coverage": [{"id": "AC-001", "evidence": "e"}]}'
assert_rc "FAIL" 1 "$TC" "$led18"
assert_output "names why" "no \`covered\` value" "$TC" "$led18"

t_case "a malformed coverage entry is counted as a problem, not dropped"
led19="$d/led19"
mk_ledger "$led19" \
  'criteria:
  - id: AC-001' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t"},
    "this entry is a bare string"
  ]}'
assert_rc "FAIL" 1 "$TC" "$led19"
assert_output "names the malformed entry" "malformed" "$TC" "$led19"

t_case "all-yes still PASSes, and the headline says so precisely"
led20="$d/led20"
mk_ledger "$led20" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "yes", "evidence": "t2"}
  ]}'
assert_rc "PASS" 0 "$TC" "$led20"
assert_output "says all criteria are fully covered" "all 2 criteria marked fully covered" "$TC" "$led20"

t_case "covered:yes citing NO evidence still passes (unchanged), but is called out as a note"
led21="$d/led21"
mk_ledger "$led21" \
  'criteria:
  - id: AC-001' \
  '{"acceptance_criteria_coverage": [{"id": "AC-001", "covered": "yes", "evidence": ""}]}'
assert_rc "exit 0 — behaviour for covered:yes is preserved" 0 "$TC" "$led21"
assert_output "still PASS" "TRACEABILITY: PASS" "$TC" "$led21"
assert_output "but the unsourced claim is named" "covered=yes but cites NO evidence" "$TC" "$led21"

t_case "zero acceptance criteria is CANNOT VERIFY, not a vacuous PASS"
led22="$d/led22"
mk_ledger "$led22" 'task_slug: nothing-here
' '{"acceptance_criteria_coverage": []}'
assert_rc "exit 1" 1 "$TC" "$led22"
assert_output "says nothing to trace is not coverage" "nothing to trace is not coverage" "$TC" "$led22"

t_case "with a YAML parser present, a BROKEN criteria file is CANNOT VERIFY, not a quiet regex fallback"
# A half-readable criteria file yields a SHORT id list, and every criterion missing from that list is
# then never checked for coverage — the gate silently shrinks. Both parser branches are exercised:
# with_yaml_parser proves the hard-failure path, without_yaml proves the degraded path still works.
led24="$d/led24"
mk_ledger "$led24" \
  'criteria:
  - id: AC-001
   id: AC-002 [unclosed' \
  '{"acceptance_criteria_coverage": [{"id": "AC-001", "covered": "yes", "evidence": "t"}]}'
assert_rc "exit 1" 1 with_yaml_parser "$TC" "$led24"
assert_output "names the invalid YAML" "not valid YAML" with_yaml_parser "$TC" "$led24"
assert_output "did not silently proceed on a partial id list" "CANNOT VERIFY" with_yaml_parser "$TC" "$led24"

t_case "with a YAML parser present, a criteria file that is not a mapping is CANNOT VERIFY"
led25="$d/led25"
mk_ledger "$led25" 'just prose where the criteria should be' \
  '{"acceptance_criteria_coverage": []}'
assert_rc "exit 1" 1 with_yaml_parser "$TC" "$led25"
assert_output "names the wrong top-level type" "expected a mapping" with_yaml_parser "$TC" "$led25"

t_case "the pyyaml branch agrees with the fallback on a well-formed file (parser axis really varies)"
led26="$d/led26"
mk_ledger "$led26" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "partial", "evidence": "unit only"}
  ]}'
assert_rc "parser-present branch: exit 0" 0 with_yaml_parser "$TC" "$led26"
assert_output "parser-present branch: INCOMPLETE" "TRACEABILITY: INCOMPLETE" with_yaml_parser "$TC" "$led26"
assert_rc "fallback branch: exit 0" 0 without_yaml "$TC" "$led26"
assert_output "fallback branch: INCOMPLETE" "TRACEABILITY: INCOMPLETE" without_yaml "$TC" "$led26"

t_case "an unparseable verdict is CANNOT VERIFY, not a crash and not a pass"
led23="$d/led23"
mk_ledger "$led23" 'criteria:
  - id: AC-001' '{not json at all'
assert_rc "exit 1" 1 "$TC" "$led23"
assert_output "names the bad JSON" "not valid JSON" "$TC" "$led23"

t_summary
