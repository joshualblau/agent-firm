#!/usr/bin/env bash
# tests/lib.sh — framework-free assertions for the firm's own tooling.
#
# Deliberately plain: no bats, no node. (python3 IS used — by the scripts under test and by tests that
# check JSON/YAML; test-validate-verdict needs jsonschema and test-policy-yaml-valid needs pyyaml, the
# firm's own declared prerequisites. What's avoided is a test FRAMEWORK, not a runtime.)
# The bin/ scripts hold themselves to bash 3.2
# (macOS ships 3.2.57 and always will), so their tests must run there too — that means no
# associative arrays, no `mapfile`, no `${var^^}`, no process substitution in the hot path.
#
# A test file sources this, calls assertions, and ends with `t_summary`. It must NOT `set -e`:
# assertions capture non-zero exit codes on purpose, and -e would abort the run on the first
# expected failure.

T_PASS=0
T_FAIL=0

# ---- temp-dir bookkeeping -------------------------------------------------
# Two accumulators, on purpose:
#   T_TMPDIRS         — the space-separated variable several test files append to directly. Those
#                       appends happen in the test's own shell, so they work.
#   T_TMPDIR_REGISTRY — a FILE, one absolute path per line. Fixtures like mk_repo/mk_linked_worktree
#                       are invoked as `d="$(mk_repo)"`, i.e. inside a command-substitution SUBSHELL,
#                       so their `T_TMPDIRS=...` appends died with that subshell and the parent's
#                       cleanup trap saw an empty list — every suite run leaked its throwaway git
#                       repos into $TMPDIR. A file is the one channel that crosses back out of a
#                       subshell without restructuring the fixtures into out-parameters.
# Newline-delimited (not space-delimited) so a path containing spaces stays one entry.
T_TMPDIRS=""
T_TMPDIR_REGISTRY="$(mktemp "${TMPDIR:-/tmp}/firm-test-reg.XXXXXX" 2>/dev/null || printf '')"

# t_track <dir> — register an absolute path for teardown. Safe to call from inside a subshell.
t_track() {
  [ -n "${1:-}" ] || return 0
  if [ -n "$T_TMPDIR_REGISTRY" ]; then printf '%s\n' "$1" >> "$T_TMPDIR_REGISTRY"; fi
  return 0
}

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
  t_track "$d"   # NOT `T_TMPDIRS=...`: this runs inside `$(mk_repo)`, so a variable append is lost
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
  t_track "$_parent"   # subshell again — see mk_repo
  _p="$_parent/linked"
  ( cd "$_r" && git worktree add -q "$_p" -b "$_b" ) >/dev/null 2>&1 || return 1
  printf '%s' "$_p"
}

sha_of() { git -C "$1" rev-parse "$2" 2>/dev/null; }

# ---- teardown ------------------------------------------------------------
# _t_rm_fixture <dir> — delete ONE registered fixture directory. This is the ONLY `rm -rf` in the
# harness, so every constraint on what teardown may delete lives here and nowhere else. Anything
# that is not an absolute path to a real, non-symlink directory is skipped silently: the cost of
# skipping is a leaked temp dir, the cost of a wrong delete is somebody's working tree.
_t_rm_fixture() {
  _t_target="${1:-}"
  [ -n "$_t_target" ] || return 0
  case "$_t_target" in
    /*) ;;
    *)  return 0 ;;          # relative entry — would delete relative to $PWD
  esac
  case "$_t_target" in
    */..|*/../*) return 0 ;; # no traversal components
  esac
  [ "$_t_target" = "/" ] && return 0
  [ -d "$_t_target" ] || return 0   # already gone, or never a directory
  [ -L "$_t_target" ] && return 0   # a symlink: delete nothing rather than chase it somewhere else
  rm -rf "$_t_target"
}

t_cleanup() {
  # 1) Fixtures registered from inside a command-substitution subshell, via the registry file.
  if [ -n "$T_TMPDIR_REGISTRY" ] && [ -f "$T_TMPDIR_REGISTRY" ]; then
    # `|| [ -n "$_t_entry" ]` picks up a final line with no trailing newline — otherwise `read`
    # returns non-zero on it and the last fixture registered silently never gets cleaned.
    while IFS= read -r _t_entry || [ -n "$_t_entry" ]; do
      _t_rm_fixture "$_t_entry"
      _t_entry=""
    done < "$T_TMPDIR_REGISTRY"
    rm -f "$T_TMPDIR_REGISTRY"
  fi
  # 2) The space-separated T_TMPDIRS variable that several test files append to directly. Word
  #    splitting is the point here (that is the format), but `set -f` goes on FIRST: an unquoted
  #    expansion feeding an `rm -rf` argument list must never be able to glob — one stray `*` in
  #    that variable and teardown deletes whatever happens to be in $PWD. Restore the caller's
  #    noglob setting afterwards so a test that relied on it is unaffected.
  case "$-" in *f*) _t_had_f=1 ;; *) _t_had_f=0 ;; esac
  set -f
  for _t_d in $T_TMPDIRS; do
    _t_rm_fixture "$_t_d"
  done
  [ "$_t_had_f" -eq 1 ] || set +f
}
trap t_cleanup EXIT

t_summary() {
  printf '  ── %d passed, %d failed\n' "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}
