#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

t_case "provider matrix is canonical"
assert_ok "matrix maps all four tiers for both providers" python3 -c "
import yaml
d=yaml.safe_load(open('$FIRM_ROOT/agent-firm/policy/model-tiers.yaml'))
t=d['tiers']
assert t['heavyweight']['claude']['model']=='opus'
assert t['heavyweight']['codex']=={'model':'gpt-5.6-sol','display':'GPT-5.6 sol','effort':'xhigh'}
assert t['workhorse']['claude']['model']=='sonnet'
assert t['workhorse']['codex']['model']=='gpt-5.6-terra' and t['workhorse']['codex']['effort']=='high'
assert t['fast']['claude']['model']=='haiku'
assert t['fast']['codex']['model']=='gpt-5.6-terra' and t['fast']['codex']['effort']=='low'
assert t['ceiling']['codex']['effort']=='ultra'
assert d['legacy_aliases']=={'fable':'ceiling','opus':'heavyweight','sonnet':'workhorse','haiku':'fast','codex':'heavyweight'}
"

t_case "new and historical job specs both validate"
assert_ok "abstract and legacy model names remain schema-valid" python3 -c "
import json, jsonschema
s=json.load(open('$FIRM_ROOT/agent-firm/schemas/job-spec.schema.json'))
base={'role_name':'x','task':'x','why_core_staff_cant':'x','expected_deliverable':'x','required_tools':[],'denied_tools':[],'mcp_servers':[],'max_turns':1,'max_wall_clock_minutes':1,'success_criteria':'x','retirement_condition':'x','mode':'ephemeral'}
for model in ('ceiling','heavyweight','workhorse','fast','fable','opus','sonnet','haiku','codex'):
 d=dict(base); d['model']=model; jsonschema.validate(d,s)
"

t_summary
