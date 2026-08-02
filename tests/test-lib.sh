#!/usr/bin/env bash
# tests/test-lib.sh — the harness tests the harness.
#
# lib.sh is sourced by EVERY other test file, so a defect in it is invisible in the worst way: the
# other suites keep printing "ok" while quietly doing less than they claim. Two properties are pinned
# here, both of which were previously broken:
#
#   1. Teardown ACTUALLY RUNS for fixtures created inside a `$(mk_repo)` subshell. It did not.
#      mk_repo/mk_linked_worktree are invoked as `d="$(mk_repo)"`, so their `T_TMPDIRS=...` append
#      happened in a command-substitution subshell that then exited; the parent's EXIT trap iterated
#      an empty list and every suite run leaked throwaway git repos into $TMPDIR forever.
#
#   2. Teardown CANNOT WIDEN. The cleanup loop expanded `$T_TMPDIRS` UNQUOTED straight into `rm -rf`,
#      so a glob character reaching that variable would expand against the cleanup shell's $PWD and
#      delete whatever happened to be sitting there. That is the more dangerous of the two by far.
#
# Every case runs lib.sh in a CHILD bash and inspects what survived, because the behaviour under test
# is an EXIT trap — which by definition only fires when a shell exits.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

child() { # <cwd> <tmpdir> <bash code> — source lib.sh in a child shell and let it exit for real
  ( cd "$1" && TMPDIR="$2" /bin/bash -c ". '$TESTS_DIR/lib.sh'; $3" )
}

# ---------------------------------------------------------------------------
t_case "teardown removes a fixture created inside a \$(mk_repo) subshell"
sandbox="$(mk_repo)"; mkdir -p "$sandbox/tmp"
made="$(child "$sandbox" "$sandbox/tmp/" 'd="$(mk_repo)"; printf "%s" "$d"')"
assert_ne  "the child really created a fixture" "" "$made"
assert_eq  "and it really was a git repo (so this is the same fixture other suites use)" \
  "" "$(ls -A "$sandbox/tmp" 2>/dev/null)"
assert_no_file "the EXIT trap deleted it" "$made"
assert_file "and the child's teardown did NOT touch the parent's own fixture" "$sandbox"

t_case "teardown removes a mk_linked_worktree fixture too (also created in a subshell)"
sandbox2="$(mk_repo)"; mkdir -p "$sandbox2/tmp"
made2="$(child "$sandbox2" "$sandbox2/tmp/" 'r="$(mk_repo)"; p="$(mk_linked_worktree "$r" some-branch)"; printf "%s" "$p"')"
assert_ne "the child really created a linked worktree" "" "$made2"
assert_no_file "the worktree fixture is gone" "$made2"
assert_eq "and its parent temp dir went with it — nothing left in the child's TMPDIR" \
  "" "$(ls -A "$sandbox2/tmp" 2>/dev/null)"

t_case "the registry is NOT exported, so a child's teardown can never reach the parent's fixtures"
assert_eq "T_TMPDIR_REGISTRY is unset in a child process" \
  "" "$(/bin/bash -c 'printf "%s" "${T_TMPDIR_REGISTRY:-}"')"

# ---------------------------------------------------------------------------
t_case "SEC-016 · a glob in T_TMPDIRS cannot widen what teardown deletes"
# The cleanup shell is `cd`'d into $victim, so an unquoted `*` would expand to that directory's
# contents and rm -rf them. The bystanders below are the canaries.
victim="$(mk_repo)"; mkdir -p "$victim/tmp" "$victim/do-not-delete-a" "$victim/do-not-delete-b"
printf 'precious\n' > "$victim/do-not-delete-a/keep.txt"
child "$victim" "$victim/tmp/" 'T_TMPDIRS="$T_TMPDIRS *"' >/dev/null 2>&1
assert_file "a bystander directory in the cleanup shell's CWD survived" "$victim/do-not-delete-a"
assert_file "so did its contents"                                       "$victim/do-not-delete-a/keep.txt"
assert_file "and so did the second bystander"                           "$victim/do-not-delete-b"
assert_file "and the repo's own seed file"                              "$victim/seed.txt"

t_case "SEC-016 · other hostile T_TMPDIRS entries are refused rather than acted on"
# SAFETY NOTE — read before adding an entry here. Every string below is fed to a LIVE teardown, so
# the blast radius if the guard under test ever regresses is real, not hypothetical. Each entry is
# therefore chosen to resolve INSIDE this disposable sandbox and nowhere else.
# `/` is deliberately NOT tested. _t_rm_fixture refuses it, but the only way to test that is to hand
# `/` to a live `rm -rf` and hope the guard holds — and a harness regression would then be limited
# only by whatever the OS happens to refuse. That trade is not worth one assertion; the `/` guard is
# a single line reviewed by eye.
victim2="$(mk_repo)"; mkdir -p "$victim2/tmp" "$victim2/keepme" "$victim2/sub"
child "$victim2" "$victim2/tmp/" 'T_TMPDIRS="$T_TMPDIRS keepme $PWD/sub/.."' >/dev/null 2>&1
assert_file "a RELATIVE entry did not delete anything relative to \$PWD" "$victim2/keepme"
assert_file "an absolute entry with a '..' component was refused"        "$victim2/sub"
assert_file "so the fixture root it would have resolved to is untouched" "$victim2/seed.txt"

# ---------------------------------------------------------------------------
t_case "a fixture path containing a space stays ONE entry and is still cleaned up"
spacey="$(mk_repo)"; mkdir -p "$spacey/tmp dir"
made3="$(child "$spacey" "$spacey/tmp dir/" 'd="$(mk_repo)"; printf "%s" "$d"')"
assert_output "the fixture path really did contain a space" " " printf '%s' "$made3"
assert_no_file "teardown still removed it whole" "$made3"
assert_eq "nothing left behind in the space-containing TMPDIR" "" "$(ls -A "$spacey/tmp dir" 2>/dev/null)"

# ---------------------------------------------------------------------------
t_case "the legacy channel still works: a direct T_TMPDIRS append is cleaned up"
# Six other test files append to T_TMPDIRS by hand. That path must keep working — the registry is an
# addition, not a replacement.
legacy="$(mk_repo)"; mkdir -p "$legacy/tmp"
made4="$(child "$legacy" "$legacy/tmp/" \
  'd="$(mktemp -d "${TMPDIR}legacy.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $d"; printf "%s" "$d"')"
assert_ne  "the child created a directly-registered dir" "" "$made4"
assert_no_file "and teardown removed it" "$made4"

t_summary
