#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVE="$BIN/firm-model-resolve"
POLICY="$FIRM_ROOT/agent-firm/policy/model-tiers.yaml"
W="$(mktemp -d "${TMPDIR:-/tmp}/firm-model-tiers.XXXXXX")"; t_track "$W"

matrix='ceiling|claude|fable|Fable 5|max
ceiling|codex|gpt-5.6-sol|GPT-5.6 sol|ultra
heavyweight|claude|opus|Opus 5|xhigh
heavyweight|codex|gpt-5.6-sol|GPT-5.6 sol|xhigh
workhorse|claude|sonnet|Sonnet 5|high
workhorse|codex|gpt-5.6-terra|GPT-5.6 terra|high
fast|claude|haiku|Haiku 4.5|low
fast|codex|gpt-5.6-terra|GPT-5.6 terra|low'

t_case "all four tiers resolve exact model, display, and effort for both providers"
old_ifs="$IFS"; IFS='|'
printf '%s\n' "$matrix" | while read tier provider model display effort; do
  "$RESOLVE" --provider "$provider" --tier "$tier" --expect-model "$model" \
    --expect-display "$display" --expect-effort "$effort" >/dev/null || exit 1
done
matrix_rc=$?; IFS="$old_ifs"
if [ "$matrix_rc" -eq 0 ]; then _t_ok "8 provider/tier cells and all 24 fields match"; else _t_no "8 provider/tier cells and all 24 fields match"; fi

t_case "all runtime roles and both named judges resolve without a hidden default"
roles='lead intake-analyst architect implementer integrator reviewer recruiter packager qa-tester specialist scout judge claude-judge gpt-judge'
for role in $roles; do
  for provider in claude codex; do
    assert_rc "$provider/$role resolves" 0 "$RESOLVE" --provider "$provider" --role "$role"
  done
done

t_case "every supported legacy alias resolves to its documented tier"
for pair in fable:ceiling opus:heavyweight sonnet:workhorse haiku:fast codex:heavyweight; do
  alias="${pair%%:*}"; tier="${pair#*:}"
  got="$($RESOLVE --provider codex --alias "$alias" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tier"])')"
  assert_eq "$alias resolves to $tier" "$tier" "$got"
done

t_case "unknown roles, tiers, aliases, explicit models, displays, and efforts fail closed"
assert_rc "unknown role" 2 "$RESOLVE" --provider codex --role mystery
assert_rc "unknown tier" 2 "$RESOLVE" --provider codex --tier mystery
assert_rc "unknown alias" 2 "$RESOLVE" --provider codex --alias mystery
assert_rc "wrong model" 2 "$RESOLVE" --provider codex --tier heavyweight --expect-model unknown-model
assert_rc "wrong display" 2 "$RESOLVE" --provider codex --tier heavyweight --expect-display unknown-display
assert_rc "wrong effort" 2 "$RESOLVE" --provider codex --tier heavyweight --expect-effort unknown-effort
assert_output "failure is explicitly blocking and says no fallback" "no fallback applied" \
  "$RESOLVE" --provider codex --tier heavyweight --expect-effort unknown-effort

t_case "mutation of every canonical model/display/effort cell is detected"
mutation_fail=0; mutation_count=0
old_ifs="$IFS"; IFS='|'
printf '%s\n' "$matrix" | while read tier provider model display effort; do
  for field in model display effort; do
    mutation_count=$((mutation_count+1))
    p="$W/mutated-$tier-$provider-$field.yaml"
    cp "$POLICY" "$p"
    python3 - "$p" "$tier" "$provider" "$field" <<'PY'
import sys,yaml
p,tier,provider,field=sys.argv[1:]
d=yaml.safe_load(open(p)); d['tiers'][tier][provider][field]='MUTATED'
yaml.safe_dump(d,open(p,'w'),sort_keys=False)
PY
    "$RESOLVE" --policy "$p" --provider "$provider" --tier "$tier" \
      --expect-model "$model" --expect-display "$display" --expect-effort "$effort" >/dev/null 2>&1
    [ "$?" -eq 2 ] || { echo "    mutation escaped: $tier/$provider/$field"; exit 1; }
  done
done
mutation_rc=$?; IFS="$old_ifs"
if [ "$mutation_rc" -eq 0 ]; then _t_ok "all 24 mapping-field mutations fail"; else _t_no "all 24 mapping-field mutations fail"; fi

t_case "native adapters and both judge commands carry resolved values explicitly"
assert_ok "all Claude subagent adapters include model and effort" python3 - "$FIRM_ROOT" <<'PY'
import pathlib,re,sys,yaml
root=pathlib.Path(sys.argv[1])
expected={
'architect':('opus','xhigh'),'intake-analyst':('opus','xhigh'),'implementer':('opus','xhigh'),
'integrator':('opus','xhigh'),'reviewer':('opus','xhigh'),'recruiter':('sonnet','high'),
'packager':('sonnet','high'),'qa-tester':('sonnet','high'),'specialist':('sonnet','high'),
'scout':('haiku','low')}
for role,(model,effort) in expected.items():
    text=(root/'agents'/f'{role}.md').read_text()
    front=yaml.safe_load(text.split('---',2)[1])
    assert (front.get('model'),front.get('effort'))==(model,effort), (role,front)
PY
assert_ok "GPT and Claude judge invocations are heavyweight/xhigh" sh -c \
  "grep -q -- '-m.*, model' '$BIN/firm-reviewer-common' && grep -q 'model_reasoning_effort=\\\"xhigh\\\"' '$BIN/firm-reviewer-common' && grep -q -- '--model.*, model,.*--effort.*,.*xhigh' '$BIN/firm-reviewer-common'"
assert_output "Codex adapter documents explicit resolver use" "firm-model-resolve" cat "$FIRM_ROOT/codex-skills/start/SKILL.md"
assert_output "Claude adapter documents explicit resolver use" "firm-model-resolve" cat "$FIRM_ROOT/commands/start.md"

t_summary
