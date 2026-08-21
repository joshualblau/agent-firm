#!/usr/bin/env bash
# tests/test-criteria-authoring-rule.sh — the rule that an acceptance criterion asserts a PROPERTY,
# never a measured constant, must be stated normatively at the two surfaces that actually author
# criteria: the canonical role contract agent-firm/contracts/roles/intake-analyst.md (which is the
# shared adapter boundary for BOTH providers) and the header of
# agent-firm/templates/01-acceptance-criteria.yaml (which bin/firm-new-run seeds into every run
# directory, so it is physically in front of the author at the moment they write a criterion).
#
# WHAT THIS FILE PROVES, AND WHAT IT DOES NOT. It proves the rule is PRESENT and NORMATIVE at both
# binding surfaces, and that the two statements are the same statement. It does not — and cannot —
# prove that any given criterion complies. An automated detector of measured constants in free prose
# was considered and deliberately rejected (NC-09): loose enough to catch a millisecond band, it also
# fires on the exit statuses, SHA lengths and field counts criteria legitimately name and gets
# suppressed; tight enough not to fire, it is a check that cannot fail. The rule is enforced by the
# authoring contract and by review. This file guards the contract, and says so rather than letting the
# absence look like an oversight.
#
# Structure follows tests/test-review-artifacts.sh, the precedent for asserting role-contract content:
# the checker is a function OF ITS FILE PATHS, so the mutation cases run against COPIES in a temp tree
# and the real contract and template are never touched.
#
# Needs no ledger, no git and no fixtures beyond a temp dir: parallel-safe, and it does NOT belong in
# tests/run-tests.sh's requires_supported_p2 or runs_alone lists.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROLE="$FIRM_ROOT/agent-firm/contracts/roles/intake-analyst.md"
TEMPLATE="$FIRM_ROOT/agent-firm/templates/01-acceptance-criteria.yaml"
W="$(mktemp -d "${TMPDIR:-/tmp}/firm-criteria-rule.XXXXXX")"; t_track "$W"

cat > "$W/rule-check.py" <<'PY'
import pathlib, re, sys

# THE canonical sentence, carried here exactly once. Every surface named on the command line must
# contain it, so "the two statements must not contradict each other" reduces to "both are this same
# constant" — a SUFFICIENT condition, and the strongest one that is actually checkable without
# reading English. Two non-contradicting paraphrases would fail this test; that cost is deliberate,
# because paraphrases drifting apart is precisely what the criterion asks to prevent.
RULE = ("A criterion MUST assert a property. A measured value MAY be cited as evidence but "
        "MUST NOT be the criterion's threshold.")

# The rule must be NORMATIVE rather than advice, and that is a property of the constant above, not of
# the files. Asserting it here is what makes a COORDINATED softening fail: rewriting every surface to
# "a criterion should assert a property" only goes green if this line is edited too, at which point
# the weakening is in the diff of a test file rather than hidden in prose.
for modal in ("MUST", "MAY", "MUST NOT"):
    assert modal in RULE, ("rule is no longer normative: missing " + modal)

def normalise(text):
    # Strip one leading comment marker per line (the template states the rule inside a YAML comment
    # header, the role contract states it as prose), then collapse ALL whitespace including newlines,
    # then casefold. A rewrap at a different column, a deeper indent, or a change of comment prefix
    # must not turn a true statement into a red test — the assertion is about the sentence, not about
    # where the line breaks fall.
    lines = [re.sub(r"^[ \t]*#+[ \t]?", "", line) for line in text.splitlines()]
    return re.sub(r"\s+", " ", " ".join(lines)).strip().casefold()

paths = sys.argv[1:]
if not paths:
    print("rule-check: no surface given — refusing to report success on nothing", file=sys.stderr)
    raise SystemExit(2)

wanted = normalise(RULE)
missing = [p for p in paths if wanted not in normalise(pathlib.Path(p).read_text(encoding="utf-8"))]
if missing:
    print("criteria authoring rule missing from: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
print("criteria authoring rule present in %d surface(s)" % len(paths))
PY

rule_check() { t_python "$W/rule-check.py" "$@"; }

# ---------------------------------------------------------------------------
t_case "both criteria-authoring surfaces state the rule, normatively and identically"
assert_ok "the canonical intake-analyst role contract states it" rule_check "$ROLE"
assert_ok "the 01-acceptance-criteria.yaml template header states it" rule_check "$TEMPLATE"
# Identity is a SUFFICIENT condition for "the two statements do not contradict each other", not a
# proof of it in general -- neither this assertion nor any other in this file reads the rest of either
# file for a contradiction. The title says what the body drives: the same sentence, in both.
assert_ok "both surfaces carry the same sentence, after whitespace normalisation" \
  rule_check "$ROLE" "$TEMPLATE"
# rule_check casefolds, deliberately, so that a rewrap or a case change cannot make a true statement
# red. These two assert the SHIPPED BYTES carry the uppercase RFC-2119 form, which casefolding would
# otherwise let slide — the needle is one unwrapped line of the sentence, so a future rewrap still
# cannot break them for the wrong reason.
assert_output "the shipped role contract carries the uppercase MUST, not a lowercase paraphrase" \
  "A criterion MUST assert a property." cat "$ROLE"
assert_output "the shipped template header carries the uppercase MUST, not a lowercase paraphrase" \
  "A criterion MUST assert a property." cat "$TEMPLATE"
# The template is a YAML file the firm seeds into every run directory; a header written as anything
# other than comments would break every run that reads it. tests/test-policy-yaml-valid.sh asserts
# this generically for all templates; asserting it here too keeps THIS file's edit self-guarding.
assert_ok "the template still parses as YAML with the rule in its header" \
  t_python -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$TEMPLATE"

# ---------------------------------------------------------------------------
# The mutation proof, run against copies so the shipped files are never modified. Each half deletes
# the rule from ONE surface and requires the checker to go red for it while the OTHER surface stays
# green — a check that only goes red when both surfaces are broken would not distinguish the two, and
# a check that goes red for the untouched surface would be reporting about the wrong file.
t_case "deleting the rule from either surface makes the check fail, and only for that surface"
mutant_role="$W/intake-analyst-without-the-rule.md"
mutant_template="$W/01-acceptance-criteria-without-the-rule.yaml"
t_python - "$ROLE" "$mutant_role" "$TEMPLATE" "$mutant_template" <<'PY'
import pathlib, re, sys
role_src, role_out, template_src, template_out = map(pathlib.Path, sys.argv[1:])
# Delete every line that carries any part of the sentence, in whatever comment/prose form it takes.
needles = ("A criterion MUST assert a property", "criterion's threshold", "MAY be cited as evidence")
def strip_rule(path):
    kept = [line for line in path.read_text(encoding="utf-8").splitlines(True)
            if not any(needle in line for needle in needles)]
    return "".join(kept)
role_text = strip_rule(role_src)
template_text = strip_rule(template_src)
assert role_text != role_src.read_text(encoding="utf-8"), "role mutation removed nothing"
assert template_text != template_src.read_text(encoding="utf-8"), "template mutation removed nothing"
role_out.write_text(role_text, encoding="utf-8")
template_out.write_text(template_text, encoding="utf-8")
PY
assert_fail "a role contract with the rule deleted is refused" rule_check "$mutant_role"
assert_ok "and the untouched template is still green" rule_check "$TEMPLATE"
assert_fail "the pair is refused when only the role contract lost it" rule_check "$mutant_role" "$TEMPLATE"

assert_fail "a template with the rule deleted is refused" rule_check "$mutant_template"
assert_ok "and the untouched role contract is still green" rule_check "$ROLE"
assert_fail "the pair is refused when only the template lost it" rule_check "$ROLE" "$mutant_template"

# ---------------------------------------------------------------------------
t_case "the checker is not satisfied by a paraphrase, and never reports success on nothing"
softened="$W/softened.md"
t_python - "$ROLE" "$softened" <<'PY'
import pathlib, sys
src, out = map(pathlib.Path, sys.argv[1:])
text = src.read_text(encoding="utf-8")
# Advice, not a rule. This is the failure mode AC-008 exists to prevent, and it must be red.
softened = (text.replace("A criterion MUST assert a property", "A criterion should assert a property")
                .replace("MUST NOT be the criterion's threshold", "should not be the criterion's threshold"))
assert softened != text, "softening replaced nothing"
out.write_text(softened, encoding="utf-8")
PY
assert_fail "a softened, advisory restatement does not satisfy the rule" rule_check "$softened"
assert_rc "asked about no surface at all, the checker refuses instead of passing" 2 rule_check

t_summary
