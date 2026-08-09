#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FINAL="$BIN/firm-final-qa-check"
NEW="$BIN/firm-new-run"

write_verdict() { # path verdict [blocker]
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys
path, verdict, blocker = sys.argv[1:]
d = {
  "verdict": verdict, "commit_sha": "abc1234", "environment": "test",
  "commands_run": [{"cmd":"tests", "exit_code":0, "duration_s":1, "artifact":"09-test-evidence/test.log"}],
  "unit":{"status":"pass","evidence":"09-test-evidence/test.log"},
  "integration":{"status":"not_applicable","evidence":"none"},
  "e2e":{"status":"not_applicable","evidence":"none"},
  "visual":{"status":"not_applicable","evidence":"none"},
  "acceptance_criteria_coverage":[{"id":"AC-001","covered":"yes","evidence":"tests"}],
  "untested_risks":[], "blockers":([blocker] if blocker else []), "warnings":[],
  "artifacts":["09-test-evidence/test.log"], "summary":"fixture"
}
json.dump(d, open(path, "w"), indent=2)
PY
}

mk_qa_run() { # provider -> repo|run
  _repo="$(mk_repo)"
  _rel="$(cd "$_repo" && "$NEW" --primary "$1" qa-matrix fast_path)"
  _run="$_repo/$_rel"
  printf 'criteria:\n  - id: AC-001\n    description: fixture\n    type: functional\n    verification: automated_test\nexplicitly_out_of_scope: []\n' > "$_run/01-acceptance-criteria.yaml"
  mkdir -p "$_run/09-test-evidence"
  printf 'ok\n' > "$_run/09-test-evidence/test.log"
  write_verdict "$_run/08-qa-verdict.json" APPROVE
  printf '%s|%s' "$_repo" "$_run"
}

trace_case() { # run provider status required granted record mode
  python3 - "$@" <<'PY'
import sys, yaml
run, provider, status, required, granted, record, mode = sys.argv[1:]
d = {
 "task_slug":"fixture",
 "matrix":[{"id":"AC-001","implementation_files":["src/x"],"tests":["test/x"],"manual_verification":"","evidence":"09-test-evidence/test.log","status":"covered"}],
 "two_voice":{"secondary_provider":provider,"status":status,"required":required=="true","human_waiver":{"granted":granted=="true","record":record}},
 "two_voice_diff":[]
}
blocker = "secondary found a defect"
if mode != "none":
  risk = "high" if mode == "high-proceed" else "low"
  attempted = mode in ("low-after", "low-after-no-evidence")
  resolution_evidence = "" if mode == "low-after-no-evidence" else ("09-test-evidence/resolution.md" if attempted else "")
  d["two_voice_diff"]=[{
    "secondary_blocker":blocker,
    "primary_position":"Primary QA reads the cited evidence differently",
    "positive_dissent": mode not in ("no-dissent", "proceed-no-dissent"),
    "risk":risk,
    "bounded_resolution":{"attempted":attempted,"rerun":"block" if attempted else "not_run","evidence":resolution_evidence},
    "evidence":"09-test-evidence/test.log",
    "disposition":"unresolved" if mode in ("no-dissent","low-before") else "proceed_with_primary"
  }]
with open(run + "/traceability.yaml", "w") as f: yaml.safe_dump(d, f, sort_keys=False)
PY
}

t_case "both providers approve"
pair="$(mk_qa_run claude)"; run="${pair#*|}"
write_verdict "$run/08-qa-verdict.gpt.json" APPROVE
trace_case "$run" gpt available false false "" none
assert_rc "both approve -> pass" 0 "$FINAL" "$run"

t_case "secondary verdict is checked against the same acceptance criteria"
pair="$(mk_qa_run claude)"; run="${pair#*|}"
write_verdict "$run/08-qa-verdict.gpt.json" APPROVE
python3 - "$run/08-qa-verdict.gpt.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["acceptance_criteria_coverage"][0]["id"]="AC-WRONG"
json.dump(d, open(p,"w"), indent=2)
PY
trace_case "$run" gpt available false false "" none
assert_rc "mismatched secondary traceability cannot evaluate" 2 "$FINAL" "$run"

t_case "secondary BLOCK with no dissent"
pair="$(mk_qa_run claude)"; run="${pair#*|}"
write_verdict "$run/08-qa-verdict.gpt.json" BLOCK "secondary found a defect"
trace_case "$run" gpt available false false "" no-dissent
assert_rc "no dissent keeps the block" 1 "$FINAL" "$run"

t_case "high-risk dissent remains blocking"
pair="$(mk_qa_run codex)"; run="${pair#*|}"
write_verdict "$run/08-qa-verdict.claude.json" BLOCK "secondary found a defect"
trace_case "$run" claude available false false "" high-proceed
assert_rc "high-risk proceed-on-primary forbidden" 1 "$FINAL" "$run"

t_case "low-risk dissent needs one bounded round"
pair="$(mk_qa_run codex)"; run="${pair#*|}"
write_verdict "$run/08-qa-verdict.claude.json" BLOCK "secondary found a defect"
trace_case "$run" claude available false false "" low-before
assert_rc "before bounded resolution -> block" 1 "$FINAL" "$run"
trace_case "$run" claude available false false "" low-after
assert_rc "after bounded resolution -> pass on primary" 0 "$FINAL" "$run"

t_case "primary QA BLOCK always blocks"
pair="$(mk_qa_run claude)"; run="${pair#*|}"
write_verdict "$run/08-qa-verdict.json" BLOCK "primary found a defect"
write_verdict "$run/08-qa-verdict.gpt.json" APPROVE
trace_case "$run" gpt available false false "" none
assert_rc "secondary cannot clear primary BLOCK" 1 "$FINAL" "$run"

t_case "required unavailable reviewer needs a human waiver"
pair="$(mk_qa_run codex)"; run="${pair#*|}"
trace_case "$run" claude unavailable true false "" none
assert_rc "no waiver -> block" 1 "$FINAL" "$run"
trace_case "$run" claude unavailable true true "10-handoff.md#judge-waiver" none
assert_rc "recorded waiver -> pass" 0 "$FINAL" "$run"

t_case "invalid or missing gate inputs cannot evaluate"
pair="$(mk_qa_run claude)"; run="${pair#*|}"
printf '{bad json\n' > "$run/08-qa-verdict.json"
assert_rc "invalid primary verdict -> cannot evaluate" 2 "$FINAL" "$run"

pair="$(mk_qa_run claude)"; run="${pair#*|}"
rm -f "$run/traceability.yaml"
assert_rc "missing traceability -> cannot evaluate" 2 "$FINAL" "$run"

pair="$(mk_qa_run codex)"; run="${pair#*|}"
python3 - "$run/run-metadata.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["primary_provider"]="other"
json.dump(d, open(p,"w"))
PY
assert_rc "invalid primary provider metadata -> cannot evaluate" 2 "$FINAL" "$run"

t_case "missing secondary verdict fails closed in every recorded state"
pair="$(mk_qa_run codex)"; run="${pair#*|}"
trace_case "$run" claude available false false "" none
assert_rc "missing verdict recorded available -> block" 1 "$FINAL" "$run"
trace_case "$run" claude unavailable false false "" none
assert_rc "optional unavailable secondary with explicit state -> pass" 0 "$FINAL" "$run"
trace_case "$run" claude unavailable false false "" low-after
assert_rc "missing verdict cannot carry blocker dispositions" 2 "$FINAL" "$run"

t_case "secondary blocker closure is exact and evidence-bearing"
pair="$(mk_qa_run codex)"; run="${pair#*|}"
write_verdict "$run/08-qa-verdict.claude.json" BLOCK "different blocker"
trace_case "$run" claude available false false "" low-after
assert_rc "one disposition per exact blocker is required" 1 "$FINAL" "$run"

write_verdict "$run/08-qa-verdict.claude.json" BLOCK "secondary found a defect"
trace_case "$run" claude available false false "" proceed-no-dissent
assert_rc "proceed-on-primary requires positive dissent" 1 "$FINAL" "$run"
trace_case "$run" claude available false false "" low-after-no-evidence
assert_rc "bounded resolution requires evidence" 1 "$FINAL" "$run"

t_case "historical run without provider metadata defaults Claude-first"
pair="$(mk_qa_run claude)"; run="${pair#*|}"
rm -f "$run/run-metadata.json"
python3 - "$run/run.jsonl" <<'PY'
import json, sys
p=sys.argv[1]; lines=[]
for line in open(p):
    d=json.loads(line); d.pop("primary_provider", None); lines.append(json.dumps(d))
open(p,"w").write("\n".join(lines)+"\n")
PY
write_verdict "$run/08-qa-verdict.gpt.json" APPROVE
trace_case "$run" gpt available false false "" none
assert_rc "legacy default chooses GPT secondary" 0 "$FINAL" "$run"

t_summary
