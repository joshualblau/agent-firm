#!/usr/bin/env bash
# The judge's credential boundary: what it inherits, what it must NOT, and what the provider
# structured-output transports actually accept.
#
# Guards the 2026-08-23 defect, where the reviewer built the judge's environment out of freshly
# created empty directories and seeded no credential into any of them, so the provider CLI was
# unauthenticated on every run the firm has ever done and both directions returned a trusted exit 3
# `authentication`. It also guards the three transport defects found immediately behind that gate,
# none of which had ever executed against a live provider.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GPT="$BIN/firm-gpt-qa"
CLAUDE="$BIN/firm-claude-qa"
COMMON="$BIN/firm-reviewer-common"
SCHEMA="$FIRM_ROOT/agent-firm/schemas/qa-verdict.schema.json"

t_case "the credential passthrough is DECLARED, per provider, and published without values"
CONTRACT="$("$GPT" --print-capability-contract 2>/dev/null)"
assert_ok "introspection still succeeds with the credential declaration attached" \
  test -n "$CONTRACT"

decl() { printf '%s' "$CONTRACT" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["credentials"][sys.argv[1]][sys.argv[2]],sort_keys=True))' "$1" "$2"; }

assert_eq "gpt inherits NO ambient environment variable" "[]" "$(decl gpt inherit_environment)"
assert_eq "gpt unsets nothing" "[]" "$(decl gpt unset_environment)"
assert_eq "gpt materialises exactly a COPY of ~/.codex/auth.json and nothing else" \
  '[{"destination": "codex/auth.json", "exposes": "codex_oauth_credential", "id": "codex_auth", "kind": "copy", "source": "~/.codex/auth.json"}]' \
  "$(decl gpt materialize)"
assert_eq "claude inherits USER and only USER" '["USER"]' "$(decl claude inherit_environment)"
# The measured mechanism: the keychain SERVICE name is suffixed with sha256(CLAUDE_CONFIG_DIR)[:8]
# whenever that variable is set to ANY value, so a set CLAUDE_CONFIG_DIR asks for an item that does
# not exist. Setting it to the sealed directory is exactly what made the judge report logged out.
assert_eq "claude UNSETS CLAUDE_CONFIG_DIR rather than sealing it" \
  '["CLAUDE_CONFIG_DIR"]' "$(decl claude unset_environment)"
assert_eq "claude materialises exactly the login keychain and nothing else" \
  '[{"destination": "Library/Keychains/login.keychain-db", "exposes": "macos_login_keychain", "id": "login_keychain", "kind": "symlink", "source": "~/Library/Keychains/login.keychain-db"}]' \
  "$(decl claude materialize)"
assert_ok "the published declaration carries no environment VALUE" \
  sh -c "! printf '%s' \"\$1\" | grep -q '\"USER\": *\"[^\"]'" sh "$CONTRACT"

t_case "the declaration states the READ boundary, and states it truthfully per provider"
# This replaces an `isolated_surfaces` list that named nine operator surfaces as unreachable. In the
# gpt direction that was FALSE: `-s read-only` denies writes and permits reads everywhere, and
# review read ~/.codex/history.jsonl and ~/.claude/settings.json verbatim from inside this exact
# environment. The seal redirects CONFIGURATION lookup; it does not bound reads. These cases exist
# so the honest wording cannot quietly drift back into the reassuring one.
assert_ok "the old, false isolation claim is gone from the published contract" \
  sh -c "! printf '%s' \"\$1\" | grep -q 'isolated_surfaces'" sh "$CONTRACT"
# The name may still appear in the comment that records why it was wrong — that history is the point.
# What must not exist is the DEFINITION.
assert_ok "the wrapper no longer defines an ISOLATED_SURFACES list" \
  sh -c "! grep -qE '^ISOLATED_SURFACES *=' \"\$1\"" sh "$COMMON"
assert_ok "the comment that replaced it records why the claim was false" \
  sh -c "grep -q 'THAT CLAIM WAS FALSE' \"\$1\"" sh "$COMMON"
assert_eq "the gpt judge's read boundary is declared as the operator's uid, not the seal" \
  '"operator_uid"' "$(decl gpt read_boundary | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["bounded_by"]))')"
assert_eq "the claude judge's read boundary is declared as the permission system" \
  '"permission_system"' "$(decl claude read_boundary | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["bounded_by"]))')"
assert_ok "the gpt declaration says plainly that reads are NOT bounded by the seal" \
  sh -c "printf '%s' \"\$1\" | grep -q 'any path readable by the operator'" sh "$(decl gpt read_boundary)"
assert_ok "the gpt declaration records how that was established" \
  sh -c "printf '%s' \"\$1\" | grep -q 'history.jsonl'" sh "$(decl gpt read_boundary)"
# The smaller claim that IS true is still made, and still named for what it is.
SEAL="$(decl gpt seal_redirects_configuration_for)"
for surface in agent_settings hooks plugins mcp_servers skills session_history operator_projects codex_history codex_global_state; do
  assert_ok "the seal is declared to redirect configuration lookup for: $surface" \
    sh -c "printf '%s' \"\$1\" | grep -q '\"$surface\"'" sh "$SEAL"
done

t_case "the wire-format projection loosens what is ASKED, never what is ACCEPTED"
PROJ="$(python3 - "$COMMON" "$SCHEMA" <<'PY'
import json,sys
src=open(sys.argv[1]).read()
start=src.index("TRANSPORT_SCHEMA_DROP = (")
end=src.index("def readiness_invocation")
namespace={}
exec(compile(src[start:end], "transport", "exec"), namespace)
canonical=json.load(open(sys.argv[2]))
projected=namespace["transport_schema"](canonical)
# A property whose NAME collides with a dropped keyword must survive: it is a verdict field, not a
# schema keyword, and deleting it would silently remove a field from what the judge is asked for.
probe=namespace["transport_schema"](
    {"type":"object","properties":{"pattern":{"type":"string","format":"uri"},
                                   "default":{"type":"string"}}})
def carries_rule(node):
    """Does the projected schema still TELL the judge the BLOCK/APPROVE blocker rule? The canonical
    allOf that encodes it cannot go on the wire, so it is carried in descriptions, which the
    projection preserves verbatim. If this ever returns False the APPROVE branch is a trap again."""
    text = json.dumps(node).lower()
    return ("blocker" in text and "empty" in text and "approve" in text and "block" in text)
print(json.dumps({
    "top_keys": sorted(projected),
    "has_allOf": "allOf" in projected,
    "has_schema_key": "$schema" in projected,
    "blocker_id_pattern": projected["$defs"]["blockerObject"]["properties"]["id"].get("pattern"),
    "required_is_every_property": sorted(projected["required"]) == sorted(projected["properties"]),
    "additional_properties": projected.get("additionalProperties"),
    "keyword_named_properties_survive": sorted(probe["properties"]),
    "keyword_named_property_format_dropped": "format" not in probe["properties"]["pattern"],
    "canonical_untouched": "allOf" in canonical and "$schema" in canonical,
    # The collateral loss, stated as a fact rather than denied by a comment. These live ONLY inside
    # the dropped combinator, so they cannot survive it; what must survive is the RULE.
    "const_lost": "const" not in json.dumps(projected),
    "minitems_lost": "minItems" not in json.dumps(projected),
    "maxitems_lost": "maxItems" not in json.dumps(projected),
    "rule_reaches_verdict_property": carries_rule(projected["properties"]["verdict"]),
    "rule_reaches_blockers_property": carries_rule(projected["properties"]["blockers"]),
    "rule_reaches_blocker_objects_property": carries_rule(projected["properties"]["blocker_objects"]),
}, sort_keys=True))
PY
)"
proj() { printf '%s' "$PROJ" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$1"; }
# claude: "--json-schema is not a valid JSON Schema: no schema with key or ref
# https://json-schema.org/draft/2020-12/schema"
assert_eq "the unresolvable meta-schema identity is projected away" "false" "$(proj has_schema_key)"
# claude: "input_schema does not support oneOf, allOf, or anyOf at the top level"
assert_eq "the top-level combinator is projected away" "false" "$(proj has_allOf)"
# codex: "'required' is required to be supplied and to be an array including every key in properties"
assert_eq "every object closes itself and requires every property" "true" "$(proj required_is_every_property)"
assert_eq "every object forbids additional properties" "false" "$(proj additional_properties)"
# The projection that dropped `pattern` made a live claude judge return blocker id "BLOCKER-6",
# which the canonical schema then rejected — a returned verdict lost to a rule the judge was never
# shown. Value constraints stay ON the wire.
assert_eq "value constraints are KEPT so the answer can satisfy the canonical schema" \
  '"^obj-[A-Za-z0-9._:-]{1,128}$"' "$(proj blocker_id_pattern)"
assert_eq "a verdict field named like a dropped keyword survives" \
  '["default", "pattern"]' "$(proj keyword_named_properties_survive)"
assert_eq "keywords are still dropped INSIDE such a field" "true" \
  "$(proj keyword_named_property_format_dropped)"
assert_eq "the canonical schema on disk is not rewritten" "true" "$(proj canonical_untouched)"

t_case "the APPROVE branch is not a trap: the one rule the combinator carried still reaches the judge"
# The canonical allOf is a SINGLE rule and it lives nowhere else:
#   BLOCK -> blockers/blocker_objects minItems 1; otherwise -> both maxItems 0.
# Dropping the combinator takes `const`, `minItems` and `maxItems` with it as collateral, while the
# projection simultaneously forces `required: [every property]`. That combination makes an
# approve-with-nits verdict VALID on the wire and then fatal at the canonical gate — the BLOCKER-6
# failure again, aimed at the branch that has never run live. State the loss, then prove the rule
# still arrives by the route that survives projection.
assert_eq "const is lost with the combinator (stated, not denied)" "true" "$(proj const_lost)"
assert_eq "minItems is lost with the combinator" "true" "$(proj minitems_lost)"
assert_eq "maxItems is lost with the combinator" "true" "$(proj maxitems_lost)"
assert_eq "the rule still reaches the judge on the verdict property" "true" "$(proj rule_reaches_verdict_property)"
assert_eq "the rule still reaches the judge on the blockers property" "true" "$(proj rule_reaches_blockers_property)"
assert_eq "the rule still reaches the judge on the blocker_objects property" "true" \
  "$(proj rule_reaches_blocker_objects_property)"
assert_ok "the judge prompt states the rule too, since the wire schema cannot enforce it" \
  sh -c "grep -q 'APPROVE/BLOCK blocker rule is enforced after you answer' \"\$1\"" sh "$COMMON"

# And walk a real APPROVE-shaped verdict through the FULL path the wrapper uses: valid on the wire,
# then valid canonically. This is the case both live runs happened to avoid by returning BLOCK.
assert_ok "an APPROVE with empty blockers passes the wire schema AND the canonical gate" \
  python3 - "$COMMON" "$SCHEMA" <<'PY'
import json, sys, jsonschema
src = open(sys.argv[1]).read()
ns = {}
exec(compile(src[src.index("TRANSPORT_SCHEMA_DROP = ("):src.index("def readiness_invocation")],
             "transport", "exec"), ns)
canonical = json.load(open(sys.argv[2]))
wire = ns["transport_schema"](canonical)
approve = {
    "commit_sha": "0" * 40, "run_id": "r", "generation": 1, "provider": "gpt",
    "attempt_id": "gpt-c1-a0001", "environment": "test", "commands_run": [{"cmd": "node --test", "exit_code": 0, "duration_s": 1.0,
                      "artifact": "09-test-evidence/p.log"}],
    "unit": {"status": "pass", "evidence": "09-test-evidence/p.log"},
    "integration": {"status": "not_applicable", "evidence": "none"},
    "e2e": {"status": "not_applicable", "evidence": "none"},
    "visual": {"status": "not_applicable", "evidence": "none"},
    "acceptance_criteria_coverage": [], "untested_risks": [],
    "warnings": ["a non-blocking nit, which is where nits belong"],
    "artifacts": [], "verdict": "APPROVE", "blockers": [], "blocker_objects": [],
    "summary": "approve with a nit",
}
jsonschema.validate(approve, wire)          # the judge could legitimately return this
jsonschema.validate(approve, canonical)     # and the gate must accept it
# The inverse must still be rejected canonically, or the rule has been lost rather than moved.
bad = dict(approve, blockers=["a nit recorded in the wrong field"])
try:
    jsonschema.validate(bad, canonical)
except jsonschema.ValidationError:
    pass
else:
    raise SystemExit("canonical schema accepted an APPROVE carrying blockers")
PY

t_case "a refused passthrough stays a trusted unavailable, never an unauthenticated judge"
# The wrapper's fail-closed path is structural: a source that is missing, symlinked or foreign-owned
# is simply not materialised, the seal is unchanged, and the readiness probe then answers in the
# provider's own words. Assert the refusal vocabulary exists and that no branch can promote a refusal
# into a ready judge.
assert_ok "refusal reasons are enumerated in the wrapper" \
  grep -q 'source_is_a_symlink' "$COMMON"
assert_ok "a foreign-owned credential source is refused" \
  grep -q 'source_is_foreign_owned' "$COMMON"
assert_ok "materialisation never returns 'ready' and never touches the readiness answer" \
  sh -c '! grep -n "materialize_credentials" "$1" | grep -q "readiness"' sh "$COMMON"

t_case "the seal audit is a BLOCK, not a note"
assert_ok "an undeclared escape from the sealed home blocks the attempt" \
  grep -q 'sealed judge home escapes to undeclared paths' "$COMMON"

t_case "the declaration is bound to the CLIs installed on this host"
# Offline checking cannot prove a passthrough authenticates or that the seal holds around it. Both
# are facts about the vendor binaries and this machine, so they are measured. Neither probe starts a
# model turn. Skipped, loudly, only where a provider CLI is absent.
if command -v codex >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
  LIVE="$(python3 "$TESTS_DIR/credential-live-check.py" "$BIN" 2>&1)"; live_rc=$?
  assert_eq "the live credential binding passes (authenticates, canary clean, fails closed)" \
    "0" "$live_rc"
  printf '%s\n' "$LIVE" | sed 's/^/      /'
else
  printf '      SKIP (a provider CLI is not installed; the live binding was NOT checked)\n'
fi

t_summary
