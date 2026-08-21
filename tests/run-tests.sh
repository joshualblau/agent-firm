#!/usr/bin/env bash
# tests/run-tests.sh [--unsupported-p2] [--fast] [-j N | --jobs N | --serial] [test-name ...]
# Runs the firm's own test suite. No test framework — just bash + git, plus the firm's own declared
# python3 prerequisites: jsonschema (test-validate-verdict) and pyyaml (test-policy-yaml-valid). Those
# two files FAIL if the packages are absent; the rest of the suite runs. See tests/lib.sh for why.
#
#   tests/run-tests.sh                  # everything, on as many workers as the host has CPUs
#   tests/run-tests.sh integrate        # just tests/test-integrate.sh
#   tests/run-tests.sh --unsupported-p2 # suites safe on a host where ledger writes must fail closed
#   tests/run-tests.sh --serial         # one file at a time, streaming (same results, much slower)
#   tests/run-tests.sh --jobs 4         # a specific worker count ($FIRM_TEST_JOBS does the same)
#   tests/run-tests.sh --fast           # DEVELOPMENT ONLY — only the files a change can reach
#   /bin/bash tests/run-tests.sh        # force macOS bash 3.2 (what CI does on the macos runner)
#
# WHY THE FILE LOOP IS CONCURRENT
# Runtime here is process spawn and filesystem work, not assertion count: nearly every case builds a
# throwaway git repo and shells out to git and python many times over. Measured serially on an 8-CPU
# host the suite is dominated by a long tail of such files, so they are run on N workers.
#
# What makes that legitimate is that the fixtures were ALREADY isolated, which is a property of this
# suite rather than an assumption about suites in general: every case works inside its own `mktemp -d`
# (see tests/lib.sh mk_repo/mk_linked_worktree), every ledger lock is `run.jsonl.lock` inside a
# throwaway run directory, and every reference to the real checkout in tests/ is a READ — `git
# ls-files`, `cat`, `json.load`, `cp` out of it. `runs_alone` below is where a file that cannot hold
# that property gets classified, and why.
#
# Concurrency changes the SCHEDULE and nothing else. Every file still runs, every assertion still
# runs, and any file exiting non-zero still fails the suite.
#
# OUTPUT ORDER IS NOT COMPLETION ORDER. Each file's output is captured whole and printed in the
# position a serial run would have printed it, so a parallel transcript is a serial transcript plus
# one timing line per file. Interleaving would make a failure hard to attribute, which costs more than
# earlier feedback is worth.
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _d="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  case $_src in /*) ;; *) _src="$_d/$_src";; esac
done
TESTS_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
FIRM_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

host_profile=full          # full | unsupported-p2
scope_profile=full         # full | fast
jobs=""
jobs_given=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --unsupported-p2) host_profile=unsupported-p2; shift ;;
    --fast)           scope_profile=fast; shift ;;
    --serial)         jobs=1; jobs_given=1; shift ;;
    --jobs|-j)        [ "$#" -ge 2 ] || { printf 'missing value for %s\n' "$1" >&2; exit 2; }
                      jobs="$2"; jobs_given=1; shift 2 ;;
    --jobs=*)         jobs="${1#--jobs=}"; jobs_given=1; shift ;;
    -j*)              jobs="${1#-j}"; jobs_given=1; shift ;;
    --)               shift; break ;;
    --*)              printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)                break ;;
  esac
done

# These suites intentionally exercise successful ledger mutation or consume events emitted by that
# mutation. Running them on a host outside a PROVEN P2 row would test a configuration the production
# writer explicitly rejects. (Plural since the row set became a closed allowlist of two — "the exact
# P2 row" is the old singular and it now reads as excluding hosts that are in fact supported.) Keep
# the exclusion closed and named: a new test runs by default and must be consciously classified here
# if it really requires a supported write host.
requires_supported_p2() {
  case "$1" in
    check-assertions|final-qa-check|ledger-compatibility|ledger-log|ledger-role-start|merge-guard|\
    new-worktree|policy-hire|provider-reviewers|qa-checkout|qa-clean-check|reviewer-hermeticity) return 0 ;;
    *) return 1 ;;
  esac
}

# runs_alone <name> — files that must be the ONLY file in flight. Closed and named for the same reason
# the P2 list above is: a new test file is parallel-safe BY DEFAULT and has to be classified here
# deliberately, with its evidence written down next to it.
#
# The question is not "is this file slow". It is "can two of these run at once and still be asserting
# what they claim". Two properties would disqualify a file, and both were checked across all 32:
#
#   1. It writes state outside its own temp directory — the real checkout, a fixed path, a shared
#      lock, a global git config. None does. Every fixture is an `mktemp -d` with an XXXXXX template
#      (so two runs cannot collide), the only `git worktree add` in the suite targets a throwaway
#      repo, and the `git config --global` strings in tests/test-merge-guard.sh are payloads handed to
#      the guard as text, never executed.
#   2. It asserts an upper bound on elapsed time that host load could break. Most have wide margins —
#      a 30s registered hook timeout for a pair that takes well under a second, two 20s polls for a
#      state transition, a 30s deadline on a command asserted to exit in ~0s, one real 5s descriptor
#      deadline asserted to land under 6.5s.
#
#      THE ORIGINAL SURVEY MISSED THE TWO TIGHTEST WAITS IN THE SUITE (CR-08): a 2.0s poll for the
#      reviewer lock and a 3.0s poll for the hard-kill lock, both in tests/test-provider-reviewers.sh,
#      both sitting on a path this change measurably lengthened (bin/firm-reviewer-common shells out
#      to bin/firm-model-resolve before creating the lock, and both now pay a full interpreter
#      resolution — ~200ms each on an idle host, so ~0.4s of a 2.0s budget before any concurrency
#      multiplier). Neither is a wall-clock ASSERTION, which is why they were not on this list, but
#      an expired poll there fails an assertion AND makes the next one wrong in the misleading
#      direction. They are now 10s, matching wait_ready() in tests/test-ledger-role-start.sh; the
#      loops exit on the first successful test, so a green run pays nothing. That is the cheaper of
#      the two fixes CR-08 offered — the other was classifying provider-reviewers `runs_alone`, which
#      costs a large share of the remaining speedup to buy margin the widened polls already give.
#
#      ONE FILE DOES assert an elapsed-time bound that load can break, and it is measured rather than
#      assumed:
#
#        tests/test-merge-guard.sh's "classification finishes inside PARSE_BUDGET" runs the guard's
#        real parse phase against its real 4000ms production budget. Serially it lands at 2675ms —
#        already 67% of budget before any of this. Across 11 full concurrent runs it landed at
#        2835-2890ms on 8 workers (72%) and once at 3829ms on 6 workers (96%). Every one of those
#        runs was green, but 96% is not margin, and the worst sample was not the busiest setting, so
#        it is co-scheduling luck rather than worker count that moves it.
#
#      Classifying merge-guard `runs_alone` buys that case a serial-quality margin and costs most of
#      the speedup. That trade HAS now been made, deliberately — see the entry below for the reason,
#      which is not the margin. Both hosted CI jobs use `--unsupported-p2`, which skips merge-guard
#      outright, so the exposure this removes was local runs and the exact-P2 job only.
runs_alone() {
  case "$1" in
    # WHY merge-guard IS ALONE: validity, not flake-avoidance. Its "classification finishes inside
    # PARSE_BUDGET" case drives the guard's REAL 4000ms production budget. Sharing the host does not
    # merely narrow that assertion's margin, it changes WHAT IT MEASURES — the same unchanged guard
    # code timed 2675ms with the host to itself and 3829ms while co-scheduled, so the concurrent
    # number is a fact about this scheduler, not about the guard's parse cost. A production budget
    # asserted against harness contention is asserting the wrong thing even on the runs it passes.
    # Serializing the file restores the measurement; the margin it also restores is a side effect.
    #
    # Re-evaluate against the three numbers, not from memory: 2675ms serial, 3829ms worst observed
    # concurrent, 4000ms budget. If the guard's parse cost drops well clear of the budget, or the
    # budget rises, this entry can go back on the pool.
    #
    # Accepted cost: an estimated ~412s -> ~590s, still roughly 2.2x faster than the 1287s serial
    # baseline. `--serial` and `--jobs N` are unaffected and still mean exactly what they meant.
    merge-guard) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- worker count ---------------------------------------------------------
# A count the caller states explicitly (flag or $FIRM_TEST_JOBS) is validated and never quietly
# replaced by a guess — `--jobs 0` is an error, not an invitation to auto-detect. Only the unstated
# case probes the host, and it degrades to 1 (i.e. to the old serial behaviour) if it cannot tell.
if [ "$jobs_given" -eq 0 ] && [ -n "${FIRM_TEST_JOBS:-}" ]; then jobs="$FIRM_TEST_JOBS"; jobs_given=1; fi
if [ "$jobs_given" -eq 0 ]; then
  jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || jobs=""
  case "$jobs" in ''|*[!0-9]*) jobs="$(sysctl -n hw.logicalcpu 2>/dev/null)" || jobs="" ;; esac
  case "$jobs" in ''|*[!0-9]*) jobs="$(nproc 2>/dev/null)" || jobs="" ;; esac
  case "$jobs" in ''|*[!0-9]*) jobs=1 ;; esac
fi
case "$jobs" in ''|*[!0-9]*) printf 'not a worker count: %s\n' "$jobs" >&2; exit 2 ;; esac
[ "$jobs" -ge 1 ] || { printf 'not a worker count: %s\n' "$jobs" >&2; exit 2; }

# ---- millisecond clock ----------------------------------------------------
# bash 5 has $EPOCHREALTIME and it costs no process; bash 3.2.57 (macOS, and what CI pins) does not,
# so perl is the fallback and `date` the last resort at one-second resolution. The decimal separator
# is matched as a class because $EPOCHREALTIME follows LC_NUMERIC. Timing is REPORTING ONLY — no
# assertion anywhere depends on it, so a coarse clock degrades the profile and nothing else.
_now_ms() { printf '%s' "$(( $(date +%s) * 1000 ))"; }
if [ -n "${EPOCHREALTIME:-}" ]; then
  _now_ms() {
    local _er="$EPOCHREALTIME" _s _f
    _s="${_er%%[.,]*}"; _f="${_er#*[.,]}"
    [ "$_f" != "$_er" ] || _f=0
    _f="${_f}000"
    printf '%s' "$(( _s * 1000 + 10#${_f:0:3} ))"
  }
elif command -v perl >/dev/null 2>&1; then
  _now_ms() { perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time()*1000'; }
fi
_secs() { printf '%d.%01d' "$(( ${1:-0} / 1000 ))" "$(( (${1:-0} % 1000) / 100 ))"; }
SUITE_BEGAN="$(_now_ms)"

# Sub-second `sleep` is not in POSIX but is real on every host this runs on. Fall back to whole
# seconds rather than spin: a busy-wait would steal a core from the tests on a small CI runner.
if sleep 0.05 2>/dev/null; then _snooze=0.05; else _snooze=1; fi

# ---- which files ----------------------------------------------------------
want="$*"
names=(); paths=()
for f in "$TESTS_DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .sh)"; name="${name#test-}"
  if [ -n "$want" ]; then
    match=0
    for w in $want; do [ "$w" = "$name" ] && match=1; done
    [ "$match" -eq 1 ] || continue
  fi
  names[${#names[@]}]="$name"
  paths[${#paths[@]}]="$f"
done

# ---- the `fast` scope profile ---------------------------------------------
# A DEVELOPMENT convenience: run the files a change can plausibly reach instead of the whole suite.
# `full` remains mandatory before QA, the Final gate and CI, and this profile is built so it cannot be
# quietly substituted for one — it announces itself, prints the selection it derived so an
# under-selection is visible rather than silent, and does NOT print the line a passing full run prints.
#
# The mapping is DERIVED, not tabulated, so it cannot rot as files are added: for each changed path,
# the test files that mention its basename are selected, after expanding one level through bin/ (a
# changed bin/firm-X that some bin/firm-Y also names — every tool names firm-python — pulls in
# firm-Y's tests too). It fails OPEN in every direction it cannot reason about: no git checkout, an
# unreadable base, a change to the harness itself, or a changed path no test file names anywhere all
# select EVERY file.
FAST_REASONS=""
FAST_SELECTED=""
fast_select_all=0
fast_note() { FAST_REASONS="${FAST_REASONS}$1
"; }

fast_compute() {
  local base changed p b tools t f hits rest
  if ! git -C "$FIRM_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    fast_note "not a git checkout — selecting every file"; fast_select_all=1; return 0
  fi
  base="${FIRM_TEST_FAST_BASE:-}"
  if [ -z "$base" ]; then
    if git -C "$FIRM_ROOT" rev-parse --verify -q main >/dev/null 2>&1; then
      base="$(git -C "$FIRM_ROOT" merge-base HEAD main 2>/dev/null)" || base=""
    fi
    [ -n "$base" ] || base=HEAD
  fi
  changed="$( { git -C "$FIRM_ROOT" diff --name-only "$base" 2>/dev/null
                git -C "$FIRM_ROOT" ls-files --others --exclude-standard 2>/dev/null; } | sort -u )"
  fast_note "changes since $base"
  if [ -z "$changed" ]; then fast_note "nothing changed — no file selected"; return 0; fi

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    b="$(basename "$p")"
    case "$p" in
      tests/lib.sh|tests/run-tests.sh)
        fast_note "$p — the harness itself, so every file"; fast_select_all=1; continue ;;
      tests/test-*.sh)
        t="${b%.sh}"; t="${t#test-}"
        FAST_SELECTED="$FAST_SELECTED $t"; fast_note "$p -> $t"; continue ;;
    esac
    tools="$b"
    for t in "$FIRM_ROOT"/bin/firm-*; do
      [ -f "$t" ] || continue
      [ "$(basename "$t")" = "$b" ] && continue
      if grep -qF -- "$b" "$t" 2>/dev/null; then tools="$tools $(basename "$t")"; fi
    done
    hits=""
    for t in $tools; do
      for f in "$TESTS_DIR"/test-*.sh; do
        [ -f "$f" ] || continue
        if grep -qF -- "$t" "$f" 2>/dev/null; then
          rest="$(basename "$f" .sh)"; rest="${rest#test-}"
          case " $hits " in *" $rest "*) ;; *) hits="$hits $rest" ;; esac
        fi
      done
    done
    if [ -z "$hits" ]; then
      fast_note "$p — named by no test file, so every file"; fast_select_all=1
    else
      FAST_SELECTED="$FAST_SELECTED$hits"; fast_note "$p ->$hits"
    fi
  done <<EOF
$changed
EOF
  return 0
}

fast_wants() {
  [ "$fast_select_all" -eq 1 ] && return 0
  case " $FAST_SELECTED " in *" $1 "*) return 0 ;; esac
  return 1
}

if [ "$scope_profile" = fast ]; then
  if [ "$host_profile" = full ]; then profile=fast; else profile="$host_profile+fast"; fi
  fast_compute
else
  profile="$host_profile"
fi

# ---- disposition, in canonical order --------------------------------------
# Skipped files keep their place in the transcript, so `--unsupported-p2` prints exactly what it
# always printed, in the order it always printed it, whether or not the run is concurrent.
n="${#names[@]}"
disp=(); skipped=0; descoped=0; runcount=0
i=0
while [ "$i" -lt "$n" ]; do
  if [ "$host_profile" = unsupported-p2 ] && requires_supported_p2 "${names[$i]}"; then
    disp[$i]=skip-p2; skipped=$((skipped+1))
  elif [ "$scope_profile" = fast ] && ! fast_wants "${names[$i]}"; then
    disp[$i]=descoped; descoped=$((descoped+1))
  else
    disp[$i]=run; runcount=$((runcount+1))
  fi
  i=$((i+1))
done
[ "$runcount" -gt 1 ] || jobs=1

printf 'firm test suite  (bash %s; profile %s; %s worker%s)\n' \
  "${BASH_VERSION%%(*}" "$profile" "$jobs" "$( [ "$jobs" = 1 ] || printf s )"
if [ "$scope_profile" = fast ]; then
  printf '  FAST is a development scope, NOT a gate — the full profile has not run.\n'
  printf '%s' "$FAST_REASONS" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '    %s\n' "$line"
  done
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-testrun.XXXXXX")" || {
  printf 'cannot create a work directory under %s\n' "${TMPDIR:-/tmp}" >&2; exit 1; }

st=(); pid=(); frc=(); dur=(); beg=()
i=0
while [ "$i" -lt "$n" ]; do
  frc[$i]=0; dur[$i]=0; beg[$i]=0; pid[$i]=0
  case "${disp[$i]}" in run) st[$i]=0 ;; *) st[$i]=2 ;; esac
  i=$((i+1))
done

_reap_all() {
  local k=0
  while [ "$k" -lt "$n" ]; do
    if [ "${st[$k]}" = 1 ] && [ "${pid[$k]}" != 0 ]; then kill "${pid[$k]}" 2>/dev/null; fi
    k=$((k+1))
  done
}
trap '_reap_all; rm -rf "$WORK"' EXIT
trap '_reap_all; rm -rf "$WORK"; exit 130' INT TERM

rc=0
failed=""
_emit_time() { printf '  ⧗ %ss\n' "$(_secs "${dur[$1]}")"; }
_tally()     { if [ "${frc[$1]}" -ne 0 ]; then rc=1; failed="$failed ${names[$1]}"; fi; }
_emit() {
  case "${disp[$1]}" in
    skip-p2)  printf '\n%s\n  SKIP — requires the exact supported P2 write host\n' "${names[$1]}"; return ;;
    descoped) printf '\n%s\n  SKIP — outside the fast scope\n' "${names[$1]}"; return ;;
  esac
  printf '\n%s\n' "${names[$1]}"
  if [ -f "$WORK/$1.out" ]; then cat "$WORK/$1.out"; fi
  _emit_time "$1"; _tally "$1"
}

if [ "$runcount" -eq 0 ]; then
  i=0; while [ "$i" -lt "$n" ]; do _emit "$i"; i=$((i+1)); done
  printf '\n────────\n'
  if [ "$skipped" -gt 0 ]; then printf '%d exact-P2 test files skipped by profile\n' "$skipped"; fi
  # "nothing was in scope" and "you named a file that does not exist" are different answers and get
  # different exit codes. Only the first is a legitimate zero: `$n` counts what the NAME FILTER
  # matched, before either profile narrowed it, so a typo'd name still fails the way it always has
  # rather than being absorbed by whichever profile happens to be on.
  if [ "$scope_profile" = fast ] && [ "$n" -gt 0 ]; then
    printf '%d test files outside the fast scope\n' "$descoped"
    printf 'no test file ran — fast is not a gate; the full profile has not run\n'
    exit 0
  fi
  printf 'no test files matched%s\n' "${want:+ ($want)}"
  exit 1
fi

# ---- run ------------------------------------------------------------------
if [ "$jobs" -eq 1 ]; then
  # One file at a time, streaming live the way this runner always has. `tee` keeps a copy so the
  # totals below are computed identically in both modes, and `pipefail` keeps the FILE's exit status —
  # not tee's — as the thing that fails the suite. stdin is /dev/null so a test that ever reads it
  # fails the same way here as it would in CI, instead of blocking on a terminal.
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${disp[$i]}" != run ]; then _emit "$i"; i=$((i+1)); continue; fi
    printf '\n%s\n' "${names[$i]}"
    beg[$i]="$(_now_ms)"
    bash "${paths[$i]}" </dev/null 2>&1 | tee "$WORK/$i.out"
    frc[$i]=$?
    dur[$i]=$(( $(_now_ms) - ${beg[$i]} ))
    st[$i]=2
    _emit_time "$i"; _tally "$i"
    i=$((i+1))
  done
else
  # Bounded worker pool. Three things are deliberate.
  #
  # Completion is detected by a SENTINEL FILE the worker renames into place as its last act. Not
  # `kill -0`: a finished-but-unreaped child still answers signal 0, so polling it never terminates.
  # Not `wait -n`: bash 3.2.57 has no such thing, and these scripts hold themselves to 3.2. The
  # rename is what makes the sentinel atomic, so a reader can never see a half-written exit code.
  #
  # Launch order is longest-first, approximated by file size, purely to shorten the makespan — with
  # the pool this size the finish time is set by whichever long file starts last. It changes when a
  # file starts and nothing else: not what it asserts, not where its output goes, not its exit code.
  # `runs_alone` files launch first, since they can only start when nothing else is in flight.
  #
  # Printing is by CANONICAL index, not completion, so the transcript matches a serial one.
  # `alone[]` is evaluated ONCE per file. The classification has to be read at reap time as well as at
  # launch time, and a scheduler that asked the classifier again later could be told something else.
  alone=(); ord=()
  i=0
  while [ "$i" -lt "$n" ]; do
    if runs_alone "${names[$i]}"; then alone[$i]=1; else alone[$i]=0; fi
    if [ "${disp[$i]}" = run ] && [ "${alone[$i]}" = 1 ]; then ord[${#ord[@]}]="$i"; fi
    i=$((i+1))
  done
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    ord[${#ord[@]}]="$k"
  done <<EOF
$(i=0; while [ "$i" -lt "$n" ]; do
    if [ "${disp[$i]}" = run ] && [ "${alone[$i]}" = 0 ]; then
      printf '%s\t%s\n' "$(wc -c < "${paths[$i]}" | tr -d ' ')" "$i"
    fi
    i=$((i+1))
  done | sort -k1,1nr -k2,2n | cut -f2)
EOF

  launched=0; running=0; printed=0; alone_running=0
  while [ "$printed" -lt "$n" ]; do
    while [ "$launched" -lt "$runcount" ]; do
      # Nothing at all starts beside a `runs_alone` file: not another alone file, and not an ordinary
      # one. "Alone" that only held until the next launch would be a scheduler that lets a file it
      # classified as unsafe run next to everything anyway.
      [ "$alone_running" -eq 0 ] || break
      k="${ord[$launched]}"
      if [ "${alone[$k]}" = 1 ]; then
        [ "$running" -eq 0 ] || break
      else
        [ "$running" -lt "$jobs" ] || break
      fi
      beg[$k]="$(_now_ms)"
      (
        bash "${paths[$k]}" >"$WORK/$k.out" 2>&1 </dev/null
        printf '%s\n' "$?" > "$WORK/$k.rc"
        mv -f "$WORK/$k.rc" "$WORK/$k.done"
      ) &
      pid[$k]=$!
      st[$k]=1
      launched=$((launched+1)); running=$((running+1))
      if [ "${alone[$k]}" = 1 ]; then alone_running=1; break; fi
    done

    moved=0
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${st[$i]}" = 1 ] && [ -f "$WORK/$i.done" ]; then
        dur[$i]=$(( $(_now_ms) - ${beg[$i]} ))
        wait "${pid[$i]}" 2>/dev/null
        r="$(cat "$WORK/$i.done" 2>/dev/null)"
        case "$r" in ''|*[!0-9]*) r=1 ;; esac
        frc[$i]="$r"
        st[$i]=2; running=$((running-1)); moved=1
        [ "${alone[$i]}" = 1 ] && alone_running=0
      elif [ "${st[$i]}" = 1 ] && ! kill -0 "${pid[$i]}" 2>/dev/null; then
        # LIVENESS, not completion (CR-02). The sentinel above stays the ONLY way a worker reports
        # its exit status, for the reason stated at the top of this block. But a worker that dies
        # BETWEEN `bash <file>` and the `mv` never writes one, and without this arm `st[i]` stays 1,
        # `moved` stays 0, `printed` never advances and the runner sleeps 0.05s forever. Reproduced
        # with a file that does `kill -9 $PPID` after printing its summary — which is what an OOM
        # kill, a memory cgroup limit, a `ulimit` kill or a stray `pkill -9` looks like from here,
        # and what a full or read-only $TMPDIR looks like when the write of <i>.rc fails. The serial
        # runner has no such failure mode; the hosted CI job would have burned GitHub's 360-minute
        # default and reported a transcript naming nothing, because printing is index-ordered.
        #
        # `kill -0` is refused ABOVE as a COMPLETION detector and that refusal still stands: a
        # finished-but-unreaped child answers signal 0, so a poll on it never terminates. Failing
        # signal 0 is the other direction and it is sound — the pid is gone, and the `mv` is the
        # worker's last act before exiting, so a live worker cannot be here. The re-test closes the
        # only remaining window (exit observed between the -f above and the kill -0 here); if the
        # sentinel has appeared, the next pass through this loop takes the normal branch.
        if [ ! -f "$WORK/$i.done" ]; then
          dur[$i]=$(( $(_now_ms) - ${beg[$i]} ))
          # The runner authors a summary line here, which it does nowhere else. Whatever count the
          # file printed before it died describes a run that did not finish, and `tail -1` in the
          # totals block takes the LAST such line — so without this the grand total would fold in a
          # "N passed, 0 failed" from a file that was killed. Substituting 0/1 keeps the totals in
          # the only safe direction and keeps them consistent with the FAILURES list.
          {
            printf '\n  WORKER DIED without reporting an exit status — killed (OOM, cgroup, ulimit,\n'
            printf '  a stray signal), or its exit-status file could not be written. Counted as a\n'
            printf '  FAILURE of this file, not as a hang. Any count printed above is from an\n'
            printf '  execution that did not finish and is superseded by the line below.\n'
            printf '  ── 0 passed, 1 failed\n'
          } >> "$WORK/$i.out" 2>/dev/null || true
          frc[$i]=1
          st[$i]=2; running=$((running-1)); moved=1
          [ "${alone[$i]}" = 1 ] && alone_running=0
        fi
      fi
      i=$((i+1))
    done

    while [ "$printed" -lt "$n" ] && [ "${st[$printed]}" = 2 ]; do
      _emit "$printed"; printed=$((printed+1))
    done

    if [ "$moved" -eq 0 ] && [ "$printed" -lt "$n" ]; then sleep "$_snooze"; fi
  done
fi

# ---- totals ---------------------------------------------------------------
# Summed out of the same `── N passed, M failed` line every file already prints for itself, so the
# grand total can never claim more than the files did.
tot_pass=0; tot_fail=0
i=0
while [ "$i" -lt "$n" ]; do
  if [ "${disp[$i]}" = run ] && [ -f "$WORK/$i.out" ]; then
    line="$(grep '── [0-9][0-9]* passed, [0-9][0-9]* failed' "$WORK/$i.out" | tail -1)"
    case "$line" in
      *"── "*" passed, "*" failed"*)
        p="${line##*── }"; p="${p%% passed,*}"
        q="${line##*passed, }"; q="${q%% failed*}"
        case "$p$q" in
          ''|*[!0-9]*) ;;
          *) tot_pass=$((tot_pass+p)); tot_fail=$((tot_fail+q)) ;;
        esac
        ;;
    esac
  fi
  i=$((i+1))
done

summed=0
i=0; while [ "$i" -lt "$n" ]; do summed=$((summed + ${dur[$i]})); i=$((i+1)); done

printf '\n────────\n'
printf 'per-file wall clock, slowest first\n'
i=0
while [ "$i" -lt "$n" ]; do
  [ "${disp[$i]}" = run ] && printf '%s\t%s\n' "${dur[$i]}" "${names[$i]}"
  i=$((i+1))
done | sort -k1,1nr | while IFS="$(printf '\t')" read -r ms nm; do
  printf '  %8ss  %s\n' "$(_secs "$ms")" "$nm"
done
printf '  %8ss  summed across %d file%s\n' \
  "$(_secs "$summed")" "$runcount" "$( [ "$runcount" = 1 ] || printf s )"
printf '  %8ss  suite wall clock on %s worker%s\n' \
  "$(_secs "$(( $(_now_ms) - SUITE_BEGAN ))")" "$jobs" "$( [ "$jobs" = 1 ] || printf s )"

printf '%d passed, %d failed across %d test file%s\n' \
  "$tot_pass" "$tot_fail" "$runcount" "$( [ "$runcount" = 1 ] || printf s )"
if [ "$skipped" -gt 0 ]; then printf '%d exact-P2 test files skipped by profile\n' "$skipped"; fi
if [ "$descoped" -gt 0 ]; then printf '%d test files outside the fast scope\n' "$descoped"; fi
if [ "$rc" -eq 0 ]; then
  if [ "$scope_profile" = fast ]; then
    printf 'all SELECTED test files passed — fast is not a gate; the full profile has not run\n'
  else
    printf 'all test files passed\n'
  fi
else
  printf 'FAILURES —%s\n' "$failed"
fi
exit "$rc"
