#!/usr/bin/env bash
# tests/test-lib.sh — the harness tests the harness.
#
# lib.sh is sourced by EVERY other test file, so a defect in it is invisible in the worst way: the
# other suites keep printing "ok" while quietly doing less than they claim. And its teardown runs
# `rm -rf`, so a defect there does not just fail a test — it deletes a directory. Three properties are
# pinned here, all of which were previously broken:
#
#   1. Teardown ACTUALLY RUNS for fixtures created inside a `$(mk_repo)` subshell. It did not.
#      mk_repo/mk_linked_worktree are invoked as `d="$(mk_repo)"`, so a `T_TMPDIRS=...` variable
#      append happened in a command-substitution subshell that then exited; the parent's EXIT trap
#      iterated an empty list and every suite run leaked throwaway git repos into $TMPDIR.
#
#   2. Teardown CANNOT WIDEN. The cleanup loop expanded `$T_TMPDIRS` UNQUOTED straight into `rm -rf`,
#      so a glob character reaching that variable would expand against the cleanup shell's $PWD and
#      delete whatever happened to be sitting there.
#
#   3. Teardown DELETES WHOLE ENTRIES ONLY (SEC-R8). Both accumulators used to frame entries with a
#      delimiter that can legally occur inside a path, so a fixture path containing a space (the
#      T_TMPDIRS variable) or a newline (the old newline-framed registry) split into FRAGMENTS — and
#      the first fragment of an absolute path is itself absolute, passes every shape check, and gets
#      deleted while the real fixture leaks. A live reproduction deleted an unrelated directory.
#
# HOW THESE CASES ARE BUILT — read before adding one.
#   · Every case runs lib.sh in a CHILD bash and inspects what survived, because the behaviour under
#     test is an EXIT trap, which by definition only fires when a shell exits.
#   · Every path a case hands to a live teardown resolves INSIDE a fresh mktemp -d sandbox. No
#     literal `/`, no `$HOME`, no repo path, nothing this file did not just create. `/` itself is
#     deliberately NOT tested: the only way to test it is to hand `/` to a live `rm -rf` and hope the
#     guard holds. That trade is not worth one assertion; the `/` guard is one line, reviewed by eye.
#   · _t_rm_fixture applies FIVE guards and two of them (absolute-path, and "under this shell's temp
#     root") overlap. A case that means to exercise one specific guard therefore has to be arranged
#     so the OTHERS cannot be what saves the canary — hence the `control` directory most cases
#     register and then assert was deleted: it proves teardown ran AND that deleting at that exact
#     location was permitted, so the canary's survival can only be the guard under test.
#   · Do not let an OS backstop stand in for a guard. `/bin/rm -rf X/sub/..` is refused by rm itself
#     ("." and ".." may not be removed), so that shape can never exercise lib.sh's traversal check;
#     `rm -rf X/sub/../keepme` is a delete rm performs happily, which is why that is the shape used.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

child() { # <cwd> <tmpdir> <bash code> — source lib.sh in a child shell and let it exit for real
  ( cd "$1" && TMPDIR="$2" /bin/bash -c ". '$TESTS_DIR/lib.sh'; $3" )
}

# A disposable sandbox with a `tmp/` subdir for the child to use as its TMPDIR. Echoes its path.
sandbox() {
  local _d
  _d="$(mktemp -d "${TMPDIR:-/tmp}/firm-libtest.XXXXXX")"
  t_track "$_d"
  mkdir -p "$_d/tmp"
  printf '%s' "$_d"
}

# ---------------------------------------------------------------------------
t_case "teardown removes a fixture created inside a \$(mk_repo) subshell"
sb="$(mk_repo)"; mkdir -p "$sb/tmp"
made="$(child "$sb" "$sb/tmp/" 'd="$(mk_repo)"; printf "%s" "$d"')"
assert_ne  "the child really created a fixture" "" "$made"
assert_eq  "and it really was a git repo (so this is the same fixture other suites use)" \
  "" "$(ls -A "$sb/tmp" 2>/dev/null)"
assert_no_file "the EXIT trap deleted it" "$made"
assert_file "and the child's teardown did NOT touch the parent's own fixture" "$sb"

t_case "teardown removes a mk_linked_worktree fixture too (also created in a subshell)"
sb2="$(mk_repo)"; mkdir -p "$sb2/tmp"
made2="$(child "$sb2" "$sb2/tmp/" 'r="$(mk_repo)"; p="$(mk_linked_worktree "$r" some-branch)"; printf "%s" "$p"')"
assert_ne "the child really created a linked worktree" "" "$made2"
assert_no_file "the worktree fixture is gone" "$made2"
assert_eq "and its parent temp dir went with it — nothing left in the child's TMPDIR" \
  "" "$(ls -A "$sb2/tmp" 2>/dev/null)"

t_case "the registry is NOT exported, so a child's teardown can never reach the parent's fixtures"
assert_eq "T_TMPDIR_REGISTRY is unset in a child process" \
  "" "$(/bin/bash -c 'printf "%s" "${T_TMPDIR_REGISTRY:-}"')"

# ---------------------------------------------------------------------------
# SEC-R8 · WHOLE-ENTRY FRAMING. One case per delimiter that can occur inside a path, each with a
# bystander named after the FRAGMENT that entry would split into, and each with a `control` fixture
# proving teardown was permitted to delete at that same location.
# ---------------------------------------------------------------------------
t_case "SEC-R8 · a fixture path containing a SPACE, via the retired T_TMPDIRS channel, deletes nothing"
# The exact reproduction from the SEC-R8 finding: with TMPDIR under a space-containing path, the
# space-framed variable word-splits "<root>/my dir.XXXXXX" into "<root>/my" — absolute, non-root,
# traversal-free, a real directory, not a symlink, and (here, deliberately) inside the temp root, so
# every one of the five guards passes and the wrong directory dies. Nothing may be deleted from this
# channel now; the fixture LEAKS instead, which is the cheap failure, and teardown says so on stderr.
spc="$(sandbox)"; mkdir -p "$spc/tmp/my"; printf 'precious\n' > "$spc/tmp/my/PRECIOUS.txt"
made3="$(child "$spc" "$spc/tmp/" \
  'mkdir -p "${TMPDIR}control"; t_track "${TMPDIR}control"; d="$(mktemp -d "${TMPDIR}my dir.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $d"; printf "%s" "$d"  # legacy-append-ok: this case proves the channel is inert' \
  2>"$spc/err.txt")"
assert_output "the fixture path really did contain a space" " " printf '%s' "$made3"
assert_no_file "the control fixture WAS deleted, so teardown ran and could delete here" "$spc/tmp/control"
assert_file "the fragment directory the space would split off survived" "$spc/tmp/my"
assert_file "and so did its contents"                                   "$spc/tmp/my/PRECIOUS.txt"
assert_file "the T_TMPDIRS entry leaked rather than being deleted (the documented trade)" "$made3"
assert_output "and teardown warned that the channel is retired" "T_TMPDIRS is retired" cat "$spc/err.txt"

t_case "SEC-R8 · whitespace in a fixture path never splits it: SPACE and TAB via t_track"
ws="$(sandbox)"
mkdir -p "$ws/tmp/sp" "$ws/tmp/ta"
printf 'keep\n' > "$ws/tmp/sp/keep.txt"; printf 'keep\n' > "$ws/tmp/ta/keep.txt"
made4="$(child "$ws" "$ws/tmp/" \
  'a="$(mktemp -d "${TMPDIR}sp ace.XXXXXX")"; b="$(mktemp -d "${TMPDIR}ta$(printf "\t")b.XXXXXX")"; t_track "$a"; t_track "$b"; printf "%s\n%s" "$a" "$b"')"
sp_made="$(printf '%s' "$made4" | sed -n 1p)"; ta_made="$(printf '%s' "$made4" | sed -n 2p)"
assert_output "the first fixture path really did contain a space" " "            printf '%s' "$sp_made"
assert_output "the second really did contain a tab"               "$(printf '\t')" printf '%s' "$ta_made"
assert_no_file "the space-containing fixture was removed, whole" "$sp_made"
assert_no_file "the tab-containing fixture was removed, whole"   "$ta_made"
assert_file "the sibling the space would have split off survived" "$ws/tmp/sp"
assert_file "…with its contents"                                  "$ws/tmp/sp/keep.txt"
assert_file "the sibling the tab would have split off survived"   "$ws/tmp/ta"
assert_file "…with its contents"                                  "$ws/tmp/ta/keep.txt"

t_case "SEC-R8 · a fixture path containing a NEWLINE is registered and removed whole"
# This is the delimiter the previous registry chose, so it is the one the previous registry split on.
nlx="$(sandbox)"; mkdir -p "$nlx/tmp/nl"; printf 'precious\n' > "$nlx/tmp/nl/PRECIOUS.txt"
made5="$(child "$nlx" "$nlx/tmp/" \
  'NL="$(printf "\nx")"; NL="${NL%x}"; mkdir -p "${TMPDIR}control"; t_track "${TMPDIR}control"; d="$(mktemp -d "${TMPDIR}nl${NL}b.XXXXXX")"; t_track "$d"; printf "%s" "$d"')"
assert_eq "the fixture path really did contain exactly one newline" \
  "1" "$(printf '%s' "$made5" | wc -l | tr -d ' ')"
assert_no_file "the control fixture was deleted, so teardown ran" "$nlx/tmp/control"
assert_no_file "the newline-containing fixture was removed, whole" "$made5"
assert_file "the fragment directory the newline would split off survived" "$nlx/tmp/nl"
assert_file "and so did its contents"                                     "$nlx/tmp/nl/PRECIOUS.txt"

t_case "SEC-R8 · a fixture path containing a GLOB character removes itself and nothing else"
# `keep*me` as a PATTERN matches the literal `keep*me` AND the bystander `keepXme`, so an unquoted
# expansion anywhere on the delete path takes both. Only the literal directory may go.
gl="$(sandbox)"; mkdir -p "$gl/tmp/keepXme"; printf 'keep\n' > "$gl/tmp/keepXme/keep.txt"
child "$gl" "$gl/tmp/" \
  'mkdir -p "${TMPDIR}keep*me"; t_track "${TMPDIR}keep*me"' >/dev/null 2>&1
assert_no_file "the literal glob-named fixture was removed" "$gl/tmp/keep*me"
assert_file "the bystander its pattern would also have matched survived" "$gl/tmp/keepXme"
assert_file "…with its contents"                                         "$gl/tmp/keepXme/keep.txt"

# ---------------------------------------------------------------------------
# The per-entry guards in _t_rm_fixture, each exercised through t_track — the LIVE channel. Feeding
# them through T_TMPDIRS would prove nothing now: that channel refuses everything, so the case would
# pass with the guard deleted.
# ---------------------------------------------------------------------------
t_case "SEC-016 · an absolute glob in the retired T_TMPDIRS channel cannot widen what teardown deletes"
# The cleanup shell is `cd`'d into the child's own TMPDIR, so `$PWD/*` expands to absolute paths that
# are inside the temp root — the identity guard cannot be what saves them, and the `control` fixture
# below proves teardown was allowed to delete right there. Only the channel's refusal stops this.
vg="$(sandbox)"; mkdir -p "$vg/tmp/do-not-delete-a" "$vg/tmp/do-not-delete-b"
printf 'precious\n' > "$vg/tmp/do-not-delete-a/keep.txt"
child "$vg/tmp" "$vg/tmp/" \
  'mkdir -p "${TMPDIR}control"; t_track "${TMPDIR}control"; T_TMPDIRS="$T_TMPDIRS $PWD/*"  # legacy-append-ok: this case proves the channel is inert' \
  >/dev/null 2>&1
assert_no_file "the control fixture WAS deleted, so teardown ran and could delete here" "$vg/tmp/control"
assert_file "a bystander directory in the cleanup shell's CWD survived" "$vg/tmp/do-not-delete-a"
assert_file "so did its contents"                                       "$vg/tmp/do-not-delete-a/keep.txt"
assert_file "and so did the second bystander"                           "$vg/tmp/do-not-delete-b"

t_case "SEC-016 · a '..' entry that rm WOULD execute is refused by the guard, not by the OS"
# `$PWD/sub/../keepme` resolves to `$PWD/keepme`, is inside the temp root, and is a delete /bin/rm
# performs without complaint. The traversal guard is the only thing standing in front of it.
tv="$(sandbox)"; mkdir -p "$tv/tmp/sub" "$tv/tmp/keepme"
printf 'precious\n' > "$tv/tmp/keepme/keep.txt"
child "$tv/tmp" "$tv/tmp/" \
  'mkdir -p "${TMPDIR}control"; t_track "${TMPDIR}control"; t_track "$PWD/sub/../keepme"' >/dev/null 2>&1
assert_no_file "the control fixture WAS deleted, so teardown ran and could delete here" "$tv/tmp/control"
assert_file "the directory the '..' entry resolves to survived" "$tv/tmp/keepme"
assert_file "…with its contents"                                "$tv/tmp/keepme/keep.txt"
assert_file "and the traversal's own intermediate directory is untouched" "$tv/tmp/sub"

t_case "a RELATIVE entry is never resolved against \$PWD"
# Guarded twice on purpose — by the absolute-path check and, independently, by the temp-root check.
# Neither deletion alone turns this red; see 09-test-evidence for the both-removed mutation.
rv="$(sandbox)"; mkdir -p "$rv/tmp/keepme"; printf 'precious\n' > "$rv/tmp/keepme/keep.txt"
child "$rv/tmp" "$rv/tmp/" \
  'mkdir -p "${TMPDIR}control"; t_track "${TMPDIR}control"; t_track keepme' >/dev/null 2>&1
assert_no_file "the control fixture WAS deleted, so teardown ran and could delete here" "$rv/tmp/control"
assert_file "the directory a relative entry would have hit survived" "$rv/tmp/keepme"
assert_file "…with its contents"                                     "$rv/tmp/keepme/keep.txt"

t_case "a registered path OUTSIDE this shell's temp root is refused on identity, not shape"
# Well-formed by every shape rule — absolute, not "/", no "..", a real non-symlink directory — and
# still not ours to delete, because a fixture lives under the temp root this shell creates them in.
ov="$(sandbox)"; mkdir -p "$ov/outsider"; printf 'precious\n' > "$ov/outsider/keep.txt"
child "$ov" "$ov/tmp/" \
  'mkdir -p "${TMPDIR}control"; t_track "${TMPDIR}control"; t_track "$PWD/outsider"' >/dev/null 2>&1
assert_no_file "the control fixture inside the temp root WAS deleted" "$ov/tmp/control"
assert_file "the directory outside the temp root survived" "$ov/outsider"
assert_file "…with its contents"                           "$ov/outsider/keep.txt"

# ---------------------------------------------------------------------------
t_case "no test file registers fixtures through the retired T_TMPDIRS channel"
# The variable is inert now, so an append here is a silent leak rather than a wrong delete — but it
# is also how SEC-R8 came back the first time. Lines marked `legacy-append-ok` are this file's own
# two cases above, which exist precisely to prove the channel deletes nothing.
offenders="$(grep -n 'T_TMPDIRS="\$T_TMPDIRS' "$TESTS_DIR"/*.sh 2>/dev/null | grep -v 'legacy-append-ok')"
assert_eq "every fixture is registered with t_track" "" "$offenders"

t_summary
