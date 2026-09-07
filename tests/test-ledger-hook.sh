#!/usr/bin/env bash
# tests/test-ledger-hook.sh — bin/firm-ledger-hook's run-containment check (AC-020 / SEC-11).
#
# WHY THIS FILE EXISTS. The hook reads a DIRECTORY PATH out of .agent-firm/CURRENT_RUN and appends
# JSON there on every single Bash tool call. bin/firm-merge-guard's ledger() has refused to append
# outside the invoking working tree since SEC-11 ("CURRENT_RUN is DATA, not an instruction"); this
# hook performed the same ambient read with NO such check, so whatever wrote CURRENT_RUN — including
# a concurrent run in the same working tree that simply overwrote the pointer — steered the appends
# wherever it liked. That is not hypothetical: it is the mechanism by which one engagement's `bash`
# observations landed in an unrelated run's ledger.
#
# HOW THE CASES ARE BUILT — read before adding one.
#   · BOTH DIRECTIONS ARE PINNED IN EVERY DIRECTION THE CHECK CAN BE WRONG. A containment check that
#     just disabled the ledger would satisfy every negative assertion here on its own, so each
#     refusal case is paired with a positive one — several of them in the SAME fixture, so "the hook
#     was working right there and still refused" is what the case proves, not "the hook did nothing".
#   · The refusal is SILENT and still exits 0. This hook is best-effort and non-blocking by contract
#     (it runs PreToolUse on every Bash call), so each case asserts rc AND that stdout+stderr were
#     empty. A refusal that printed would surface an error into an unrelated tool call.
#   · Containment is decided on RESOLVED paths, both sides, which is why two cases here are about
#     symlinks: one where a textually-contained run dir resolves outside (must refuse) and one where
#     the caller's cwd is spelled through a symlink and everything resolves to the same real
#     directory (must still append — macOS ships that spelling by default, $TMPDIR being
#     /var/folders/… whose physical path is /private/var/folders/…).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$BIN/firm-ledger-hook"

# mk_payload <command> — a real Claude Code PreToolUse(Bash) payload. Deliberately local rather than
# in lib.sh: only this file and test-merge-guard.sh drive this hook, and lib.sh is sourced by every
# suite in the repository.
mk_payload() {
  python3 -c 'import json,sys; print(json.dumps({"session_id":"t","cwd":".",
    "hook_event_name":"PreToolUse","tool_name":"Bash",
    "tool_input":{"command":sys.argv[1],"description":"d"}}))' "$1"
}

# run_hook <cwd> <command> — drive the hook from <cwd> with a payload naming <command>.
# Sets HOOK_RC and HOOK_OUT (stdout+stderr combined) rather than echoing, so a case can assert on
# both without running the hook twice.
HOOK_RC=0; HOOK_OUT=""
run_hook() {
  local _cwd="$1" _cmd="$2" _p
  _p="$(mk_payload "$_cmd")"
  HOOK_OUT="$( ( cd "$_cwd" && printf '%s' "$_p" | "$HOOK" ) 2>&1 )"; HOOK_RC=$?
}

# assert_hook_quiet <desc> — the non-blocking contract: exit 0, nothing written to either stream.
assert_hook_quiet() {
  assert_eq "$1: exits 0 (non-blocking)" "0" "$HOOK_RC"
  assert_eq "$1: says nothing on stdout or stderr" "" "$HOOK_OUT"
}

# has_bash_record <ledger> <command> — 0 when a {ts,event:bash,cmd} record for <command> is present.
has_bash_record() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
recs = [json.loads(l) for l in open(path) if l.strip()]
assert any(r.get("event") == "bash" and r.get("cmd") == cmd for r in recs), recs
PY
}

if command -v jq >/dev/null 2>&1; then HAS_JQ=1; else HAS_JQ=0; fi

# ---------------------------------------------------------------------------
t_case "AC-020 a CURRENT_RUN contained under the invoking working tree still gets the append"
# The counterweight to every refusal below, and the whole reason this check has to be a comparison
# rather than a deletion: ordinary in-project logging is unchanged, byte shape included.
IN_REPO="$(mk_repo)"
mk_run "$IN_REPO" "20260907T000001Z-contained"
IN_LEDGER="$IN_REPO/.agent-firm/runs/20260907T000001Z-contained/run.jsonl"
run_hook "$IN_REPO" 'ls -la'
assert_hook_quiet "contained append"
assert_file "the contained run.jsonl was written" "$IN_LEDGER"
if [ "$HAS_JQ" -eq 1 ]; then
  assert_ok "  and it holds a bash record naming the command" has_bash_record "$IN_LEDGER" 'ls -la'
  assert_ok "  with exactly today's {ts,event,cmd} shape and ts format" python3 - "$IN_LEDGER" <<'PY'
import json, re, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(recs) == 1, recs
r = recs[0]
assert sorted(r) == ["cmd", "event", "ts"], sorted(r)
assert r["event"] == "bash" and r["cmd"] == "ls -la", r
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", r["ts"]), r["ts"]
PY
else
  t_skip "  and it holds a bash record naming the command" "jq is not on PATH; the hook's append path needs it"
fi

# ---------------------------------------------------------------------------
t_case "AC-020 a CURRENT_RUN pointing OUTSIDE the working tree gets no append, and the hook exits 0"
# The mis-attribution mechanism itself: an absolute path to a perfectly real directory that simply
# is not this project. ELSEWHERE is pre-created and writable, so nothing but the containment check
# stands between the hook and it.
OUT_REPO="$(mk_repo)"
ELSEWHERE="$(mktemp -d "${TMPDIR:-/tmp}/firm-lh-elsewhere.XXXXXX")"; t_track "$ELSEWHERE"
mkdir -p "$ELSEWHERE/runs/hijacked" "$OUT_REPO/.agent-firm"
printf '%s\n' "$ELSEWHERE/runs/hijacked" > "$OUT_REPO/.agent-firm/CURRENT_RUN"
run_hook "$OUT_REPO" 'ls -la'
assert_hook_quiet "out-of-project refusal"
assert_no_file "nothing was appended outside the project" "$ELSEWHERE/runs/hijacked/run.jsonl"
assert_eq "and the out-of-project directory is still empty" \
  "" "$(ls -A "$ELSEWHERE/runs/hijacked" 2>/dev/null)"
# SAME FIXTURE, SAME COMMAND, contained pointer: proves the refusal above was the containment check
# and not a hook that had stopped appending anywhere.
mk_run "$OUT_REPO" "20260907T000002Z-control"
run_hook "$OUT_REPO" 'ls -la'
assert_hook_quiet "in-project control"
assert_file "  and the same hook DID append once the pointer was contained" \
  "$OUT_REPO/.agent-firm/runs/20260907T000002Z-control/run.jsonl"

# ---------------------------------------------------------------------------
t_case "AC-020 a SIBLING whose name merely starts with the working tree's path is refused"
# The exact case Python's `here + os.sep` guards against, and the one a plain substring/startswith
# port drops on the floor: "/repo-other" starts with "/repo" as a string and is not under it. The
# sibling is a real, writable directory at the same depth as a legitimate run root.
SIB_REPO="$(mk_repo)"
SIB_DIR="$(cd -P "$SIB_REPO" && pwd -P)-other"   # resolved, so this is a true prefix of `pwd -P`
mkdir -p "$SIB_DIR/runs/hijacked" "$SIB_REPO/.agent-firm"; t_track "$SIB_DIR"
printf '%s\n' "$SIB_DIR/runs/hijacked" > "$SIB_REPO/.agent-firm/CURRENT_RUN"
assert_output "the sibling path really is a string-prefix match for the working tree" \
  "$(cd -P "$SIB_REPO" && pwd -P)" printf '%s' "$SIB_DIR"
run_hook "$SIB_REPO" 'ls -la'
assert_hook_quiet "sibling refusal"
assert_no_file "nothing was appended to the name-prefix sibling" "$SIB_DIR/runs/hijacked/run.jsonl"
mk_run "$SIB_REPO" "20260907T000003Z-control"
run_hook "$SIB_REPO" 'ls -la'
assert_file "  and the same hook DID append to a genuinely contained run" \
  "$SIB_REPO/.agent-firm/runs/20260907T000003Z-control/run.jsonl"

# ---------------------------------------------------------------------------
t_case "AC-020 containment is resolved, not spelled: a symlinked run dir cannot smuggle the append out"
# The run dir is written into CURRENT_RUN as an ordinary relative in-project path, so every textual
# check accepts it; only resolving it finds the escape. This is why the check resolves both sides.
LNK_REPO="$(mk_repo)"
LNK_OUT="$(mktemp -d "${TMPDIR:-/tmp}/firm-lh-linked.XXXXXX")"; t_track "$LNK_OUT"
mkdir -p "$LNK_OUT/hijacked" "$LNK_REPO/.agent-firm/runs"
ln -s "$LNK_OUT/hijacked" "$LNK_REPO/.agent-firm/runs/linked"
printf '%s\n' ".agent-firm/runs/linked" > "$LNK_REPO/.agent-firm/CURRENT_RUN"
assert_eq "the pointer is a relative, textually in-project path" \
  ".agent-firm/runs/linked" "$(cat "$LNK_REPO/.agent-firm/CURRENT_RUN")"
run_hook "$LNK_REPO" 'ls -la'
assert_hook_quiet "symlinked-run-dir refusal"
assert_no_file "nothing was appended through the symlink" "$LNK_OUT/hijacked/run.jsonl"
assert_eq "and the symlink's target directory is still empty" \
  "" "$(ls -A "$LNK_OUT/hijacked" 2>/dev/null)"

t_case "AC-020 a working tree REACHED through a symlink still appends (the check is not a refusal)"
# The other direction of "resolved, not spelled", and the one that would silently disable this hook
# on macOS: comparing the caller's $PWD (which keeps the symlinked spelling) against a resolved run
# dir never matches, so every append would be refused while every negative case above stayed green.
ALIAS_REPO="$(mk_repo)"
mk_run "$ALIAS_REPO" "20260907T000004Z-aliased"
ALIAS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/firm-lh-alias.XXXXXX")"; t_track "$ALIAS_ROOT"
ln -s "$ALIAS_REPO" "$ALIAS_ROOT/alias"
assert_ne "the alias really is a different spelling of the repo" \
  "$(cd -P "$ALIAS_REPO" && pwd -P)" "$ALIAS_ROOT/alias"
run_hook "$ALIAS_ROOT/alias" 'ls -la'
assert_hook_quiet "aliased-cwd append"
assert_file "the append landed in the run the alias resolves to" \
  "$ALIAS_REPO/.agent-firm/runs/20260907T000004Z-aliased/run.jsonl"
if [ "$HAS_JQ" -eq 1 ]; then
  assert_ok "  and it is a bash record naming the command" \
    has_bash_record "$ALIAS_REPO/.agent-firm/runs/20260907T000004Z-aliased/run.jsonl" 'ls -la'
else
  t_skip "  and it is a bash record naming the command" "jq is not on PATH"
fi

# ---------------------------------------------------------------------------
t_case "AC-020 an absent, empty, dangling or unreadable CURRENT_RUN behaves exactly as before"
# Pre-existing behaviour, pinned here because the new check sits between the pointer read and the
# append and must not turn any of these into an error, a message, or a non-zero exit.
NO_RUN="$(mk_repo)"
run_hook "$NO_RUN" 'ls -la'
assert_hook_quiet "no .agent-firm at all"
assert_eq "  and no ledger was created anywhere in the repo" \
  "" "$(find "$NO_RUN" -name run.jsonl -not -path '*/.git/*' 2>/dev/null)"

mkdir -p "$NO_RUN/.agent-firm"
: > "$NO_RUN/.agent-firm/CURRENT_RUN"
run_hook "$NO_RUN" 'ls -la'
assert_hook_quiet "an empty CURRENT_RUN"

printf '%s\n' ".agent-firm/runs/never-created" > "$NO_RUN/.agent-firm/CURRENT_RUN"
run_hook "$NO_RUN" 'ls -la'
assert_hook_quiet "a CURRENT_RUN naming a directory that does not exist"
assert_no_file "  and it created nothing" "$NO_RUN/.agent-firm/runs/never-created"

if [ "$(id -u)" = "0" ]; then
  t_skip "an unreadable CURRENT_RUN is skipped, not read" "running as root, which reads mode-000 files anyway"
else
  UNREADABLE="$(mk_repo)"
  mk_run "$UNREADABLE" "20260907T000005Z-unreadable"
  UNREADABLE_LEDGER="$UNREADABLE/.agent-firm/runs/20260907T000005Z-unreadable/run.jsonl"
  chmod 000 "$UNREADABLE/.agent-firm/CURRENT_RUN"
  run_hook "$UNREADABLE" 'ls -la'
  assert_hook_quiet "an unreadable CURRENT_RUN"
  assert_no_file "  and no append was made on an unread pointer" "$UNREADABLE_LEDGER"
  # The fixture is otherwise perfectly appendable — restore the mode and the same call writes.
  chmod 600 "$UNREADABLE/.agent-firm/CURRENT_RUN"
  run_hook "$UNREADABLE" 'ls -la'
  assert_file "  and the very same fixture appends once the pointer is readable" "$UNREADABLE_LEDGER"
fi

# ---------------------------------------------------------------------------
t_case "AC-020 the hook and firm-merge-guard's ledger() are findable as one pair (SEC-11)"
# The two checks are a matched pair in different languages. A future reader who changes one has to
# be able to find the other, and the work order that added this one asked for exactly that anchor.
assert_output "the hook's containment check is labelled SEC-11" "SEC-11" cat "$HOOK"
assert_output "so is firm-merge-guard's" "SEC-11" cat "$BIN/firm-merge-guard"

t_summary
