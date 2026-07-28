#!/usr/bin/env bash
# tests/run-tests.sh [test-name ...]
# Runs the firm's own test suite. No dependencies beyond bash + git — see tests/lib.sh for why.
#
#   tests/run-tests.sh                 # everything
#   tests/run-tests.sh integrate       # just tests/test-integrate.sh
#   /bin/bash tests/run-tests.sh       # force macOS bash 3.2 (what CI does on the macos runner)
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _d="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  case $_src in /*) ;; *) _src="$_d/$_src";; esac
done
TESTS_DIR="$(cd -P "$(dirname "$_src")" && pwd)"

printf 'firm test suite  (bash %s)\n' "${BASH_VERSION%%(*}"

want="$*"
rc=0
files=0

for f in "$TESTS_DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .sh)"; name="${name#test-}"
  if [ -n "$want" ]; then
    match=0
    for w in $want; do [ "$w" = "$name" ] && match=1; done
    [ "$match" -eq 1 ] || continue
  fi
  files=$((files+1))
  printf '\n%s\n' "$name"
  if bash "$f"; then :; else rc=1; fi
done

if [ "$files" -eq 0 ]; then
  printf 'no test files matched%s\n' "${want:+ ($want)}"
  exit 1
fi

printf '\n────────\n'
if [ "$rc" -eq 0 ]; then printf 'all test files passed\n'; else printf 'FAILURES — see above\n'; fi
exit "$rc"
