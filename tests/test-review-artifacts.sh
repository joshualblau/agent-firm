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

cat > "$W/current-contract.js" <<'JS'
const fs=require('fs')
const source=fs.readFileSync(process.argv[2],'utf8')
const sm=source.match(/export const REVIEW_SCHEMA = (\{[\s\S]*?\n\})\n\nexport const aggregateReviewArtifact/)
if (!sm) throw new Error('exported REVIEW_SCHEMA not found')
const REVIEW_SCHEMA=eval(`(${sm[1]})`)
const am=source.match(/export const aggregateReviewArtifact = \(panel, taskSlug\) => \(\{[\s\S]*?\n\}\)/)
if (!am) throw new Error('exported aggregateReviewArtifact not found')
const aggregateReviewArtifact=eval(`(${am[0].replace('export const aggregateReviewArtifact = ','')})`)
const input=JSON.parse(fs.readFileSync(0,'utf8'))
process.stdout.write(JSON.stringify({schema:REVIEW_SCHEMA,aggregate:aggregateReviewArtifact(input.panel,input.task_slug)}))
JS

cat > "$W/current-artifact-check.py" <<'PY'
import hashlib,json,pathlib,subprocess,sys,yaml,jsonschema
run,workflow,helper=map(pathlib.Path,sys.argv[1:])
expected={
 '07-review-findings.R02.yaml':(26743,'99291f6d350d6157a7df1a948791cf4ef068e59ff95c61e8b92d73c9a33701de'),
 '07-review-correctness.R02.yaml':(20442,'f9662ce9cdf7f8e5cf6bfe9a5aff9f3002b2b31d01e0e728cd94a71458192541'),
 '07-review-security.R02.yaml':(10051,'2e3b0d476b07ecf9631da18fb59dea4263b3ca4c171706dc1d76955408442522'),
 '07-review-compatibility.R02.yaml':(12854,'7ecb5b0dcd12019b13558192a0cfc285d6e2fe0795879a4299a3035e2d5cf351'),
 '07-review-test-quality.R02.yaml':(15572,'c53693da2af59b897e2a65f1b42b81048114dbe790bb3b9fcaad0c0f8c25ada3'),
}
before={name:(run/name).read_bytes() for name in expected}
for name,(size,sha) in expected.items():
 data=before[name]
 assert len(data)==size,(name,len(data),size)
 assert hashlib.sha256(data).hexdigest()==sha,(name,hashlib.sha256(data).hexdigest(),sha)
docs={name:yaml.safe_load(data) for name,data in before.items()}
canonical=docs['07-review-findings.R02.yaml']
sources=canonical['source_lenses']
assert len(sources)==4 and len({entry['path'] for entry in sources})==4,sources
assert canonical['synthesis_method']['raw_open_findings']==19
required=['severity','confidence','location','issue','suggested_fix','status']
panel=[]
expected_flat=[]
for source in sources:
 name=source['path']; assert name in expected and name!='07-review-findings.R02.yaml',name
 raw=before[name]
 assert source['bytes']==len(raw) and source['sha256']==hashlib.sha256(raw).hexdigest(),source
 doc=docs[name]
 findings=doc.get('findings',doc.get('build_findings'))
 assert isinstance(findings,list) and source['raw_open_findings']==sum(item.get('status')=='open' for item in findings),(name,source,findings)
 projected=[]
 for finding in findings:
  item={field:finding[field] for field in required}
  assert set(item)==set(required)
  projected.append(item)
 review={'lens':source['lens'],'verdict':doc['verdict'],'findings':projected}
 panel.append(review)
 expected_flat.extend([{'lens':source['lens'],**item} for item in projected])
payload=json.dumps({'task_slug':canonical['task_slug'],'panel':panel},separators=(',',':'))
done=subprocess.run(['node',str(helper),str(workflow)],input=payload,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
assert done.returncode==0,done.stderr
runtime=json.loads(done.stdout); schema=runtime['schema']; aggregate=runtime['aggregate']
for review in panel: jsonschema.validate(review,schema)
expected_aggregate={
 'task_slug':canonical['task_slug'],
 'reviewers':[source['lens'] for source in sources],
 'findings':expected_flat,
 'verdict':canonical['verdict'],
}
assert canonical['verdict']=='changes_requested'
assert aggregate==expected_aggregate,(aggregate,expected_aggregate)
assert len(aggregate['findings'])==sum(len(review['findings']) for review in panel)==19
after={name:(run/name).read_bytes() for name in expected}
assert before==after,'current review input bytes changed during validation'
print('CURRENT_R02_CONTRACT_PASS canonical=1 lenses=4 projected_findings=19 input_bytes_unchanged=yes')
PY

discover_current_r02_run() {
  if [ -n "${FIRM_R02_REVIEW_RUN:-}" ]; then printf '%s\n' "$FIRM_R02_REVIEW_RUN"; return; fi
  _common="$(git -C "$FIRM_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$_common" in /*) : ;; *) _common="$FIRM_ROOT/$_common" ;; esac
  _repo="$(cd "$(dirname "$_common")" 2>/dev/null && pwd)" || return 0
  _found=""
  for _candidate in "$_repo"/.agent-firm/runs/*; do
    [ -f "$_candidate/07-review-findings.R02.yaml" ] || continue
    _sha="$(shasum -a 256 "$_candidate/07-review-findings.R02.yaml" | awk '{print $1}')"
    [ "$_sha" = 99291f6d350d6157a7df1a948791cf4ef068e59ff95c61e8b92d73c9a33701de ] || continue
    [ -z "$_found" ] || return 1
    _found="$_candidate"
  done
  printf '%s\n' "$_found"
}

t_case "current canonical aggregate and all four current R-02 lenses use the production contract"
CURRENT_R02_RUN="$(discover_current_r02_run)"; current_discovery_rc=$?
if [ "$current_discovery_rc" -ne 0 ]; then
  _t_no "exactly one current R-02 input set is discoverable" "multiple digest-matching runs"
elif [ -n "$CURRENT_R02_RUN" ]; then
  assert_ok "actual current inputs bind, validate, aggregate losslessly, and remain byte-identical" \
    python3 "$W/current-artifact-check.py" "$CURRENT_R02_RUN" "$WORKFLOW" "$W/current-contract.js"
else
  _t_ok "portable checkout has no current R-02 run; no synthetic artifact was substituted (set FIRM_R02_REVIEW_RUN for engagement proof)"
fi

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
const implementation=(id,result='green')=>({work_order:id,branch:`wt/${id}`,files_changed:[],tests_added:[],test_result:result,summary:'ok'})
const integration=(result='green')=>({status:result,branch:'integration/fixture',conflicts_resolved:[],test_result:result,summary:'ok'})
const review=(lens,verdict='approved')=>({lens,verdict,findings:verdict==='approved'?[]:[{severity:'medium',confidence:'high',location:'x:1',issue:'change',suggested_fix:'fix',status:'open'}]})
async function run(track,scenario='clean',single=false) {
  const state={phases:[],build:0,integrate:0,review:0,qa:0}
  const work_orders=single?[{id:'wo1',brief:'fixture'}]:[{id:'wo1',brief:'fixture'},{id:'wo2',brief:'fixture'}]
  const args={run_dir:'.agent-firm/runs/fixture',task_slug:'fixture',track,work_orders,review_lenses:['correctness','security_privacy']}
  if (scenario==='build-empty') args.work_orders=[]
  if (scenario==='review-empty-input') args.review_lenses=[]
  if (scenario==='review-duplicate-input') args.review_lenses=['correctness','correctness']
  const phase=x=>state.phases.push(x)
  const log=()=>{}
  const parallel=async tasks=>{
    const results=await Promise.all(tasks.map(task=>task()))
    if (scenario==='review-duplicate' && state.phases[state.phases.length-1]==='Review') return [...results,results[0]]
    return results
  }
  const agent=async (_prompt,options)=>{
    if (options.agentType==='implementer') {
      const index=state.build++
      const id=options.label.slice(6)
      if (scenario==='build-rejected') throw new Error('fixture rejection')
      if (scenario==='build-null' || (scenario==='build-partial' && index===1)) return null
      if (scenario==='build-malformed') return {work_order:id,test_result:'green'}
      if (scenario==='build-duplicate' && index===1) return implementation('wo1')
      if (scenario==='build-mismatch') return implementation(`wrong-${id}`)
      if (scenario==='build-red') return implementation(id,'red')
      if (scenario==='build-blocked') return implementation(id,'blocked')
      return implementation(id)
    }
    if (options.agentType==='integrator') {
      state.integrate+=1
      if (scenario==='integration-rejected') throw new Error('fixture rejection')
      if (scenario==='integration-null') return null
      if (scenario==='integration-malformed') return {status:'green'}
      if (scenario==='integration-red') return integration('red')
      if (scenario==='integration-blocked') return integration('blocked')
      return integration()
    }
    if (options.agentType==='reviewer') {
      const index=state.review++
      const lens=options.label.slice(7)
      if (scenario==='review-rejected') throw new Error('fixture rejection')
      if (scenario==='review-null' || (scenario==='review-partial' && (track==='fast_path' || index===1))) return null
      if (scenario==='review-malformed') return {lens,verdict:'approved'}
      if (scenario==='review-duplicate' && index===1) return review('correctness')
      if (scenario==='review-mismatch') return review(`wrong-${lens}`)
      if (scenario==='review-changes') return review(lens,'changes_requested')
      return review(lens)
    }
    if (options.agentType==='qa-tester') { state.qa+=1; return {verdict:'APPROVE'} }
    throw new Error(options.agentType)
  }
  const execute=new AsyncFunction('args','phase','log','parallel','agent',source)
  return {result:await execute(args,phase,log,parallel,agent),state}
}
(async()=>{
  for (const track of ['full_track','fast_path']) {
    for (const scenario of ['build-empty','build-rejected','build-null','build-partial','build-malformed','build-duplicate','build-mismatch','build-red','build-blocked']) {
      const blocked=await run(track,scenario)
      if (blocked.result.status!=='build_blocked' || blocked.result.failed_stage!=='Build' || blocked.result.qa!==null || blocked.state.integrate!==0 || blocked.state.review!==0 || blocked.state.qa!==0 || blocked.state.phases.includes('Test')) throw new Error(JSON.stringify({track,scenario,blocked}))
    }
    for (const scenario of ['integration-rejected','integration-null','integration-malformed','integration-red','integration-blocked']) {
      const blocked=await run(track,scenario)
      if (blocked.result.status!=='integration_blocked' || blocked.result.failed_stage!=='Integrate' || blocked.result.qa!==null || blocked.state.review!==0 || blocked.state.qa!==0 || blocked.state.phases.includes('Test')) throw new Error(JSON.stringify({track,scenario,blocked}))
    }
    for (const scenario of ['review-rejected','review-null','review-partial','review-malformed','review-duplicate','review-mismatch','review-changes']) {
      const blocked=await run(track,scenario)
      if (blocked.result.status!=='review_blocked' || blocked.result.failed_stage!=='Review' || blocked.result.qa!==null || blocked.state.qa!==0 || blocked.state.phases.includes('Test')) throw new Error(JSON.stringify({track,scenario,blocked}))
    }
    const clean=await run(track)
    if (clean.result.status!=='qa_complete' || clean.state.qa!==1 || clean.state.phases.filter(x=>x==='Test').length!==1) throw new Error(JSON.stringify({track,clean}))
  }
  for (const scenario of ['review-empty-input','review-duplicate-input']) {
    const blocked=await run('full_track',scenario)
    if (blocked.result.status!=='build_blocked' || blocked.result.qa!==null || blocked.state.build!==0 || blocked.state.qa!==0) throw new Error(JSON.stringify({scenario,blocked}))
  }
  const fastSingle=await run('fast_path','clean',true)
  if (fastSingle.result.status!=='qa_complete' || fastSingle.state.integrate!==0 || fastSingle.state.qa!==1) throw new Error(JSON.stringify({fastSingle}))
  const fullSingle=await run('full_track','clean',true)
  if (fullSingle.result.status!=='qa_complete' || fullSingle.state.integrate!==1 || fullSingle.state.qa!==1) throw new Error(JSON.stringify({fullSingle}))
})().catch(error=>{console.error(error);process.exit(1)})
JS

t_case "full_track and fast_path require exact green Build, required Integrator, and Review panels"
assert_ok "null/rejected/red/blocked/duplicate/malformed/partial/empty stage states never enter Test" \
  node "$W/workflow-harness.js" "$WORKFLOW"

t_summary
