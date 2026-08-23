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

t_case "the declaration names the surfaces authentication must NOT reach"
ISO="$(decl gpt isolated_surfaces)"
for surface in agent_settings hooks plugins mcp_servers skills session_history operator_projects codex_history codex_global_state; do
  assert_ok "isolated surface is declared: $surface" \
    sh -c "printf '%s' \"\$1\" | grep -q '\"$surface\"'" sh "$ISO"
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
