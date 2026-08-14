#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOUND="$BIN/firm-bounded-exec"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-bounded.XXXXXX")"; t_track "$WORK"

result_field() {
  python3 - "$1" "$2" <<'PY'
import json,sys
print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])
PY
}

t_case "a successful phase emits bounded structured identity and mode-0600 files"
assert_rc "child success is success" 0 "$BOUND" --phase discovery --provider gpt --timeout 2 --grace 1 \
  --max-output 1024 --generation 7 --output "$WORK/ok.out" --result "$WORK/ok.json" -- sh -c 'printf hello'
assert_eq "phase is retained" discovery "$(result_field "$WORK/ok.json" phase)"
assert_eq "provider is retained" gpt "$(result_field "$WORK/ok.json" provider)"
assert_eq "generation is retained" 7 "$(result_field "$WORK/ok.json" generation)"
assert_eq "status is ok" ok "$(result_field "$WORK/ok.json" status)"
assert_eq "child output retained" hello "$(cat "$WORK/ok.out")"
assert_eq "output mode is 600" 600 "$(t_file_mode "$WORK/ok.out")"
assert_eq "result mode is 600" 600 "$(t_file_mode "$WORK/ok.json")"

t_case "stdout can be isolated from bounded provider diagnostics"
assert_rc "split stream capture succeeds" 0 "$BOUND" --phase discovery --provider codex --timeout 2 --grace 1 \
  --max-output 1024 --generation 1 --output "$WORK/split.out" --stderr-output "$WORK/split.err" \
  --result "$WORK/split.json" -- sh -c 'printf structured; printf warning >&2'
assert_eq "stdout contains only provider data" structured "$(cat "$WORK/split.out")"
assert_eq "stderr contains only provider diagnostics" warning "$(cat "$WORK/split.err")"
assert_eq "stderr output mode is 600" 600 "$(t_file_mode "$WORK/split.err")"
assert_eq "stdout byte count is explicit" 10 "$(result_field "$WORK/split.json" stdout_bytes)"
assert_eq "stderr byte count is explicit" 7 "$(result_field "$WORK/split.json" stderr_bytes)"
assert_eq "combined retained count preserves the output cap accounting" 17 "$(result_field "$WORK/split.json" retained_bytes)"

t_case "every invalid caller bound is rejected before provider execution"
for spec in \
  "--timeout 0" "--timeout -1" "--timeout nope" "--timeout 901" \
  "--grace 0" "--grace -1" "--grace nope" "--grace 31" \
  "--max-output 0" "--max-output -1" "--max-output nope" "--max-output 1048577" \
  "--generation 0" "--generation nope" "--max-turns 0" "--max-turns 1001"
do
  rm -f "$WORK/invalid-sentinel"
  assert_rc "rejects $spec" 2 sh -c "'$BOUND' --phase judge --provider claude $spec -- sh -c 'touch \"$WORK/invalid-sentinel\"'"
  assert_no_file "provider did not start for $spec" "$WORK/invalid-sentinel"
done

t_case "output is capped independently from child classification"
assert_rc "large successful output still returns child success" 0 "$BOUND" --phase model --provider claude \
  --timeout 2 --grace 1 --max-output 64 --generation 1 --output "$WORK/cap.out" --result "$WORK/cap.json" -- \
  python3 -c 'print("S"*4096)'
assert_eq "only 64 bytes retained" 64 "$(wc -c < "$WORK/cap.out" | tr -d ' ')"
assert_eq "result marks truncation" True "$(result_field "$WORK/cap.json" truncated)"
assert_eq "result records full observed output" 4097 "$(result_field "$WORK/cap.json" output_bytes)"

t_case "a large newline-free provider record has an independent bounded parser buffer"
assert_rc "16 MiB newline-free stream completes without growing the parser with output" 0 "$BOUND" \
  --phase judge --provider gpt --timeout 10 --grace 1 --max-output 4096 --generation 1 \
  --output "$WORK/no-newline.out" --result "$WORK/no-newline.json" -- \
  python3 -c 'import sys; chunk=b"X"*65536; [sys.stdout.buffer.write(chunk) for _ in range(256)]; sys.stdout.buffer.flush()'
assert_eq "retained bytes remain independently capped" 4096 "$(wc -c < "$WORK/no-newline.out" | tr -d ' ')"
assert_eq "overlong event record has an explicit parser state" overlong_record "$(result_field "$WORK/no-newline.json" parser_status)"
assert_ok "parser peak never exceeds its fixed 64 KiB bound" python3 - "$WORK/no-newline.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d["parser_peak_bytes"] <= d["parser_limit_bytes"] == 65536
assert d["overlong_records"] == 1
PY

t_case "wall timeout supervises the process group and escalates TERM to KILL"
for phase in discovery authentication model judge; do
  pidfile="$WORK/$phase.pid"
  assert_rc "$phase hang returns timeout" 124 "$BOUND" --phase "$phase" --provider gpt \
    --timeout 1 --grace 1 --max-output 1024 --generation 1 --output "$WORK/$phase.out" \
    --result "$WORK/$phase.json" -- sh -c 'trap "" TERM; (trap "" TERM; sleep 30) & echo $! > "$1"; wait' sh "$pidfile"
  assert_eq "$phase status is timeout" timeout "$(result_field "$WORK/$phase.json" status)"
  assert_eq "$phase sent TERM" True "$(result_field "$WORK/$phase.json" term_sent)"
  assert_eq "$phase sent KILL after bounded grace" True "$(result_field "$WORK/$phase.json" kill_sent)"
  child="$(cat "$pidfile")"
  assert_ok "$phase descendant is gone" sh -c "! kill -0 '$child' 2>/dev/null"
done

t_case "a cooperative process exits during grace without a KILL"
assert_rc "TERM-handling child is still classified as timeout" 124 "$BOUND" --phase judge --provider claude \
  --timeout 1 --grace 2 --max-output 1024 --generation 1 --result "$WORK/term.json" -- \
  sh -c 'trap "exit 0" TERM; while :; do sleep 1; done'
assert_eq "TERM was sent" True "$(result_field "$WORK/term.json" term_sent)"
assert_eq "KILL was unnecessary" False "$(result_field "$WORK/term.json" kill_sent)"

t_case "streamed top-level turns stop the process group preemptively"
assert_rc "second top-level turn terminates the child" 125 "$BOUND" --phase judge --provider gpt \
  --timeout 10 --grace 1 --max-output 4096 --max-turns 2 --generation 1 \
  --output "$WORK/turn.out" --result "$WORK/turn.json" -- sh -c \
  'printf "%s\n" "{\"type\":\"assistant\"}"; sleep 1; printf "%s\n" "{\"type\":\"assistant_message\"}"; sleep 4; touch "$1"' sh "$WORK/over-turn"
assert_eq "turn-limit status is distinct" turn_limit "$(result_field "$WORK/turn.json" status)"
assert_eq "exactly two top-level turns counted" 2 "$(result_field "$WORK/turn.json" turn_count)"
assert_no_file "work beyond the turn limit did not complete" "$WORK/over-turn"

t_case "unsafe result redirection targets are refused"
printf 'keep\n' > "$WORK/real-target"
ln -s "$WORK/real-target" "$WORK/result-link"
assert_rc "symlink result path is rejected" 2 "$BOUND" --phase judge --provider gpt --timeout 2 \
  --grace 1 --max-output 100 --generation 1 --result "$WORK/result-link" -- sh -c 'exit 0'
assert_eq "redirect target is byte-identical" keep "$(cat "$WORK/real-target")"

t_summary
