#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEMPLATE="$FIRM_ROOT/agent-firm/templates/07-review-findings.yaml"
ROLE="$FIRM_ROOT/agent-firm/contracts/roles/reviewer.md"
WORKFLOW="$FIRM_ROOT/agent-firm/workflows/build-review-test.js"
W="$(mktemp -d "${TMPDIR:-/tmp}/firm-review-artifacts.XXXXXX")"; t_track "$W"

cat > "$W/contract-check.py" <<'PY'
import pathlib,re,sys,yaml
template,role,workflow=map(pathlib.Path,sys.argv[1:])
fields=['lens','severity','confidence','location','issue','suggested_fix','status']
doc=yaml.safe_load(template.read_text())
finding=doc['findings'][0]
assert list(finding)==fields, (list(finding),fields)
role_text=role.read_text().lower().replace(' ', '_')
for field in fields:
    assert field in role_text, ('role',field)
source=workflow.read_text()
required=re.search(r"required: \['severity', 'confidence', 'location', 'issue', 'suggested_fix', 'status'\]",source)
assert required, 'strict required list missing'
assert "type: 'object', additionalProperties: false" in source
for field in fields[1:]:
    assert re.search(rf"\b{field}: \{{ type: 'string'",source), ('workflow property',field)
assert "confidence: { type: 'string', enum: ['low', 'medium', 'high'] }" in source
assert "status: { type: 'string', enum: ['open', 'accepted', 'rejected', 'fixed'] }" in source
assert "({ lens: review.lens, ...finding })" in source
assert "review_artifact: reviewArtifact" in source
PY

contract_check() { python3 "$W/contract-check.py" "$1" "$2" "$3"; }

t_case "template, role contract, strict workflow schema, and aggregation share one finding shape"
assert_ok "all three surfaces contain the canonical fields" contract_check "$TEMPLATE" "$ROLE" "$WORKFLOW"

t_case "strict finding shape rejects missing, unknown, and invalid confidence/status values"
assert_ok "canonical shape validates and invalid shapes reject" python3 - <<'PY'
import jsonschema
fields=['lens','severity','confidence','location','issue','suggested_fix','status']
schema={'type':'object','additionalProperties':False,'required':fields,'properties':{
'lens':{'type':'string'},'severity':{'enum':['low','medium','high','blocker']},
'confidence':{'enum':['low','medium','high']},'location':{'type':'string'},'issue':{'type':'string'},
'suggested_fix':{'type':'string'},'status':{'enum':['open','accepted','rejected','fixed']}}}
good={'lens':'correctness','severity':'high','confidence':'medium','location':'a:1','issue':'bug','suggested_fix':'fix','status':'open'}
jsonschema.validate(good,schema)
bad=[]
for field in fields:
    value=dict(good); value.pop(field); bad.append(value)
value=dict(good); value['unknown']='x'; bad.append(value)
for field in ('confidence','status','severity'):
    value=dict(good); value[field]='invalid'; bad.append(value)
for value in bad:
    try: jsonschema.validate(value,schema)
    except jsonschema.ValidationError: continue
    raise AssertionError(value)
PY

t_case "the workflow's actual aggregator preserves ranking and disposition metadata losslessly"
cat > "$W/aggregate-test.js" <<'JS'
const fs=require('fs')
const source=fs.readFileSync(process.argv[2],'utf8')
const match=source.match(/const aggregateReviewArtifact = \(panel, taskSlug\) => \(\{[\s\S]*?\n\}\)/)
if (!match) throw new Error('aggregateReviewArtifact helper not found')
eval(match[0] + `
const input=[
 {lens:'correctness',verdict:'approved',findings:[{severity:'low',confidence:'high',location:'a:1',issue:'one',suggested_fix:'x',status:'fixed'}]},
 {lens:'security_privacy',verdict:'changes_requested',findings:[{severity:'blocker',confidence:'medium',location:'b:2',issue:'two',suggested_fix:'y',status:'open'}]}
]
const got=aggregateReviewArtifact(input,'task')
if (got.task_slug!=='task' || got.verdict!=='changes_requested') throw new Error(JSON.stringify(got))
if (got.reviewers.join(',')!=='correctness,security_privacy') throw new Error(JSON.stringify(got))
const want=[
 {lens:'correctness',severity:'low',confidence:'high',location:'a:1',issue:'one',suggested_fix:'x',status:'fixed'},
 {lens:'security_privacy',severity:'blocker',confidence:'medium',location:'b:2',issue:'two',suggested_fix:'y',status:'open'}
]
if (JSON.stringify(got.findings)!==JSON.stringify(want)) throw new Error(JSON.stringify(got))
`)
JS
assert_ok "canonical result round-trips every finding field" node "$W/aggregate-test.js" "$WORKFLOW"

t_case "per-field mutations on every contract surface make the alignment check fail"
fields='lens severity confidence location issue suggested_fix status'
for field in $fields; do
  mt="$W/template-$field.yaml"; cp "$TEMPLATE" "$mt"
  python3 - "$mt" "$field" <<'PY'
import sys,yaml
p,field=sys.argv[1:]; d=yaml.safe_load(open(p)); d['findings'][0].pop(field); yaml.safe_dump(d,open(p,'w'),sort_keys=False)
PY
  assert_fail "template mutation removes $field" contract_check "$mt" "$ROLE" "$WORKFLOW"

  mr="$W/role-$field.md"; cp "$ROLE" "$mr"
  python3 - "$mr" "$field" <<'PY'
import sys
p,field=sys.argv[1:]; s=open(p).read(); s=s.replace(field.replace('_',' '),'REMOVED').replace(field,'REMOVED'); open(p,'w').write(s)
PY
  assert_fail "role mutation removes $field" contract_check "$TEMPLATE" "$mr" "$WORKFLOW"

  mw="$W/workflow-$field.js"; cp "$WORKFLOW" "$mw"
  python3 - "$mw" "$field" <<'PY'
import sys
p,field=sys.argv[1:]; s=open(p).read(); s=s.replace(field,'REMOVED'); open(p,'w').write(s)
PY
  assert_fail "workflow mutation removes $field" contract_check "$TEMPLATE" "$ROLE" "$mw"
done

t_summary
