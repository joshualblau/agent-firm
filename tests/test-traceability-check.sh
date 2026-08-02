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

# ===========================================================================
# LOCALE INDEPENDENCE.
#
# This is a GATE: its exit code must be decided by the run's coverage and by nothing else. It used to
# be decided, in part, by the ambient locale. The coverage-summary line printed U+00B7 BEFORE any
# verdict line, so under an ASCII stdout encoding the script died with UnicodeEncodeError at the same
# point on EVERY run and exited 1 regardless of coverage:
#
#     `traceability_passes: true`  could NEVER pass
#     `traceability_passes: false` passed VACUOUSLY   <- the gate silently inverted
#
# Same class, second door: the ledger files were read with open()'s locale-default encoding, so one
# UTF-8 character in a criterion statement or an evidence string (an em dash is routine) raised
# UnicodeDecodeError under that locale before a single criterion had been read.
#
# The axis under test here is the LOCALE, so the locale is what varies; coverage is held at two known
# values (fully covered / gapped) so that "the verdict did not change" is a statement with content.
# ---------------------------------------------------------------------------

# ascii_locale <cmd...> — run <cmd> with a stdout encoding that cannot represent U+00B7.
# PYTHONCOERCECLOCALE=0 stops Python 3.7+ silently coercing C -> C.UTF-8; PYTHONUTF8=0 stops UTF-8
# mode doing the same. Without both, this helper quietly becomes a second UTF-8 run.
ascii_locale() { ( LC_ALL=C LANG=C LC_CTYPE=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0 "$@" ); }

# utf8_locale <cmd...> — the control. Prefer a real UTF-8 locale, PROBED rather than assumed (locale
# names are not portable: en_US.UTF-8 is absent on many CI images, C.UTF-8 on many macs). If the host
# has none, Python's UTF-8 mode gives the same stdout encoding by the other door, so the control is
# never skipped.
UTF8_LOCALE_NAME=""
for _cand in C.UTF-8 en_US.UTF-8 en_US.utf8 UTF-8; do
  if LC_ALL="$_cand" LANG="$_cand" LC_CTYPE="$_cand" PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 \
       python3 -c "import sys; sys.exit(0 if 'utf' in (sys.stdout.encoding or '').lower() else 1)" \
       </dev/null >/dev/null 2>&1; then
    UTF8_LOCALE_NAME="$_cand"; break
  fi
done
if [ -n "$UTF8_LOCALE_NAME" ]; then
  utf8_locale() { ( LC_ALL="$UTF8_LOCALE_NAME" LANG="$UTF8_LOCALE_NAME" LC_CTYPE="$UTF8_LOCALE_NAME" \
                    PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 "$@" ); }
  UTF8_HOW="locale $UTF8_LOCALE_NAME"
else
  utf8_locale() { ( LC_ALL=C LANG=C LC_CTYPE=C PYTHONUTF8=1 "$@" ); }
  UTF8_HOW="PYTHONUTF8=1 (no UTF-8 locale on this host)"
fi
printf '    (UTF-8 control runs via: %s)\n' "$UTF8_HOW"

t_case "preconditions: the two locale helpers really give python3 different stdout encodings"
# Without these, every assertion below could pass because BOTH helpers ran in UTF-8 — the locale axis
# would be named in the titles and varied nowhere, which is exactly the overclaim this suite forbids.
assert_ok "the ASCII helper gives a stdout that CANNOT encode U+00B7" ascii_locale python3 -c '
import sys
try:
    "·".encode(sys.stdout.encoding or "ascii")
except (UnicodeEncodeError, LookupError):
    sys.exit(0)
sys.exit(1)'
assert_ok "the UTF-8 helper gives a stdout that CAN" utf8_locale python3 -c '
import sys
"·".encode(sys.stdout.encoding or "ascii")'

t_case "the script emits no non-ASCII byte at all (nothing to encode, so nothing can raise)"
# The streams are also reconfigured to escape-on-error (see the script), which is what protects
# DATA-derived text. This assertion covers the other half: the script's own LITERALS. Both layers are
# wanted — the first stops a future decorative bullet reintroducing the bug, the second covers text
# the script never chose.
assert_ok "bin/firm-traceability-check is pure ASCII" python3 -c '
import sys
data = open(sys.argv[1], "rb").read()
bad = []
for lineno, line in enumerate(data.split(b"\n"), 1):
    for byte in line:
        if byte > 127:
            bad.append(lineno); break
if bad:
    print("non-ASCII byte(s) on line(s):", bad[:20])
    sys.exit(1)' "$TC"

t_case "a FULLY COVERED run passes under an ASCII stdout locale (it used to be unable to)"
led27="$d/led27"
mk_ledger "$led27" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "yes", "evidence": "t2"}
  ]}'
assert_rc "exit 0 under LC_ALL=C" 0 ascii_locale "$TC" "$led27"
assert_output "prints its PASS headline there" "TRACEABILITY: PASS" ascii_locale "$TC" "$led27"
assert_output "and the coverage summary line survives" "2 full (yes)" ascii_locale "$TC" "$led27"
assert_not_output "no UnicodeEncodeError" "UnicodeEncodeError" ascii_locale "$TC" "$led27"
assert_not_output "no traceback of any kind" "Traceback" ascii_locale "$TC" "$led27"

t_case "a GAPPED run still FAILs under an ASCII stdout locale (and for the right reason)"
led28="$d/led28"
mk_ledger "$led28" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"}
  ]}'
assert_rc "exit 1 under LC_ALL=C" 1 ascii_locale "$TC" "$led28"
assert_output "names the uncovered criterion, not an encoding error" \
  "AC-002: NOT in verdict coverage" ascii_locale "$TC" "$led28"
assert_not_output "no UnicodeEncodeError" "UnicodeEncodeError" ascii_locale "$TC" "$led28"

t_case "the verdict is the SAME under both locales, and still tells the two runs apart"
ascii_locale "$TC" "$led27" >/dev/null 2>&1; rc_ascii_full=$?
utf8_locale  "$TC" "$led27" >/dev/null 2>&1; rc_utf8_full=$?
ascii_locale "$TC" "$led28" >/dev/null 2>&1; rc_ascii_gap=$?
utf8_locale  "$TC" "$led28" >/dev/null 2>&1; rc_utf8_gap=$?
assert_eq "fully-covered run: identical exit code under UTF-8 and ASCII" "$rc_utf8_full" "$rc_ascii_full"
assert_eq "gapped run: identical exit code under UTF-8 and ASCII" "$rc_utf8_gap" "$rc_ascii_gap"
# The load-bearing one. Before the fix both ASCII runs exited 1, so they were indistinguishable: the
# `true` assertion could never hold and the `false` assertion held for a reason unrelated to coverage.
assert_ne "under ASCII the gate still DISTINGUISHES covered from gapped" "$rc_ascii_full" "$rc_ascii_gap"

t_case "non-ASCII in the LEDGER DATA cannot crash the gate under an ASCII locale either"
# Built from octal escapes rather than a literal character so this file stays readable in any editor
# and this fixture cannot be flattened to '-' by a well-meaning reformat.
EMDASH="$(printf '\342\200\224')"
led29="$d/led29"
mk_ledger "$led29" \
  "criteria:
  - id: AC-001
    statement: \"the gate ${EMDASH} an em dash ${EMDASH} lives in a criterion statement\"
  - id: AC-002
    statement: \"plain ascii\"" \
  "{\"acceptance_criteria_coverage\": [
    {\"id\": \"AC-001\", \"covered\": \"yes\", \"evidence\": \"t1\"},
    {\"id\": \"AC-002\", \"covered\": \"partial\", \"evidence\": \"happy path only ${EMDASH} error branch untested\"}
  ]}"
assert_rc "exit 0 under LC_ALL=C (justified partial)" 0 ascii_locale "$TC" "$led29"
assert_not_output "no UnicodeDecodeError reading the criteria file" \
  "UnicodeDecodeError" ascii_locale "$TC" "$led29"
assert_not_output "no UnicodeEncodeError printing the evidence" \
  "UnicodeEncodeError" ascii_locale "$TC" "$led29"
assert_output "still reports the gap" "TRACEABILITY: INCOMPLETE" ascii_locale "$TC" "$led29"
assert_output "still names the partial criterion" "AC-002: PARTIAL" ascii_locale "$TC" "$led29"
ascii_locale "$TC" "$led29" >/dev/null 2>&1; rc_ascii_data=$?
utf8_locale  "$TC" "$led29" >/dev/null 2>&1; rc_utf8_data=$?
assert_eq "same exit code under UTF-8" "$rc_utf8_data" "$rc_ascii_data"

t_case "a ledger file that is not valid UTF-8 is CANNOT VERIFY, under either locale"
# Reading it as the locale's encoding was one of the two doors; reading it with errors="replace" would
# have been the other kind of mistake — a file this script cannot decode yields a SHORT or subtly
# wrong id list, silently shrinking the set the gate enforces. So it fails closed, the same way a
# YAML syntax error does, and says the same thing under every locale.
BADBYTE="$(printf '\377')"
led34="$d/led34"
mk_ledger "$led34" \
  "criteria:
  - id: AC-001
    statement: \"a lone ${BADBYTE} byte is not valid UTF-8 in any encoding\"" \
  '{"acceptance_criteria_coverage": [{"id": "AC-001", "covered": "yes", "evidence": "t"}]}'
assert_rc "undecodable criteria file -> exit 1 [ascii]" 1 ascii_locale "$TC" "$led34"
assert_rc "undecodable criteria file -> exit 1 [utf-8]" 1 utf8_locale "$TC" "$led34"
assert_output "says CANNOT VERIFY, naming the encoding [ascii]" "not valid UTF-8" ascii_locale "$TC" "$led34"
assert_output "says CANNOT VERIFY, naming the encoding [utf-8]" "not valid UTF-8" utf8_locale "$TC" "$led34"
assert_not_output "never PASSes it [ascii]" "TRACEABILITY: PASS" ascii_locale "$TC" "$led34"
assert_not_output "no raw traceback [ascii]" "Traceback" ascii_locale "$TC" "$led34"

led35="$d/led35"
mk_ledger "$led35" \
  'criteria:
  - id: AC-001' \
  "{\"acceptance_criteria_coverage\": [{\"id\": \"AC-001\", \"covered\": \"yes\", \"evidence\": \"${BADBYTE}\"}]}"
assert_rc "undecodable VERDICT file -> exit 1 [ascii]" 1 ascii_locale "$TC" "$led35"
assert_rc "undecodable VERDICT file -> exit 1 [utf-8]" 1 utf8_locale "$TC" "$led35"
assert_output "names the encoding, not a bogus JSON error [ascii]" "not valid UTF-8" ascii_locale "$TC" "$led35"
assert_not_output "never PASSes it [ascii]" "TRACEABILITY: PASS" ascii_locale "$TC" "$led35"

t_case "regression under BOTH locales: the partial / waiver semantics are unchanged"
# Two axes, both varied: the coverage value (yes / partial+justified / partial+bare / no+justified)
# AND the stdout locale. The fixtures are the ones the partial cases above already pin down, re-driven
# under the ASCII locale that used to swallow every one of them.
for _loc_fn in ascii_locale utf8_locale; do
  assert_rc "justified partial -> exit 0 [$_loc_fn]" 0 $_loc_fn "$TC" "$led11"
  assert_output "justified partial -> INCOMPLETE headline [$_loc_fn]" \
    "TRACEABILITY: INCOMPLETE" $_loc_fn "$TC" "$led11"
  assert_not_output "justified partial -> never the substring TRACEABILITY: PASS [$_loc_fn]" \
    "TRACEABILITY: PASS" $_loc_fn "$TC" "$led11"
  assert_output "justified partial -> counts truthfully [$_loc_fn]" \
    "1/2 criteria fully covered" $_loc_fn "$TC" "$led11"
  assert_rc "EVERY criterion partial -> still exit 0, still not a PASS [$_loc_fn]" 0 $_loc_fn "$TC" "$led12"
  assert_not_output "EVERY criterion partial -> no PASS headline [$_loc_fn]" \
    "TRACEABILITY: PASS" $_loc_fn "$TC" "$led12"
  assert_rc "partial with NO justification -> exit 1 [$_loc_fn]" 1 $_loc_fn "$TC" "$led13"
  assert_output "partial with NO justification -> names why [$_loc_fn]" \
    "covered=partial with no justification" $_loc_fn "$TC" "$led13"
  assert_rc "justified waiver -> exit 0 [$_loc_fn]" 0 $_loc_fn "$TC" "$led16"
  assert_not_output "justified waiver -> never the substring TRACEABILITY: PASS [$_loc_fn]" \
    "TRACEABILITY: PASS" $_loc_fn "$TC" "$led16"
  assert_output "justified waiver -> shown as a gap [$_loc_fn]" \
    "AC-002: NOT COVERED (waived)" $_loc_fn "$TC" "$led16"
  assert_rc "all yes -> exit 0 [$_loc_fn]" 0 $_loc_fn "$TC" "$led20"
  assert_output "all yes -> PASS headline [$_loc_fn]" "TRACEABILITY: PASS" $_loc_fn "$TC" "$led20"
done

# ===========================================================================
# SEC-R13 — the regex fallback must not accept a document SHAPE the real parser refuses.
#
# `re.findall(r'...id:\s*...')` harvests ids out of ANY text. A criteria file whose TOP LEVEL is a
# LIST (`- id: AC-001`, no `criteria:` key) is loaded by pyyaml as a list and refused by the
# parser-present branch as "not a mapping" — but the fallback returned two ids from it and the run
# PASSED. Same file, opposite verdicts, decided by whether the host happens to have pyyaml installed,
# and diverging in the dangerous direction: the looser reader was the one saying yes.
# ---------------------------------------------------------------------------

t_case "SEC-R13: a LIST-shaped criteria file is REFUSED by the regex fallback, not silently accepted"
led30="$d/led30"
# The top level is a SEQUENCE — no `criteria:` key anywhere. Deliberately kept to the block shapes
# both parser doubles handle (tests/fixtures/stub-yaml/yaml.py cannot read a nested mapping under a
# list item), so the parser branch refuses this for its SHAPE rather than for a syntax error.
mk_ledger "$led30" \
  '- id: AC-001
- id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "yes", "evidence": "t2"}
  ]}'
assert_rc "fallback: exit 1" 1 without_yaml "$TC" "$led30"
assert_output "fallback: says CANNOT VERIFY" "CANNOT VERIFY" without_yaml "$TC" "$led30"
assert_output "fallback: names the missing top-level criteria: key" \
  "no top-level" without_yaml "$TC" "$led30"
assert_not_output "fallback: never PASSes it" "TRACEABILITY: PASS" without_yaml "$TC" "$led30"

t_case "SEC-R13: and the two parser branches now AGREE on that file (the divergence is what was wrong)"
# Both axes vary: the parser branch (fallback vs a real/stubbed parser) and — implicitly — the answer
# each gives. The point is not merely that each exits 1; it is that they exit the SAME.
assert_rc "parser-present branch: exit 1" 1 with_yaml_parser "$TC" "$led30"
assert_output "parser-present branch: also CANNOT VERIFY" "CANNOT VERIFY" with_yaml_parser "$TC" "$led30"
without_yaml    "$TC" "$led30" >/dev/null 2>&1; rc_fb_list=$?
with_yaml_parser "$TC" "$led30" >/dev/null 2>&1; rc_yaml_list=$?
assert_eq "fallback and parser-present return the same exit code" "$rc_yaml_list" "$rc_fb_list"

t_case "SEC-R13: the refusal is SHAPE-specific — the same ids in a proper mapping still PASS"
# Guards the other failure mode: a shape check that just rejects everything would also make every
# assertion above green while breaking the tool. Same ids, same verdict, correct shape.
led31="$d/led31"
# Same two ids as led30, correct shape: a mapping whose `criteria:` key holds the sequence.
mk_ledger "$led31" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "yes", "evidence": "t2"}
  ]}'
assert_rc "fallback: exit 0" 0 without_yaml "$TC" "$led31"
assert_output "fallback: PASS" "TRACEABILITY: PASS" without_yaml "$TC" "$led31"
assert_rc "parser-present branch agrees: exit 0" 0 with_yaml_parser "$TC" "$led31"

t_case "SEC-R13: an id: key nested under some OTHER top-level key is refused too"
led32="$d/led32"
mk_ledger "$led32" \
  'metadata:
  criteria:
    - id: AC-001
    - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "yes", "evidence": "t2"}
  ]}'
# pyyaml reads this as {"metadata": {...}} — doc.get("criteria") is None, so the parser branch finds
# no ids and fails closed. The fallback used to find two and PASS.
assert_rc "fallback: exit 1" 1 without_yaml "$TC" "$led32"
assert_not_output "fallback: never PASSes it" "TRACEABILITY: PASS" without_yaml "$TC" "$led32"
assert_rc "parser-present branch agrees: exit 1" 1 with_yaml_parser "$TC" "$led32"

t_case "SEC-R13: a uniformly INDENTED criteria mapping is not falsely refused by the fallback"
# The shape check measures the top-level indent from the document's first structural line instead of
# hard-coding column 0, so an indented — but still mapping-shaped — document is accepted. Asserted
# about the FALLBACK only: this file makes no claim here about what pyyaml does with it.
led33="$d/led33"
mk_ledger "$led33" \
  '  criteria:
    - id: AC-001
    - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "yes", "evidence": "t2"}
  ]}'
assert_rc "fallback: exit 0" 0 without_yaml "$TC" "$led33"

t_case "SEC-R13: the pre-existing zero-id messages are unchanged (the new guard did not swallow them)"
assert_output "criteria: present, no ids -> the 'install pyyaml or fix the format' message" \
  "'criteria:' present but no ids parsed" without_yaml "$TC" "$led8"
assert_output "no criteria: and no ids -> the 'nothing to trace' message" \
  "nothing to trace is not coverage" without_yaml "$TC" "$led22"

t_summary
