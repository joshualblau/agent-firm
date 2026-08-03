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
# ONE registration channel: t_track, backed by a FILE of NUL-TERMINATED absolute paths.
#
# Why a file. Fixtures like mk_repo/mk_linked_worktree are invoked as `d="$(mk_repo)"`, i.e. inside a
# command-substitution SUBSHELL, so a plain variable append died with that subshell and the parent's
# cleanup trap saw an empty list — every suite run leaked its throwaway git repos into $TMPDIR. A file
# is the one channel that crosses back out of a subshell without restructuring the fixtures into
# out-parameters.
#
# Why NUL framing, and not spaces or newlines (SEC-R8). Teardown DELETES what it reads back, so the
# framing has to be lossless. A delimiter that can legally occur inside a path lets one entry split
# into FRAGMENTS — and the first fragment of an absolute path is itself absolute, so it satisfies
# every shape check _t_rm_fixture applies while pointing somewhere else entirely. A space-framed list
# deletes "/x/my" when the real fixture is "/x/my tmp/fix" (and leaks the fixture); a newline-framed
# list fails identically on a path containing a newline. NUL is the one byte a POSIX path cannot
# contain, so it is the one framing that cannot split. With it, a fixture path containing a space, a
# tab, a newline or a glob character is registered and removed exactly, and nothing else is touched.
#
# T_TMPDIRS is a RETIRED compatibility shim, kept only so `$T_TMPDIRS` still expands under `set -u`.
# It is space-framed — precisely the case above that cannot be split back safely — so teardown refuses
# to act on it and warns instead (see t_cleanup). A leaked temp dir is the cheap failure; deleting a
# fragment of somebody's real path is not. Register fixtures with `t_track "$dir"`.
T_TMPDIRS=""
T_TMPDIR_REGISTRY="$(mktemp "${TMPDIR:-/tmp}/firm-test-reg.XXXXXX" 2>/dev/null || printf '')"

# t_track <dir> — register an absolute path for teardown. Safe to call from inside a subshell, and
# safe for any path a filesystem can actually hold: the record is NUL-terminated here and every
# expansion of it in t_cleanup/_t_rm_fixture is quoted, so it can never split or glob.
t_track() {
  [ -n "${1:-}" ] || return 0
  if [ -n "$T_TMPDIR_REGISTRY" ]; then printf '%s\0' "$1" >> "$T_TMPDIR_REGISTRY"; fi
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
# harness, so every constraint on what teardown may delete lives here and nowhere else. Anything that
# fails a check is skipped silently: the cost of skipping is a leaked temp dir, the cost of a wrong
# delete is somebody's working tree.
#
# The checks are deliberately two kinds, because shape alone is not enough (SEC-R8). Most constrain
# the SHAPE of the string — absolute, no traversal component, not "/", a real non-symlink directory.
# One constrains its IDENTITY: a fixture lives under the temp root this shell makes fixtures in, so
# anything outside that is not ours to remove however well-formed it looks. (Shape was all the guard
# checked when a space-split FRAGMENT of a real fixture path sailed through every one of them.) The
# two kinds overlap on relative paths, so that case is guarded twice; tests/test-lib.sh says so, and
# 09-test-evidence records which single deletions the redundancy masks.
#
# IDENTITY IS A QUESTION ABOUT DIRECTORIES, NOT ABOUT STRINGS (SEC-R9). The identity check used to
# compare the target to the temp root as normalized TEXT, and the symlink check tests only the FINAL
# component — so an INTERMEDIATE symlink was never considered. "$TMPDIR/link/fixture", where
# "$TMPDIR/link" points anywhere at all, is a perfect textual match for "under the temp root" while
# `rm -rf` follows the link and deletes outside it. Both sides are therefore resolved to their
# physical paths (_t_realdir) before they are compared, and the delete targets the RESOLVED path —
# the one that was actually validated. Resolving also fixes the mirror-image bug: on macOS $TMPDIR is
# reached through a symlink ("/var" -> "/private/var", and "/tmp" -> "/private/tmp"), so a fixture
# spelled the other way textually "escaped" the root and leaked instead of being cleaned up.

# _t_norm <path> — set _t_normed to <path> with runs of "/" collapsed. "$TMPDIR/x" is routinely
# spelled "/a/T//x" (TMPDIR usually ends in a slash) while the same directory reached through $PWD is
# spelled "/a/T/x". Without this, two spellings of one path fail to match: the fixture leaks, and —
# worse for a test suite — a case meant to exercise some other guard passes for this reason instead,
# which is how a guard test goes quietly decorative. _t_realdir now subsumes this for both sides of
# the identity check (`pwd -P` emits a collapsed path); this remains the cheap textual tidy applied to
# the raw $TMPDIR before its shape is judged, which is what keeps an unusable root from widening.
_t_norm() {
  _t_normed="$1"
  while :; do
    case "$_t_normed" in
      *//*)
        _t_prev="$_t_normed"
        _t_normed="${_t_normed//\/\///}"          # s|//|/| — bash 3.2 wants the replacement unescaped
        # If some shell ever declines that substitution, stop rather than spin: an un-normalized path
        # simply fails the identity check below, which leaks a temp dir instead of hanging teardown.
        [ "$_t_normed" != "$_t_prev" ] || break
        ;;
      *) break ;;
    esac
  done
}

# _t_realdir <dir> — set _t_realdir_out to the physical path of <dir>, every component resolved, or
# to "" (rc 1) if it cannot be resolved. `( cd -P -- "$d" && pwd -P )` is the resolver because it is
# the only one that is actually portable here: BSD/macOS `readlink` has no `-f`, and `realpath` is not
# guaranteed installed — while `cd -P` + `pwd -P` are bash builtins present in 3.2.57 and resolve
# EVERY component, which is precisely the intermediate-symlink case. Notes on the details:
#   · CDPATH is cleared: with CDPATH set, `cd` can print the directory it chose and pick a different
#     one. (Absolute operands already bypass CDPATH, but this must not depend on that.)
#   · The `printf 'x'` sentinel is stripped back off because command substitution eats TRAILING
#     newlines — without it a directory whose name ends in a newline would resolve to a truncated
#     path, and truncating a path is how a delete lands somewhere it was never meant to.
#   · Callers must treat rc 1 as "delete nothing". Failing safe is the whole contract: an
#     unresolvable path is never a licence to fall back to the unresolved string.
_t_nl="$(printf '\nx')"; _t_nl="${_t_nl%x}"
_t_realdir() {
  _t_realdir_out=""
  [ -n "${1:-}" ] || return 1
  _t_realdir_out="$( CDPATH=''; cd -P -- "$1" 2>/dev/null && pwd -P && printf 'x' )" \
    || { _t_realdir_out=""; return 1; }
  case "$_t_realdir_out" in
    *x) _t_realdir_out="${_t_realdir_out%x}"; _t_realdir_out="${_t_realdir_out%$_t_nl}" ;;
    *)  _t_realdir_out=""; return 1 ;;      # no sentinel: `pwd -P` itself failed
  esac
  case "$_t_realdir_out" in
    /?*) return 0 ;;                        # absolute and not "/" — "/" is never a temp root or fixture
    *)   _t_realdir_out=""; return 1 ;;
  esac
}

_t_rm_fixture() {
  _t_target="${1:-}"
  [ -n "$_t_target" ] || return 0
  case "$_t_target" in
    /*) ;;
    *)  return 0 ;;          # relative entry — would delete relative to $PWD
  esac
  # Both string-shape checks below run BEFORE resolution, and must stay there: `cd -P` resolves ".."
  # away, so a `<dir>/sub/../keepme` entry would arrive at the identity check looking innocent.
  case "$_t_target" in
    */..|*/../*) return 0 ;; # no traversal components: `<dir>/sub/../keepme` IS a delete rm performs
  esac
  [ "$_t_target" = "/" ] && return 0
  [ -d "$_t_target" ] || return 0   # already gone, or never a directory
  [ -L "$_t_target" ] && return 0   # a symlink: delete nothing rather than chase it somewhere else
  # Identity: strictly inside this shell's temp root, as DIRECTORIES rather than as text (SEC-R9).
  # The raw root is slash-normalized and its trailing slashes stripped first, so an unusable root
  # refuses everything rather than widening to "/"; then both sides are resolved to physical paths, so
  # an intermediate symlink cannot carry a textually-inside target outside the root. If either side
  # fails to resolve, nothing is deleted.
  _t_norm "${TMPDIR:-/tmp}"; _t_root="$_t_normed"
  while :; do case "$_t_root" in */) _t_root="${_t_root%/}" ;; *) break ;; esac; done
  case "$_t_root" in /?*) ;; *) return 0 ;; esac
  _t_realdir "$_t_root"   || return 0
  _t_rroot="$_t_realdir_out"
  _t_realdir "$_t_target" || return 0
  _t_rtarget="$_t_realdir_out"
  case "$_t_rtarget" in
    "$_t_rroot"/?*) ;;       # quoted pattern: a glob character in $TMPDIR matches itself, literally
    *) return 0 ;;
  esac
  # Delete the path that was validated, not the spelling that arrived: they name the same directory,
  # and the resolved one is the one every check above was actually applied to.
  rm -rf "$_t_rtarget"
}

t_cleanup() {
  # 1) Every registered fixture, read back with the same NUL framing t_track wrote. `IFS=` + `-r`
  #    + `-d ''` means the record arrives byte-for-byte as registered, and the QUOTED argument keeps
  #    it one argument no matter what whitespace or glob characters it holds.
  if [ -n "$T_TMPDIR_REGISTRY" ] && [ -f "$T_TMPDIR_REGISTRY" ]; then
    # `|| [ -n "$_t_entry" ]` picks up a final record with no terminating NUL (an append that was
    # cut short) — otherwise `read` returns non-zero on it and that fixture never gets cleaned.
    _t_entry=""
    while IFS= read -r -d '' _t_entry || [ -n "$_t_entry" ]; do
      _t_rm_fixture "$_t_entry"
      _t_entry=""
    done < "$T_TMPDIR_REGISTRY"
    rm -f "$T_TMPDIR_REGISTRY"
  fi
  # 2) The retired T_TMPDIRS variable. It is NOT iterated: splitting a space-framed list back into
  #    paths is the SEC-R8 bug itself, and no amount of per-entry validation can tell a whole entry
  #    from the first fragment of one. So teardown deletes nothing from here and says so — a leaked
  #    temp dir is loud and cheap, a fragment delete is silent and destructive.
  if [ -n "${T_TMPDIRS:-}" ]; then
    printf '%s\n' \
      "tests/lib.sh: T_TMPDIRS is retired and is NOT cleaned up — space framing cannot be split back" \
      "tests/lib.sh: into paths safely (SEC-R8). Use: t_track \"\$dir\". Leaked, not deleted:" \
      "tests/lib.sh:   $T_TMPDIRS" >&2
  fi
}
trap t_cleanup EXIT

t_summary() {
  printf '  ── %d passed, %d failed\n' "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}
