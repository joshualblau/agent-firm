#!/usr/bin/env bash
# tests/test-deny-rule-labeling.sh — the new Bash `deny` entries must stay labeled as unverified
# supplemental protection, never quietly re-described as enforced security.
#
# Their pattern syntax (`Bash(cat .env*)`) deviates from every existing Bash rule in this repo's
# settings.json, which uses the `Bash(cmd:*)` colon-prefix form throughout. An independent review
# could not confirm — and found no non-interactive way to confirm — that Claude Code's permission
# engine matches the bare-glob form as intended. That uncertainty must stay visible in the one file
# that documents these rules, or a future edit could silently overclaim protection the firm never
# verified. This test does not (and cannot, in this environment) verify the patterns themselves —
# it only guards the disclosure.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETIRED_JSON="$FIRM_ROOT/agent-firm/policy/retired-permissions.json"
SETTINGS_JSON="$FIRM_ROOT/.claude/settings.json"

t_case "the policy file discloses the deny rules as unverified, not enforced"
assert_file "retired-permissions.json exists" "$RETIRED_JSON"
assert_ok "it is valid JSON" python3 -c "import json; json.load(open('$RETIRED_JSON'))"
assert_output "explicitly says UNVERIFIED" "UNVERIFIED" cat "$RETIRED_JSON"
assert_output "explicitly says not enforced security" "not enforced security" cat "$RETIRED_JSON"
assert_output "names the concrete gap: never confirmed against the live engine" "never confirmed" cat "$RETIRED_JSON"
assert_output "distinguishes the ENFORCED half of the fix" "ENFORCED" cat "$RETIRED_JSON"

t_case "no dangling reference to a doc that doesn't exist yet"
assert_ok "does not point at the not-yet-shipped ENFORCEMENT.md" \
  sh -c "! grep -q 'docs/ENFORCEMENT.md' '$RETIRED_JSON'"

t_case "the disclosure is anchored to rules that actually exist in settings.json"
assert_ok "settings.json is valid JSON" python3 -c "import json; json.load(open('$SETTINGS_JSON'))"
assert_output "at least one of the labeled example rules is really present" "Bash(cat .env" cat "$SETTINGS_JSON"

t_case "the enforced half of the fix holds regardless of the disclosure"
# The load-bearing claim is that removing Bash(cat:*)/Bash(jq:*) from `allow` is unconditionally
# effective. Re-assert that directly here so this file fails if that ever regresses, independent of
# whatever the deny-rule labeling says.
assert_ok "Bash(cat:*) is not in allow" \
  python3 -c "
import json
d = json.load(open('$SETTINGS_JSON'))
assert 'Bash(cat:*)' not in d['permissions']['allow']
assert 'Bash(jq:*)' not in d['permissions']['allow']
"

t_summary
