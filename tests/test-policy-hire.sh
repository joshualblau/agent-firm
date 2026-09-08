#!/usr/bin/env bash
# tests/test-policy-hire.sh — firm-policy (lookup + list, policy/ then schemas/ with the extension
# fallback) and firm-hire (job-spec scaffold, idempotent, needs an active run).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLICY="$BIN/firm-policy"
HIRE="$BIN/firm-hire"
NEW_RUN="$BIN/firm-new-run"

# ---------------------------------------------------------------------------
t_case "firm-policy: resolves a real policy file regardless of CWD"
repo="$(mk_repo)"
assert_ok "gate-matrix (.md in policy/) resolves from a scratch repo's CWD" \
  sh -c "cd '$repo' && '$POLICY' gate-matrix"
assert_output "gate-matrix content really is the gate matrix" "Gate matrix" \
  sh -c "cd '$repo' && '$POLICY' gate-matrix"

t_case "firm-policy: resolves a schema (.json in schemas/), extension fallback works both dirs"
assert_ok "qa-verdict.schema resolves (schemas/, not policy/)" \
  sh -c "cd '$repo' && '$POLICY' qa-verdict.schema"
assert_output "it's really the qa-verdict schema" '"title": "QA verdict"' \
  sh -c "cd '$repo' && '$POLICY' qa-verdict.schema"

t_case "firm-policy: an unknown name fails clearly, not silently"
assert_rc "exit 1" 1 sh -c "cd '$repo' && '$POLICY' totally-made-up-name-xyz"
assert_output "suggests 'firm-policy list'" "firm-policy list" \
  sh -c "cd '$repo' && '$POLICY' totally-made-up-name-xyz"

t_case "firm-policy list: enumerates both policy/ and schemas/"
assert_output "lists policies" "policies (" sh -c "cd '$repo' && '$POLICY' list"
assert_output "lists schemas"  "schemas  (" sh -c "cd '$repo' && '$POLICY' list"
assert_output "gate-matrix.md shows up under policies" "gate-matrix.md" \
  sh -c "cd '$repo' && '$POLICY' list"
assert_output "no-arg call defaults to list, same as explicit 'list'" "policies (" \
  sh -c "cd '$repo' && '$POLICY'"

# ---------------------------------------------------------------------------
t_case "firm-hire: needs an active run"
repo2="$(mk_repo)"
assert_rc "exit 1 without a run" 1 sh -c "cd '$repo2' && '$HIRE' data-engineer"
assert_output "names firm-new-run as the fix" "new-run" sh -c "cd '$repo2' && '$HIRE' data-engineer"

t_case "firm-hire: usage error with no role"
assert_rc "exit 2" 2 sh -c "cd '$repo2' && '$HIRE'"

# ---------------------------------------------------------------------------
t_case "firm-hire: scaffolds a job-spec file with the expected shape"
repo3="$(mk_repo)"
( cd "$repo3" && "$NEW_RUN" hire-basic fast_path >/dev/null )
run_dir_rel3="$(cat "$repo3/.agent-firm/CURRENT_RUN")"   # firm-hire echoes a CWD-relative path
run_dir3="$repo3/$run_dir_rel3"
out3="$( (cd "$repo3" && "$HIRE" data-engineer) )"
spec="$run_dir3/hires/data-engineer.job.yaml"
assert_file "job spec written under <run>/hires/" "$spec"
assert_output "printed path matches what was written" "$run_dir_rel3/hires/data-engineer.job.yaml" printf '%s' "$out3"
assert_output "role_name field present" "role_name: data-engineer" cat "$spec"
assert_output "why_core_staff_cant field present (prevents role-theater)" "why_core_staff_cant:" cat "$spec"
assert_output "defaults to ephemeral mode" "mode: ephemeral" cat "$spec"

t_case "firm-hire: role name sanitization matches firm-new-run's slug convention"
# Same tr pipeline as firm-new-run's slug sanitization, and the same double-dash artifact from
# leading/repeated spaces applies here too (verified via the same tr pipeline, not guessed) -- so this
# uses a single-leading-space-free input to keep the expectation unambiguous, same fix as
# test-new-run.sh's slug case.
( cd "$repo3" && "$HIRE" "Data ENGINEER!! v2" ) >/dev/null
assert_file "punctuation stripped, case/spaces normalized" "$run_dir3/hires/data-engineer-v2.job.yaml"

t_case "firm-hire: idempotent — a second call does not overwrite an existing spec"
printf 'CUSTOM CONTENT — must survive\n' >> "$spec"
# assert_output captures stdout+stderr itself (2>&1) -- pre-capturing via `$(...)` first would only
# grab stdout, missing "(already exists)", which the script deliberately prints to stderr.
assert_output "reports it already exists" "already exists" sh -c "cd '$repo3' && '$HIRE' data-engineer"
assert_output "the custom edit was NOT clobbered" "CUSTOM CONTENT — must survive" cat "$spec"

t_case "firm-hire: hire_scaffolded ledger event lands with the role"
assert_output "event present" '"event":"hire_scaffolded"' cat "$run_dir3/run.jsonl"
assert_output "role recorded"  '"role":"data-engineer"'    cat "$run_dir3/run.jsonl"

# ---------------------------------------------------------------------------
t_case "firm-hire: --run is authoritative — the spec AND the ledger event follow it, not CURRENT_RUN"
# Both runs are real and valid, and CURRENT_RUN names the one that must NOT be written to. A fixture
# with only one usable run would pass even if the tool ignored the selector entirely.
repo4="$(mk_repo)"
run_a4="$( (cd "$repo4" && "$NEW_RUN" hire-alpha fast_path) )"
run_b4="$( (cd "$repo4" && "$NEW_RUN" hire-bravo fast_path) )"   # second, so CURRENT_RUN -> B
id_a4="$(basename "$run_a4")"; id_b4="$(basename "$run_b4")"
assert_ne "fixture precondition: the two runs are genuinely different runs" "$id_a4" "$id_b4"
assert_eq "fixture precondition: CURRENT_RUN really names run B" \
  ".agent-firm/runs/$id_b4" "$(cat "$repo4/.agent-firm/CURRENT_RUN")"

out4="$( (cd "$repo4" && "$HIRE" --run ".agent-firm/runs/$id_a4" data-engineer) )"
assert_file "job spec was scaffolded into run A" "$repo4/.agent-firm/runs/$id_a4/hires/data-engineer.job.yaml"
assert_no_file "run B got no hires/ directory at all" "$repo4/.agent-firm/runs/$id_b4/hires"
assert_output "the printed path names run A" ".agent-firm/runs/$id_a4/hires/data-engineer.job.yaml" printf '%s' "$out4"
assert_output "hire_scaffolded landed in run A's ledger" '"event":"hire_scaffolded"' \
  cat "$repo4/.agent-firm/runs/$id_a4/run.jsonl"
# The other half of the defect: that ledger call carried no --run before this change, so the event
# went wherever CURRENT_RUN pointed even when the scaffold did not.
assert_fail "run B's ledger got NO hire_scaffolded event" \
  grep -q hire_scaffolded "$repo4/.agent-firm/runs/$id_b4/run.jsonl"

t_case "firm-hire: an absolute --run works, and the zero-selector form still follows CURRENT_RUN"
out4b="$( (cd "$repo4" && "$HIRE" --run "$repo4/.agent-firm/runs/$id_a4" ml-engineer) )"
assert_output "absolute selector writes into run A too" ".agent-firm/runs/$id_a4/hires/ml-engineer.job.yaml" printf '%s' "$out4b"
out4c="$( (cd "$repo4" && "$HIRE" sre) )"   # no --run: the pre-change invocation form
assert_output "unchanged: no selector means CURRENT_RUN, i.e. run B" ".agent-firm/runs/$id_b4/hires/sre.job.yaml" printf '%s' "$out4c"

t_case "firm-hire: a selector it will not accept refuses and scaffolds nothing"
assert_rc "--run=<dir> is refused by spelling" 2 \
  sh -c "cd '$repo4' && '$HIRE' --run=.agent-firm/runs/$id_a4 data-engineer"
assert_output "and names the accepted two-word form" "two words" \
  sh -c "cd '$repo4' && '$HIRE' --run=.agent-firm/runs/$id_a4 data-engineer"
assert_rc "a run directory that does not exist is refused" 2 \
  sh -c "cd '$repo4' && '$HIRE' --run .agent-firm/runs/nope data-engineer"
assert_output "the diagnostic names the specific violation" "does not exist" \
  sh -c "cd '$repo4' && '$HIRE' --run .agent-firm/runs/nope data-engineer"
assert_no_file "no run directory was fabricated for the refused selector" "$repo4/.agent-firm/runs/nope"
assert_rc "a role-position argument beginning with '-' is refused, not sanitized into a role name" 2 \
  sh -c "cd '$repo4' && '$HIRE' -data-engineer"
assert_no_file "so no junk-named job spec was written" "$repo4/.agent-firm/runs/$id_b4/hires/-data-engineer.job.yaml"

t_case "firm-hire: invoked from a subdirectory it refuses by name (its written paths are CWD-relative)"
# A deliberate behavior change, pinned rather than left as prose: the CWD-relative ambient read used
# to make this fail by accident, and firm-run-resolve anchors the pointer at the repository root on
# purpose, so the precondition is now asserted instead of inherited.
mkdir -p "$repo4/sub"
assert_rc "exit 1 from a subdirectory" 1 sh -c "cd '$repo4/sub' && '$HIRE' data-scientist"
assert_output "and it names the repository root it requires" "repository root" \
  sh -c "cd '$repo4/sub' && '$HIRE' data-scientist"
assert_no_file "no run tree was created under the subdirectory" "$repo4/sub/.agent-firm"
assert_ok "the same call from the repository root still works" \
  sh -c "cd '$repo4' && '$HIRE' data-scientist"

# ---------------------------------------------------------------------------
# wo6_inventory <repo> — everything a --help invocation must not change. Not a bare `find`: the
# hire_scaffolded ledger event is an APPEND to a file that already exists, so a name-only snapshot
# would call "help logged a hire" unchanged.
wo6_inventory() {
  ( cd "$1" 2>/dev/null || exit 0
    find . -path ./.git -prune -o -type f -print 2>/dev/null | LC_ALL=C sort | while read -r f; do
      cksum < "$f" 2>/dev/null | sed "s|\$| $f|"
    done
    find . -path ./.git -prune -o -type d -print 2>/dev/null | LC_ALL=C sort )
}

t_case "AC-010: firm-hire --help states how the run is selected, on stdout, exit 0, scaffolding nothing"
# Before this, `--help` fell into the leading-dash catch-all: rc 2, and the answer to "which run does
# this write into?" was "unknown option". Worse, the copy that predates --run scaffolded
# hires/--help.job.yaml for the same call, so "help creates nothing" is a property with history.
repo5="$(mk_repo)"
run_out5="$( (cd "$repo5" && "$NEW_RUN" hire-help fast_path) )"
inv5_before="$(wo6_inventory "$repo5")"
help5="$( (cd "$repo5" && "$HIRE" --help) 2>/dev/null )"; rc5=$?
inv5_after="$(wo6_inventory "$repo5")"
assert_eq "--help exits 0" 0 "$rc5"
assert_output "the synopsis is on stdout" "usage: firm-hire" printf '%s' "$help5"
assert_output "it names the selector in the accepted two-word spelling" "--run <run-dir>" \
  printf '%s' "$help5"
assert_output "it says the explicit selector is authoritative" "AUTHORITATIVE" printf '%s' "$help5"
assert_output "…and that the ambient pointer is then not read at all" "CURRENT_RUN is not" \
  printf '%s' "$help5"
assert_output "…naming the ambient pointer it beats" ".agent-firm/CURRENT_RUN" printf '%s' "$help5"
assert_output "…in the wording shared across every in-scope tool" "Explicit beats ambient" \
  printf '%s' "$help5"
assert_eq "--help wrote no job spec and appended no ledger event" "$inv5_before" "$inv5_after"
assert_no_file "and scaffolded no hires/ directory at all" \
  "$repo5/.agent-firm/runs/$(basename "$run_out5")/hires"
help5b="$( (cd "$repo5" && "$HIRE" -h) 2>/dev/null )"; rc5b=$?
assert_eq "-h exits 0 too" 0 "$rc5b"
assert_eq "-h prints the byte-identical synopsis" "$help5" "$help5b"

t_case "…and the leading-dash refusal was not widened by it"
# Only -h and --help in the OPTION position are help. Everything the catch-all refused before, it
# still refuses. (Deliberately NOT asserted here: `firm-hire -- -h`. Unlike firm-new-worktree, this
# tool has never re-checked <role-name> for a leading dash after the `--` terminator, so that call
# scaffolds hires/-h.job.yaml and exits 0. That is PRE-EXISTING and unchanged by the help carve-out --
# it behaves identically with and without it -- and pinning it here would cement a wart this work
# order is not authorised to fix. It is reported instead.)
assert_rc "-data-engineer is still refused" 2 sh -c "cd '$repo5' && '$HIRE' -data-engineer"
assert_rc "--run=<dir> is still refused by spelling" 2 \
  sh -c "cd '$repo5' && '$HIRE' --run=.agent-firm/runs/x data-engineer"
assert_eq "none of those refusals scaffolded anything" "$inv5_before" "$(wo6_inventory "$repo5")"
# Without this, every comparison above could be passing because wo6_inventory watches something that
# never moves. A real hire must move it.
(cd "$repo5" && "$HIRE" data-engineer >/dev/null 2>&1)
assert_ne "fixture precondition: a REAL hire does move that inventory" \
  "$inv5_before" "$(wo6_inventory "$repo5")"

t_summary
