#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUBLISH="$BIN/firm-integration-summary"
RUN_ID="20260814T000000Z-integration-summary"

publish() {
  _repo="$1"; _stage="$2"; _source="$3"
  ( cd "$_repo" && "$PUBLISH" --stage "$_stage" --source "$_source" )
}

write_draft() {
  _path="$1"; _label="$2"
  printf '# Integration summary\n\n%s\n' "$_label" > "$_path"
  chmod 644 "$_path"
}

t_case "publishes immutable stage summaries and an append-only digest index"
repo="$(mk_repo)"; mk_run "$repo" "$RUN_ID"
run="$repo/.agent-firm/runs/$RUN_ID"
draft1="$repo/int-01.md"; draft2="$repo/int-02.md"
write_draft "$draft1" "first cycle"
write_draft "$draft2" "second cycle"

assert_output "first stage publishes" '"status":"published"' publish "$repo" integrate/INT-01 "$draft1"
assert_file "first immutable summary exists" "$run/integration-summaries/INT-01.md"
assert_file "history index exists" "$run/integration-summaries/index.json"
assert_no_file "publisher does not create the legacy singleton" "$run/integration-summary.md"
first_sha="$(shasum -a 256 "$run/integration-summaries/INT-01.md" | awk '{print $1}')"

assert_output "second stage publishes" '"history_entries":2' publish "$repo" integrate/INT-02 "$draft2"
assert_eq "first stage bytes remain unchanged" "$first_sha" \
  "$(shasum -a 256 "$run/integration-summaries/INT-01.md" | awk '{print $1}')"
assert_ok "index binds both exact summaries in order" python3 - "$run" <<'PY'
import hashlib,json,os,sys
run=sys.argv[1]
d=json.load(open(run+"/integration-summaries/index.json"))
assert d["schema_version"]==1 and d["run_id"]==os.path.basename(run)
assert d["current_stage"]=="integrate/INT-02"
assert [x["stage"] for x in d["entries"]]==["integrate/INT-01","integrate/INT-02"]
for item in d["entries"]:
    raw=open(run+"/"+item["path"],"rb").read()
    assert item["bytes"]==len(raw)
    assert item["sha256"]==hashlib.sha256(raw).hexdigest()
PY
assert_output "exact republish is idempotent" '"status":"unchanged"' \
  publish "$repo" integrate/INT-01 "$draft1"
assert_ok "idempotence does not duplicate or rewind history" python3 - "$run" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]+"/integration-summaries/index.json"))
assert len(d["entries"])==2 and d["current_stage"]=="integrate/INT-02"
PY

t_case "refuses same-stage replacement and historical drift"
replacement="$repo/replacement.md"; draft3="$repo/int-03.md"
write_draft "$replacement" "different first cycle"
write_draft "$draft3" "third cycle"
index_before="$(shasum -a 256 "$run/integration-summaries/index.json" | awk '{print $1}')"
assert_rc "same stage cannot be replaced" 1 publish "$repo" integrate/INT-01 "$replacement"
assert_eq "replacement refusal leaves index unchanged" "$index_before" \
  "$(shasum -a 256 "$run/integration-summaries/index.json" | awk '{print $1}')"

printf '# Integration summary\n\nmutated history\n' > "$run/integration-summaries/INT-01.md"
assert_rc "changed historical bytes block a later publication" 1 \
  publish "$repo" integrate/INT-03 "$draft3"
assert_no_file "blocked publication creates no later summary" "$run/integration-summaries/INT-03.md"
assert_eq "drift rejection leaves index unchanged" "$index_before" \
  "$(shasum -a 256 "$run/integration-summaries/index.json" | awk '{print $1}')"

t_case "missing history and unsafe inputs fail closed"
repo2="$(mk_repo)"; mk_run "$repo2" "$RUN_ID"
run2="$repo2/.agent-firm/runs/$RUN_ID"
draft_a="$repo2/a.md"; draft_b="$repo2/b.md"
write_draft "$draft_a" "A"; write_draft "$draft_b" "B"
assert_ok "fixture first publish" publish "$repo2" integrate/INT-A "$draft_a"
mv "$run2/integration-summaries/INT-A.md" "$repo2/saved-A.md"
assert_rc "missing historical summary blocks" 2 publish "$repo2" integrate/INT-B "$draft_b"
assert_no_file "missing-history rejection creates no B summary" "$run2/integration-summaries/INT-B.md"
mv "$repo2/saved-A.md" "$run2/integration-summaries/INT-A.md"

assert_rc "unsafe stage is rejected" 2 publish "$repo2" integrate/../escape "$draft_b"
ln -s "$draft_b" "$repo2/source-link.md"
assert_rc "symlinked source is rejected" 2 publish "$repo2" integrate/INT-B "$repo2/source-link.md"
chmod 666 "$draft_b"
assert_rc "group/world-writable source is rejected" 2 publish "$repo2" integrate/INT-B "$draft_b"
chmod 644 "$draft_b"

t_case "publication lock prevents lost updates under concurrent stages"
repo3="$(mk_repo)"; mk_run "$repo3" "$RUN_ID"
run3="$repo3/.agent-firm/runs/$RUN_ID"
draft_x="$repo3/x.md"; draft_y="$repo3/y.md"
write_draft "$draft_x" "X"; write_draft "$draft_y" "Y"
( publish "$repo3" integrate/INT-X "$draft_x" >"$repo3/x.out" 2>"$repo3/x.err"; echo $? >"$repo3/x.rc" ) & pid_x=$!
( publish "$repo3" integrate/INT-Y "$draft_y" >"$repo3/y.out" 2>"$repo3/y.err"; echo $? >"$repo3/y.rc" ) & pid_y=$!
wait "$pid_x"; wait "$pid_y"
assert_eq "concurrent X publish exits zero" 0 "$(cat "$repo3/x.rc")"
assert_eq "concurrent Y publish exits zero" 0 "$(cat "$repo3/y.rc")"
assert_ok "concurrent publications retain both exact entries" python3 - "$run3" <<'PY'
import hashlib,json,sys
run=sys.argv[1]; d=json.load(open(run+"/integration-summaries/index.json"))
assert len(d["entries"])==2
assert {x["stage"] for x in d["entries"]}=={"integrate/INT-X","integrate/INT-Y"}
assert d["current_stage"]==d["entries"][-1]["stage"]
for item in d["entries"]:
    raw=open(run+"/"+item["path"],"rb").read()
    assert (len(raw),hashlib.sha256(raw).hexdigest())==(item["bytes"],item["sha256"])
PY

t_summary
