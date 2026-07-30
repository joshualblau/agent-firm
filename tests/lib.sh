#!/usr/bin/env bash
# tests/lib.sh — dependency-free assertions for the firm's own tooling.
#
# Deliberately plain: no bats, no node, no python. The bin/ scripts hold themselves to bash 3.2
# (macOS ships 3.2.57 and always will), so their tests must run there too — that means no
# associative arrays, no `mapfile`, no `${var^^}`, no process substitution in the hot path.
#
# A test file sources this, calls assertions, and ends with `t_summary`. It must NOT `set -e`:
# assertions capture non-zero exit codes on purpose, and -e would abort the run on the first
# expected failure.

T_PASS=0
T_FAIL=0
T_TMPDIRS=""

# ---- repo under test -----------------------------------------------------
# Resolve the firm root from this file's location so tests can be invoked from anywhere.
_t_src="${BASH_SOURCE[0]}"
while [ -L "$_t_src" ]; do
  _t_d="$(cd -P "$(dirname "$_t_src")" && pwd)"; _t_src="$(readlink "$_t_src")"
  case $_t_src in /*) ;; *) _t_src="$_t_d/$_t_src";; esac
done
TESTS_DIR="$(cd -P "$(dirname "$_t_src")" && pwd)"
FIRM_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
BIN="$FIRM_ROOT/bin"

# ---- output --------------------------------------------------------------
_t_ok() { T_PASS=$((T_PASS+1)); printf '    ok   %s\n' "$1"; }
_t_no() {
  T_FAIL=$((T_FAIL+1)); printf '    FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '         %s\n' "$2"
  return 0
}
# Collapse captured output to one readable line of context on failure.
_t_ctx() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-200; }

t_case() { printf '  · %s\n' "$1"; }

# ---- assertions ----------------------------------------------------------
# Every assertion below declares its working variables `local`. Without it, a bare `desc=`/`out=`/
# `rc=`/`needle=` assignment leaks into and silently CLOBBERS any identically-named variable in the
# calling test script — these functions are called directly (not via `$(...)`), so they share the
# caller's shell, unlike mk_repo/mk_run/etc. below (which command-substitution naturally isolates).
# Caught by test-new-run.sh: an `out="$(...)"` in that file was silently overwritten to "" by the next
# assert_ok call, and a later `assert_eq` against the now-clobbered `$out` failed for the wrong reason
# — the exact class of bug this project's own no-overclaiming-tests policy exists to catch, just one
# layer down (in the harness itself, not a test body).

# assert_ok <desc> <cmd...>        — command must exit 0
assert_ok() {
  local desc="$1" out rc; shift
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then _t_ok "$desc"; else _t_no "$desc" "rc=$rc  $(_t_ctx "$out")"; fi
}

# assert_fail <desc> <cmd...>      — command must exit non-zero
assert_fail() {
  local desc="$1" out rc; shift
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then _t_ok "$desc (rc=$rc)"; else _t_no "$desc" "expected non-zero, got 0  $(_t_ctx "$out")"; fi
}

# assert_rc <desc> <expected-rc> <cmd...>  — exact exit code (the firm uses 2/3/4 meaningfully)
assert_rc() {
  local desc="$1" want="$2" out rc; shift 2
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then _t_ok "$desc (rc=$rc)"; else _t_no "$desc" "expected rc=$want got rc=$rc  $(_t_ctx "$out")"; fi
}

# assert_output <desc> <needle> <cmd...>   — stdout+stderr must contain <needle>
assert_output() {
  local desc="$1" needle="$2" out; shift 2
  out="$("$@" 2>&1)"
  case "$out" in
    *"$needle"*) _t_ok "$desc" ;;
    *) _t_no "$desc" "missing '$needle' in: $(_t_ctx "$out")" ;;
  esac
}

# assert_eq <desc> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then _t_ok "$1"; else _t_no "$1" "expected '$2' got '$3'"; fi
}

# assert_ne <desc> <not-expected> <actual>
assert_ne() {
  if [ "$2" != "$3" ]; then _t_ok "$1"; else _t_no "$1" "expected something other than '$2'"; fi
}

assert_file()    { if [ -e "$2" ]; then _t_ok "$1"; else _t_no "$1" "missing file: $2"; fi; }
assert_no_file() { if [ ! -e "$2" ]; then _t_ok "$1"; else _t_no "$1" "file should not exist: $2"; fi; }

# ---- fixtures ------------------------------------------------------------
# mk_repo — a throwaway git repo with one seed commit on `main`. Echoes its path.
mk_repo() {
  d="$(mktemp -d "${TMPDIR:-/tmp}/firm-test.XXXXXX")"
  T_TMPDIRS="$T_TMPDIRS $d"
  (
    cd "$d" || exit 1
    git init -q .
    git symbolic-ref HEAD refs/heads/main      # portable `-b main` (works on older git too)
    git config user.email test@agent-firm.local
    git config user.name  "firm tests"
    git config commit.gpgsign false
    # Mirror what firm-new-worktree does in production: keep the ledger out of every commit.
    # Without this a work-order branch's `git add -A` swallows .agent-firm/, and switching back
    # deletes CURRENT_RUN out from under the next command.
    printf '%s\n' '.agent-firm/' '.agent-firm-worktree.env' >> .git/info/exclude
    printf 'seed\n' > seed.txt
    git add -A
    git commit -qm seed
  ) >/dev/null 2>&1 || return 1
  printf '%s' "$d"
}

# mk_run <repo> <run-id> — open a run ledger the firm's scripts will recognize. Called directly (not
# via `$(...)`), so its working variables are `local` for the same reason the assertions above are.
mk_run() {
  local _r="$1" _id="$2"
  mkdir -p "$_r/.agent-firm/runs/$_id"
  printf '%s\n' ".agent-firm/runs/$_id" > "$_r/.agent-firm/CURRENT_RUN"
}

# mk_wt_branch <repo> <run-id> <wo> <file> <content> — a work-order branch with one commit,
# created without leaving the current branch (the firm's own worktree branches look like this).
mk_wt_branch() {
  _r="$1"; _id="$2"; _wo="$3"; _f="$4"; _c="$5"
  (
    cd "$_r" || exit 1
    _here="$(git rev-parse --abbrev-ref HEAD)"
    git checkout -q -b "wt/${_id}-implementer-${_wo}"
    printf '%s\n' "$_c" > "$_f"
    git add -A && git commit -qm "wo ${_wo}"
    git checkout -q "$_here"
  ) >/dev/null 2>&1
}

# mk_linked_worktree <repo> <branch> — check <branch> out in a second worktree, the way the firm
# does during Build. Uses a unique path (a fixed sibling name collides between cases and makes
# `git worktree add` fail, which silently turns this fixture into a no-op). Echoes the path.
mk_linked_worktree() {
  _r="$1"; _b="$2"
  _parent="$(mktemp -d "${TMPDIR:-/tmp}/firm-wt.XXXXXX")"
  T_TMPDIRS="$T_TMPDIRS $_parent"
  _p="$_parent/linked"
  ( cd "$_r" && git worktree add -q "$_p" -b "$_b" ) >/dev/null 2>&1 || return 1
  printf '%s' "$_p"
}

sha_of() { git -C "$1" rev-parse "$2" 2>/dev/null; }

# ---- teardown ------------------------------------------------------------
t_cleanup() {
  for d in $T_TMPDIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap t_cleanup EXIT

t_summary() {
  printf '  ── %d passed, %d failed\n' "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}
