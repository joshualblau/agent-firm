#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GPT="$BIN/firm-gpt-qa"
CLAUDE="$BIN/firm-claude-qa"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-reviewers.XXXXXX")"; t_track "$WORK"
RUN="$WORK/run"; mkdir -p "$RUN/09-test-evidence"
STUB="$WORK/stub"; mkdir -p "$STUB"
CALLS="$WORK/calls.log"; : > "$CALLS"

python3 - "$WORK" <<'PY'
import json, os, sys
w=sys.argv[1]
base={
 "commit_sha":"abc1234","environment":"test","commands_run":[],
 "unit":{"status":"pass","evidence":"test"},"integration":{"status":"not_applicable","evidence":"none"},
 "e2e":{"status":"not_applicable","evidence":"none"},"visual":{"status":"not_applicable","evidence":"none"},
 "acceptance_criteria_coverage":[],"untested_risks":[],"warnings":[],"artifacts":[],"summary":"fixture"
}
for verdict in ("APPROVE","BLOCK"):
 d=dict(base); d["verdict"]=verdict; d["blockers"]=([] if verdict=="APPROVE" else ["fixture blocker"])
 json.dump(d, open(os.path.join(w, verdict.lower()+".json"),"w"))
PY

# Stubs use only absolute system tools so PATH can exclude the real provider CLIs.
cat > "$STUB/codex" <<'SH'
#!/bin/sh
printf 'judge=%s codex %s\n' "${FIRM_QA_JUDGE:-unset}" "$*" >> "$STUB_CALLS"
case "$1" in
  --help) exit 0 ;;
esac
case "$STUB_MODE" in
  auth) echo 'not logged in; login required' >&2; exit 1 ;;
  incompatible) echo 'unsupported model' >&2; exit 1 ;;
esac
case " $* " in
  *" reply with: ok "*) echo ok; exit 0 ;;
esac
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && { shift; out="$1"; }; shift; done
case "$STUB_MODE" in
  timeout) /bin/sleep 2; exit 0 ;;
  malformed) printf '{bad json\n' > "$out"; exit 0 ;;
  generic400) echo 'HTTP 400 malformed request' >&2; exit 1 ;;
  block) /bin/cp "$STUB_BLOCK" "$out" ;;
  *) /bin/cp "$STUB_APPROVE" "$out" ;;
esac
exit 0
SH
cat > "$STUB/claude" <<'SH'
#!/bin/sh
printf 'judge=%s claude %s\n' "${FIRM_QA_JUDGE:-unset}" "$*" >> "$STUB_CALLS"
if [ "$1 $2" = "auth status" ]; then
  [ "$STUB_MODE" = auth ] && { echo 'not authenticated' >&2; exit 1; }
  echo authenticated; exit 0
fi
case "$STUB_MODE" in
  incompatible) echo 'unknown model' >&2; exit 1 ;;
  timeout) /bin/sleep 2; exit 0 ;;
  malformed) printf 'not-json\n'; exit 0 ;;
  generic400) echo 'HTTP 400 malformed request' >&2; exit 1 ;;
esac
src="$STUB_APPROVE"; [ "$STUB_MODE" = block ] && src="$STUB_BLOCK"
/usr/bin/python3 - "$src" <<'PY'
import json, sys
print(json.dumps({"structured_output":json.load(open(sys.argv[1]))}))
PY
SH
chmod +x "$STUB/codex" "$STUB/claude"

review_env() {
  env PATH="$STUB:/usr/bin:/bin" STUB_MODE="$1" STUB_APPROVE="$WORK/approve.json" STUB_BLOCK="$WORK/block.json" STUB_CALLS="$CALLS" \
    FIRM_GPT_QA_PREFLIGHT_TIMEOUT=2 FIRM_GPT_QA_TIMEOUT="${2:-3}" FIRM_CLAUDE_QA_TIMEOUT="${2:-3}" "$3" "$RUN"
}

t_case "GPT reviewer exit contract"
assert_rc "schema-valid APPROVE exits 0" 0 review_env approve 3 "$GPT"
assert_rc "schema-valid BLOCK exits 1" 1 review_env block 3 "$GPT"
assert_rc "malformed structured output exits 1" 1 review_env malformed 3 "$GPT"
assert_rc "timeout exits 1" 1 review_env timeout 1 "$GPT"
assert_rc "incompatible model exits 3" 3 review_env incompatible 3 "$GPT"
assert_rc "unavailable authentication exits 3" 3 review_env auth 3 "$GPT"
assert_rc "generic HTTP 400 remains a blocking failure" 1 review_env generic400 3 "$GPT"
assert_rc "missing CLI exits 3" 3 env PATH="/usr/bin:/bin" "$GPT" "$RUN"

t_case "Claude reviewer exit contract"
assert_rc "schema-valid APPROVE exits 0" 0 review_env approve 3 "$CLAUDE"
assert_rc "schema-valid BLOCK exits 1" 1 review_env block 3 "$CLAUDE"
assert_rc "malformed structured output exits 1" 1 review_env malformed 3 "$CLAUDE"
assert_rc "timeout exits 1" 1 review_env timeout 1 "$CLAUDE"
assert_rc "incompatible model exits 3" 3 review_env incompatible 3 "$CLAUDE"
assert_rc "unavailable authentication exits 3" 3 review_env auth 3 "$CLAUDE"
assert_rc "generic HTTP 400 remains a blocking failure" 1 review_env generic400 3 "$CLAUDE"
assert_rc "forced incompatible model exits 3" 3 env PATH="$STUB:/usr/bin:/bin" STUB_MODE=approve STUB_APPROVE="$WORK/approve.json" STUB_BLOCK="$WORK/block.json" STUB_CALLS="$CALLS" FIRM_CLAUDE_QA_FORCE_INCOMPAT=1 "$CLAUDE" "$RUN"
assert_rc "missing CLI exits 3" 3 env PATH="/usr/bin:/bin" "$CLAUDE" "$RUN"

t_case "reviewer security posture is passed to the actual provider command"
: > "$CALLS"
assert_ok "GPT approval run succeeds" review_env approve 3 "$GPT"
assert_output "GPT judge mode is set" "judge=1 codex" cat "$CALLS"
assert_output "GPT uses the read-only Codex sandbox" "-s read-only -a never" cat "$CALLS"
assert_output "GPT uses an ephemeral session" "--ephemeral" cat "$CALLS"
assert_output "GPT requests schema-constrained output" "--output-schema" cat "$CALLS"

: > "$CALLS"
assert_ok "Claude approval run succeeds" review_env approve 3 "$CLAUDE"
assert_output "Claude judge mode is set" "judge=1 claude" cat "$CALLS"
assert_output "Claude allows only read/search tools" "--tools Read,Grep,Glob" cat "$CALLS"
assert_output "Claude explicitly disables Bash and write tools" "--disallowedTools Edit,Write,Bash" cat "$CALLS"
assert_output "Claude disables session persistence" "--no-session-persistence" cat "$CALLS"
assert_ok "Claude command does not allow Bash" sh -c "! grep -q -- '--tools Read,Grep,Glob,Bash' '$CALLS'"

t_case "canonical verdict lifecycle is fresh and validated"
cp "$WORK/approve.json" "$RUN/08-qa-verdict.gpt.json"
assert_rc "GPT preflight failure removes a stale canonical verdict" 3 review_env auth 3 "$GPT"
assert_no_file "stale GPT approval is absent after preflight failure" "$RUN/08-qa-verdict.gpt.json"
cp "$WORK/approve.json" "$RUN/08-qa-verdict.gpt.json"
assert_rc "failed GPT rerun removes a stale canonical verdict" 1 review_env malformed 3 "$GPT"
assert_no_file "stale GPT approval is absent after failure" "$RUN/08-qa-verdict.gpt.json"
assert_rc "valid GPT BLOCK is promoted even though command exits 1" 1 review_env block 3 "$GPT"
assert_output "canonical GPT verdict is the fresh BLOCK" '"verdict": "BLOCK"' cat "$RUN/08-qa-verdict.gpt.json"

cp "$WORK/approve.json" "$RUN/08-qa-verdict.claude.json"
assert_rc "Claude preflight failure removes a stale canonical verdict" 3 review_env auth 3 "$CLAUDE"
assert_no_file "stale Claude approval is absent after preflight failure" "$RUN/08-qa-verdict.claude.json"
cp "$WORK/approve.json" "$RUN/08-qa-verdict.claude.json"
assert_rc "failed Claude rerun removes a stale canonical verdict" 1 review_env malformed 3 "$CLAUDE"
assert_no_file "stale Claude approval is absent after failure" "$RUN/08-qa-verdict.claude.json"
assert_rc "valid Claude BLOCK is promoted even though command exits 1" 1 review_env block 3 "$CLAUDE"
assert_output "canonical Claude verdict is the fresh BLOCK" '"verdict": "BLOCK"' cat "$RUN/08-qa-verdict.claude.json"
assert_eq "temporary verdict candidates are cleaned" "" "$(find "$RUN" -maxdepth 1 -name '.qa-verdict.*.candidate.*' -print)"

t_case "attempt logs are fresh and retained"
before="$(find "$RUN/09-test-evidence" -type f -name 'gpt-qa.log.*' | wc -l | tr -d ' ')"
assert_rc "an unavailable attempt is recorded" 3 review_env auth 3 "$GPT"
assert_rc "a later generic 400 is not contaminated by prior auth text" 1 review_env generic400 3 "$GPT"
after="$(find "$RUN/09-test-evidence" -type f -name 'gpt-qa.log.*' | wc -l | tr -d ' ')"
assert_eq "each wrapper attempt has its own retained log" "$((before + 2))" "$after"

t_summary
