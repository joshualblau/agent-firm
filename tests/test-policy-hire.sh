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

t_summary
