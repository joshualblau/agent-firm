#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# tests/test-reviewer-hermeticity.sh — the reviewer suite's result does not depend on the machine.
#
# WHAT THIS FILE IS FOR, AND WHY IT IS A SEPARATE FILE.
# tests/test-provider-reviewers.sh drives bin/firm-reviewer-common, which imports the codex
# credential from `os.environ.get("CODEX_HOME") or ~/.codex` on every gpt attempt. For a long time
# that file named no store, so what it measured depended on whether the operator running it happened
# to be logged in to codex: green on a laptop, differently green on a runner, and reading a live
# credential either way. The isolation that closed that lives in that file's own `review_env`. THIS
# file asserts the property from the outside instead — run it twice under two different credential
# environments and the same named cases pass in both — which is the assertion that would have caught
# the defect without anyone having to already suspect it.
#
# BOTH ENVIRONMENTS ARE BUILT HERE, WHICH IS THE POINT. One CODEX_HOME is a directory this file
# creates holding a synthetic credential; the other is a path that is deliberately never created. So
# "a machine with a credential" and "a machine without one" are both reproduced on any host, the
# invariance is measurable on a host that has never seen codex, and — this is the part that matters —
# the operator's real ~/.codex is never the answer to `os.environ.get("CODEX_HOME")` in either child.
# A version of this file that measured "the operator's actual state" versus "an empty one" would
# consume the very credential store it exists to prove is not consumed, and would report a different
# thing on every host.
#
# WHAT MAKES IT ABLE TO FAIL. Comparing sets of passing case names is only a real check if some case
# in the child would actually answer differently. Exactly one does: the absence case in the codex
# credential boundary block at the end of tests/test-provider-reviewers.sh, which asserts that an
# empty store is RECORDED as absent. Remove that file's CODEX_HOME override and that case imports
# the ambient credential in the first child and finds nothing in the second, so the two passing sets
# diverge. The provenance case beside it fails in BOTH children under the same mutation — a case that
# fails everywhere diverges nowhere — so it contributes nothing here. That is why the two cases are
# specified together and why the absence case may not be dropped: deleting it makes this file green
# against a harness with no isolation at all.
#
# CHILD TRANSCRIPTS ARE CAPTURED, NEVER STREAMED. tests/run-tests.sh totals the suite by taking the
# last `passed, failed` summary line out of each file's output, so echoing a child's summary would
# make this file's numbers a second copy of another file's. What is printed here instead is derived:
# per-child counts and, on divergence, the names that differ.
#
# THIS FILE IS CLASSIFIED `requires_supported_p2` IN tests/run-tests.sh, and the reason is entirely
# derivative: it executes tests/test-provider-reviewers.sh, which is on that list because it drives
# real ledger mutation. On an `--unsupported-p2` host — which is what both hosted CI jobs are — every
# ledger write in the child fails closed, so both children would fail identically, this file's
# invariance would hold, and it would report a green that means nothing. It costs what it says it
# costs: two full runs of the largest file in the suite, paid on local full runs and the exact-P2 job.

t_case "the reviewer suite's result does not depend on the machine's credential state"

TARGET="$TESTS_DIR/test-provider-reviewers.sh"
assert_file "the file whose invariance is measured is present" "$TARGET"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-hermeticity.XXXXXX")"; t_track "$WORK"

# Environment 1: a store that holds a credential. Its content is deliberately NOT the marker
# tests/test-provider-reviewers.sh builds for itself — this stands in for the operator's store, and
# a stand-in that carried the fixture's own marker would let an unisolated harness pass by accident.
PRESENT="$WORK/store-with-a-credential"; mkdir -p "$PRESENT"
printf '{"OPENAI_API_KEY":null,"tokens":{"access_token":"AMBIENT-STORE-STANDIN-5a41"}}\n' \
  > "$PRESENT/auth.json"
chmod 600 "$PRESENT/auth.json"
# Environment 2: a path that does not exist, and is never created.
MISSING="$WORK/store-that-does-not-exist"

# The two environments must really differ, or this file compares a thing to itself and can never
# fail. Asserted, not assumed.
assert_file "the credential-bearing environment really holds a credential" "$PRESENT/auth.json"
assert_no_file "the other environment really does not exist" "$MISSING"

# run_child <label> <codex-home> — one full run of the target under one exported CODEX_HOME.
# `${BASH:-bash}` so the child runs under the same interpreter as this file: the two children must
# differ in the credential environment and in nothing else, and on macOS `bash` on PATH and the
# `/bin/bash` 3.2 CI pins are not the same program. stdin is /dev/null for the same reason
# tests/run-tests.sh gives it: a test that reads stdin must fail here the way it would in CI.
run_child() {
  env CODEX_HOME="$2" "${BASH:-bash}" "$TARGET" >"$WORK/$1.transcript" 2>&1 </dev/null
  printf '%s' "$?" > "$WORK/$1.rc"
}

# `sort` and not `sort -u`: a case name that passes twice in one child and once in the other is a
# divergence, and de-duplicating would hide it.
passing_set() { sed -n 's/^    ok   //p' "$WORK/$1.transcript" | sort; }
count_ok()    { sed -n 's/^    ok   //p' "$WORK/$1.transcript" | wc -l | tr -d ' '; }
count_fail()  { grep -c '^    FAIL ' "$WORK/$1.transcript"; }

run_child present "$PRESENT"
run_child missing "$MISSING"

for label in present missing; do
  printf '    · child %s: passing=%s failing=%s exit=%s\n' \
    "$label" "$(count_ok "$label")" "$(count_fail "$label")" "$(cat "$WORK/$label.rc")"
done

# An empty transcript would make every set comparison below true, so completion is asserted first
# and separately: the child's own exit status, and the fact that it got as far as passing anything.
assert_eq "the run against a credential-bearing store completed successfully" 0 "$(cat "$WORK/present.rc")"
assert_eq "the run against a nonexistent store completed successfully" 0 "$(cat "$WORK/missing.rc")"
assert_ne "the credential-bearing run recorded passing cases" 0 "$(count_ok present)"
assert_ne "the nonexistent-store run recorded passing cases" 0 "$(count_ok missing)"

# "No case fails in either" is the other half of the criterion, and it is stated SEPARATELY from the
# set comparison on purpose: the child carries real subprocess timeouts and real polls, so a loaded
# host can turn one case red. Split like this, that reports as a failing child — re-run it — instead
# of as a phantom breach of hermeticity, which is a much more expensive thing to be told wrongly.
assert_eq "no case fails when a credential is present" 0 "$(count_fail present)"
assert_eq "no case fails when no credential exists" 0 "$(count_fail missing)"

passing_set present > "$WORK/passing.present"
passing_set missing > "$WORK/passing.missing"
assert_eq "both runs recorded the same number of passing cases" \
  "$(count_ok present)" "$(count_ok missing)"

diff "$WORK/passing.present" "$WORK/passing.missing" > "$WORK/divergence" 2>&1
divergence="$(grep '^[<>]' "$WORK/divergence" | head -8 | tr '\n' '|')"
if [ -n "$divergence" ]; then
  printf '    !! cases whose result differs between the two credential environments:\n'
  grep '^[<>]' "$WORK/divergence" | head -20 | while IFS= read -r line; do
    case "$line" in
      '<'*) printf '    !!   passes ONLY when a credential is present: %s\n' "${line#< }" ;;
      '>'*) printf '    !!   passes ONLY when no credential exists:    %s\n' "${line#> }" ;;
    esac
  done
fi
assert_eq "the same set of named cases passes under both credential environments" "" "$divergence"

t_summary
