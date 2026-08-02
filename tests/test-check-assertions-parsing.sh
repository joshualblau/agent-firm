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
# Both parse paths are pinned here, on any host, via PYTHONPATH doubles — the same technique
# tests/test-traceability-check.sh and tests/test-validate-verdict.sh:52-57 already use:
#   without_yaml    a `yaml.py` that raises ImportError -> forces the regex fallback
#   with_stub_yaml  tests/fixtures/stub-yaml/yaml.py — safe_load over the tiny subset these files
#                   use, RAISING on input outside it -> forces the pyyaml branch
# The double is NOT pyyaml and does not claim to be; it is a stand-in for "a YAML parser is present",
# which is the only thing the branch under test depends on. Every case therefore also asserts WHICH
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
with_stub_yaml() { ( PYTHONPATH="$STUBYAML${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

af() { printf '%s' "$2" > "$W/$1.yaml"; printf '%s' "$W/$1.yaml"; }

# ---------------------------------------------------------------------------
t_case "preconditions: both parser doubles really do what the cases below assume"
assert_fail "without_yaml: importing yaml raises" without_yaml python3 -c "import yaml"
assert_ok   "with_stub_yaml: importing yaml succeeds and exposes a working safe_load" \
  with_stub_yaml python3 -c "import yaml; assert yaml.safe_load('a: 1') == {'a': 1}"

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
# pyyaml PRESENT (stub double) — a YAML SYNTAX ERROR must be a hard failure, never a quiet fallback.
# ===========================================================================
t_case "pyyaml branch: a well-formed file passes, and says which parser ran"
assert_rc "PASS" 0 with_stub_yaml "$CA" "$good" "$repo"
assert_output "names pyyaml (proves this branch, not the fallback, ran)" \
  "via pyyaml" with_stub_yaml "$CA" "$good" "$repo"

t_case "pyyaml branch: INVALID YAML is a hard failure, NOT a silent regex fallback"
bad="$(af bad 'assertions:
  - file_exists: seed.txt
   bad_indent_here: [unclosed')"
assert_rc "exit 2" 2 with_stub_yaml "$CA" "$bad" "$repo"
assert_output "says the file is not valid YAML" "not valid YAML" with_stub_yaml "$CA" "$bad" "$repo"
out_bad="$(with_stub_yaml "$CA" "$bad" "$repo" 2>&1)"
case "$out_bad" in
  *"regex fallback"*) _t_no "no fallback happened on a syntax error" "fell back: $(_t_ctx "$out_bad")" ;;
  *) _t_ok "no fallback happened on a syntax error" ;;
esac
case "$out_bad" in
  *"PASS file_exists"*) _t_no "no assertion was run from a broken file" "ran anyway: $(_t_ctx "$out_bad")" ;;
  *) _t_ok "no assertion was run from a broken file" ;;
esac

t_case "pyyaml branch: EMPTY file is a FAILURE"
assert_rc "exit 2" 2 with_stub_yaml "$CA" "$empty" "$repo"
assert_output "names emptiness" "is empty" with_stub_yaml "$CA" "$empty" "$repo"

t_case "pyyaml branch: a prose-only file is a FAILURE (top level is not a mapping)"
assert_rc "exit 2" 2 with_stub_yaml "$CA" "$prose" "$repo"
assert_output "names the wrong top-level type" "expected a mapping" with_stub_yaml "$CA" "$prose" "$repo"

t_case "pyyaml branch: a file with no 'assertions:' key is a FAILURE"
nokey="$(af nokey 'name: no-assertions-here
fixture: ./fixture')"
assert_rc "exit 2" 2 with_stub_yaml "$CA" "$nokey" "$repo"
assert_output "names the missing key" "no top-level" with_stub_yaml "$CA" "$nokey" "$repo"

t_case "pyyaml branch: an 'assertions:' value that is not a list is a FAILURE"
notalist="$(af notalist 'assertions: see the README')"
assert_rc "exit 2" 2 with_stub_yaml "$CA" "$notalist" "$repo"
assert_output "names the wrong type" "expected a list" with_stub_yaml "$CA" "$notalist" "$repo"

t_case "pyyaml branch: a non-mapping list item FAILS instead of being skipped and counted as passed"
bare="$(af bare 'assertions:
  - file_exists: seed.txt
  - just a bare string')"
assert_rc "exit 1 (an assertion failed)" 1 with_stub_yaml "$CA" "$bare" "$repo"
assert_output "names it as malformed" "malformed_assertion" with_stub_yaml "$CA" "$bare" "$repo"

# ---------------------------------------------------------------------------
t_case "both paths agree on the same well-formed file"
assert_rc "fallback: PASS"   0 without_yaml   "$CA" "$good" "$repo"
assert_rc "pyyaml:   PASS"   0 with_stub_yaml "$CA" "$good" "$repo"
failing="$(af failing 'assertions:
  - file_exists: definitely-not-here.txt')"
assert_rc "fallback: FAIL=1" 1 without_yaml   "$CA" "$failing" "$repo"
assert_rc "pyyaml:   FAIL=1" 1 with_stub_yaml "$CA" "$failing" "$repo"

t_summary
