#!/usr/bin/env bash
# tests/test-bench-record.sh — firm-bench-record's shared, untracked, cross-worktree usage log.
#
# The design this guards: raw bench-usage events live at
# $(git rev-parse --git-common-dir)/agent-firm/bench-usage.jsonl, NOT a tracked bench/usage-log.jsonl.
# A tracked file would be wrong twice over — append-only state in version control, and every LINKED
# WORKTREE getting its own separate working-tree copy, so parallel writers in different worktrees
# would append to different files and take different locks entirely. The decisive case below proves
# the shared-path design actually holds under real concurrency from real worktrees, not just that the
# script runs without error.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BR="$BIN/firm-bench-record"

common_log() { # <repo> — the one file every worktree of <repo> should converge on
  printf '%s/agent-firm/bench-usage.jsonl' "$(cd "$1" && cd -P "$(git rev-parse --git-common-dir)" && pwd)"
}

# ---------------------------------------------------------------------------
t_case "usage and validation errors"
repo="$(mk_repo)"
assert_rc "missing args" 2 sh -c "cd '$repo' && '$BR'"
assert_rc "missing outcome" 2 sh -c "cd '$repo' && '$BR' reviewer"
assert_rc "invalid outcome rejected" 2 sh -c "cd '$repo' && '$BR' reviewer maybe"
assert_output "names the valid values" "success" sh -c "cd '$repo' && '$BR' reviewer maybe 2>&1"

t_case "outside a git repo -> fails cleanly, does not crash"
nogit="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $nogit"
assert_rc "exit 1, not a git repo" 1 sh -c "cd '$nogit' && '$BR' reviewer success"

# ---------------------------------------------------------------------------
t_case "basic write: correct path, valid JSONL, right fields"
repo2="$(mk_repo)"
log2="$(common_log "$repo2")"
assert_no_file "log does not exist before the first write" "$log2"
assert_ok "records successfully" sh -c "cd '$repo2' && '$BR' reviewer success APPROVE"
assert_file "log created at the git-common-dir path" "$log2"
assert_ok "line is valid JSON" python3 -c "import json; json.loads(open('$log2').readline())"
assert_output "role recorded"       '"role":"reviewer"'    cat "$log2"
assert_output "outcome recorded"    '"outcome":"success"'  cat "$log2"
assert_output "qa_verdict recorded" '"qa_verdict":"APPROVE"' cat "$log2"
assert_output "project recorded"    "\"project\":\"$(basename "$repo2")\"" cat "$log2"

t_case "no active run -> still records, with run_id=unknown rather than failing"
assert_ok "records without CURRENT_RUN set" sh -c "cd '$repo2' && '$BR' hire failure"
assert_output "run_id falls back to unknown" '"run_id":"unknown"' cat "$log2"

# ---------------------------------------------------------------------------
t_case "the lockdir is cleaned up after a normal write (no leftover lock)"
repo3="$(mk_repo)"
( cd "$repo3" && "$BR" reviewer success ) >/dev/null
lockdir="$(dirname "$(common_log "$repo3")")/.bench-usage.lock"
assert_no_file "lockdir removed by the EXIT trap" "$lockdir"

# ---------------------------------------------------------------------------
t_case "log is untracked -- lives inside .git/, git status sees nothing new"
repo4="$(mk_repo)"
( cd "$repo4" && "$BR" reviewer success ) >/dev/null
assert_eq "no untracked/modified files reported" "" "$( (cd "$repo4" && git status --porcelain) )"

# ---------------------------------------------------------------------------
t_case "CROSS-WORKTREE CONCURRENCY (the case a tracked file would have failed silently)"
repo5="$(mk_repo)"
wt_a="$(mk_linked_worktree "$repo5" wt-record-a)"
wt_b="$(mk_linked_worktree "$repo5" wt-record-b)"
assert_file "fixture precondition: worktree A really exists" "$wt_a"
assert_file "fixture precondition: worktree B really exists" "$wt_b"

log5="$(common_log "$repo5")"
n=10
pids=""
for i in $(seq 1 "$n"); do ( cd "$repo5" && "$BR" "role-main-$i" success )   >/dev/null 2>&1 & pids="$pids $!"; done
for i in $(seq 1 "$n"); do ( cd "$wt_a"  && "$BR" "role-a-$i"    success )  >/dev/null 2>&1 & pids="$pids $!"; done
for i in $(seq 1 "$n"); do ( cd "$wt_b"  && "$BR" "role-b-$i"    failure )  >/dev/null 2>&1 & pids="$pids $!"; done
for p in $pids; do wait "$p" 2>/dev/null || true; done

assert_ok "every expected line is present, none truncated/interleaved" python3 -c "
import json
lines = [l for l in open('$log5') if l.strip()]
assert len(lines) == $((n*3)), f'expected $((n*3)) lines, got {len(lines)}'
roles = set()
for l in lines:
    d = json.loads(l)   # raises if any line is malformed/truncated/interleaved
    roles.add(d['role'])
assert len(roles) == $((n*3)), f'expected $((n*3)) unique roles, got {len(roles)}'
"

# The defect this design fixes: a tracked file would give EACH worktree its OWN copy. Sweep every
# working tree and confirm exactly one bench-usage.jsonl exists anywhere in this repo's worktrees.
copies="$(find "$repo5" "$wt_a" "$wt_b" -name 'bench-usage.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "exactly one copy of the log exists across all worktrees" "1" "$copies"

t_summary
