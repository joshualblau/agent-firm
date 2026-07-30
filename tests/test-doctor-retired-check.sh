#!/usr/bin/env bash
# tests/test-doctor-retired-check.sh — firm-doctor's retired-permission-rules check must not report a
# clean PASS on a settings.json it could not actually inspect.
#
# The first version of this check swallowed every parse failure with `except Exception: sys.exit(0)`,
# which silently printed "carries no retired permission rules" for a file that was invalid JSON, or
# whose `permissions` key was shaped as a list instead of an object. A project with a genuinely stale
# Bash(cat:*) grant AND a corrupted settings.json would have gotten a clean bill of health from the one
# check meant to catch exactly that — the opposite of "fail closed on uncertainty".
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOCTOR="$BIN/firm-doctor"

doctor_in() { ( cd "$1" && HOME="$1/fake-home" "$DOCTOR" ); }
retired_lines() { doctor_in "$1" 2>&1 | grep -iE 'retired permission|carry no retired'; }

# ---------------------------------------------------------------------------
t_case "malformed JSON is a WARN, never a silent PASS"
proj="$(mk_repo)"; mkdir -p "$proj/.claude" "$proj/fake-home"
printf '{ this is not valid json\n' > "$proj/.claude/settings.json"

out="$(retired_lines "$proj")"
assert_output "project line WARNs about the parse failure" "WARN" retired_lines "$proj"
assert_ok "project line does NOT claim PASS" sh -c "! printf '%s' \"\$1\" | grep -q 'PASS project settings carry no retired'" _ "$out"
assert_output "names the fix (re-run after repair)" "re-run firm-doctor" retired_lines "$proj"

# ---------------------------------------------------------------------------
t_case "permissions as the wrong JSON type is a WARN, never a silent PASS"
proj2="$(mk_repo)"; mkdir -p "$proj2/.claude" "$proj2/fake-home"
printf '{ "permissions": [] }\n' > "$proj2/.claude/settings.json"

out2="$(retired_lines "$proj2")"
assert_output "project line WARNs on the type mismatch" "WARN" retired_lines "$proj2"
assert_ok "project line does NOT claim PASS" sh -c "! printf '%s' \"\$1\" | grep -q 'PASS project settings carry no retired'" _ "$out2"

# ---------------------------------------------------------------------------
t_case "a bucket of the wrong JSON type is a WARN, never a silent PASS"
proj3="$(mk_repo)"; mkdir -p "$proj3/.claude" "$proj3/fake-home"
printf '{ "permissions": { "allow": "Bash(cat:*)", "ask": [], "deny": [] } }\n' > "$proj3/.claude/settings.json"

assert_output "project line WARNs when a bucket isn't an array" "WARN" retired_lines "$proj3"

# ---------------------------------------------------------------------------
t_case "a genuinely stale project still FAILs (the check still works when it CAN parse)"
proj4="$(mk_repo)"; mkdir -p "$proj4/.claude" "$proj4/fake-home"
printf '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": [], "deny": [] } }\n' > "$proj4/.claude/settings.json"

assert_output "project line FAILs on a real retired grant" "FAIL project settings still grant RETIRED" retired_lines "$proj4"

# ---------------------------------------------------------------------------
t_case "a clean, well-formed project still PASSes"
proj5="$(mk_repo)"; mkdir -p "$proj5/fake-home"
( cd "$proj5" && HOME="$proj5/fake-home" "$BIN/firm-install" ) >/dev/null 2>&1

assert_output "project line PASSes on a fresh install" "PASS project settings carry no retired" retired_lines "$proj5"

t_summary
