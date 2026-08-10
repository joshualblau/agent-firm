#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEMPLATE="$FIRM_ROOT/agent-firm/templates/07-review-findings.yaml"
ROLE="$FIRM_ROOT/agent-firm/contracts/roles/reviewer.md"
WORKFLOW="$FIRM_ROOT/agent-firm/workflows/build-review-test.js"
W="$(mktemp -d "${TMPDIR:-/tmp}/firm-review-artifacts.XXXXXX")"; t_track "$W"

cat > "$W/extract-contract.js" <<'JS'
const fs=require('fs')
const source=fs.readFileSync(process.argv[2],'utf8')
const sm=source.match(/export const REVIEW_SCHEMA = (\{[\s\S]*?\n\})\n\nexport const aggregateReviewArtifact/)
if (!sm) throw new Error('exported REVIEW_SCHEMA not found')
const REVIEW_SCHEMA=eval(`(${sm[1]})`)
const am=source.match(/export const aggregateReviewArtifact = \(panel, taskSlug\) => \(\{[\s\S]*?\n\}\)/)
if (!am) throw new Error('exported aggregateReviewArtifact not found')
eval(am[0].replace('export const ','const ') + `
const panel=[
 {lens:'correctness',verdict:'approved',findings:[{severity:'low',confidence:'high',location:'a:1',issue:'one',suggested_fix:'x',status:'fixed'}]},
 {lens:'security_privacy',verdict:'changes_requested',findings:[{severity:'blocker',confidence:'medium',location:'b:2',issue:'two',suggested_fix:'y',status:'open'}]}
]
process.stdout.write(JSON.stringify({schema:REVIEW_SCHEMA,aggregate:aggregateReviewArtifact(panel,'task')}))
`)
JS

cat > "$W/contract-check.py" <<'PY'
import json,pathlib,subprocess,sys,yaml
template,role,workflow=map(pathlib.Path,sys.argv[1:])
fields=['lens','severity','confidence','location','issue','suggested_fix','status']
doc=yaml.safe_load(template.read_text()); finding=doc['findings'][0]
assert list(finding)==fields, (list(finding),fields)
role_text=role.read_text().lower().replace(' ','_')
for field in fields: assert field in role_text, ('role',field)
extract=pathlib.Path(sys.argv[0]).with_name('extract-contract.js')
contract=json.loads(subprocess.check_output(['node',str(extract),str(workflow)],text=True))
schema=contract['schema']; item=schema['properties']['findings']['items']
assert schema['additionalProperties'] is False
assert schema['required']==['lens','verdict','findings']
assert set(schema['properties'])=={'lens','verdict','findings'}
assert schema['properties']['verdict']['enum']==['approved','changes_requested']
assert item['additionalProperties'] is False
assert item['required']==fields[1:]
assert set(item['properties'])==set(fields[1:])
assert item['properties']['severity']['enum']==['low','medium','high','blocker']
assert item['properties']['confidence']['enum']==['low','medium','high']
assert item['properties']['status']['enum']==['open','accepted','rejected','fixed']
want={'task_slug':'task','reviewers':['correctness','security_privacy'],'findings':[
 {'lens':'correctness','severity':'low','confidence':'high','location':'a:1','issue':'one','suggested_fix':'x','status':'fixed'},
 {'lens':'security_privacy','severity':'blocker','confidence':'medium','location':'b:2','issue':'two','suggested_fix':'y','status':'open'}],
 'verdict':'changes_requested'}
assert contract['aggregate']==want,(contract['aggregate'],want)

# Validate the canonical artifact's reviewer shape against the exact production schema.
import jsonschema
review={'lens':finding.pop('lens'),'verdict':doc['verdict'],'findings':[finding]}
jsonschema.validate(review,schema)
bad=[]
for field in item['required']:
    value=json.loads(json.dumps(review)); value['findings'][0].pop(field); bad.append(value)
value=json.loads(json.dumps(review)); value['findings'][0]['unknown']='x'; bad.append(value)
for field in ('severity','confidence','status'):
    value=json.loads(json.dumps(review)); value['findings'][0][field]='invalid'; bad.append(value)
for field in schema['required']:
    value=json.loads(json.dumps(review)); value.pop(field); bad.append(value)
value=json.loads(json.dumps(review)); value['unknown']='x'; bad.append(value)
value=json.loads(json.dumps(review)); value['verdict']='invalid'; bad.append(value)
for value in bad:
    try: jsonschema.validate(value,schema)
    except jsonschema.ValidationError: continue
    raise AssertionError(value)
PY

contract_check() { python3 "$W/contract-check.py" "$1" "$2" "$3"; }

t_case "template, role, exported production schema, and aggregator share one exact finding contract"
assert_ok "canonical artifact validates through the production schema and projection" \
  contract_check "$TEMPLATE" "$ROLE" "$WORKFLOW"

t_case "real schema inner requirements, strictness, every enum, and projection are mutation-sensitive"
python3 - "$WORKFLOW" "$W" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text(); out=pathlib.Path(sys.argv[2]); mutations={}
mutations['inner-required']=source.replace("required: ['severity', 'confidence', 'location', 'issue', 'suggested_fix', 'status']","required: ['severity', 'confidence', 'location', 'issue', 'suggested_fix']",1)
needle="items: {\n        type: 'object', additionalProperties: false,"
mutations['inner-additional-properties']=source.replace(needle,needle.replace('false','true'),1)
enum_lines={
 'verdict': "verdict: { type: 'string', enum: ['approved', 'changes_requested'] }",
 'severity': "severity: { type: 'string', enum: ['low', 'medium', 'high', 'blocker'] }",
 'confidence': "confidence: { type: 'string', enum: ['low', 'medium', 'high'] }",
 'status': "status: { type: 'string', enum: ['open', 'accepted', 'rejected', 'fixed'] }",
}
for group,values in {'verdict':['approved','changes_requested'],'severity':['low','medium','high','blocker'],'confidence':['low','medium','high'],'status':['open','accepted','rejected','fixed']}.items():
    for value in values:
        line=enum_lines[group]
        mutations[f'enum-{group}-{value}']=source.replace(line,line.replace("'"+value+"'", "'MUTATED_"+value+"'"),1)
mutations['aggregation-projection']=source.replace('({ lens: review.lens, ...finding })','({ lens: review.lens, severity: finding.severity })',1)
for name,text in mutations.items(): (out/(name+'.js')).write_text(text)
PY
for mutated in "$W"/inner-*.js "$W"/enum-*.js "$W"/aggregation-projection.js; do
  assert_fail "$(basename "$mutated") makes the exact production contract check fail" \
    contract_check "$TEMPLATE" "$ROLE" "$mutated"
done

t_case "template and reviewer-role per-field mutations break canonical alignment"
for field in lens severity confidence location issue suggested_fix status; do
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
done

cat > "$W/workflow-harness.js" <<'JS'
const fs=require('fs')
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor
const source=fs.readFileSync(process.argv[2],'utf8').replaceAll('export const ','const ')
async function run(track,blocked) {
  const state={phases:[],qa:0}
  const args={run_dir:'.agent-firm/runs/fixture',task_slug:'fixture',track,work_orders:[{id:'wo1',brief:'fixture'}],review_lenses:['correctness','security_privacy']}
  const phase=x=>state.phases.push(x)
  const log=()=>{}
  const parallel=tasks=>Promise.all(tasks.map(task=>task()))
  const agent=async (_prompt,options)=>{
    if (options.agentType==='implementer') return {work_order:'wo1',branch:'wt/x',files_changed:[],tests_added:[],test_result:'green',summary:'ok'}
    if (options.agentType==='integrator') return {status:'green'}
    if (options.agentType==='reviewer') return {lens:options.label.slice(7),verdict:blocked?'changes_requested':'approved',findings:blocked?[{severity:'high',confidence:'high',location:'x:1',issue:'block',suggested_fix:'fix',status:'open'}]:[]}
    if (options.agentType==='qa-tester') { state.qa+=1; return {verdict:'APPROVE'} }
    throw new Error(options.agentType)
  }
  const execute=new AsyncFunction('args','phase','log','parallel','agent',source)
  return {result:await execute(args,phase,log,parallel,agent),state}
}
(async()=>{
  for (const track of ['full_track','fast_path']) {
    const blocked=await run(track,true)
    if (blocked.result.status!=='review_blocked' || blocked.result.qa!==null || blocked.state.qa!==0 || blocked.state.phases.includes('Test')) throw new Error(JSON.stringify({track,blocked}))
    const clean=await run(track,false)
    if (clean.result.status!=='qa_complete' || clean.state.qa!==1 || clean.state.phases.filter(x=>x==='Test').length!==1) throw new Error(JSON.stringify({track,clean}))
  }
})().catch(error=>{console.error(error);process.exit(1)})
JS

t_case "full_track and fast_path stop before QA on review blockers, then clean runs launch QA once"
assert_ok "mocked production workflow enforces the Review-to-Test boundary in both tracks" \
  node "$W/workflow-harness.js" "$WORKFLOW"

t_summary
