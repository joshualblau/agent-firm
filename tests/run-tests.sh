#!/usr/bin/env bash
# tests/run-tests.sh [--unsupported-p2] [test-name ...]
# Runs the firm's own test suite. No test framework — just bash + git, plus the firm's own declared
# python3 prerequisites: jsonschema (test-validate-verdict) and pyyaml (test-policy-yaml-valid). Those
# two files FAIL if the packages are absent; the rest of the suite runs. See tests/lib.sh for why.
#
#   tests/run-tests.sh                 # everything
#   tests/run-tests.sh integrate       # just tests/test-integrate.sh
#   tests/run-tests.sh --unsupported-p2 # suites safe on a host where ledger writes must fail closed
#   /bin/bash tests/run-tests.sh       # force macOS bash 3.2 (what CI does on the macos runner)
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _d="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  case $_src in /*) ;; *) _src="$_d/$_src";; esac
done
TESTS_DIR="$(cd -P "$(dirname "$_src")" && pwd)"

profile=full
case "${1:-}" in
  --unsupported-p2) profile=unsupported-p2; shift ;;
  --*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

# These suites intentionally exercise successful ledger mutation or consume events emitted by that
# mutation. Running them on a host outside the exact P2 row would test a configuration the production
# writer explicitly rejects. Keep the exclusion closed and named: a new test runs by default and must
# be consciously classified here if it really requires a supported write host.
requires_supported_p2() {
  case "$1" in
    check-assertions|final-qa-check|ledger-compatibility|ledger-log|ledger-role-start|merge-guard|\
    new-worktree|policy-hire|provider-reviewers|qa-checkout|qa-clean-check) return 0 ;;
    *) return 1 ;;
  esac
}

printf 'firm test suite  (bash %s; profile %s)\n' "${BASH_VERSION%%(*}" "$profile"

want="$*"
rc=0
files=0
skipped=0

for f in "$TESTS_DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .sh)"; name="${name#test-}"
  if [ -n "$want" ]; then
    match=0
    for w in $want; do [ "$w" = "$name" ] && match=1; done
    [ "$match" -eq 1 ] || continue
  fi
  if [ "$profile" = unsupported-p2 ] && requires_supported_p2 "$name"; then
    skipped=$((skipped+1))
    printf '\n%s\n  SKIP — requires the exact supported P2 write host\n' "$name"
    continue
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
if [ "$skipped" -gt 0 ]; then printf '%d exact-P2 test files skipped by profile\n' "$skipped"; fi
if [ "$rc" -eq 0 ]; then printf 'all test files passed\n'; else printf 'FAILURES — see above\n'; fi
exit "$rc"
