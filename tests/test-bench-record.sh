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

# ===========================================================================
# Regression cover for the four defects found in review. This log is PROMOTION EVIDENCE: the failure
# mode that matters is not "the script errored", it is "the script looked like it worked". So each
# case below checks the observable consequence (what is in the log, what the exit code was), not just
# that a message appeared.
# ===========================================================================

# A PATH with no jq on it, so the jq-free encoder is genuinely exercised on a machine that has jq.
# Same device, and for the same reason, as tests/test-ledger-log.sh.
NOJQ_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-nojq.XXXXXX")"; t_track "$NOJQ_DIR"
for tool in bash sh env cat mkdir rmdir rm date printf basename dirname readlink git awk sleep; do
  real="$(command -v "$tool" 2>/dev/null)"; [ -n "$real" ] && ln -sf "$real" "$NOJQ_DIR/$tool"
done
without_jq() { ( PATH="$NOJQ_DIR" "$@" ); }
assert_ok  "precondition: jq IS on the normal PATH (so the jq branch above was the one tested)" sh -c 'command -v jq'
assert_fail "precondition: jq is NOT on the no-jq PATH (so the fallback branch is really reached)" \
  without_jq sh -c 'command -v jq'

# ---------------------------------------------------------------------------
t_case "SEC-010 · a role carrying a newline cannot forge a second record"
repo6="$(mk_repo)"
log6="$(common_log "$repo6")"
( cd "$repo6" && "$BR" reviewer success APPROVE ) >/dev/null   # one legitimate record to append to
forged='reviewer
{"role":"promoted-by-injection","run_id":"r","project":"p","outcome":"success","qa_verdict":"APPROVE","ts":"2026-01-01T00:00:00Z"}'
assert_rc "a role containing a newline is rejected outright" 2 \
  sh -c 'cd "$1" && "$2" "$3" success APPROVE' _ "$repo6" "$BR" "$forged"
assert_output "and the caller is told why" "invalid role" \
  sh -c 'cd "$1" && "$2" "$3" success APPROVE 2>&1' _ "$repo6" "$BR" "$forged"
assert_eq "the log still holds exactly the one legitimate line" "1" "$(wc -l < "$log6" | tr -d ' ')"
assert_eq "no forged record reached the log" "0" "$(grep -c 'promoted-by-injection' "$log6" 2>/dev/null || true)"

t_case "SEC-010 · a rejected role touches nothing at all — no log, no log dir, no lockdir"
repo6b="$(mk_repo)"
log6b="$(common_log "$repo6b")"
assert_rc "rejected before any path is opened" 2 sh -c 'cd "$1" && "$2" "$3" success' _ "$repo6b" "$BR" "$forged"
assert_no_file "no log file"      "$log6b"
assert_no_file "not even the log directory" "$(dirname "$log6b")"

t_case "SEC-010 · every other structural byte is refused by the same allow-list"
assert_rc "double quote in role"     2 sh -c 'cd "$1" && "$2" "$3" success' _ "$repo6" "$BR" 'rev"iewer'
assert_rc "backslash in role"        2 sh -c 'cd "$1" && "$2" "$3" success' _ "$repo6" "$BR" 'rev\iewer'
assert_rc "carriage return in role"  2 sh -c 'cd "$1" && "$2" "$3" success' _ "$repo6" "$BR" "$(printf 'rev\riewer')"
assert_rc "tab in role"              2 sh -c 'cd "$1" && "$2" "$3" success' _ "$repo6" "$BR" "$(printf 'rev\tiewer')"
assert_rc "C0 control byte in role"  2 sh -c 'cd "$1" && "$2" "$3" success' _ "$repo6" "$BR" "$(printf 'rev\001iewer')"
assert_rc "leading dash in role"     2 sh -c 'cd "$1" && "$2" "$3" success' _ "$repo6" "$BR" '-reviewer'
assert_rc "role longer than 64"      2 sh -c 'cd "$1" && "$2" "$3" success' _ "$repo6" "$BR" "$(python3 -c 'print("a"*65)')"
assert_rc "newline in qa_verdict"    2 sh -c 'cd "$1" && "$2" reviewer success "$3"' _ "$repo6" "$BR" "$forged"
# ...and the allow-list is not so tight that real role names stop working:
assert_ok "a kebab-case agent name is still accepted" sh -c 'cd "$1" && "$2" qa-tester success APPROVE' _ "$repo6" "$BR"
assert_ok "a dotted/colon-qualified specialist id is still accepted" \
  sh -c 'cd "$1" && "$2" specialist:solidity-auditor.v2 success BLOCK' _ "$repo6" "$BR"
assert_eq "so the log grew by exactly the two accepted records" "3" "$(wc -l < "$log6" | tr -d ' ')"

# ---------------------------------------------------------------------------
t_case "SEC-010 · the jq-free encoder escapes control bytes exactly as jq does"
# `project` is the one field that CANNOT be charset-restricted — it is the repo's directory basename
# and a real repo may legitimately be named anything — so it is the field that proves the ENCODER is
# sound rather than just the input filter. Give it every byte class that used to break the record.
nasty_parent="$(mktemp -d "${TMPDIR:-/tmp}/firm-nasty.XXXXXX")"; t_track "$nasty_parent"
nasty_name="$(printf 'ev"il\\repo\nSECOND\tline\001x')"
nasty_repo="$nasty_parent/$nasty_name"
mkdir -p "$nasty_repo"
( cd "$nasty_repo" && git init -q . \
    && git config user.email test@agent-firm.local && git config user.name "firm tests" \
    && git config commit.gpgsign false \
    && printf 'seed\n' > seed.txt && git add -A && git commit -qm seed ) >/dev/null 2>&1
assert_file "fixture precondition: the awkwardly-named repo really exists" "$nasty_repo/.git"
nasty_log="$nasty_repo/.git/agent-firm/bench-usage.jsonl"

assert_ok "records once WITH jq"    sh -c 'cd "$1" && "$2" reviewer success APPROVE' _ "$nasty_repo" "$BR"
assert_ok "records once WITHOUT jq" without_jq sh -c 'cd "$1" && "$2" reviewer success APPROVE' _ "$nasty_repo" "$BR"
assert_eq "two records, so neither encoder split one record into two lines" "2" "$(wc -l < "$nasty_log" | tr -d ' ')"
assert_ok "both lines are valid JSON, both round-trip the name, and both encoders emit the same bytes" \
  python3 - "$nasty_log" "$nasty_name" <<'PY'
import json, re, sys
path, name = sys.argv[1], sys.argv[2]
lines = [l for l in open(path, encoding='utf-8') if l.strip()]
assert len(lines) == 2, f"expected 2 lines, got {len(lines)}"
for l in lines:
    r = json.loads(l)                      # raises if the record was split or malformed
    assert r["project"] == name, f"project did not round-trip: {r['project']!r} != {name!r}"
    assert r["role"] == "reviewer", r["role"]
strip_ts = lambda s: re.sub(r',"ts":"[^"]*"', '', s.strip())
assert strip_ts(lines[0]) == strip_ts(lines[1]), (
    f"jq and jq-free encoders disagree:\n  jq   : {lines[0]!r}\n  no-jq: {lines[1]!r}")
PY

# ---------------------------------------------------------------------------
t_case "F-CODE-014 · a failed append is reported, never reported as 'recorded'"
repo7="$(mk_repo)"
log7="$(common_log "$repo7")"
mkdir -p "$log7"        # the log PATH is now a directory, so the append cannot possibly succeed
assert_rc "non-zero exit when the append fails" 1 sh -c 'cd "$1" && "$2" reviewer success' _ "$repo7" "$BR"
assert_output "says the record was NOT recorded" "was NOT recorded" \
  sh -c 'cd "$1" && "$2" reviewer success 2>&1' _ "$repo7" "$BR"
out7="$( (cd "$repo7" && "$BR" reviewer success) 2>/dev/null || true )"
assert_eq "and stdout never claims success" "" "$out7"
assert_no_file "the lockdir is still released on the failure path" "$(dirname "$log7")/.bench-usage.lock"

t_case "F-CODE-014 · a failed mkdir of the log directory is reported, not swallowed"
repo8="$(mk_repo)"
log8="$(common_log "$repo8")"
: > "$(dirname "$log8")"   # $common/agent-firm is now a FILE, so `mkdir -p` must fail
assert_rc "non-zero exit when the log dir cannot be created" 1 sh -c 'cd "$1" && "$2" reviewer success' _ "$repo8" "$BR"
assert_output "and says so" "cannot create" sh -c 'cd "$1" && "$2" reviewer success 2>&1' _ "$repo8" "$BR"

# ---------------------------------------------------------------------------
t_case "F-CODE-013 · an unreclaimable stale lock fails fast instead of spinning forever"
# Before the fix the stale-lock branch `continue`d past BOTH the attempt counter and the sleep, so a
# lock that kept looking stale span at 100% CPU with no exit. A NON-EMPTY lockdir reproduces that
# exactly: rmdir can never remove it, so every iteration re-enters the reclaim branch. The deadline
# is what separates "bounded failure" from "hung" — an rc of 124 below means the spin came back.
_wd_kill_tree() { # kill a pid and everything under it — a spin is inherited by the grandchild, and
  for _wd_c in $(pgrep -P "$1" 2>/dev/null); do _wd_kill_tree "$_wd_c"; done   # orphaning one at
  kill -9 "$1" 2>/dev/null                                                     # 100% CPU is rude
}
with_deadline() { # <seconds> <cmd...> — returns the command's rc, or 124 if it outlived the deadline
  _wd_secs="$1"; shift
  "$@" >/dev/null 2>&1 &
  _wd_pid=$!; _wd_i=0
  while kill -0 "$_wd_pid" 2>/dev/null; do
    _wd_i=$((_wd_i+1))
    if [ "$_wd_i" -gt $((_wd_secs * 10)) ]; then
      _wd_kill_tree "$_wd_pid"; wait "$_wd_pid" 2>/dev/null; return 124
    fi
    sleep 0.1
  done
  wait "$_wd_pid"
}
repo9="$(mk_repo)"
log9="$(common_log "$repo9")"
lock9="$(dirname "$log9")/.bench-usage.lock"
mkdir -p "$lock9"
: > "$lock9/held-by-a-dead-writer"   # non-empty => rmdir always fails => the lock never stops being stale
touch -t 200001010000 "$lock9"       # ancient mtime => always past the staleness threshold
assert_file "fixture precondition: the lockdir is genuinely unremovable" "$lock9/held-by-a-dead-writer"
assert_fail "fixture precondition: rmdir really cannot reclaim it" rmdir "$lock9"
# ONE bounded invocation, output captured to a file. Deliberately not a second, unbounded
# assert_output call: if this defect ever regresses, an unbounded call would hang the whole suite
# forever instead of failing it.
with_deadline 30 sh -c 'cd "$1" && "$2" reviewer success >"$1/lock-attempt.out" 2>&1' _ "$repo9" "$BR"
rc9=$?
assert_eq "exits 1 within the deadline (124 here would mean the busy loop is back)" "1" "$rc9"
assert_output "explains that it gave up on the lock" "giving up" cat "$repo9/lock-attempt.out"
assert_no_file "and wrote no record while locked out" "$log9"

# ---------------------------------------------------------------------------
t_case "F-CODE-015 · a git that cannot name the common dir is refused, not turned into /agent-firm"
# The old code was `cd -P "$(git rev-parse --git-common-dir)"`. An empty capture makes `cd -P ""`
# fail, `$(...)` still yields "", and the log path degenerates to /agent-firm — outside the repo
# entirely, where a "successful" record is one nobody will ever find. A stubbed git is the only way
# to drive that from outside the script; the real one always answers.
STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-gitstub.XXXXXX")"; t_track "$STUB_DIR"
REAL_GIT="$(command -v git)"
make_git_stub() {  # <what `rev-parse --git-common-dir` should print>
  cat > "$STUB_DIR/git" <<EOF
#!/bin/sh
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--is-inside-work-tree" ]; then echo true; exit 0; fi
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--git-common-dir" ]; then printf '%s' '$1'; exit 0; fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$STUB_DIR/git"
}
repo10="$(mk_repo)"
make_git_stub ""
assert_eq "fixture precondition: the stub really reports an empty common dir" "" \
  "$(PATH="$STUB_DIR:$PATH" git rev-parse --git-common-dir)"
assert_rc "empty --git-common-dir -> exit 1" 1 \
  sh -c 'cd "$1" && PATH="$2:$PATH" "$3" reviewer success' _ "$repo10" "$STUB_DIR" "$BR"
assert_output "and refuses to guess a path" "refusing to guess" \
  sh -c 'cd "$1" && PATH="$2:$PATH" "$3" reviewer success 2>&1' _ "$repo10" "$STUB_DIR" "$BR"
make_git_stub "/definitely/not/a/real/git/common/dir"
assert_rc "unresolvable --git-common-dir -> exit 1" 1 \
  sh -c 'cd "$1" && PATH="$2:$PATH" "$3" reviewer success' _ "$repo10" "$STUB_DIR" "$BR"
assert_output "and says it could not resolve it" "could not resolve the git common dir" \
  sh -c 'cd "$1" && PATH="$2:$PATH" "$3" reviewer success 2>&1' _ "$repo10" "$STUB_DIR" "$BR"
assert_no_file "no root-level /agent-firm was ever created" "/agent-firm"
assert_no_file "and the repo itself got no log from the stubbed runs" "$(common_log "$repo10")"

t_summary
