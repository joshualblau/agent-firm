#!/usr/bin/env bash
# tests/test-traceability-check.sh — cross-references acceptance criteria against QA verdict coverage.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TC="$BIN/firm-traceability-check"

# without_yaml simulates pyyaml GENUINELY NOT INSTALLED, so the regex fallback runs without pyyaml
# having to be absent from this machine.
#
# THIS HELPER CHANGED, and the change is required by the fix rather than incidental to it. It used to
# be a PYTHONPATH `yaml.py` that raised ImportError (the technique tests/test-validate-verdict.sh:52-57
# still uses for jsonschema). Now that firm-traceability-check discriminates ABSENT from BROKEN with
# `importlib.util.find_spec("yaml")`, a stub file no longer expresses absence at all: a stub is
# FINDABLE, so a findable stub whose import raises IS an installed-but-broken pyyaml, and it is reused
# for exactly that case further down. Every `without_yaml` assertion in this file would otherwise have
# been silently testing the BROKEN branch while claiming to test the degraded one.
#
# What does express absence is a `sitecustomize.py` — imported by site.py at interpreter startup,
# before the script's own `import yaml` — that wraps the path finder so nothing can find `yaml`.
# Surgical on purpose: only the `yaml` name disappears, so anything else installed alongside it stays
# importable, and NOTHING is installed or uninstalled — the host's real pyyaml is untouched, it is just
# invisible to this one interpreter. Same mechanism, same wording, as
# tests/test-check-assertions-parsing.sh, which pins the identical discriminator in this script's
# caller. If a future python changes sys.meta_path's composition this stops hiding pyyaml, and the
# precondition below FAILS LOUDLY rather than letting these cases pass on the wrong branch.
NOYAML="$(mktemp -d "${TMPDIR:-/tmp}/firm-tc-noyaml.XXXXXX")"; t_track "$NOYAML"
cat > "$NOYAML/sitecustomize.py" <<'PYSC'
import sys
from importlib.machinery import PathFinder


class _NoYamlPathFinder(PathFinder):
    @classmethod
    def find_spec(cls, fullname, path=None, target=None):
        if fullname == "yaml" or fullname.startswith("yaml."):
            return None          # what the import system reports for a module installed nowhere
        return super().find_spec(fullname, path, target)


sys.meta_path[:] = [_NoYamlPathFinder if f is PathFinder else f for f in sys.meta_path]
PYSC
without_yaml() { ( PYTHONPATH="$NOYAML${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

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
# The property the ABSENT branch is now selected BY. Asserted separately from "the import raises",
# because those two came apart: a findable-but-failing stub also raises, and it must NOT reach the
# fallback. Without this, every `without_yaml` case below could be silently testing the broken-install
# path instead of the absent one — which is exactly what the old stub-file helper did.
assert_ok "without_yaml: pyyaml is UNFINDABLE (find_spec -> None), which is genuine absence and not a broken install" \
  without_yaml python3 -c '
import importlib.util
spec = importlib.util.find_spec("yaml")
assert spec is None, "yaml is still findable at %s -- this simulates BROKEN, not ABSENT" % (spec,)'

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
assert_rc "CANNOT VERIFY -> exit 2 (cannot evaluate), not a silent pass" 2 without_yaml "$TC" "$led8"
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
assert_rc "CANNOT EVALUATE -> exit 2, not exit 1" 2 "$TC" "$led17"
assert_output "names the bad value" "is not one of yes/no/partial" "$TC" "$led17"

t_case "a coverage entry with no covered value at all -> FAIL"
led18="$d/led18"
mk_ledger "$led18" \
  'criteria:
  - id: AC-001' \
  '{"acceptance_criteria_coverage": [{"id": "AC-001", "evidence": "e"}]}'
assert_rc "CANNOT EVALUATE -> exit 2, not exit 1" 2 "$TC" "$led18"
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
assert_rc "CANNOT EVALUATE -> exit 2, not exit 1" 2 "$TC" "$led19"
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
assert_rc "exit 2 (cannot evaluate)" 2 "$TC" "$led22"
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
assert_rc "exit 2 (cannot evaluate)" 2 with_yaml_parser "$TC" "$led24"
assert_output "names the invalid YAML" "not valid YAML" with_yaml_parser "$TC" "$led24"
assert_output "did not silently proceed on a partial id list" "CANNOT VERIFY" with_yaml_parser "$TC" "$led24"

t_case "with a YAML parser present, a criteria file that is not a mapping is CANNOT VERIFY"
led25="$d/led25"
mk_ledger "$led25" 'just prose where the criteria should be' \
  '{"acceptance_criteria_coverage": []}'
assert_rc "exit 2 (cannot evaluate)" 2 with_yaml_parser "$TC" "$led25"
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
assert_rc "exit 2 (cannot evaluate)" 2 "$TC" "$led23"
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
# U+00B7 is written as an ASCII escape, never as a literal byte. Under a strict C locale glibc decodes
# argv with the locale encoding, so a literal here crashes python3 while it is still decoding its own
# arguments — before the test body runs. macOS decodes argv as UTF-8 regardless, which is why the
# literal form passed locally and would have reddened the Linux CI runner. The runtime value is
# identical; only the source bytes change.
assert_ok "the ASCII helper gives a stdout that CANNOT encode U+00B7" ascii_locale python3 -c '
import sys
try:
    "\u00b7".encode(sys.stdout.encoding or "ascii")
except (UnicodeEncodeError, LookupError):
    sys.exit(0)
sys.exit(1)'
assert_ok "the UTF-8 helper gives a stdout that CAN" utf8_locale python3 -c '
import sys
"\u00b7".encode(sys.stdout.encoding or "ascii")'

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
assert_rc "undecodable criteria file -> exit 2 (cannot evaluate) [ascii]" 2 ascii_locale "$TC" "$led34"
assert_rc "undecodable criteria file -> exit 2 (cannot evaluate) [utf-8]" 2 utf8_locale "$TC" "$led34"
assert_output "says CANNOT VERIFY, naming the encoding [ascii]" "not valid UTF-8" ascii_locale "$TC" "$led34"
assert_output "says CANNOT VERIFY, naming the encoding [utf-8]" "not valid UTF-8" utf8_locale "$TC" "$led34"
assert_not_output "never PASSes it [ascii]" "TRACEABILITY: PASS" ascii_locale "$TC" "$led34"
assert_not_output "no raw traceback [ascii]" "Traceback" ascii_locale "$TC" "$led34"

led35="$d/led35"
mk_ledger "$led35" \
  'criteria:
  - id: AC-001' \
  "{\"acceptance_criteria_coverage\": [{\"id\": \"AC-001\", \"covered\": \"yes\", \"evidence\": \"${BADBYTE}\"}]}"
assert_rc "undecodable VERDICT file -> exit 2 (cannot evaluate) [ascii]" 2 ascii_locale "$TC" "$led35"
assert_rc "undecodable VERDICT file -> exit 2 (cannot evaluate) [utf-8]" 2 utf8_locale "$TC" "$led35"
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
assert_rc "fallback: exit 2 (cannot evaluate)" 2 without_yaml "$TC" "$led30"
assert_output "fallback: says CANNOT VERIFY" "CANNOT VERIFY" without_yaml "$TC" "$led30"
assert_output "fallback: names the missing top-level criteria: key" \
  "no top-level" without_yaml "$TC" "$led30"
assert_not_output "fallback: never PASSes it" "TRACEABILITY: PASS" without_yaml "$TC" "$led30"

t_case "SEC-R13: and the two parser branches now AGREE on that file (the divergence is what was wrong)"
# Both axes vary: the parser branch (fallback vs a real/stubbed parser) and — implicitly — the answer
# each gives. The point is not merely that each exits 1; it is that they exit the SAME.
assert_rc "parser-present branch: exit 2 (cannot evaluate)" 2 with_yaml_parser "$TC" "$led30"
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
assert_rc "fallback: exit 2 (cannot evaluate)" 2 without_yaml "$TC" "$led32"
assert_not_output "fallback: never PASSes it" "TRACEABILITY: PASS" without_yaml "$TC" "$led32"
assert_rc "parser-present branch agrees: exit 2 (cannot evaluate)" 2 with_yaml_parser "$TC" "$led32"

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

# ===========================================================================
# EXIT-CODE CLASSIFICATION — "evaluated, coverage is inadequate" vs "could not evaluate".
#
# This gate is INVERTED by its callers: `traceability_passes: false` in a golden eval asserts "this
# run SHOULD fail traceability". Every CANNOT VERIFY path used to exit 1, exactly like a genuine
# coverage gap, so bin/firm-check-assertions' `(rc == 0) == (want == "true")` was satisfied by a
# usage error, an unparseable verdict, a missing run dir, or an outright crash. An eval asserting
# "traceability correctly fails here" passed when the checker merely blew up.
#
# The contract now has THREE codes: 0 evaluated/acceptable, 1 evaluated/INADEQUATE, 2 CANNOT
# EVALUATE. The axis under test in this whole section is WHICH KIND OF BAD INPUT the checker was
# given, so that is what varies; every case below asserts the exact code, never merely "non-zero" —
# "non-zero" is the very conflation being removed, and a test that only asserted it would go green
# against the bug.
# ---------------------------------------------------------------------------

t_case "a GENUINE coverage failure is exit 1 — the only code that means 'the gate looked and said no'"
# Held first and separately: if the fix made cannot-evaluate exit 2 by making EVERYTHING exit 2,
# `traceability_passes: false` would become unsatisfiable and every eval that inverts this gate would
# break. These three are the whole of the exit-1 class.
assert_rc "an uncovered criterion -> exit 1" 1 "$TC" "$led4"
assert_rc "covered=no with no justification -> exit 1" 1 "$TC" "$led5"
assert_rc "covered=partial with no justification -> exit 1" 1 "$TC" "$led13"
assert_output "and it is reported as a FAIL, not as CANNOT VERIFY" "TRACEABILITY: FAIL" "$TC" "$led4"
assert_not_output "a real coverage gap never claims the run was unevaluable" \
  "CANNOT VERIFY" "$TC" "$led4"

# --- fixtures for the cannot-evaluate conditions this script defines -------
# Three are new here because they had no coverage at all before: a non-list
# acceptance_criteria_coverage, a verdict whose top level is not an object, and a criteria PATH that
# exists but cannot be read as a file (a directory). The last one used to escape read_text as a bare
# OSError and take Python's default exit code — 1, i.e. "coverage is inadequate", for a file the
# script never managed to open.
led36="$d/led36"
mk_ledger "$led36" 'criteria:
  - id: AC-001' '{"acceptance_criteria_coverage": {"AC-001": "yes"}}'

led37="$d/led37"
mk_ledger "$led37" 'criteria:
  - id: AC-001' '["not", "an", "object"]'

led38="$d/led38"
mkdir -p "$led38/01-acceptance-criteria.yaml"      # a DIRECTORY where the criteria file belongs
printf '%s' '{"acceptance_criteria_coverage": [{"id": "AC-001", "covered": "yes", "evidence": "t"}]}' \
  > "$led38/08-qa-verdict.json"
assert_file "precondition: the criteria path exists (so the MISSING guard does not catch it first)" \
  "$led38/01-acceptance-criteria.yaml"

led39="$d/led39"   # BOTH kinds at once: an uninterpretable entry AND a genuine uncovered criterion
mk_ledger "$led39" \
  'criteria:
  - id: AC-001
  - id: AC-002
  - id: AC-003' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "t1"},
    {"id": "AC-002", "covered": "mostly", "evidence": "e"}
  ]}'

t_case "every CANNOT-EVALUATE condition exits 2, and none of them exits 1"
# One loop, one assertion shape, every condition the script defines as unevaluable. `|`-separated
# because bash 3.2 has no associative arrays; the label is only for the failure message.
while IFS='|' read -r _lbl _dir; do
  [ -n "$_lbl" ] || continue
  assert_rc "cannot evaluate -> exit 2: $_lbl" 2 "$TC" "$_dir"
  assert_not_output "and never claims a coverage verdict: $_lbl" "TRACEABILITY: PASS" "$TC" "$_dir"
  assert_not_output "and never reports it as a coverage FAIL: $_lbl" "TRACEABILITY: FAIL" "$TC" "$_dir"
done <<EOF
run dir does not exist|$d/no-such-run-dir
missing 01-acceptance-criteria.yaml|$led1
missing 08-qa-verdict.json|$d/led2
criteria path is a directory, not a file|$led38
criteria file is not valid UTF-8|$led34
verdict file is not valid UTF-8|$led35
verdict is not valid JSON|$led23
verdict top level is not an object|$led37
acceptance_criteria_coverage is not a list|$led36
zero acceptance criteria|$led22
a coverage entry is malformed|$led19
covered value is outside the schema enum|$led17
no covered value at all|$led18
EOF

t_case "cannot-evaluate conditions that need a specific parser branch exit 2 there too"
# Same class, but each only reachable on one side of the pyyaml/regex split, so they cannot ride the
# loop above (which runs with whatever parser the host has).
assert_rc "broken YAML, parser present -> exit 2" 2 with_yaml_parser "$TC" "$led24"
assert_rc "criteria top level is not a mapping, parser present -> exit 2" 2 with_yaml_parser "$TC" "$led25"
assert_rc "criteria: present but no ids parseable, fallback -> exit 2" 2 without_yaml "$TC" "$led8"
assert_rc "LIST-shaped criteria file, fallback -> exit 2" 2 without_yaml "$TC" "$led30"
assert_rc "criteria nested under another key, fallback -> exit 2" 2 without_yaml "$TC" "$led32"

t_case "an UNEXPECTED internal error is exit 2, not Python's default exit 1"
# Python exits 1 on an unhandled exception — the exact code reserved for a real coverage failure. So
# a crash was indistinguishable from "this run has an uncovered criterion", and a caller inverting
# the gate counted the crash as the failure it wanted.
#
# THE INJECTION CHANGED HERE, because the fix changed what a broken pyyaml MEANS. This case used to
# inject a PYTHONPATH `yaml.py` raising RuntimeError and assert the excepthook's generic "internal
# error" line. That state is now CLASSIFIED explicitly (findable + import fails = a broken install,
# with the exception named), and it is pinned as such in the parser-state section at the bottom of this
# file — where its exit code, its wording, and the absence of a silent downgrade are all asserted. The
# excepthook still has to hold for the genuinely UNFORESEEN, so it is now driven by an error the script
# has no branch for at all: os.path.exists() raising while the script probes for its input file. Same
# harness technique (a PYTHONPATH sitecustomize), nothing added to production code, and no yaml
# involvement — so this case cannot pass via the new discriminator instead of the hook it names.
BOOMHOOK="$(mktemp -d "${TMPDIR:-/tmp}/firm-tc-boom.XXXXXX")"; t_track "$BOOMHOOK"
cat > "$BOOMHOOK/sitecustomize.py" <<'PYSC'
import os.path

_real_exists = os.path.exists


def _boom(path):
    # Only the criteria-file probe: everything else the interpreter does must keep working, or the
    # failure would be startup noise rather than a fault inside the script under test.
    if str(path).endswith("01-acceptance-criteria.yaml"):
        raise RuntimeError("simulated unexpected internal error")
    return _real_exists(path)


os.path.exists = _boom
PYSC
with_internal_crash() { ( PYTHONPATH="$BOOMHOOK${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }
assert_ok "precondition: the hook makes an os.path.exists the script does NOT guard raise, and is not an import problem" \
  with_internal_crash python3 -c '
import os.path, sys
assert os.path.exists("/") is True, "the hook broke unrelated paths -- too blunt to attribute"
try:
    os.path.exists("/nowhere/01-acceptance-criteria.yaml")
except ImportError:
    sys.exit("raised ImportError -- would be classified as a parser state, wrong axis")
except RuntimeError as e:
    assert "simulated unexpected internal error" in str(e), "wrong RuntimeError: %s" % e
else:
    sys.exit("os.path.exists did not raise -- the injection is inert")'
# led3 is FULLY COVERED: without the crash this run exits 0, so a non-zero code here is the crash and
# nothing else — the fixture cannot pass for an unrelated coverage reason.
assert_rc "precondition: this ledger exits 0 when nothing goes wrong" 0 "$TC" "$led3"
assert_rc "a crashing run -> exit 2 (cannot evaluate), NOT 1" 2 with_internal_crash "$TC" "$led3"
assert_output "and says so in one line, on top of the traceback" \
  "TRACEABILITY: CANNOT VERIFY -- internal error" with_internal_crash "$TC" "$led3"
assert_output "naming the real exception, not a guess at a cause" "RuntimeError" \
  with_internal_crash "$TC" "$led3"
assert_not_output "a crash is never dressed up as a coverage verdict" \
  "TRACEABILITY: FAIL" with_internal_crash "$TC" "$led3"
assert_not_output "and certainly never as a PASS" "TRACEABILITY: PASS" with_internal_crash "$TC" "$led3"

t_case "unevaluable coverage takes PRECEDENCE over a real gap found alongside it"
# AC-002's value cannot be interpreted and AC-003 is genuinely uncovered. The run has NO verdict: the
# uninterpretable value could have gone either way. Reporting exit 1 here would let a caller treat a
# half-unreadable verdict as a decided coverage failure.
assert_rc "exit 2, not 1" 2 "$TC" "$led39"
assert_output "names the uninterpretable value" "is not one of yes/no/partial" "$TC" "$led39"
assert_output "AND still surfaces the genuine gap rather than hiding it" \
  "AC-003: NOT in verdict coverage" "$TC" "$led39"
assert_not_output "but does not call the run a coverage FAIL" "TRACEABILITY: FAIL" "$TC" "$led39"
assert_output "the summary counts both kinds separately" "1 problem(s) | 1 unverifiable" "$TC" "$led39"

t_case "the three codes are genuinely DISTINCT (this is the whole point)"
"$TC" "$led3"  >/dev/null 2>&1; rc_cls_ok=$?
"$TC" "$led4"  >/dev/null 2>&1; rc_cls_gap=$?
"$TC" "$led17" >/dev/null 2>&1; rc_cls_unv=$?
assert_eq "covered run -> 0" "0" "$rc_cls_ok"
assert_eq "genuine coverage failure -> 1" "1" "$rc_cls_gap"
assert_eq "cannot evaluate -> 2" "2" "$rc_cls_unv"
assert_ne "a coverage failure is NOT reported with the cannot-evaluate code" "$rc_cls_unv" "$rc_cls_gap"
assert_ne "and neither is confusable with success" "$rc_cls_ok" "$rc_cls_gap"

t_case "the classification survives an ASCII stdout locale (both axes vary: locale AND outcome)"
# The locale property this script already holds must cover the NEW code too: an exit code decided by
# the ambient locale rather than by the input is the original fail-open in this file, one door along.
for _loc_fn in ascii_locale utf8_locale; do
  assert_rc "covered -> 0 [$_loc_fn]" 0 $_loc_fn "$TC" "$led3"
  assert_rc "genuine coverage failure -> 1 [$_loc_fn]" 1 $_loc_fn "$TC" "$led4"
  assert_rc "cannot evaluate (bad enum value) -> 2 [$_loc_fn]" 2 $_loc_fn "$TC" "$led17"
  assert_rc "cannot evaluate (unparseable verdict) -> 2 [$_loc_fn]" 2 $_loc_fn "$TC" "$led23"
  assert_not_output "no UnicodeEncodeError on the new CANNOT VERIFY path [$_loc_fn]" \
    "UnicodeEncodeError" $_loc_fn "$TC" "$led17"
done

# ===========================================================================
# PARSER STATE — pyyaml INSTALLED BUT BROKEN is a THIRD state, and the sixth instance of this repo's
# characteristic defect: a check that cannot evaluate its input reported something other than "cannot
# evaluate".
#
# `try: import yaml / except ImportError: yaml = None` saw two worlds. A partial or corrupted install
# is a third, and the dangerous shape was SILENT:
#   · ImportError raised from INSIDE the package -> swallowed, so this gate DOWNGRADED ITSELF to the
#     regex reader and then spoke as though the host had no pyyaml. It matters more here than almost
#     anywhere: the fallback cannot see a YAML syntax error at all, so a document the real parser
#     REFUSES yields a SHORT id list and the criteria that fell out of it are never checked for
#     coverage. The set this gate enforces shrinks, and nothing says so.
#   · anything else (RuntimeError / SystemExit) -> the excepthook already forced exit 2, so the CODE
#     was right; the diagnosis was a generic "internal error" that named neither pyyaml nor the fault.
#
# The discriminator under test is importlib.util.find_spec("yaml") — findable + import fails = BROKEN
# (exit 2); unfindable = genuinely absent (the documented fallback, unchanged); probe raises =
# inconclusive (exit 2, checked FIRST so an unknown state is never mistaken for a known one). Same
# discriminator, ordering and wording as bin/firm-check-assertions, which is this script's caller
# (tests/test-check-assertions-parsing.sh pins it there); the two must not disagree about whether a
# host has a usable YAML parser.
#
# TWO axes vary across these cases and both matter: WHAT the import does (ImportError from inside /
# a non-ImportError / exits the process / genuinely unfindable / works) and WHAT the gate must then
# report (cannot-evaluate vs. a real coverage verdict). Varying only the first would not show that
# absence still degrades correctly; varying only the second would not show which shapes of breakage
# reach it.
#
# TWO LEDGERS carry the outcome axis, deliberately, because "no silent downgrade" is a claim about
# what the fallback WOULD have said:
#   $led3   fully covered, well-formed  -> a downgrade PASSES it (exit 0). Asserted below.
#   $led24  a YAML SYNTAX ERROR         -> the real parser refuses it (exit 2) while the fallback
#                                          harvests both ids and reports a coverage FAIL (exit 1).
#                                          Asserted below. So a downgrade here manufactures a
#                                          criterion-level VERDICT out of a file no parser accepted.
# Neither ledger's exit code can therefore come from the coverage data alone.
# ===========================================================================
t_case "the broken-pyyaml doubles really are findable-but-failing, and differ on the axis that matters"
# Each double is a pyyaml the import system CAN find (that is what makes it "installed") whose import
# does not complete. A real corrupted install / half-removed wheel / bad extension module presents
# exactly like these. NOTHING is installed or uninstalled: the host's real pyyaml is simply shadowed on
# PYTHONPATH for one interpreter.
BROKEN_IMP="$(mktemp -d "${TMPDIR:-/tmp}/firm-tc-badyaml-imp.XXXXXX")"; t_track "$BROKEN_IMP"
mkdir -p "$BROKEN_IMP/yaml"
printf 'from yaml.does_not_exist import SafeLoader   # a half-installed package\n' \
  > "$BROKEN_IMP/yaml/__init__.py"
with_broken_partial() { ( PYTHONPATH="$BROKEN_IMP${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

BROKEN_RT="$(mktemp -d "${TMPDIR:-/tmp}/firm-tc-badyaml-rt.XXXXXX")"; t_track "$BROKEN_RT"
printf 'raise RuntimeError("simulated broken pyyaml install")\n' > "$BROKEN_RT/yaml.py"
with_broken_rt() { ( PYTHONPATH="$BROKEN_RT${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

BROKEN_EXIT="$(mktemp -d "${TMPDIR:-/tmp}/firm-tc-badyaml-exit.XXXXXX")"; t_track "$BROKEN_EXIT"
printf 'import sys\nsys.exit(0)   # module-level SystemExit: NOT an Exception\n' > "$BROKEN_EXIT/yaml.py"
with_broken_sysexit() { ( PYTHONPATH="$BROKEN_EXIT${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

assert_ok "partial-install double: FINDABLE, and raises ImportError from INSIDE the package (the swallowed shape)" \
  with_broken_partial python3 -c '
import importlib.util, sys
assert importlib.util.find_spec("yaml") is not None, "not findable -> would be absence, wrong axis"
try:
    import yaml
except ImportError as e:
    assert "yaml.does_not_exist" in str(e), "wrong ImportError: %s" % e
else:
    sys.exit("import unexpectedly succeeded")'
assert_ok "runtime-broken double: FINDABLE, and raises a NON-ImportError (the shape that escaped)" \
  with_broken_rt python3 -c '
import importlib.util, sys
assert importlib.util.find_spec("yaml") is not None, "not findable -> would be absence, wrong axis"
try:
    import yaml
except ImportError:
    sys.exit("raised ImportError -- wrong axis for this double")
except RuntimeError:
    pass
else:
    sys.exit("import unexpectedly succeeded")'
assert_ok "sysexit double: FINDABLE, and an 'except Exception' does NOT catch what it raises" \
  with_broken_sysexit python3 -c '
import importlib.util, sys
assert importlib.util.find_spec("yaml") is not None, "not findable -> would be absence, wrong axis"
try:
    import yaml
except Exception:
    sys.exit("an `except Exception` would have caught this -- wrong axis for this double")
except BaseException as e:
    assert isinstance(e, SystemExit) and e.code == 0, "unexpected: %r" % (e,)'

t_case "broken pyyaml (ImportError from INSIDE the package) is CANNOT EVALUATE — never a silent downgrade"
# The dangerous one. This ledger is fully covered and well-formed, so the regex fallback PASSES it:
# before the fix a findable-but-broken pyyaml exited 0 here, on the weaker reader, while nothing said
# the exact parser had not run.
assert_rc "exit 2 (cannot evaluate), NOT the 0 a downgrade produces" 2 with_broken_partial "$TC" "$led3"
assert_output "says CANNOT VERIFY" "CANNOT VERIFY" with_broken_partial "$TC" "$led3"
assert_output "reports pyyaml as INSTALLED (it is findable), not missing" "pyyaml IS installed" \
  with_broken_partial "$TC" "$led3"
assert_output "names the failure inside the package, so the install is diagnosable" "yaml.does_not_exist" \
  with_broken_partial "$TC" "$led3"
assert_output "and says which state this is, in the operator's words" "BROKEN install, not a missing one" \
  with_broken_partial "$TC" "$led3"
assert_not_output "the regex reader did NOT quietly take over and pass the run" \
  "TRACEABILITY: PASS" with_broken_partial "$TC" "$led3"
assert_not_output "and no coverage was evaluated at all (no summary line)" \
  "verdict coverage entries" with_broken_partial "$TC" "$led3"
# The control that makes the assertion above a statement about the DOWNGRADE rather than about this
# ledger: genuine absence really does reach the fallback and really does pass this same file.
assert_rc "control: genuine absence still runs the fallback and PASSes the same ledger" 0 \
  without_yaml "$TC" "$led3"
assert_output "control: and it is the fallback's own PASS" "TRACEABILITY: PASS" without_yaml "$TC" "$led3"

t_case "a downgrade would MANUFACTURE a coverage verdict from a file the real parser refuses"
# $led24 has a YAML syntax error. The fallback cannot see one: it harvests AC-001 and AC-002 and
# reports AC-002 uncovered — exit 1, a criterion-level verdict, from a document no parser accepted.
# So on this ledger the silent downgrade is not merely "the weaker reader ran", it is a FAIL invented
# out of an unreadable file. Both axes vary here: the parser state AND what each state concludes.
assert_rc "control: genuine absence yields a coverage FAIL (exit 1) on this ledger" 1 without_yaml "$TC" "$led24"
assert_output "control: and calls it a FAIL" "TRACEABILITY: FAIL" without_yaml "$TC" "$led24"
assert_rc "broken pyyaml: exit 2, NOT the 1 a downgrade produces" 2 with_broken_partial "$TC" "$led24"
assert_not_output "broken pyyaml: never reports a criterion-level coverage FAIL" \
  "TRACEABILITY: FAIL" with_broken_partial "$TC" "$led24"
assert_not_output "broken pyyaml: and never names a criterion it never read" \
  "AC-002: NOT in verdict coverage" with_broken_partial "$TC" "$led24"
assert_output "broken pyyaml: says the parser is broken, not that the FILE is" "pyyaml IS installed" \
  with_broken_partial "$TC" "$led24"
assert_not_output "broken pyyaml: does not blame the file's syntax, which it never parsed" \
  "not valid YAML" with_broken_partial "$TC" "$led24"

t_case "broken pyyaml (non-ImportError) is exit 2 WITH a named cause, not a generic internal error"
# This shape always exited 2 (the excepthook forced it), but all the operator got was
# "internal error: RuntimeError" plus a traceback — no mention of pyyaml, and no way to tell a broken
# parser from a bug in the gate. It is now classified before it can escape.
assert_rc "exit 2 (cannot evaluate), NOT 1" 2 with_broken_rt "$TC" "$led3"
assert_output "names the REAL exception type" "RuntimeError" with_broken_rt "$TC" "$led3"
assert_output "and its message" "simulated broken pyyaml install" with_broken_rt "$TC" "$led3"
assert_output "attributes it to pyyaml rather than to the gate" "pyyaml IS installed" \
  with_broken_rt "$TC" "$led3"
assert_not_output "classified, so it never reaches the generic excepthook" "internal error" \
  with_broken_rt "$TC" "$led3"
assert_not_output "and no raw traceback is needed to diagnose it" "Traceback" with_broken_rt "$TC" "$led3"
assert_not_output "never a PASS" "TRACEABILITY: PASS" with_broken_rt "$TC" "$led3"
assert_not_output "never a coverage FAIL either" "TRACEABILITY: FAIL" with_broken_rt "$TC" "$led3"

t_case "a module-level sys.exit inside pyyaml cannot set this gate's exit code — exit 2, never 0"
# SystemExit is not an Exception and does NOT pass through sys.excepthook, so this shape reached
# neither the old `except ImportError` nor the crash hook: the gate exited 0, silently, having read no
# criteria at all. firm-check-assertions' traceability_passes reads 0 as "coverage is acceptable".
assert_rc "exit 2, NOT the 0 the broken module tried to exit with" 2 with_broken_sysexit "$TC" "$led3"
assert_output "says CANNOT VERIFY" "CANNOT VERIFY" with_broken_sysexit "$TC" "$led3"
assert_output "names SystemExit rather than hiding it" "SystemExit" with_broken_sysexit "$TC" "$led3"
assert_not_output "never a PASS" "TRACEABILITY: PASS" with_broken_sysexit "$TC" "$led3"
assert_not_output "and evaluated no coverage" "verdict coverage entries" with_broken_sysexit "$TC" "$led3"

t_case "an INCONCLUSIVE probe is cannot-evaluate too — 'I could not tell' is not 'not installed'"
# The third branch of the discriminator, and the one a careless implementation leaves as a fall-through
# to the fallback. If find_spec() ITSELF raises (a broken import hook, a poisoned sys.modules entry, a
# corrupt parent package) the gate knows only that it has no parser and no diagnosis. Guessing "absent"
# there downgrades the reader on no evidence, which is the fail-open being closed.
#
# Stated rather than overclaimed: what these assertions pin is that the branch EXISTS — delete it and
# the gate falls through to the fallback and PASSes this ledger. Its POSITION (before the spec branch,
# as in bin/firm-check-assertions) is defence in depth that they cannot distinguish: a raising probe
# leaves yaml_spec None, so with both branches present either order refuses the run. The order matters
# only against a future edit that stops the spec branch exiting.
BROKEN_HOOK="$(mktemp -d "${TMPDIR:-/tmp}/firm-tc-badyaml-hook.XXXXXX")"; t_track "$BROKEN_HOOK"
cat > "$BROKEN_HOOK/sitecustomize.py" <<'PYSC'
import sys


class _ExplodingFinder:
    """Blows up when ANYTHING asks the import system about yaml, so `import yaml` and
    importlib.util.find_spec("yaml") BOTH raise: the state where absent and broken are
    indistinguishable."""

    @classmethod
    def find_spec(cls, fullname, path=None, target=None):
        if fullname == "yaml" or fullname.startswith("yaml."):
            raise RuntimeError("simulated broken import hook")
        return None


sys.meta_path.insert(0, _ExplodingFinder)
PYSC
with_broken_hook() { ( PYTHONPATH="$BROKEN_HOOK${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }
assert_ok "precondition: BOTH the import and the find_spec probe raise (that is what makes it inconclusive)" \
  with_broken_hook python3 -c '
import importlib.util
raised = []
try:
    importlib.util.find_spec("yaml")
except RuntimeError:
    raised.append("probe")
try:
    import yaml
except RuntimeError:
    raised.append("import")
except ImportError:
    pass
assert raised == ["probe", "import"], "expected both to raise, got %r" % (raised,)'
assert_rc "exit 2, NOT the 0 a guessed fallback produces" 2 with_broken_hook "$TC" "$led3"
assert_output "says so in the operator's words" "cannot tell whether pyyaml is absent or broken" \
  with_broken_hook "$TC" "$led3"
assert_output "names what the probe itself did" "find_spec('yaml') itself raised" \
  with_broken_hook "$TC" "$led3"
# Deliberately anchored to the import clause. A bare "RuntimeError" needle would also match the
# probe's half of the same sentence, so it would not actually prove BOTH halves are reported.
assert_output "and what the import did, separately from the probe" '`import yaml` raised RuntimeError' \
  with_broken_hook "$TC" "$led3"
assert_not_output "did NOT guess 'absent' and downgrade" "TRACEABILITY: PASS" with_broken_hook "$TC" "$led3"
assert_not_output "and evaluated no coverage" "verdict coverage entries" with_broken_hook "$TC" "$led3"

t_case "a broken install's exception text cannot crash the report out of exit 2 (ASCII stdout locale)"
# The exception message is DATA from a third-party package: it can be multi-line and non-ASCII. If
# emitting it raised UnicodeEncodeError the gate would exit 1 — a coverage verdict — which is the
# original fail-open of this file, one door along. Both axes vary: the locale AND the message's bytes.
# The UTF-8 control reuses $UTF8_LOCALE_NAME, probed once further up, so it is never skipped.
BROKEN_NA="$(mktemp -d "${TMPDIR:-/tmp}/firm-tc-badyaml-na.XXXXXX")"; t_track "$BROKEN_NA"
printf 'raise RuntimeError("caf\xc3\xa9 \xe2\x80\x94 corrupt install\\nsecond line")\n' > "$BROKEN_NA/yaml.py"
na_ascii() { ( PYTHONPATH="$BROKEN_NA${PYTHONPATH:+:$PYTHONPATH}" \
               LC_ALL=C LANG=C LC_CTYPE=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0 "$@" ); }
if [ -n "$UTF8_LOCALE_NAME" ]; then
  na_utf8() { ( PYTHONPATH="$BROKEN_NA${PYTHONPATH:+:$PYTHONPATH}" \
                LC_ALL="$UTF8_LOCALE_NAME" LANG="$UTF8_LOCALE_NAME" LC_CTYPE="$UTF8_LOCALE_NAME" \
                PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 "$@" ); }
else
  na_utf8() { ( PYTHONPATH="$BROKEN_NA${PYTHONPATH:+:$PYTHONPATH}" \
                LC_ALL=C LANG=C LC_CTYPE=C PYTHONUTF8=1 "$@" ); }
fi
_na_enc_probe='import sys; print((sys.stdout.encoding or "?").lower())'
na_enc_ascii="$(na_ascii python3 -c "$_na_enc_probe")"
na_enc_utf8="$(na_utf8  python3 -c "$_na_enc_probe")"
assert_ne "precondition: the two locale helpers give python3 DIFFERENT stdout encodings (else this axis is decorative)" \
  "$na_enc_ascii" "$na_enc_utf8"
assert_ok "precondition: the ascii helper's stdout genuinely cannot hold non-ASCII (got '$na_enc_ascii')" \
  python3 -c 'import sys; sys.exit(0 if "utf" not in sys.argv[1] else 1)' "$na_enc_ascii"
assert_ok "precondition: the double's message really is non-ASCII and multi-line" python3 -c '
import sys
raw = open(sys.argv[1], "rb").read()
assert any(b > 127 for b in raw), "message is pure ASCII -- wrong axis"
assert b"\\n" in raw, "message is single-line -- wrong axis"' "$BROKEN_NA/yaml.py"
for _nafn in na_ascii na_utf8; do
  assert_rc "exit 2 with a non-ASCII, multi-line exception message [$_nafn]" 2 $_nafn "$TC" "$led3"
  assert_output "still says CANNOT VERIFY [$_nafn]" "CANNOT VERIFY" $_nafn "$TC" "$led3"
  assert_output "and still names the exception type [$_nafn]" "RuntimeError" $_nafn "$TC" "$led3"
  assert_output "the message is collapsed onto ONE line [$_nafn]" "corrupt install second line" \
    $_nafn "$TC" "$led3"
  assert_not_output "no encoding crash escaped [$_nafn]" "UnicodeEncodeError" $_nafn "$TC" "$led3"
  assert_not_output "never a PASS [$_nafn]" "TRACEABILITY: PASS" $_nafn "$TC" "$led3"
  # The OTHER half of what the one-line/ASCII helper claims. Collapsing alone would leave the raw
  # UTF-8 bytes in the report wherever the locale happened to permit them, so the two halves are
  # asserted separately: this one is a statement about the REPORT's bytes, not about surviving.
  _na_out="$($_nafn "$TC" "$led3" 2>&1)"
  assert_ok "the report itself stays pure ASCII, in a file whose ASCII purity is load-bearing [$_nafn]" \
    python3 -c '
import sys
bad = [c for c in sys.argv[1] if ord(c) > 127]
if bad:
    print("non-ASCII in the report: %r" % (bad[:8],))
    sys.exit(1)' "$_na_out"
done

t_case "absent / working / broken are THREE outcomes for the SAME ledger, not two"
# Without this, "broken fails" could be satisfied by a script broken into always failing, and "absence
# still degrades" by one that never chooses the fallback.
without_yaml        "$TC" "$led3" >/dev/null 2>&1; rc_ps_absent=$?
with_yaml_parser    "$TC" "$led3" >/dev/null 2>&1; rc_ps_working=$?
with_broken_partial "$TC" "$led3" >/dev/null 2>&1; rc_ps_broken=$?
with_broken_hook    "$TC" "$led3" >/dev/null 2>&1; rc_ps_unknown=$?
assert_eq "pyyaml ABSENT  -> 0 (the fallback legitimately evaluated coverage)" "0" "$rc_ps_absent"
assert_eq "pyyaml WORKING -> 0 (pyyaml evaluated coverage)"                    "0" "$rc_ps_working"
assert_eq "pyyaml BROKEN  -> 2 (nothing could be evaluated)"                   "2" "$rc_ps_broken"
assert_eq "pyyaml UNKNOWN -> 2 (nothing could be evaluated)"                   "2" "$rc_ps_unknown"
assert_ne "a broken install is NOT reported as a passing run" "$rc_ps_working" "$rc_ps_broken"
assert_ne "and NOT as a coverage failure"                     "1"              "$rc_ps_broken"

t_case "the fix did not widen exit 2: the three-code contract holds under EVERY usable parser state"
# Guards the mutation "make everything cannot-evaluate". `traceability_passes: false` in a golden eval
# needs exit 1 to remain reachable, so 0/1/2 must stay distinct on both sides of the parser split.
for _pfn in without_yaml with_yaml_parser; do
  assert_rc "fully covered -> 0 [$_pfn]"                            0 $_pfn "$TC" "$led3"
  assert_rc "an uncovered criterion -> 1 [$_pfn]"                   1 $_pfn "$TC" "$led4"
  assert_rc "covered=partial with no justification -> 1 [$_pfn]"    1 $_pfn "$TC" "$led13"
  assert_rc "a coverage value outside the enum -> 2 [$_pfn]"        2 $_pfn "$TC" "$led17"
  assert_output "and the exit-1 case is reported as a FAIL [$_pfn]" "TRACEABILITY: FAIL" $_pfn "$TC" "$led4"
done

t_case "regression: the partial/waiver semantics are unchanged on the genuine-absence path, ASCII locale included"
# Three axes at once, all varied: the parser state (genuine absence, via the NEW helper), the coverage
# value (justified partial / every-criterion partial / justified waiver / all yes) and the stdout
# locale. The old stub-file helper made this same set of assertions describe the BROKEN path instead —
# which is why the helper had to change with the fix rather than after it.
noyaml_ascii() { ( PYTHONPATH="$NOYAML${PYTHONPATH:+:$PYTHONPATH}" \
                   LC_ALL=C LANG=C LC_CTYPE=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0 "$@" ); }
assert_ok "precondition: the absence helper still hides pyyaml under an ASCII locale too" \
  noyaml_ascii python3 -c '
import importlib.util
assert importlib.util.find_spec("yaml") is None, "yaml became findable under the ASCII locale"'
for _nyfn in without_yaml noyaml_ascii; do
  assert_rc "justified partial -> exit 0 [$_nyfn]" 0 $_nyfn "$TC" "$led11"
  assert_output "justified partial -> INCOMPLETE headline [$_nyfn]" \
    "TRACEABILITY: INCOMPLETE" $_nyfn "$TC" "$led11"
  assert_not_output "justified partial -> never the substring TRACEABILITY: PASS [$_nyfn]" \
    "TRACEABILITY: PASS" $_nyfn "$TC" "$led11"
  assert_output "justified partial -> counts truthfully [$_nyfn]" \
    "1/2 criteria fully covered" $_nyfn "$TC" "$led11"
  assert_rc "EVERY criterion partial -> exit 0, still not a PASS [$_nyfn]" 0 $_nyfn "$TC" "$led12"
  assert_not_output "EVERY criterion partial -> no PASS headline [$_nyfn]" \
    "TRACEABILITY: PASS" $_nyfn "$TC" "$led12"
  assert_rc "partial with NO justification -> exit 1 [$_nyfn]" 1 $_nyfn "$TC" "$led13"
  assert_output "partial with NO justification -> names why [$_nyfn]" \
    "covered=partial with no justification" $_nyfn "$TC" "$led13"
  assert_rc "justified waiver -> exit 0 [$_nyfn]" 0 $_nyfn "$TC" "$led16"
  assert_output "justified waiver -> shown as a gap [$_nyfn]" \
    "AC-002: NOT COVERED (waived)" $_nyfn "$TC" "$led16"
  assert_not_output "justified waiver -> never the substring TRACEABILITY: PASS [$_nyfn]" \
    "TRACEABILITY: PASS" $_nyfn "$TC" "$led16"
  assert_rc "all yes -> exit 0 [$_nyfn]" 0 $_nyfn "$TC" "$led20"
  assert_output "all yes -> PASS headline [$_nyfn]" "TRACEABILITY: PASS" $_nyfn "$TC" "$led20"
  assert_not_output "no encoding crash on any of them [$_nyfn]" "UnicodeEncodeError" $_nyfn "$TC" "$led11"
done

t_case "regression: the fallback's SHAPE check still refuses what the real parser refuses"
# SEC-R13 again, re-driven through the new absence helper: the shape check is the reason the degraded
# path cannot be laundered into a looser gate, so it must survive the helper swap. led30 is top-level
# LIST-shaped, led32 nests criteria under another key, led31/led33 are the correctly-shaped controls.
assert_rc "LIST-shaped criteria file -> exit 2" 2 without_yaml "$TC" "$led30"
assert_output "and names the missing top-level key" "no top-level" without_yaml "$TC" "$led30"
assert_rc "criteria nested under another key -> exit 2" 2 without_yaml "$TC" "$led32"
assert_rc "control: a correctly-shaped mapping still PASSes" 0 without_yaml "$TC" "$led31"
assert_rc "control: a uniformly indented mapping still PASSes" 0 without_yaml "$TC" "$led33"

t_case "the script is STILL pure ASCII after the fix (the new messages included)"
# The broken-install and inconclusive reports are new literals in a file whose ASCII purity is a
# load-bearing property, so the check above is re-run here against the same file rather than trusted.
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

# ---------------------------------------------------------------------------
# THE RECIPROCAL DIRECTION: coverage -> criteria.
#
# The gate checked that every CRITERION appears in the coverage. It never checked that every COVERAGE
# ENTRY names a criterion that exists, so a verdict claiming coverage for AC-999-DOES-NOT-EXIST PASSED
# — while PRINTING the discrepancy it ignored (`acceptance criteria: 2  verdict coverage entries: 4`).
# A verdict written against a DIFFERENT criteria set satisfied the acceptance-coverage gate as long as
# it also happened to name the real ids, so the gate could not tell "this verdict describes this run"
# from "this verdict describes some other run".
#
# Classified as CANNOT EVALUATE (exit 2), not as a coverage FAILURE (exit 1): a phantom id is a fact
# about the verdict's PROVENANCE, not about coverage, and once provenance is broken the entries whose
# ids DO match are untrustworthy too (an id is only a label). The full argument, degree included, is in
# bin/firm-traceability-check's header. Exit 2 is also the only classification that fails closed for
# BOTH caller polarities — firm-check-assertions rejects anything outside {0,1} for
# `traceability_passes: true` AND `false` — so a mismatched verdict can prove nothing in either
# direction.
t_case "phantom coverage: a verdict claiming coverage for ids NO criterion declares does not pass"
led40="$d/led40"
mk_ledger "$led40" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "e1"},
    {"id": "AC-002", "covered": "yes", "evidence": "e2"},
    {"id": "AC-999-DOES-NOT-EXIST", "covered": "yes", "evidence": "phantom"},
    {"id": "TOTALLY-MADE-UP", "covered": "yes", "evidence": "phantom"}
  ]}'
assert_rc "exit 2 (CANNOT EVALUATE) -- it used to exit 0 with every real criterion 'covered'" 2 "$TC" "$led40"
assert_not_output "never the substring TRACEABILITY: PASS" "TRACEABILITY: PASS" "$TC" "$led40"
assert_output "says CANNOT VERIFY" "TRACEABILITY: CANNOT VERIFY" "$TC" "$led40"
assert_output "names the first offending id" "AC-999-DOES-NOT-EXIST" "$TC" "$led40"
assert_output "names the second offending id" "TOTALLY-MADE-UP" "$TC" "$led40"
assert_output "says what is wrong with it" "NO criterion declares this id" "$TC" "$led40"
assert_output "and quotes the phantom entry's coverage claim, so the report is self-contained" \
  "(covered='yes')" "$TC" "$led40"
assert_output "explains that the verdict describes some other criteria set" \
  "this verdict does not describe THIS run's acceptance criteria" "$TC" "$led40"
assert_output "and why that is cannot-evaluate rather than a coverage failure" \
  "Not a coverage FAILURE (exit 1)" "$TC" "$led40"
assert_output "lists the ids that ARE declared, so reconciling is possible from the output alone" \
  "AC-001, AC-002" "$TC" "$led40"
assert_not_output "and is NOT reported as a criterion-level coverage FAIL" "TRACEABILITY: FAIL" "$TC" "$led40"
# The 2-vs-4 line already existed and was acted on by NOTHING — a printed fact nobody uses is not a
# check. It now carries the conclusion, in both directions.
assert_output "the criteria-vs-coverage counts now state a conclusion instead of leaving the arithmetic to the reader" \
  "acceptance criteria: 2  verdict coverage entries: 4  -- MISMATCH" "$TC" "$led40"
assert_output "the conclusion names the previously-ignored direction and the count" \
  "MISMATCH: 2 of these entries name NO criterion" "$TC" "$led40"
assert_output "the coverage summary counts phantoms separately from problems and unverifiables" \
  "0 problem(s) | 0 unverifiable | 2 phantom" "$TC" "$led40"

t_case "phantom coverage: the DEGENERATE case -- zero overlap between the two id sets"
# Deliberate behaviour CHANGE: this used to exit 1 ("every criterion is missing from coverage"). With
# non-empty coverage naming nothing this run declares, "this is not my verdict" explains the state far
# better than "I am uncovered" does, and calling it a coverage verdict would let an eval PROVE the gate
# "correctly fails" on a ledger whose coverage was never evaluated at all.
led41="$d/led41"
mk_ledger "$led41" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "XX-1", "covered": "yes", "evidence": "e"},
    {"id": "XX-2", "covered": "yes", "evidence": "e"}
  ]}'
"$TC" "$led41" >/dev/null 2>&1; rc_zero_overlap=$?
assert_eq "zero overlap -> exit 2 (CANNOT EVALUATE)" "2" "$rc_zero_overlap"
assert_ne "and NOT exit 1 -- it is not a coverage verdict of any kind" "1" "$rc_zero_overlap"
assert_ne "and NOT exit 0" "0" "$rc_zero_overlap"
assert_output "names the first phantom id" "'XX-1'" "$TC" "$led41"
assert_output "names the second phantom id" "'XX-2'" "$TC" "$led41"
assert_not_output "never the substring TRACEABILITY: PASS" "TRACEABILITY: PASS" "$TC" "$led41"
assert_output "the criterion-level findings are still printed, not swallowed by the reclassification" \
  "AC-001: NOT in verdict coverage" "$TC" "$led41"
assert_output "...and are explicitly subordinated to the cannot-evaluate finding" \
  "criterion-level coverage failures were found as well" "$TC" "$led41"
assert_output "the counts line flags the reciprocal direction" \
  "MISMATCH: 2 of these entries name NO criterion" "$TC" "$led41"
assert_output "and the report states the mismatch from the other side too, which is what makes it diagnosable" \
  "2 of this run's 2 criteria have no coverage entry at all" "$TC" "$led41"
assert_output "...naming the total non-overlap explicitly, since that is the crispest form of the finding" \
  "the two id sets do not overlap AT ALL" "$TC" "$led41"
assert_not_output "and 'no overlap AT ALL' is NOT claimed when there is partial overlap" \
  "do not overlap AT ALL" "$TC" "$led40"

t_case "an EMPTY coverage list is untouched: still an evaluated coverage FAILURE (exit 1), not cannot-evaluate"
# The boundary of the change. A verdict that names nothing holds no phantom ids, and "coverage is zero"
# is a question this gate CAN answer — so widening exit 2 to cover it would have made the commonest
# real state (two of this repo's own ledgers) unevaluable and `traceability_passes: false` harder to
# satisfy honestly.
led42="$d/led42"
mk_ledger "$led42" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": []}'
assert_rc "empty coverage -> exit 1" 1 "$TC" "$led42"
assert_output "reported as a FAIL, with the reason" "AC-001: NOT in verdict coverage" "$TC" "$led42"
assert_output "and as a FAIL headline" "TRACEABILITY: FAIL" "$TC" "$led42"
assert_output "with 0 phantoms" "0 unverifiable | 0 phantom" "$TC" "$led42"
assert_not_output "never the substring TRACEABILITY: PASS" "TRACEABILITY: PASS" "$TC" "$led42"
assert_not_output "and no MISMATCH clause: 2-vs-0 is fully explained by the itemised report below" \
  "MISMATCH" "$TC" "$led42"

t_case "regression: a verdict whose coverage matches the criteria EXACTLY still exits 0"
led43="$d/led43"
mk_ledger "$led43" \
  'criteria:
  - id: AC-001
  - id: AC-002
  - id: AC-003' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "e1"},
    {"id": "AC-002", "covered": "yes", "evidence": "e2"},
    {"id": "AC-003", "covered": "yes", "evidence": "e3"}
  ]}'
assert_rc "exact reconciliation -> exit 0" 0 "$TC" "$led43"
assert_output "and PASSes" "TRACEABILITY: PASS -- all 3 criteria marked fully covered" "$TC" "$led43"
assert_output "the counts line reports the two numbers, which now agree" \
  "acceptance criteria: 3  verdict coverage entries: 3" "$TC" "$led43"
assert_not_output "and carries no MISMATCH clause, because there is no mismatch" "MISMATCH" "$TC" "$led43"
assert_output "the phantom counter reports zero, so the reciprocal check is visibly running" \
  "0 unverifiable | 0 phantom" "$TC" "$led43"
assert_not_output "no phantom is invented out of a well-formed verdict" "NO criterion declares this id" "$TC" "$led43"
assert_rc "and the pre-existing all-yes fixture is unaffected too" 0 "$TC" "$led20"
assert_not_output "...also with no MISMATCH clause" "MISMATCH" "$TC" "$led20"

t_case "PINNED pre-existing behaviour: duplicate coverage entries for the SAME declared id"
# Not this work-order's subject and NOT changed here: a repeated id overwrites, so the LAST entry for
# an id decides that criterion. Pinned in both orders so a later change cannot alter it silently, and
# so the reciprocal check above is provably not what decides these cases. The only thing that changed
# is that the collapse is now VISIBLE (a note), because it is the sole remaining reason the reported
# entry count can differ from the number of entries in the file.
led44="$d/led44"        # identical duplicates
mk_ledger "$led44" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "e"},
    {"id": "AC-001", "covered": "yes", "evidence": "e"},
    {"id": "AC-002", "covered": "yes", "evidence": "e"}
  ]}'
assert_rc "identical duplicates -> exit 0 (unchanged)" 0 "$TC" "$led44"
assert_output "still PASSes" "TRACEABILITY: PASS" "$TC" "$led44"
assert_not_output "a duplicate of a DECLARED id is not a phantom" "NO criterion declares this id" "$TC" "$led44"
assert_output "the reported entry count is of DISTINCT ids (3 entries in the file, 2 ids)" \
  "verdict coverage entries: 2" "$TC" "$led44"
assert_output "...and the collapse is now stated instead of being an unexplained gap" \
  "coverage id(s) appear MORE THAN ONCE" "$TC" "$led44"
assert_output "the note names which id collapsed, and which of its entries wins" \
  "(earlier ones are discarded): AC-001" "$TC" "$led44"
assert_not_output "and no MISMATCH is claimed: a collapsed duplicate is not a criteria-set mismatch" \
  "MISMATCH" "$TC" "$led44"

led45="$d/led45"        # yes THEN an unjustified no -> the LAST entry decides
mk_ledger "$led45" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "e"},
    {"id": "AC-001", "covered": "no"},
    {"id": "AC-002", "covered": "yes", "evidence": "e"}
  ]}'
led46="$d/led46"        # the same two entries, ORDER SWAPPED
mk_ledger "$led46" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "no"},
    {"id": "AC-001", "covered": "yes", "evidence": "e"},
    {"id": "AC-002", "covered": "yes", "evidence": "e"}
  ]}'
"$TC" "$led45" >/dev/null 2>&1; rc_dup_last_no=$?
"$TC" "$led46" >/dev/null 2>&1; rc_dup_last_yes=$?
assert_eq "conflicting duplicates, unjustified 'no' LAST -> exit 1 (pinned)"  "1" "$rc_dup_last_no"
assert_eq "conflicting duplicates, 'yes' LAST -> exit 0 (pinned, NOT endorsed)" "0" "$rc_dup_last_yes"
assert_ne "the two orders are therefore NOT equivalent: order decides the verdict" \
  "$rc_dup_last_no" "$rc_dup_last_yes"
assert_output "and in BOTH orders the collapse is at least visible now [last=no]" \
  "appear MORE THAN ONCE" "$TC" "$led45"
assert_output "and in BOTH orders the collapse is at least visible now [last=yes]" \
  "appear MORE THAN ONCE" "$TC" "$led46"

t_case "an id TYPO is now diagnosable, because the mismatch is reported in both directions at once"
# The everyday shape of this defect: not a fabricated criterion, a mistyped one. Before, the operator
# was told only "AC-002 is not in the coverage" and had to spot the near-identical typo unaided; the
# near-miss entry itself was invisible. Case is significant here and stays so — treating 'ac-002' as
# covering 'AC-002' would be a looser gate, not a better message.
led47="$d/led47"
mk_ledger "$led47" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "e"},
    {"id": "ac-002", "covered": "yes", "evidence": "e"}
  ]}'
assert_rc "a case-mismatched id -> exit 2" 2 "$TC" "$led47"
assert_output "half one: the criterion is reported as absent from coverage (unchanged)" \
  "AC-002: NOT in verdict coverage" "$TC" "$led47"
assert_output "half two: the near-miss entry is now reported too (this is the new half)" \
  "'ac-002'" "$TC" "$led47"
assert_not_output "never the substring TRACEABILITY: PASS" "TRACEABILITY: PASS" "$TC" "$led47"

t_case "phantom AND an uninterpretable covered value together: exit 2, and BOTH are reported"
led48="$d/led48"
mk_ledger "$led48" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "mostly", "evidence": "e"},
    {"id": "AC-002", "covered": "yes", "evidence": "e"},
    {"id": "PHANTOM-1", "covered": "yes", "evidence": "e"}
  ]}'
assert_rc "exit 2" 2 "$TC" "$led48"
assert_output "the uninterpretable value is named" "is not one of yes/no/partial" "$TC" "$led48"
assert_output "the phantom id is named" "'PHANTOM-1'" "$TC" "$led48"
assert_output "and the two are counted separately" "1 unverifiable | 1 phantom" "$TC" "$led48"
assert_not_output "never the substring TRACEABILITY: PASS" "TRACEABILITY: PASS" "$TC" "$led48"

t_case "a phantom id takes precedence over a REAL coverage failure, which is still printed in full"
led49="$d/led49"
mk_ledger "$led49" \
  'criteria:
  - id: AC-001
  - id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "no"},
    {"id": "AC-002", "covered": "yes", "evidence": "e"},
    {"id": "PHANTOM-2", "covered": "yes", "evidence": "e"}
  ]}'
assert_rc "exit 2, not 1: an unjustified waiver in a verdict of unknown provenance decides nothing" \
  2 "$TC" "$led49"
assert_output "the real coverage failure is not discarded" "covered=no with no justification" "$TC" "$led49"
assert_output "it is subordinated, with the relationship spelled out" \
  "criterion-level coverage failures were found as well" "$TC" "$led49"
assert_output "and the phantom id is named as the reason the run has no verdict" "'PHANTOM-2'" "$TC" "$led49"

t_case "the reciprocal check is not parser-dependent: pyyaml-present and pyyaml-absent agree (both axes vary)"
# Two axes, both varied: the parser branch AND the ledger (phantom vs. exactly-reconciled). Without the
# control ledger, "both branches say 2" would also be satisfied by a branch that fails everything.
without_yaml     "$TC" "$led40" >/dev/null 2>&1; rc_ph_absent=$?
with_yaml_parser "$TC" "$led40" >/dev/null 2>&1; rc_ph_present=$?
without_yaml     "$TC" "$led43" >/dev/null 2>&1; rc_ok_absent=$?
with_yaml_parser "$TC" "$led43" >/dev/null 2>&1; rc_ok_present=$?
assert_eq "phantom, pyyaml ABSENT  -> 2" "2" "$rc_ph_absent"
assert_eq "phantom, pyyaml PRESENT -> 2" "2" "$rc_ph_present"
assert_eq "control: reconciled, pyyaml ABSENT  -> 0" "0" "$rc_ok_absent"
assert_eq "control: reconciled, pyyaml PRESENT -> 0" "0" "$rc_ok_present"
assert_output "and the offending id is named on the fallback path too" \
  "AC-999-DOES-NOT-EXIST" without_yaml "$TC" "$led40"

t_case "a BROKEN pyyaml still outranks the reciprocal check: no coverage is evaluated at all"
# Ordering matters. If the phantom check ran first it would report a criteria-set mismatch derived from
# an id list the gate never managed to parse — a diagnosis invented out of nothing.
assert_rc "broken install + phantom coverage -> exit 2" 2 with_broken_partial "$TC" "$led40"
assert_output "and the reason given is the BROKEN PARSER, not the coverage" \
  "pyyaml IS installed" with_broken_partial "$TC" "$led40"
assert_not_output "no coverage was evaluated" "verdict coverage entries" with_broken_partial "$TC" "$led40"
assert_not_output "so no phantom is claimed either" "NO criterion declares this id" \
  with_broken_partial "$TC" "$led40"

t_case "the regex fallback's top-level criteria: shape check still runs BEFORE the reciprocal check"
led50="$d/led50"
mk_ledger "$led50" \
  '- id: AC-001
- id: AC-002' \
  '{"acceptance_criteria_coverage": [
    {"id": "AC-001", "covered": "yes", "evidence": "e"},
    {"id": "PHANTOM-3", "covered": "yes", "evidence": "e"}
  ]}'
assert_rc "LIST-shaped criteria + phantom coverage -> exit 2" 2 without_yaml "$TC" "$led50"
assert_output "and the reason is the document SHAPE, which is the earlier and more fundamental one" \
  "no top-level" without_yaml "$TC" "$led50"
assert_not_output "the id list was never trusted, so no phantom is asserted from it" \
  "NO criterion declares this id" without_yaml "$TC" "$led50"

t_case "the three-code contract is not widened: 0, 1 and 2 all stay reachable on both parser branches"
# The mutation this guards is "make any mismatch cannot-evaluate", which would take exit 1 out of
# circulation and silently break every eval that inverts this gate with `traceability_passes: false`.
for _pfn in without_yaml with_yaml_parser; do
  assert_rc "exactly reconciled + all yes -> 0 [$_pfn]"                  0 $_pfn "$TC" "$led43"
  assert_rc "justified partial -> 0 [$_pfn]"                             0 $_pfn "$TC" "$led11"
  assert_rc "a criterion absent from a non-phantom verdict -> 1 [$_pfn]" 1 $_pfn "$TC" "$led4"
  assert_rc "empty coverage -> 1 [$_pfn]"                                1 $_pfn "$TC" "$led42"
  assert_rc "partial with no justification -> 1 [$_pfn]"                 1 $_pfn "$TC" "$led13"
  assert_rc "a covered value outside the enum -> 2 [$_pfn]"              2 $_pfn "$TC" "$led17"
  assert_rc "phantom coverage -> 2 [$_pfn]"                              2 $_pfn "$TC" "$led40"
  assert_output "and the exit-1 class is still reported as a FAIL [$_pfn]" \
    "TRACEABILITY: FAIL" $_pfn "$TC" "$led4"
done

t_case "every preserved property still holds on the fixtures the earlier waves built"
assert_rc "justified partial -> exit 0" 0 "$TC" "$led11"
assert_output "justified partial -> INCOMPLETE headline" "TRACEABILITY: INCOMPLETE" "$TC" "$led11"
assert_not_output "justified partial -> never the substring TRACEABILITY: PASS" \
  "TRACEABILITY: PASS" "$TC" "$led11"
assert_rc "EVERY criterion partial -> exit 0, still not a PASS" 0 "$TC" "$led12"
assert_not_output "EVERY criterion partial -> no PASS headline" "TRACEABILITY: PASS" "$TC" "$led12"
assert_rc "partial with NO justification -> exit 1" 1 "$TC" "$led13"
assert_rc "justified waiver -> exit 0" 0 "$TC" "$led16"
assert_output "justified waiver -> visible as a gap" "NOT COVERED (waived)" "$TC" "$led16"
assert_not_output "justified waiver -> never the substring TRACEABILITY: PASS" \
  "TRACEABILITY: PASS" "$TC" "$led16"
assert_rc "zero acceptance criteria -> exit 2" 2 "$TC" "$led22"
assert_rc "an unreadable (non-UTF-8) ledger -> exit 2" 2 "$TC" "$led34"

t_case "the reciprocal check survives an ASCII stdout locale, and non-ASCII bytes in the offending id"
# Both axes vary: the stdout encoding AND the id's bytes. The new report interpolates DATA (ids the
# gate does not control) into a message emitted BEFORE the exit, so an encoding crash there would exit
# 1 — a coverage verdict — which is this file's original fail-open one door along.
led51="$d/led51"
mkdir -p "$led51"
printf '%s\n' 'criteria:' '  - id: AC-001' > "$led51/01-acceptance-criteria.yaml"
printf '{"acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"e"},{"id":"AC-caf\xc3\xa9-\xe2\x80\x94-002","covered":"yes","evidence":"e"}]}' \
  > "$led51/08-qa-verdict.json"
assert_ok "precondition: the phantom id really does carry non-ASCII bytes" python3 -c '
import sys
raw = open(sys.argv[1], "rb").read()
assert any(b > 127 for b in raw), "the verdict is pure ASCII -- this axis would be decorative"' \
  "$led51/08-qa-verdict.json"
for _lfn in ascii_locale utf8_locale; do
  assert_rc "phantom coverage -> exit 2 [$_lfn]" 2 $_lfn "$TC" "$led40"
  assert_output "names the offending id [$_lfn]" "AC-999-DOES-NOT-EXIST" $_lfn "$TC" "$led40"
  assert_not_output "never the substring TRACEABILITY: PASS [$_lfn]" "TRACEABILITY: PASS" \
    $_lfn "$TC" "$led40"
  assert_rc "a NON-ASCII phantom id is also exit 2, not an encoding crash [$_lfn]" 2 $_lfn "$TC" "$led51"
  assert_output "and still says CANNOT VERIFY [$_lfn]" "TRACEABILITY: CANNOT VERIFY" $_lfn "$TC" "$led51"
  assert_not_output "no encoding crash escaped [$_lfn]" "UnicodeEncodeError" $_lfn "$TC" "$led51"
  assert_rc "control: a reconciled ledger is still 0 under the same locale [$_lfn]" 0 $_lfn "$TC" "$led43"
done
# Only asserted for the ASCII stream, which is where backslashreplace guarantees it. Under a UTF-8
# locale the id's own bytes legitimately reach the report, exactly as evidence strings and paths
# already do.
_ph_ascii_out="$(ascii_locale "$TC" "$led51" 2>&1)"
assert_ok "under an ASCII stdout locale the report itself stays pure ASCII" python3 -c '
import sys
bad = [c for c in sys.argv[1] if ord(c) > 127]
if bad:
    print("non-ASCII in the report: %r" % (bad[:8],))
    sys.exit(1)' "$_ph_ascii_out"

t_case "the new output still fits the 240-character detail window its caller collapses it into"
# This is WHY the counts line is annotated only for the reciprocal direction, and it is measured, not
# asserted from taste. bin/firm-check-assertions renders this script's whole output as one 240-character
# detail line; an exit-1 run had 38 characters of headroom, and any unconditional reconciliation clause
# (27 characters at the shortest) pushed the uncovered criterion's NAME out of the window. That would
# have been a silent diagnostic regression -- the eval would still fail, just without saying which
# criterion -- so it is pinned here, on this side of the boundary, rather than only in the caller's
# suite where it surfaced.
collapsed_detail() {
  # Exactly what firm-check-assertions does to the child's output: collapse all whitespace, cut at 240.
  "$@" 2>&1 | python3 -c 'import sys
print(" ".join(sys.stdin.read().split())[:240])'
}
assert_output "the uncovered criterion's id survives the collapse (led4: AC-002 is the missing one)" \
  "AC-002: NOT in verdict coverage" collapsed_detail "$TC" "$led4"
assert_output "so does the FAIL headline that classifies it" "TRACEABILITY: FAIL" collapsed_detail "$TC" "$led4"
assert_output "and on the empty-coverage ledger, the first uncovered criterion survives too" \
  "AC-001: NOT in verdict coverage" collapsed_detail "$TC" "$led42"
assert_output "the phantom finding leads the window on a phantom ledger, where it is the finding" \
  "MISMATCH: 2 of these entries name NO criterion" collapsed_detail "$TC" "$led40"

t_case "the script is STILL pure ASCII with the reciprocal-check messages added"
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

t_summary
