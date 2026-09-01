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
PY
