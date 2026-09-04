#!/bin/sh
set -eu
test -f src/value.txt
test "$(cat src/value.txt)" = sealed
run_rel="$(cat .agent-firm/CURRENT_RUN)"
run="$(pwd)/$run_rel"
test -f "$run/09-test-evidence/final-evidence/g1/seal.json"
test -f "$run/09-test-evidence/final-evidence/g1/privacy.json"
test -f "$run/09-test-evidence/final-evidence/g1/complete-local-pr-body.md"
firm-seal-qa-evidence --verify --run "$run" --phase publication >/dev/null
python3 - "$run" <<'PY'
import hashlib,json,pathlib,sys
run=pathlib.Path(sys.argv[1]); seal_path=run/'09-test-evidence/final-evidence/g1/seal.json'
raw=seal_path.read_bytes(); seal=json.loads(raw)
assert raw == (json.dumps(seal,ensure_ascii=True,sort_keys=True,separators=(',',':'))+'\n').encode()
paths=[item['path'] for item in seal['entries']]
assert paths == sorted(paths) == seal['ordinary_declared_paths'] == seal['ordinary_resolved_paths']
assert len(paths)==seal['ordinary_declared_count']==seal['ordinary_resolved_count']
assert seal['self_count']==1 and seal['total_count']==len(paths)+1
assert seal['unresolved']==seal['excluded']==[]
assert seal['privacy']['duration_ms'] >= 0
privacy=(run/seal['privacy']['report_path']).read_bytes()
assert len(privacy)==seal['privacy']['report_bytes']
assert hashlib.sha256(privacy).hexdigest()==seal['privacy']['report_sha256']
ledger=[json.loads(line) for line in (run/'run.jsonl').read_text().splitlines()]
publish=[row for row in ledger if row.get('event')=='evidence_seal_published']
assert len(publish)==1 and publish[0]['event_id']==seal['ledger']['publication']['event_id']
starts=[row for row in ledger if row.get('event')=='reviewer_attempt_started']
terminals=[row for row in ledger if row.get('event') in {'reviewer_approve','reviewer_block','reviewer_invalid','reviewer_timeout','reviewer_unavailable'}]
assert starts and terminals and starts[-1]['attempt_id']==terminals[-1]['attempt_id']
assert starts[-1]['seal_event_id']==terminals[-1]['seal_event_id']==publish[0]['event_id']
required={'ac007_opted_in_no_fallback','ac007_partial_no_fallback','ac007_both_provider_sealed',
 'ac007_privacy_category_misuse','ac007_privacy_surface_misuse','ac007_placeholder_argv',
 'ac007_unexpected_ledger_append','ac007_producer_window_defect',
 'ac007_integration_index_duplicate','ac007_integration_index_malformed',
 'ac007_pr_marker_malformed','ac007_seal_tamper','ac007_evidence_tamper',
 'ac007_synchronized_toctou','ac007_genuine_legacy_reviewable'}
manifest_path=run/'09-test-evidence/mutation-evidence/ac007-manifest.json'
manifest_raw=manifest_path.read_bytes(); manifest=json.loads(manifest_raw)
assert manifest_raw == (json.dumps(manifest,ensure_ascii=True,sort_keys=True,separators=(',',':'))+'\n').encode()
assert manifest['schema_version']==1 and manifest['kind']=='mutation_matrix_manifest'
assert manifest['criterion']=='AC-007' and manifest['run_id']==run.name
families=[item['family'] for item in manifest['families']]
assert sorted(families)==sorted(required) and len(families)==len(required)
published={row['path']:row for row in ledger if row.get('event')=='evidence_produced'}
successes=[]
for item in manifest['families']:
    payload=(run/item['path']).read_bytes()
    assert item['bytes']==len(payload)==int(published[item['path']]['bytes'])
    assert item['sha256']==hashlib.sha256(payload).hexdigest()==published[item['path']]['sha256']
    assert published[item['path']]['sha']==manifest['candidate_sha']
    assert published[item['path']]['generation']==str(manifest['generation'])
    assert item['producer']['event_id']==published[item['path']]['event_id']
    record=json.loads(payload)
    assert record['family']==item['family'] and record['criterion']=='AC-007'
    assert record['observed_category']==record['expected_category']==item['expected_category']
    assert not record['seal_published'] and not record['partial_generation_present']
    assert record['ledger_prefix_before']==record['ledger_prefix_after']
    assert record['provider_calls_before']==record['provider_calls_after']
    if record['legacy_success']:
        successes.append(item['family'])
assert successes==['ac007_genuine_legacy_reviewable']
assert manifest_path.as_posix().endswith('ac007-manifest.json')
assert published['09-test-evidence/mutation-evidence/ac007-manifest.json']['sha256']==hashlib.sha256(manifest_raw).hexdigest()
PY
