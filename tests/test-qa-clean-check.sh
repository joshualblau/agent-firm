#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QCC="$BIN/firm-qa-clean-check"
NEW="$BIN/firm-new-run"
QAC="$BIN/firm-qa-checkout"

repo="$(mk_repo)"
( cd "$repo" && "$NEW" --primary claude clean-bound fast_path >/dev/null )
run_rel="$(cat "$repo/.agent-firm/CURRENT_RUN")"; run="$repo/$run_rel"; run_id="$(basename "$run")"
( cd "$repo" && git checkout -qb "integration/$run_id" && printf 'candidate\n' > result.txt && git add -A && git commit -qm candidate && git checkout -q main )
( cd "$repo" && "$QAC" >/dev/null )
candidate="$run/09-test-evidence/qa-candidate.json"
qa_dir="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["checkout_path"])' "$candidate")"

t_case "an explicit validated run binds the exact clean checkout/SHA/common-dir/generation"
assert_rc "exact target is clean" 0 "$QCC" --run "$run"
assert_output "clean result names exact identity" "exact run/SHA/generation" "$QCC" --run "$run"
assert_output "target event carries clean status" '"event":"qa_clean_check"' cat "$run/run.jsonl"
assert_output "target event carries candidate SHA" '"sha":"' cat "$run/run.jsonl"
assert_output "target event carries generation" '"generation":"1"' cat "$run/run.jsonl"

t_case "the zero-argument assertion adapter resolves CURRENT_RUN into the same validated target"
assert_rc "current run adapter is clean" 0 sh -c "cd '$repo' && '$QCC'"
no_current="$(mk_repo)"
assert_rc "zero arguments without CURRENT_RUN fail closed" 2 sh -c "cd '$no_current' && '$QCC'"

t_case "implicit, missing, noncanonical, and wrong checkout targets fail closed"
assert_rc "run is mandatory" 2 "$QCC" "$qa_dir"
assert_rc "missing explicit run cannot verify" 2 "$QCC" --run "$repo/.agent-firm/runs/missing"
plain="$(mktemp -d "${TMPDIR:-/tmp}/firm-clean-plain.XXXXXX")"; t_track "$plain"
assert_rc "wrong checkout argument is an identity failure" 1 "$QCC" --run "$run" "$plain"

t_case "explicit target never consults or writes ambient CURRENT_RUN"
ambient="$repo/.agent-firm/runs/ambient"; mkdir -p "$ambient"
printf '{"event":"ambient"}\n' > "$ambient/run.jsonl"
printf '.agent-firm/runs/ambient\n' > "$repo/.agent-firm/CURRENT_RUN"
before="$(shasum -a 256 "$ambient/run.jsonl" | awk '{print $1}')"
assert_rc "explicit target still passes" 0 "$QCC" --run "$run"
after="$(shasum -a 256 "$ambient/run.jsonl" | awk '{print $1}')"
assert_eq "ambient ledger is byte-identical" "$before" "$after"

t_case "dirty tracked and untracked states fail against the persisted target"
printf 'dirty\n' >> "$qa_dir/result.txt"
assert_rc "tracked mutation is dirty" 1 "$QCC" --run "$run"
( cd "$qa_dir" && git checkout -- result.txt )
printf 'leftover\n' > "$qa_dir/leftover.txt"
assert_rc "untracked mutation is dirty" 1 "$QCC" --run "$run"
rm -f "$qa_dir/leftover.txt"
assert_rc "cleanup restores exact pass" 0 "$QCC" --run "$run"

t_case "wrong SHA, generation, source ref, and common-dir metadata cannot borrow a clean checkout"
cp "$candidate" "$candidate.good"
for mutation in sha generation source common; do
  cp "$candidate.good" "$candidate"
  python3 - "$candidate" "$mutation" <<'PY'
import json,sys
p,kind=sys.argv[1:]; d=json.load(open(p))
if kind=="sha": d["candidate_sha"]="0"*40
elif kind=="generation": d["generation"]+=1
elif kind=="source": d["source_ref"]="refs/heads/integration/other"
else: d["git_common_dir"]="/tmp/not-the-common-dir"
json.dump(d,open(p,"w"),indent=2,sort_keys=True)
PY
  chmod 600 "$candidate"
  assert_fail "$mutation mismatch cannot pass" "$QCC" --run "$run"
done
cp "$candidate.good" "$candidate"; chmod 600 "$candidate"
rm -f "$candidate.good"

t_case "consumer rejects redirected evidence and QA parents without touching redirect targets"
redirect_root="$(mktemp -d "${TMPDIR:-/tmp}/firm-clean-parent.XXXXXX")"; t_track "$redirect_root"
mv "$run/09-test-evidence" "$redirect_root/evidence-saved"
mkdir "$redirect_root/evidence-target"; printf 'evidence sentinel\n' > "$redirect_root/evidence-target/sentinel"
evidence_before="$(shasum -a 256 "$redirect_root/evidence-target/sentinel" | awk '{print $1}')"
ln -s "$redirect_root/evidence-target" "$run/09-test-evidence"
assert_rc "redirected evidence parent cannot be consumed" 2 "$QCC" --run "$run"
assert_eq "evidence redirect target is byte-identical" "$evidence_before" "$(shasum -a 256 "$redirect_root/evidence-target/sentinel" | awk '{print $1}')"
rm "$run/09-test-evidence"; mv "$redirect_root/evidence-saved" "$run/09-test-evidence"

qa_parent="$repo/.agent-firm/qa-checkout"; mv "$qa_parent" "$redirect_root/qa-saved"
mkdir "$redirect_root/qa-target"; printf 'qa sentinel\n' > "$redirect_root/qa-target/sentinel"
qa_before="$(shasum -a 256 "$redirect_root/qa-target/sentinel" | awk '{print $1}')"
ln -s "$redirect_root/qa-target" "$qa_parent"
assert_rc "redirected QA parent cannot be consumed" 2 "$QCC" --run "$run"
assert_eq "QA redirect target is byte-identical" "$qa_before" "$(shasum -a 256 "$redirect_root/qa-target/sentinel" | awk '{print $1}')"
rm "$qa_parent"; mv "$redirect_root/qa-saved" "$qa_parent"

t_summary
