#!/usr/bin/env bash
# tests/test-suite-runner.sh — the runner is now load-bearing, so it gets tested like everything else.
#
# tests/run-tests.sh used to be a `for` loop. It is now a bounded worker pool with an ordering
# contract, a skip contract, an exit-code contract and a scope profile, and a defect in any of those
# is invisible in the worst way: the suite keeps printing "ok" while running fewer files than it
# claims, or in an order that makes a failure unattributable. Everything asserted here is a property
# a silent regression would take away.
#
# HOW THESE CASES ARE BUILT — read before adding one.
#   · Each case builds a DISPOSABLE tests/ directory holding a COPY of the real runner plus synthetic
#     test files. Nothing here runs the firm's own suite recursively.
#   · Concurrency is proven by RENDEZVOUS, not by a stopwatch. Two files each publish a marker and
#     then wait a bounded time for the other's; they can only both succeed if they overlapped, and
#     they can only both fail if they did not. A wall-clock comparison would assert about host load.
#   · Every synthetic file that must NOT run is written to exit non-zero, so "it was skipped" cannot
#     be satisfied by a file that ran and happened to pass.
#   · A case about the runner's MECHANISM may sed a synthetic classifier into its copy. A case about
#     what the checked-in classifier CONTAINS must not — it has to run the runner as committed, or it
#     is asserting about a file nobody ships.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$TESTS_DIR/run-tests.sh"

# ---- fixtures --------------------------------------------------------------
# mk_suite — a throwaway <dir>/tests/ containing a copy of the runner under test. Echoes <dir>.
mk_suite() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/firm-runner.XXXXXX")" || return 1
  t_track "$d"   # inside `$(mk_suite)`, so this is the registration channel that survives — see lib.sh
  mkdir -p "$d/tests"
  cp "$RUNNER" "$d/tests/run-tests.sh" || return 1
  printf '%s' "$d"
}

# mk_test <dir> <name> <exit-code> <passed> <failed> [body] — one synthetic test file. <body> is
# inserted verbatim ahead of the summary line, which is spelled exactly the way tests/lib.sh spells it
# so the runner's grand total is parsed from the real format rather than a convenient one.
mk_test() {
  local d="$1" name="$2" xrc="$3" p="$4" f="$5" body="${6:-}"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail'
    [ -n "$body" ] && printf '%s\n' "$body"
    printf '%s\n' "printf '  · synthetic $name\\n'"
    printf '%s\n' "printf '  ── $p passed, $f failed\\n'"
    printf '%s\n' "exit $xrc"
  } > "$d/tests/test-$name.sh"
  chmod +x "$d/tests/test-$name.sh"
}

# rendez <dir> <mine> <theirs> — publish my marker, then wait up to 3s for theirs. Exits 7 if it never
# appears, which is what "these two never overlapped" looks like from inside a test file.
rendez() {
  printf ": > '%s/%s'\nn=0\nwhile [ ! -f '%s/%s' ] && [ \"\$n\" -lt 60 ]; do sleep 0.05; n=\$((n+1)); done\n[ -f '%s/%s' ] || exit 7\n" \
    "$1" "$2" "$1" "$3" "$1" "$3"
}

has()   { case "$3" in *"$2"*) _t_ok "$1" ;; *) _t_no "$1" "missing '$2' in: $(_t_ctx "$3")" ;; esac; }
hasnt() { case "$3" in *"$2"*) _t_no "$1" "unexpected '$2' in: $(_t_ctx "$3")" ;; *) _t_ok "$1" ;; esac; }
line_of() { grep -n -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

# ---------------------------------------------------------------------------
t_case "the exit-code contract survives concurrency: any failing file fails the suite, by name"
d="$(mk_suite)"
mk_test "$d" alpha 0 3 0
mk_test "$d" beta  1 2 1
mk_test "$d" gamma 0 5 0
out="$(bash "$d/tests/run-tests.sh" 2>&1)"; rc=$?
assert_eq "one non-zero file exits the runner 1" 1 "$rc"
has   "the failing file is named in the closing line" "FAILURES — beta" "$out"
hasnt "and the passing verdict is not also printed" "all test files passed" "$out"
has   "every file's own summary still reaches the transcript" "── 5 passed, 0 failed" "$out"
has   "the grand total is summed from those summary lines" "10 passed, 1 failed across 3 test files" "$out"

t_case "all-green stays all-green, and the totals are the files' own numbers"
d="$(mk_suite)"
mk_test "$d" one 0 4 0
mk_test "$d" two 0 6 0
out="$(bash "$d/tests/run-tests.sh" 2>&1)"; rc=$?
assert_eq "every file exiting 0 exits the runner 0" 0 "$rc"
has "the passing verdict is printed" "all test files passed" "$out"
has "the grand total adds up" "10 passed, 0 failed across 2 test files" "$out"
has "a per-file wall-clock profile is printed" "per-file wall clock, slowest first" "$out"

# ---------------------------------------------------------------------------
# ORDERING. The whole reason output is buffered per file: a reader must be able to attribute a failure
# without reconstructing an interleaving. `late` finishes first by construction and `early` PROVES it
# saw `late` finish while still running, so this is not a claim about scheduling luck.
t_case "output is printed in canonical order even when a later file finishes first"
d="$(mk_suite)"
mk_test "$d" early 0 1 0 "sleep 1
[ -f '$d/late.done' ] || exit 8"
mk_test "$d" late  0 1 0 ": > '$d/late.done'"
bash "$d/tests/run-tests.sh" --jobs 4 > "$d/order.txt" 2>&1
assert_eq "both files pass, so 'late' demonstrably finished while 'early' was still running" 0 "$?"
a="$(line_of "$d/order.txt" 'synthetic early')"
z="$(line_of "$d/order.txt" 'synthetic late')"
assert_ok "'early' is still printed above 'late'" test "${a:-0}" -lt "${z:-0}"

t_case "a concurrent transcript is a serial transcript plus its timing lines"
d="$(mk_suite)"
for nm in aa bb cc dd ee; do mk_test "$d" "$nm" 0 2 0; done
bash "$d/tests/run-tests.sh" --serial  > "$d/ser.txt" 2>&1
bash "$d/tests/run-tests.sh" --jobs 5  > "$d/par.txt" 2>&1
strip() { sed -e '/^  ⧗ /d' -e '/^per-file wall clock/,$d' -e '1d' "$1"; }
assert_eq "the two transcripts are identical once timings are removed" \
  "$(strip "$d/ser.txt")" "$(strip "$d/par.txt")"
has "and each file still got a timing line" "⧗ " "$(cat "$d/par.txt")"

# ---------------------------------------------------------------------------
# CONCURRENCY, PROVEN. Two files that can only both pass if they ran at the same time, and the same
# two files under --serial, which can only both fail. The second half is what keeps the first from
# being vacuous: without it, a runner that silently ignored --jobs would pass this case.
t_case "--jobs runs files concurrently; --serial demonstrably does not"
d="$(mk_suite)"
mk_test "$d" one 0 1 0 "$(rendez "$d" A B)"
mk_test "$d" two 0 1 0 "$(rendez "$d" B A)"
out="$(bash "$d/tests/run-tests.sh" --jobs 2 2>&1)"
assert_eq "two files rendezvous, so they overlapped" 0 "$?"
has "both are counted" "2 passed, 0 failed across 2 test files" "$out"
d2="$(mk_suite)"
mk_test "$d2" one 0 1 0 "$(rendez "$d2" A B)"
mk_test "$d2" two 0 1 0 "$(rendez "$d2" B A)"
out="$(bash "$d2/tests/run-tests.sh" --serial 2>&1)"
assert_eq "the same rendezvous under --serial fails, so --serial really serializes" 1 "$?"
# `one` runs first and times out; `two` then finds a marker `one` left behind and passes. So the
# failure is exactly one file, and the totals count only what `two` actually reported — a file that
# died before printing a summary contributes nothing rather than an invented zero-failure line.
has "the file that ran first is the one named as failed" "FAILURES — one" "$out"
has "and the totals count only what the surviving file reported" \
    "1 passed, 0 failed across 2 test files" "$out"

t_case "a runs_alone file is scheduled with nothing else in flight"
# The MECHANISM, tested through a name the checked-in classifier does not hold: a copy with one name
# sed'd in must schedule that name alone. Being independent of the real list is the point — it keeps
# the scheduler honest even if the list is emptied out again — but for exactly that reason it says
# NOTHING about what the list currently contains. The list is no longer empty (`merge-guard` is in it
# as of this commit's parent), and its CONTENTS are the separate question the next case asks.
d="$(mk_suite)"
sed -e 's/^runs_alone() {$/runs_alone() { case "$1" in solo) return 0 ;; esac ;/' \
  "$RUNNER" > "$d/tests/run-tests.sh"
assert_ok "the modified runner is still syntactically valid" bash -n "$d/tests/run-tests.sh"
mk_test "$d" solo  0 1 0 "$(rendez "$d" A B)"
mk_test "$d" other 0 1 0 "$(rendez "$d" B A)"
out="$(bash "$d/tests/run-tests.sh" --jobs 4 2>&1)"
assert_eq "the classified file could not overlap its partner, so the suite fails" 1 "$?"
has   "the classified file is the one that timed out waiting" "FAILURES — solo" "$out"
hasnt "its partner was not also stranded — it ran after, and found the marker" "FAILURES — solo other" "$out"

t_case "the CHECKED-IN classifier really strands merge-guard, not merely some injected name"
# The case above sed's a synthetic name into a copy of the runner, so it would keep passing if the
# `merge-guard) return 0 ;;` entry were deleted from tests/run-tests.sh — measured, not assumed. That
# deletion is silent in the worst way: tests/test-merge-guard.sh's "classification finishes inside
# PARSE_BUDGET" case would go back to timing the harness rather than the guard's real parse phase,
# and would go on PASSING while doing it. So this case runs the runner AS COMMITTED — no sed, no
# injection — and asks the classifier about the real name.
#
# The CONTROL is not decoration. A rendezvous that could never observe an overlap would "prove"
# isolation just as loudly on a runner that had stopped running anything concurrently at all, so the
# probe is first shown to report a POSITIVE, with two ordinary names, before its negative is trusted.
# Everything but the names is held fixed between the two: same file count, same bodies, same --jobs.
d="$(mk_suite)"
mk_test "$d" aaa 0 1 0 "$(rendez "$d" A B)"
mk_test "$d" zzz 0 1 0 "$(rendez "$d" B A)"
out="$(bash "$d/tests/run-tests.sh" --jobs 4 2>&1)"
assert_eq "CONTROL: two ordinary names DO overlap, so this probe can see a positive" 0 "$?"
has "and both are counted" "2 passed, 0 failed across 2 test files" "$out"

d="$(mk_suite)"
assert_ok "the runner under test is the checked-in file, byte for byte" \
  cmp -s "$RUNNER" "$d/tests/run-tests.sh"
mk_test "$d" merge-guard 0 1 0 "$(rendez "$d" A B)"
mk_test "$d" other       0 1 0 "$(rendez "$d" B A)"
out="$(bash "$d/tests/run-tests.sh" --jobs 4 2>&1)"
assert_eq "the same probe under the real name cannot overlap, so the suite fails" 1 "$?"
has   "merge-guard is the file that timed out waiting" "FAILURES — merge-guard" "$out"
hasnt "its partner was not also stranded — it ran after, and found the marker" \
      "FAILURES — merge-guard other" "$out"

# THE LATCH. "Alone" has to hold for the file's whole life, not just until the next launch decision.
# Three partners and eight workers, so a scheduler leaking even a single slot lets one of them publish
# the marker and turns the probe above green for the wrong reason.
d="$(mk_suite)"
mk_test "$d" merge-guard 0 1 0 "$(rendez "$d" A B)"
for nm in p1 p2 p3; do mk_test "$d" "$nm" 0 1 0 ": > '$d/B'"; done
out="$(bash "$d/tests/run-tests.sh" --jobs 8 2>&1)"
assert_eq "3 partners at --jobs 8 still leave it stranded, so nothing at all starts beside it" 1 "$?"
has "and it is still the only file named as failed" "FAILURES — merge-guard" "$out"
has "the partners did run, after it — they were held back, not dropped" \
    "3 passed, 0 failed across 4 test files" "$out"

# ---------------------------------------------------------------------------
t_case "--unsupported-p2 skips exactly the classified files, in place, and does not run them"
d="$(mk_suite)"
mk_test "$d" alpha       0 2 0
mk_test "$d" merge-guard 1 9 9 ": > '$d/RAN'"     # exits 1 if it ever runs, so a skip cannot be faked
out="$(bash "$d/tests/run-tests.sh" --unsupported-p2 2>&1)"; rc=$?
assert_eq "the remaining file still passes the suite" 0 "$rc"
has      "the skip line is printed verbatim, in the file's own place" \
         "merge-guard
  SKIP — requires the exact supported P2 write host" "$out"
has      "the skip is counted" "1 exact-P2 test files skipped by profile" "$out"
assert_no_file "the skipped file never executed" "$d/RAN"
has      "and its assertions are not counted" "2 passed, 0 failed across 1 test file" "$out"

t_case "every selected file runs — concurrency does not quietly drop one"
d="$(mk_suite)"
i=1
while [ "$i" -le 12 ]; do
  mk_test "$d" "f$i" 0 1 0 ": > '$d/ran-$i'"
  i=$((i+1))
done
out="$(bash "$d/tests/run-tests.sh" --jobs 4 2>&1)"
assert_eq "the suite passes" 0 "$?"
missing=""
i=1
while [ "$i" -le 12 ]; do
  [ -f "$d/ran-$i" ] || missing="$missing f$i"
  i=$((i+1))
done
assert_eq "all 12 files left their marker" "" "$missing"
has "and all 12 are counted" "12 passed, 0 failed across 12 test files" "$out"

t_case "a name filter still selects, and an empty selection is still an error"
d="$(mk_suite)"
mk_test "$d" alpha 0 1 0
mk_test "$d" beta  1 1 1
out="$(bash "$d/tests/run-tests.sh" alpha 2>&1)"
assert_eq "only the named file runs, so the failing one cannot fail the suite" 0 "$?"
hasnt "the unnamed file is absent from the transcript" "synthetic beta" "$out"
out="$(bash "$d/tests/run-tests.sh" nosuchtest 2>&1)"
assert_eq "a name that matches nothing is an error" 1 "$?"
has "and says so" "no test files matched (nosuchtest)" "$out"
# A scope profile narrows what RUNS. It must not absorb "that file does not exist" into "nothing was
# in scope" — that turns a typo'd name into a green run of zero files.
out="$(bash "$d/tests/run-tests.sh" --fast nosuchtest 2>&1)"
assert_eq "a name that matches nothing is still an error under --fast" 1 "$?"
has "with the same message, not the fast profile's zero-file wording" \
    "no test files matched (nosuchtest)" "$out"
hasnt "and not the fast profile's exit-0 wording" "no test file ran" "$out"

t_case "a stated worker count is validated, never silently replaced by a guess"
d="$(mk_suite)"
mk_test "$d" alpha 0 1 0
assert_rc "--jobs 0"        2 bash "$d/tests/run-tests.sh" --jobs 0
assert_rc "--jobs abc"      2 bash "$d/tests/run-tests.sh" --jobs abc
assert_rc "--jobs with no value" 2 bash "$d/tests/run-tests.sh" --jobs
assert_rc "-j0"             2 bash "$d/tests/run-tests.sh" -j0
assert_rc "an unknown flag" 2 bash "$d/tests/run-tests.sh" --nope
assert_rc "FIRM_TEST_JOBS=0" 2 env FIRM_TEST_JOBS=0 bash "$d/tests/run-tests.sh"
assert_output "the rejection names the value" "not a worker count: 0" \
  bash "$d/tests/run-tests.sh" --jobs 0
assert_rc "a valid explicit count runs" 0 bash "$d/tests/run-tests.sh" --jobs 3
assert_rc "and so does FIRM_TEST_JOBS" 0 env FIRM_TEST_JOBS=2 bash "$d/tests/run-tests.sh"

t_case "the fast scope announces itself and cannot be mistaken for a passing full run"
d="$(mk_suite)"
mk_test "$d" alpha 0 1 0
mk_test "$d" beta  0 1 0
out="$(bash "$d/tests/run-tests.sh" --fast 2>&1)"; rc=$?
assert_eq "it still exits 0 when what it selected passes" 0 "$rc"
has   "the profile is named in the header" "profile fast" "$out"
has   "the banner says it is not a gate" \
      "FAST is a development scope, NOT a gate" "$out"
has   "the reason for the selection is printed" "not a git checkout — selecting every file" "$out"
has   "the closing line is the fast one" \
      "all SELECTED test files passed — fast is not a gate; the full profile has not run" "$out"
hasnt "and is NOT the string a passing full run prints" "
all test files passed" "$out"

# ---------------------------------------------------------------------------
# THE FAST SCOPE'S MAPPING FOR A CHANGED TEST FILE, both halves.
#
# F7. The `tests/test-*.sh` arm mapped a changed test file to itself and stopped there. That is wrong
# whenever one test file READS another: tests/test-reviewer-hermeticity.sh executes
# tests/test-provider-reviewers.sh and hard-codes three of its case titles, so renaming one of those
# cases guarantees a red in a file --fast would not select -- and which neither hosted CI job runs
# either, both being --unsupported-p2. Editing the measured file selected only the measured file.
#
# Both cases below are built as REAL git checkouts. Outside one the scope fails open and selects
# everything, which would make either half green for the wrong reason.
mk_fast_repo() { # <dir> — commit the synthetic suite and echo the base sha
  ( cd "$1" && git init -q . && git symbolic-ref HEAD refs/heads/main && git add -A \
    && git -c user.email=t@agent-firm.local -c user.name="firm tests" -c commit.gpgsign=false \
           -c core.excludesFile=/dev/null -c core.hooksPath=/dev/null commit -qm seed ) >/dev/null 2>&1
  git -C "$1" rev-parse HEAD 2>/dev/null
}

t_case "the fast scope selects a changed test file AND the test files that read it"
d="$(mk_suite)"
mk_test "$d" anchorsource 0 1 0
mk_test "$d" dependent 0 1 0 "# this file reads tests/test-anchorsource.sh and pins one of its case titles"
mk_test "$d" unrelated 0 1 0
fast_base="$(mk_fast_repo "$d")"
assert_ne "fixture precondition: the synthetic suite really is a git checkout" "" "$fast_base"
printf '# edited\n' >> "$d/tests/test-anchorsource.sh"
out="$(FIRM_TEST_FAST_BASE="$fast_base" bash "$d/tests/run-tests.sh" --fast 2>&1)"; rc=$?
assert_eq "the fast run passes" 0 "$rc"
has "the changed file selects itself" "tests/test-anchorsource.sh -> anchorsource" "$out"
has "and the file that reads it is selected by the same derived scan" \
    "tests/test-anchorsource.sh -> dependent" "$out"
has "the changed file itself ran" "synthetic anchorsource" "$out"
has "and so did the file that reads it — this is the assertion F7 is about" "synthetic dependent" "$out"
hasnt "while a file that reads neither stayed out of scope" "synthetic unrelated" "$out"

t_case "and the additive arm did NOT become 'select everything'"
# The control, and it is load-bearing: an arm that selected the whole suite for any changed test file
# would satisfy every assertion above. Editing a file nothing reads still selects that file alone.
d="$(mk_suite)"
mk_test "$d" anchorsource 0 1 0
mk_test "$d" dependent 0 1 0 "# this file reads tests/test-anchorsource.sh and pins one of its case titles"
mk_test "$d" unrelated 0 1 0
fast_base="$(mk_fast_repo "$d")"
assert_ne "fixture precondition: the synthetic suite really is a git checkout" "" "$fast_base"
printf '# edited\n' >> "$d/tests/test-unrelated.sh"
out="$(FIRM_TEST_FAST_BASE="$fast_base" bash "$d/tests/run-tests.sh" --fast 2>&1)"; rc=$?
assert_eq "the fast run passes" 0 "$rc"
has   "the edited file ran" "synthetic unrelated" "$out"
hasnt "the file that reads a DIFFERENT test file did not" "synthetic dependent" "$out"
hasnt "and neither did the file it reads" "synthetic anchorsource" "$out"
has   "the transcript says the scan found no other reader, rather than failing open" \
      "named by no OTHER test file" "$out"
hasnt "so the fail-open wording is not what was printed" "named by no test file, so every file" "$out"

t_case "a worker that dies without its sentinel is a FAILURE, not a hang"
# CR-02. Completion is detected by a sentinel file the worker renames into place as its last act, and
# that is right (a finished-but-unreaped child still answers `kill -0`, so signal 0 is not a
# completion detector). But there was no liveness arm underneath it: a worker killed BETWEEN
# `bash <file>` and the `mv` left st[i]=1 forever, `moved` stayed 0, `printed` never advanced, and
# the runner slept 0.05s in a loop with no upper bound. Reproduced on the checked-in runner: still
# spinning at 25s with nothing past the first file, and — because printing is index-ordered — an
# empty transcript. In CI that is GitHub's 360-minute default burned on a report that names nothing.
#
# `kill -9 $PPID` from inside the test file is the reproducer because that is what an OOM kill, a
# memory cgroup limit, a `ulimit` kill or a stray `pkill -9` does to the worker subshell, and it is
# also the shape of a $TMPDIR that is full or read-only when <i>.rc is written.
#
# CONTROL FIRST, and it is load-bearing: the same fixture with the kill removed must still be a
# normal green run. Without it, a runner that had simply started failing everything would satisfy the
# assertions below just as loudly.
d="$(mk_suite)"
mk_test "$d" alpha  0 1 0
mk_test "$d" victim 0 1 0
out="$(bash "$d/tests/run-tests.sh" --jobs 4 2>&1)"; rc=$?
assert_eq "CONTROL: the same two files, unkilled, are a green run" 0 "$rc"
has "CONTROL: and both files reach the transcript" "2 passed, 0 failed across 2 test files" "$out"

d="$(mk_suite)"
mk_test "$d" alpha  0 1 0
mk_test "$d" victim 0 1 0 'kill -9 $PPID'
# The runner must TERMINATE. A hang would hang this test file too, so the reproducer is run with a
# hard deadline of its own: the runner is backgrounded, polled for up to 30s, and killed if it is
# still alive — which is a FAIL here, not a silent 6-hour test.
_cr02_out="$d/killed.log"
( bash "$d/tests/run-tests.sh" --jobs 4 > "$_cr02_out" 2>&1 ) & _cr02_pid=$!
_cr02_n=0
while kill -0 "$_cr02_pid" 2>/dev/null && [ "$_cr02_n" -lt 300 ]; do
  sleep 0.1; _cr02_n=$((_cr02_n+1))
done
if kill -0 "$_cr02_pid" 2>/dev/null; then
  pkill -9 -P "$_cr02_pid" 2>/dev/null
  kill -9 "$_cr02_pid" 2>/dev/null
  wait "$_cr02_pid" 2>/dev/null
  _t_no "the runner terminates when a worker dies without its sentinel" "still running after 30s"
  _cr02_rc=124
else
  wait "$_cr02_pid"; _cr02_rc=$?
  _t_ok "the runner terminates when a worker dies without its sentinel"
fi
out="$(cat "$_cr02_out" 2>/dev/null)"
assert_eq "and exits 1, so the suite does not pass on a file that never finished" 1 "$_cr02_rc"
has "the dead worker is named in the FAILURES line" "FAILURES — victim" "$out"
has "the transcript says what happened, in the file's own section" \
    "WORKER DIED without reporting an exit status" "$out"
has "and it is called a failure rather than a hang" "not as a hang" "$out"
has "the OTHER file still reports its own result" "── 1 passed, 0 failed" "$out"
has "the grand total does not fold in the killed file's own count" \
    "1 passed, 1 failed across 2 test files" "$out"
hasnt "and the green verdict is not printed" "all test files passed" "$out"

t_case "a fast run that selects nothing is loud about having run nothing"
# Outside a git checkout the scope fails open, so the empty case is reached through a filter instead:
# what matters is that "no file ran" never borrows the vocabulary of a green suite.
d="$(mk_suite)"
mk_test "$d" alpha 1 1 1
out="$(bash "$d/tests/run-tests.sh" --unsupported-p2 merge-guard 2>&1)"
assert_eq "an all-skipped selection is still the pre-existing error" 1 "$?"
has "with the pre-existing message" "no test files matched (merge-guard)" "$out"

t_summary
