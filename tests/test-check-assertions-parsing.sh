#!/usr/bin/env bash
# tests/test-check-assertions-parsing.sh — how firm-check-assertions READS assertions.yaml.
#
# Separate file from tests/test-check-assertions.sh (which covers the assertion VOCABULARY) because
# everything here is about the parse stage and its two fail-open holes:
#
#   1. an EMPTY / prose-only / parses-to-nothing file printed "0/0 assertions passed" and exited 0,
#      so an eval whose checks never ran reported green;
#   2. one bare `except Exception` around `import yaml` + `yaml.safe_load` conflated "pyyaml is not
#      installed" with "this YAML is broken", then fell back to a line parser that SILENTLY DROPPED
#      every list item it could not match.
#
# Both parse paths are pinned here, on any host, via PYTHONPATH — the same technique
# tests/test-traceability-check.sh and tests/test-validate-verdict.sh:52-57 already use:
#   without_yaml       a `yaml.py` that raises ImportError -> forces the regex fallback
#   with_yaml_parser   the REAL pyyaml wherever the host has one (CI pins pyyaml==6.0.3), and only
#                      otherwise tests/fixtures/stub-yaml/yaml.py, a subset double
# That preference is the point, and it is new. The double used to be PREPENDED to PYTHONPATH
# unconditionally, so it SHADOWED a real pyyaml everywhere one existed — CI included — and the
# genuine exact-parser path was therefore exercised on no machine anywhere. The double is a
# last-resort stand-in for "a YAML parser is present", not a replacement for the parser, and the two
# do measurably disagree (see the double's own docstring for the list). Every case also asserts WHICH
# path ran (the script prints `via pyyaml` / `via regex fallback`), so none of these can pass by
# silently taking the other branch.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CA="$BIN/firm-check-assertions"

W="$(mktemp -d "${TMPDIR:-/tmp}/firm-ca-parse.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $W"
repo="$(mk_repo)"          # has seed.txt, no nope.txt

# ---- the two parser doubles ------------------------------------------------
NOYAML="$W/noyaml"; mkdir -p "$NOYAML"
printf 'raise ImportError("hidden to exercise the regex fallback")\n' > "$NOYAML/yaml.py"
without_yaml() { ( PYTHONPATH="$NOYAML${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

STUBYAML="$TESTS_DIR/fixtures/stub-yaml"   # see that file: a minimal YAML-subset double, not pyyaml
# The probe runs with NO override, so it reports what the host genuinely has.
if python3 -c 'import yaml' >/dev/null 2>&1; then
  YAML_KIND=real
  with_yaml_parser() { ( "$@" ); }
else
  YAML_KIND=stub
  with_yaml_parser() { ( PYTHONPATH="$STUBYAML${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }
fi
# Always the double, regardless of the host — used ONLY by the block at the bottom that pins the
# double's own behaviour. Nothing that tests firm-check-assertions should reach for this.
with_stub_yaml_forced() { ( PYTHONPATH="$STUBYAML${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }
printf '    (parser-present branch runs against: %s)\n' "$YAML_KIND"

af() { printf '%s' "$2" > "$W/$1.yaml"; printf '%s' "$W/$1.yaml"; }

# ---------------------------------------------------------------------------
t_case "preconditions: both parser branches really do what the cases below assume"
assert_fail "without_yaml: importing yaml raises" without_yaml python3 -c "import yaml"
assert_ok   "with_yaml_parser: importing yaml succeeds and exposes a working safe_load" \
  with_yaml_parser python3 -c "import yaml; assert yaml.safe_load('a: 1') == {'a': 1}"
# The regression guard for the shadowing itself. On a host WITH pyyaml this fails against the old
# unconditional-prepend helper: the probe above says `real`, but the import would still resolve to
# the double. On a host WITHOUT pyyaml it confirms the fallback is what got imported. Either way the
# helper is held to what the host actually has, rather than to what the harness hoped for.
assert_ok   "with_yaml_parser resolves to the REAL pyyaml where the host has one, and to the local double ONLY where it does not" \
  with_yaml_parser python3 -c '
import os, sys, yaml
stub_dir = os.path.realpath(sys.argv[1]) + os.sep
imported_the_stub = os.path.realpath(yaml.__file__).startswith(stub_dir)
want_the_stub = sys.argv[2] == "stub"
assert imported_the_stub == want_the_stub, \
    "host has a %s parser but `import yaml` resolved to %s" % (sys.argv[2], yaml.__file__)
' "$STUBYAML" "$YAML_KIND"

# ===========================================================================
# pyyaml ABSENT — the regex fallback. This is the LIVE path on any host without pyyaml.
# ===========================================================================
good="$(af good 'assertions:
  - file_exists: seed.txt
  - file_absent: nope.txt')"

t_case "fallback: a well-formed file still passes, and says which parser ran"
assert_rc "PASS" 0 without_yaml "$CA" "$good" "$repo"
assert_output "names the fallback (so no case here can pass on the wrong branch)" \
  "via regex fallback" without_yaml "$CA" "$good" "$repo"

t_case "fallback: EMPTY assertions.yaml is a FAILURE, not '0/0 passed, exit 0'"
empty="$(af empty '')"
assert_rc "exit 2, never 0" 2 without_yaml "$CA" "$empty" "$repo"
assert_output "says it could not evaluate" "CANNOT EVALUATE" without_yaml "$CA" "$empty" "$repo"
assert_output "names the reason: nothing was checked" "0 assertions parsed" without_yaml "$CA" "$empty" "$repo"

t_case "fallback: a prose-only file is a FAILURE"
prose="$(af prose 'This file is documentation. There are no assertions in it at all.
Someone deleted the assertions block and left the prose behind.')"
assert_rc "exit 2, never 0" 2 without_yaml "$CA" "$prose" "$repo"
assert_output "says it could not evaluate" "CANNOT EVALUATE" without_yaml "$CA" "$prose" "$repo"

t_case "fallback: comments/whitespace only is a FAILURE"
cmt="$(af comments '# assertions:
#   - file_exists: seed.txt

')"
assert_rc "exit 2" 2 without_yaml "$CA" "$cmt" "$repo"

t_case "fallback: an 'assertions:' key with an EMPTY list is a FAILURE"
emptylist="$(af emptylist 'name: x
assertions:
other: y')"
assert_rc "exit 2" 2 without_yaml "$CA" "$emptylist" "$repo"
assert_output "0 parsed" "0 assertions parsed" without_yaml "$CA" "$emptylist" "$repo"

t_case "fallback: a list item it cannot parse is REPORTED and FAILS — never silently dropped"
dropped="$(af dropped 'assertions:
  - file_exists: seed.txt
  - just a bare string with no key
  - "quoted_key": nope.txt')"
assert_rc "exit 2 (the passing sibling does not carry the file)" 2 without_yaml "$CA" "$dropped" "$repo"
assert_output "counts the drops" "could not parse 2 of 3" without_yaml "$CA" "$dropped" "$repo"
assert_output "quotes the offending line so it is fixable" "just a bare string" without_yaml "$CA" "$dropped" "$repo"
assert_output "explains why a drop cannot pass" "UNRUN check" without_yaml "$CA" "$dropped" "$repo"

t_case "fallback: an indented continuation line inside the block is a drop, not a skip"
cont="$(af continuation 'assertions:
  - file_exists: seed.txt
    extra_key: something-nested')"
assert_rc "exit 2" 2 without_yaml "$CA" "$cont" "$repo"
assert_output "names the unparseable line" "extra_key" without_yaml "$CA" "$cont" "$repo"

t_case "fallback: inline/flow 'assertions: [...]' is refused, not read as an empty list"
flow="$(af flow 'assertions: [{file_exists: seed.txt}]')"
assert_rc "exit 2" 2 without_yaml "$CA" "$flow" "$repo"
assert_output "CANNOT EVALUATE" "CANNOT EVALUATE" without_yaml "$CA" "$flow" "$repo"

t_case "fallback: the real shipped-eval file shapes parse with ZERO drops"
# Mirrors every shape agent-firm/evals/*/assertions.yaml actually uses -- a folded `description: >`
# block, comments inside the assertions list, a double-quoted value, and a value containing its own
# single quotes -- but with cheap file_exists/file_absent assertions so nothing is executed.
shapes="$(af shapes 'name: shape-check
description: >
  A folded block. Its continuation lines are indented, and this parser must not read
  - this line, which begins with a dash - as an assertion.
fixture: ./fixture
assertions:
  # a comment inside the block
  - file_exists: seed.txt
  - file_absent: "nope.txt"
  - test_passes: sh -c '"'"'exit 0'"'"'
notes:
  - file_exists: this-would-be-invented-if-the-parser-ignored-block-scope')"
assert_rc "all real-world shapes parse and pass" 0 without_yaml "$CA" "$shapes" "$repo"
assert_output "exactly the 3 assertions in the block (not the dash line in description:, not notes:)" \
  "assertions: 3 parsed" without_yaml "$CA" "$shapes" "$repo"

t_case "fallback: valid YAML styles are parsed, not refused — zero-indent sequence, trailing comment"
# `- item` at the same indentation as its key is legal YAML, and so is a comment after the key. Both
# must parse; refusing them would be a false alarm (safe, but it would push authors to reformat).
styles="$(af styles 'assertions:  # the checks
- file_exists: seed.txt
- file_absent: nope.txt
trailer: ends the block')"
assert_rc "PASS" 0 without_yaml "$CA" "$styles" "$repo"
assert_output "both items parsed" "assertions: 2 parsed" without_yaml "$CA" "$styles" "$repo"

t_case "fallback: a quoted value keeps its inner quotes (regression: sh -c 'x' used to be mangled)"
# The old parser did `.strip('\"\\'')`, stripping quote chars off each end independently, so
# `sh -c 'exit 0'` lost its trailing quote and became an unbalanced shell command.
quoted="$(af quoted "assertions:
  - test_passes: sh -c 'exit 0'
  - test_passes: \"exit 0\"")"
assert_rc "both run as written" 0 without_yaml "$CA" "$quoted" "$repo"

# ===========================================================================
# A YAML PARSER IS PRESENT — a SYNTAX ERROR must be a hard failure, never a quiet fallback.
# Real pyyaml wherever the host has it (so CI runs these against pyyaml==6.0.3 for the first time);
# the subset double only on a host that has none.
# ===========================================================================
t_case "pyyaml branch: a well-formed file passes, and says which parser ran"
assert_rc "PASS" 0 with_yaml_parser "$CA" "$good" "$repo"
assert_output "names pyyaml (proves this branch, not the fallback, ran)" \
  "via pyyaml" with_yaml_parser "$CA" "$good" "$repo"

t_case "pyyaml branch: INVALID YAML is a hard failure, NOT a silent regex fallback"
bad="$(af bad 'assertions:
  - file_exists: seed.txt
   bad_indent_here: [unclosed')"
assert_rc "exit 2" 2 with_yaml_parser "$CA" "$bad" "$repo"
assert_output "says the file is not valid YAML" "not valid YAML" with_yaml_parser "$CA" "$bad" "$repo"
out_bad="$(with_yaml_parser "$CA" "$bad" "$repo" 2>&1)"
case "$out_bad" in
  *"regex fallback"*) _t_no "no fallback happened on a syntax error" "fell back: $(_t_ctx "$out_bad")" ;;
  *) _t_ok "no fallback happened on a syntax error" ;;
esac
case "$out_bad" in
  *"PASS file_exists"*) _t_no "no assertion was run from a broken file" "ran anyway: $(_t_ctx "$out_bad")" ;;
  *) _t_ok "no assertion was run from a broken file" ;;
esac

t_case "pyyaml branch: EMPTY file is a FAILURE"
assert_rc "exit 2" 2 with_yaml_parser "$CA" "$empty" "$repo"
assert_output "names emptiness" "is empty" with_yaml_parser "$CA" "$empty" "$repo"

t_case "pyyaml branch: a prose-only file is a FAILURE (top level is not a mapping)"
assert_rc "exit 2" 2 with_yaml_parser "$CA" "$prose" "$repo"
assert_output "names the wrong top-level type" "expected a mapping" with_yaml_parser "$CA" "$prose" "$repo"

t_case "pyyaml branch: a file with no 'assertions:' key is a FAILURE"
nokey="$(af nokey 'name: no-assertions-here
fixture: ./fixture')"
assert_rc "exit 2" 2 with_yaml_parser "$CA" "$nokey" "$repo"
assert_output "names the missing key" "no top-level" with_yaml_parser "$CA" "$nokey" "$repo"

t_case "pyyaml branch: an 'assertions:' value that is not a list is a FAILURE"
notalist="$(af notalist 'assertions: see the README')"
assert_rc "exit 2" 2 with_yaml_parser "$CA" "$notalist" "$repo"
assert_output "names the wrong type" "expected a list" with_yaml_parser "$CA" "$notalist" "$repo"

t_case "pyyaml branch: a non-mapping list item FAILS instead of being skipped and counted as passed"
bare="$(af bare 'assertions:
  - file_exists: seed.txt
  - just a bare string')"
assert_rc "exit 1 (an assertion failed)" 1 with_yaml_parser "$CA" "$bare" "$repo"
assert_output "names it as malformed" "malformed_assertion" with_yaml_parser "$CA" "$bare" "$repo"

# ---------------------------------------------------------------------------
t_case "both paths agree on the same well-formed file"
assert_rc "fallback: PASS"   0 without_yaml   "$CA" "$good" "$repo"
assert_rc "pyyaml:   PASS"   0 with_yaml_parser "$CA" "$good" "$repo"
failing="$(af failing 'assertions:
  - file_exists: definitely-not-here.txt')"
assert_rc "fallback: FAIL=1" 1 without_yaml   "$CA" "$failing" "$repo"
assert_rc "pyyaml:   FAIL=1" 1 with_yaml_parser "$CA" "$failing" "$repo"

# ===========================================================================
# THE DOUBLE ITSELF — pins tests/fixtures/stub-yaml/yaml.py against its own docstring.
#
# Two reasons this block exists. (1) Now that a real pyyaml is preferred, on CI nothing above touches
# the double at all, so it would rot unwatched — and it is still the live parser for the "a parser is
# present" branch on every developer machine without pyyaml. (2) Its docstring HAS been wrong: it
# claimed to handle "exactly the shapes assertions.yaml and 01-acceptance-criteria.yaml use", and it
# raises on both — on a real criteria file's nested mapping and on the evals' folded `description: >`.
# A claim about a test double is still a claim, so it gets assertions like anything else.
#
# These deliberately use with_stub_yaml_forced, not with_yaml_parser: the subject here is the double,
# not firm-check-assertions, so it must be the double that runs on every host.
# ===========================================================================
t_case "the double supports exactly what it claims — and raises on the rest, including valid YAML"
stub_py() { with_stub_yaml_forced python3 -c "$1"; }

assert_ok "SUPPORTED: top-level key: scalar, with bool/int conversion" stub_py '
import yaml
assert yaml.safe_load("name: x\ncount: 3\nflag: true\nneg: -4") == {"name": "x", "count": 3, "flag": True, "neg": -4}'

assert_ok "SUPPORTED: a quoted value keeps its INNER quotes, so a quoted shell command survives" stub_py '
import yaml
assert yaml.safe_load("k: sh -c \x27exit 0\x27") == {"k": "sh -c \x27exit 0\x27"}
assert yaml.safe_load("k: \"hello\"") == {"k": "hello"}'

assert_ok "SUPPORTED: key: followed by an INDENTED single-line - list" stub_py '
import yaml
assert yaml.safe_load("assertions:\n  - file_exists: a.txt\n  - bare item") \
    == {"assertions": [{"file_exists": "a.txt"}, "bare item"]}'

assert_ok "SUPPORTED: comments and blank lines anywhere; an empty document is None" stub_py '
import yaml
assert yaml.safe_load("# c\n\nname: x\n") == {"name": "x"}
assert yaml.safe_load("") is None'

assert_ok "SUPPORTED: a prose-only document comes back as one joined string" stub_py '
import yaml
assert yaml.safe_load("just prose here\nand more of it") == "just prose here and more of it"'

# The four documented divergences. Each is VALID YAML that real pyyaml parses and the double refuses,
# which is exactly why the double must never shadow a real pyyaml.
assert_ok "RAISES on a nested mapping — so it CANNOT parse a real 01-acceptance-criteria.yaml" stub_py '
import yaml
try: yaml.safe_load("criteria:\n  - id: AC-001\n    statement: a thing\n")
except yaml.YAMLError: pass
else: raise SystemExit("parsed a nested mapping the docstring says it refuses")'

assert_ok "RAISES on a folded/literal block scalar — so it CANNOT parse a real evals assertions.yaml" stub_py '
import yaml
for src in ("description: >\n  folded text\n  more of it\n", "description: |\n  literal text\n"):
    try: yaml.safe_load(src)
    except yaml.YAMLError: continue
    raise SystemExit("parsed a block scalar the docstring says it refuses: %r" % src)'

assert_ok "RAISES on a zero-indent block sequence, and on a top-level sequence" stub_py '
import yaml
for src in ("assertions:\n- a: 1\n- b: 2", "- id: AC-001\n- id: AC-002"):
    try: yaml.safe_load(src)
    except yaml.YAMLError: continue
    raise SystemExit("parsed a sequence shape the docstring says it refuses: %r" % src)'

assert_ok "does NOT parse flow style: it returns the plain string, neither raising nor listing" stub_py '
import yaml
assert yaml.safe_load("criteria: [{id: AC-001, type: functional}]") \
    == {"criteria": "[{id: AC-001, type: functional}]"}'

assert_ok "an empty key: yields [] here where pyyaml yields None — the divergence is real" stub_py '
import yaml
assert yaml.safe_load("criteria:\n") == {"criteria": []}'

t_summary
