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
#      every list item it could not match;
#   3. `except ImportError: yaml = None` conflated "pyyaml is not installed" with "pyyaml is installed
#      but BROKEN" — and did not catch the broken installs that raise something else at all, so those
#      escaped and python exited 1, the code reserved for "an assertion FAILED". Pinned at the bottom
#      of this file.
#
# All THREE parser states are pinned here, on any host — the PYTHONPATH technique
# tests/test-traceability-check.sh and tests/test-validate-verdict.sh:52-57 already use, plus a
# startup hook for the one state PYTHONPATH cannot express:
#   without_yaml       pyyaml UNFINDABLE (a sitecustomize path-finder wrapper) -> the regex fallback.
#                      NOT a stub `yaml.py`: a stub is findable, which is now a BROKEN install
#   with_yaml_parser   the REAL pyyaml wherever the host has one (CI pins pyyaml==6.0.3), and only
#                      otherwise tests/fixtures/stub-yaml/yaml.py, a subset double
#   with_broken_yaml_* findable pyyaml whose import fails (ImportError from inside, a non-ImportError,
#                      and a module-level SystemExit) -> CANNOT EVALUATE
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

W="$(mktemp -d "${TMPDIR:-/tmp}/firm-ca-parse.XXXXXX")"; t_track "$W"
repo="$(mk_repo)"          # has seed.txt, no nope.txt

# ---- the two parser doubles ------------------------------------------------
# without_yaml simulates pyyaml GENUINELY NOT INSTALLED. Since firm-check-assertions now discriminates
# ABSENT from BROKEN with `importlib.util.find_spec("yaml")`, that means find_spec must come back None
# — the state a host with no pyyaml is actually in.
#
# A PYTHONPATH `yaml.py` CANNOT express that any more, and this helper used to be one: a stub file is
# FINDABLE, so a stub raising ImportError is an installed-but-broken pyyaml, not an absent one (it is
# reused, deliberately, for exactly that case at the bottom of this file). What does express absence is
# a `sitecustomize.py` — imported by site.py at interpreter startup, before the script's own
# `import yaml` — that wraps the path finder so nothing can find `yaml`. Surgical on purpose: only the
# `yaml` name disappears, so anything else installed alongside it stays importable, and NOTHING is
# installed or uninstalled — the host's real pyyaml is untouched, it is just invisible to this one
# interpreter. If a future python changes sys.meta_path's composition this stops hiding pyyaml, and the
# precondition below FAILS LOUDLY rather than letting these cases pass on the wrong branch.
NOYAML="$W/noyaml"; mkdir -p "$NOYAML"
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
# The property the ABSENT branch is now selected by. Asserted separately from "the import raises",
# because those two came apart: a findable-but-failing stub also raises, and it must NOT reach the
# fallback. Without this, every `without_yaml` case below could be silently testing the broken-install
# path instead of the absent one.
assert_ok   "without_yaml: pyyaml is UNFINDABLE (find_spec -> None), which is genuine absence and not a broken install" \
  without_yaml python3 -c '
import importlib.util, sys
spec = importlib.util.find_spec("yaml")
assert spec is None, "yaml is still findable at %s -- this simulates BROKEN, not ABSENT" % (spec,)'
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

# ===========================================================================
# pyyaml INSTALLED BUT BROKEN — a THIRD state, and the fifth instance of this repo's characteristic
# defect: a check that cannot evaluate its input reported something other than "cannot evaluate".
#
# `try: import yaml / except ImportError: yaml = None` saw two worlds. A partial or corrupted install
# is a third, and it landed on a verdict either way:
#   · ImportError raised from INSIDE the package -> swallowed, so the script SILENTLY DOWNGRADED to
#     the line parser and announced "pyyaml not installed" about a host where it IS installed. Ran the
#     assertions under a narrower grammar than the operator believed. Was: exit 0.
#   · anything else (RuntimeError / SyntaxError / ValueError) -> escaped uncaught, and python exits 1
#     on an unhandled exception, which in this script's contract means "evaluated, an assertion
#     FAILED". A crash was reported as a test result. Was: exit 1.
#   · a module-level sys.exit(0) -> not an Exception at all, so `except Exception` would not have
#     helped either: exit 0, no output, ZERO assertions run. "Everything passed" from a run that
#     checked nothing — the worst of the three, and the reason the import is wrapped in
#     `except BaseException`.
#
# The discriminator under test is importlib.util.find_spec("yaml"): findable + import fails = BROKEN
# (exit 2); unfindable = genuinely absent (the documented fallback, unchanged).
#
# TWO axes vary across these cases and both matter: WHAT the import does (raises ImportError from
# inside / raises a non-ImportError / exits the process / is genuinely unfindable / works) and WHAT
# the script must then report (cannot-evaluate vs. a real verdict). Varying only the first would not
# show that absence still degrades correctly; varying only the second would not show which shapes of
# breakage reach it. `$good` is the SAME file in every case and passes 1/1 under a working parser, so
# no exit code below can come from the assertions file.
# ===========================================================================
# stdout+stderr must NOT contain <needle>. lib.sh has assert_output but no negative form, and half of
# what must be proved here is an ABSENCE: that the line parser did NOT quietly take over and that no
# assertion tally was printed. (tests/test-check-assertions.sh carries its own identical copy for the
# same reason; this is not shared harness, so it is defined where it is used.)
assert_not_output() {
  local desc="$1" needle="$2" out; shift 2
  out="$("$@" 2>&1)"
  case "$out" in
    *"$needle"*) _t_no "$desc" "unexpectedly found '$needle' in: $(_t_ctx "$out")" ;;
    *) _t_ok "$desc" ;;
  esac
}

t_case "broken pyyaml: the doubles really are findable-but-failing, and differ on the axis that matters"
# Each double is a pyyaml the import system CAN find (that is what makes it "installed") whose import
# does not complete. A real corrupted install / half-removed wheel / bad extension module presents
# exactly like these.
BROKEN_RT="$W/brokenyaml-runtime"; mkdir -p "$BROKEN_RT"
printf 'raise RuntimeError("simulated corrupt pyyaml install")\n' > "$BROKEN_RT/yaml.py"
with_broken_rt() { ( PYTHONPATH="$BROKEN_RT${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

BROKEN_IMP="$W/brokenyaml-partial"; mkdir -p "$BROKEN_IMP/yaml"
printf 'from yaml.does_not_exist import SafeLoader   # a half-installed package\n' \
  > "$BROKEN_IMP/yaml/__init__.py"
with_broken_partial() { ( PYTHONPATH="$BROKEN_IMP${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

BROKEN_EXIT="$W/brokenyaml-sysexit"; mkdir -p "$BROKEN_EXIT"
printf 'import sys\nsys.exit(0)   # module-level SystemExit: NOT an Exception\n' > "$BROKEN_EXIT/yaml.py"
with_broken_sysexit() { ( PYTHONPATH="$BROKEN_EXIT${PYTHONPATH:+:$PYTHONPATH}" "$@" ); }

assert_ok "runtime-broken double: FINDABLE, and raises a NON-ImportError (the escaping shape)" \
  with_broken_rt python3 -c '
import importlib.util, sys
assert importlib.util.find_spec("yaml") is not None, "not findable -> would be absence, wrong axis"
try:
    import yaml
except ImportError:
    raise SystemExit("raised ImportError -- wrong axis for this double")
except RuntimeError:
    pass
else:
    raise SystemExit("import unexpectedly succeeded")'

assert_ok "partial-install double: FINDABLE, and raises ImportError from INSIDE the package (the swallowed shape)" \
  with_broken_partial python3 -c '
import importlib.util, sys
assert importlib.util.find_spec("yaml") is not None, "not findable -> would be absence, wrong axis"
try:
    import yaml
except ImportError as e:
    assert "yaml.does_not_exist" in str(e), "wrong ImportError: %s" % e
else:
    raise SystemExit("import unexpectedly succeeded")'

assert_ok "sysexit double: FINDABLE, and an 'except Exception' does NOT catch what it raises" \
  with_broken_sysexit python3 -c '
import importlib.util, sys
assert importlib.util.find_spec("yaml") is not None, "not findable -> would be absence, wrong axis"
try:
    import yaml
except Exception:
    raise SystemExit("an `except Exception` would have caught this -- wrong axis for this double")
except BaseException as e:
    assert isinstance(e, SystemExit) and e.code == 0, "unexpected: %r" % (e,)'

t_case "broken pyyaml (non-ImportError) is CANNOT EVALUATE — exit 2, never 1"
assert_rc "exit 2 (cannot evaluate), NOT 1 (which would mean an assertion failed)" 2 \
  with_broken_rt "$CA" "$good" "$repo"
assert_output "says it could not evaluate" "CANNOT EVALUATE" with_broken_rt "$CA" "$good" "$repo"
assert_output "names the REAL exception type" "RuntimeError" with_broken_rt "$CA" "$good" "$repo"
assert_output "and its message, so the install is diagnosable" "simulated corrupt pyyaml install" \
  with_broken_rt "$CA" "$good" "$repo"
assert_output "distinguishes broken from missing in the operator's words" "BROKEN install, not a missing one" \
  with_broken_rt "$CA" "$good" "$repo"
assert_not_output "does NOT downgrade to the line parser" "regex fallback" \
  with_broken_rt "$CA" "$good" "$repo"
assert_not_output "and no assertion was run" "PASS file_exists" with_broken_rt "$CA" "$good" "$repo"
assert_not_output "nor reported as a passing run" "assertions passed" with_broken_rt "$CA" "$good" "$repo"

t_case "broken pyyaml (ImportError from INSIDE the package) is CANNOT EVALUATE — not a silent downgrade"
# The dangerous one: this used to exit 0 having quietly run the assertions through the fallback while
# printing "pyyaml not installed" about a host where pyyaml IS installed.
assert_rc "exit 2, NOT 0" 2 with_broken_partial "$CA" "$good" "$repo"
assert_output "names the failure inside the package" "yaml.does_not_exist" \
  with_broken_partial "$CA" "$good" "$repo"
assert_output "reports pyyaml as INSTALLED (it is findable), not missing" "pyyaml IS installed" \
  with_broken_partial "$CA" "$good" "$repo"
assert_not_output "never claims 'pyyaml not installed' about an installed pyyaml" "pyyaml not installed" \
  with_broken_partial "$CA" "$good" "$repo"
assert_not_output "the line parser did not silently take over" "regex fallback" \
  with_broken_partial "$CA" "$good" "$repo"
assert_not_output "and nothing was evaluated under it" "PASS file_exists" \
  with_broken_partial "$CA" "$good" "$repo"

t_case "broken pyyaml (module-level sys.exit) cannot set this script's exit code — exit 2, never 0"
# Was exit 0 with no output at all: `firm-run-evals` reads 0 as "every assertion passed", so a broken
# install could green-light an eval that ran no checks whatsoever.
assert_rc "exit 2, NOT the 0 the broken module tried to exit with" 2 \
  with_broken_sysexit "$CA" "$good" "$repo"
assert_output "says it could not evaluate" "CANNOT EVALUATE" with_broken_sysexit "$CA" "$good" "$repo"
assert_output "names SystemExit rather than hiding it" "SystemExit" with_broken_sysexit "$CA" "$good" "$repo"
assert_not_output "and never prints an assertion tally" "assertions passed" \
  with_broken_sysexit "$CA" "$good" "$repo"

t_case "an INCONCLUSIVE probe is cannot-evaluate too — 'I could not tell' is not 'not installed'"
# The third branch of the discriminator, and the one a careless implementation leaves as a fall-through
# to the fallback. If find_spec() ITSELF raises (a broken import hook, a poisoned sys.modules entry,
# a corrupt parent package) the script knows only that it has no parser and no diagnosis. Guessing
# "absent" there silently downgrades the parser on no evidence, which is the fail-open being closed.
BROKEN_HOOK="$W/brokenyaml-hook"; mkdir -p "$BROKEN_HOOK"
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
assert_rc "exit 2, NOT 0 via a guessed fallback" 2 with_broken_hook "$CA" "$good" "$repo"
assert_output "says so in the operator's words" "cannot tell whether pyyaml is absent or broken" \
  with_broken_hook "$CA" "$good" "$repo"
assert_output "names what the probe itself did" "find_spec('yaml') itself raised" \
  with_broken_hook "$CA" "$good" "$repo"
assert_not_output "did NOT guess 'absent' and downgrade" "regex fallback" \
  with_broken_hook "$CA" "$good" "$repo"
assert_not_output "and evaluated nothing" "PASS file_exists" with_broken_hook "$CA" "$good" "$repo"

t_case "a broken install's exception text cannot crash the report out of exit 2 (ASCII stdout locale)"
# The exception message is DATA from a third-party package: it can be multi-line and non-ASCII. If
# emitting it raised UnicodeEncodeError the process would exit 1 — a verdict — which is the same
# defect one door along. Both axes vary: locale (ascii/utf8) AND the message's bytes.
BROKEN_NA="$W/brokenyaml-nonascii"; mkdir -p "$BROKEN_NA"
printf 'raise RuntimeError("caf\xc3\xa9 \xe2\x80\x94 corrupt install\\nsecond line")\n' > "$BROKEN_NA/yaml.py"
# PYTHONCOERCECLOCALE=0 stops Python 3.7+ silently coercing C -> C.UTF-8 and PYTHONUTF8=0 stops UTF-8
# mode doing the same; without both, the "ascii" helper is quietly a second UTF-8 run. The UTF-8
# control PROBES for a locale name rather than assuming one (C.UTF-8 is absent on many macs,
# en_US.UTF-8 on many CI images) and falls back to UTF-8 mode, so the control is never skipped. Same
# construction as tests/test-traceability-check.sh's ascii_locale/utf8_locale pair.
na_ascii() { ( PYTHONPATH="$BROKEN_NA${PYTHONPATH:+:$PYTHONPATH}" \
               LC_ALL=C LANG=C LC_CTYPE=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0 "$@" ); }
NA_UTF8_LOC=""
for _cand in C.UTF-8 en_US.UTF-8 en_US.utf8 UTF-8; do
  if LC_ALL="$_cand" LANG="$_cand" LC_CTYPE="$_cand" PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 \
       python3 -c "import sys; sys.exit(0 if 'utf' in (sys.stdout.encoding or '').lower() else 1)" \
       </dev/null >/dev/null 2>&1; then
    NA_UTF8_LOC="$_cand"; break
  fi
done
if [ -n "$NA_UTF8_LOC" ]; then
  na_utf8() { ( PYTHONPATH="$BROKEN_NA${PYTHONPATH:+:$PYTHONPATH}" \
                LC_ALL="$NA_UTF8_LOC" LANG="$NA_UTF8_LOC" LC_CTYPE="$NA_UTF8_LOC" \
                PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 "$@" ); }
else
  na_utf8() { ( PYTHONPATH="$BROKEN_NA${PYTHONPATH:+:$PYTHONPATH}" \
                LC_ALL=C LANG=C LC_CTYPE=C PYTHONUTF8=1 "$@" ); }
fi
_enc_probe='import sys; print((sys.stdout.encoding or "?").lower())'
enc_ascii="$(na_ascii python3 -c "$_enc_probe")"
enc_utf8="$(na_utf8  python3 -c "$_enc_probe")"
assert_ne "precondition: the two locale helpers give python3 DIFFERENT stdout encodings (else this axis is decorative)" \
  "$enc_ascii" "$enc_utf8"
assert_ok "precondition: the ascii helper's stdout genuinely cannot hold non-ASCII (got '$enc_ascii')" \
  python3 -c 'import sys; sys.exit(0 if "utf" not in sys.argv[1] else 1)' "$enc_ascii"
for _nafn in na_ascii na_utf8; do
  assert_rc "exit 2 with a non-ASCII, multi-line exception message [$_nafn]" 2 \
    $_nafn "$CA" "$good" "$repo"
  assert_output "still says CANNOT EVALUATE [$_nafn]" "CANNOT EVALUATE" $_nafn "$CA" "$good" "$repo"
  assert_output "and still names the exception type [$_nafn]" "RuntimeError" $_nafn "$CA" "$good" "$repo"
  assert_not_output "no encoding crash escaped [$_nafn]" "UnicodeEncodeError" $_nafn "$CA" "$good" "$repo"
done

t_case "absent / working / broken are THREE outcomes for the SAME assertions file, not two"
# Without this, "broken fails" could be satisfied by a script that had simply been broken into always
# failing, and "absence still degrades" could be satisfied by one that never chose the fallback.
without_yaml       "$CA" "$good" "$repo" >/dev/null 2>&1; rc_absent=$?
with_yaml_parser   "$CA" "$good" "$repo" >/dev/null 2>&1; rc_working=$?
with_broken_rt     "$CA" "$good" "$repo" >/dev/null 2>&1; rc_broken=$?
assert_eq "pyyaml ABSENT  -> 0 (the fallback legitimately ran the assertions)" "0" "$rc_absent"
assert_eq "pyyaml WORKING -> 0 (pyyaml ran the assertions)"                    "0" "$rc_working"
assert_eq "pyyaml BROKEN  -> 2 (nothing could be evaluated)"                   "2" "$rc_broken"
assert_ne "a broken install is NOT reported as a passing run"      "$rc_working" "$rc_broken"
assert_ne "and NOT as an assertion failure"                       "1"           "$rc_broken"
assert_output "absence still names the fallback it fell back to" "via regex fallback" \
  without_yaml "$CA" "$good" "$repo"

t_case "a genuinely FAILING assertion is still exit 1 under a working parser (the fix did not widen exit 2)"
# Guards the mutation "make everything cannot-evaluate": 1 and 2 must stay distinguishable.
assert_rc "real pyyaml: a failing assertion is 1"        1 with_yaml_parser "$CA" "$failing" "$repo"
assert_rc "genuine absence: a failing assertion is 1"    1 without_yaml     "$CA" "$failing" "$repo"

t_summary
