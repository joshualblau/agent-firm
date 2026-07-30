#!/usr/bin/env bash
# tests/test-install-migrate.sh — firm-install must be able to REMOVE a rule it once granted.
#
# firm-install only ever unioned rules, so a project installed before Bash(cat:*) was retired keeps
# reading around the Read-tool deny rules forever. A warning doesn't close that; --migrate does.
# These tests pin both halves: the warning path (exit 3, nothing deleted) and the migrate path
# (retired rules gone, everything else untouched).
#
# Rules are compared as whole lines via has_rule, NOT with grep patterns: a `grep -F 'Bash(cat:\*)'`
# never matches (backslash is literal under -F), so a negated grep passes for the wrong reason and
# the test asserts nothing. That is the overclaiming-test failure the firm's own DoD prohibits.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

install_in() { d="$1"; shift; ( cd "$d" && "$BIN/firm-install" "$@" ); }

# rules_of <settings.json> <bucket> — one rule per line
rules_of() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print("\n".join(d.get("permissions",{}).get(sys.argv[2],[])))' "$1" "$2" 2>/dev/null
}
has_rule()     { rules_of "$1" "$2" | grep -qxF "$3"; }
lacks_rule()   { ! rules_of "$1" "$2" | grep -qxF "$3"; }
# present in ANY bucket — a retired rule is unsafe wherever it drifted to
has_anywhere() { for b in allow ask deny; do rules_of "$1" "$b" | grep -qxF "$2" && return 0; done; return 1; }
lacks_anywhere() { ! has_anywhere "$1" "$2"; }

# ---------------------------------------------------------------------------
t_case "a stale project keeps the retired rule until it is migrated"
proj="$(mk_repo)"; S="$proj/.claude/settings.json"
mkdir -p "$proj/.claude"
cat > "$S" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(cat:*)", "Bash(jq:*)", "Bash(my-project-tool:*)"],
    "ask": [],
    "deny": []
  }
}
JSON
# Prove the fixture really contains what the rest of the case depends on.
assert_ok "fixture precondition: stale rule present" has_rule "$S" allow "Bash(cat:*)"

assert_rc     "plain install warns and signals (exit 3)" 3 install_in "$proj"
assert_output "names the retired rule" "Bash(cat:*)"       install_in "$proj"
assert_output "names the fix"          "--migrate"          install_in "$proj"
assert_ok     "retired rule NOT silently deleted by a plain install" has_rule "$S" allow "Bash(cat:*)"

# ---------------------------------------------------------------------------
t_case "--migrate removes exactly the retired rules and nothing else"
assert_ok "migrate succeeds"                      install_in "$proj" --migrate
assert_ok "Bash(cat:*) gone from every bucket"    lacks_anywhere "$S" "Bash(cat:*)"
assert_ok "Bash(jq:*) gone from every bucket"     lacks_anywhere "$S" "Bash(jq:*)"
assert_ok "the project's own rule survives"       has_rule "$S" allow "Bash(my-project-tool:*)"
assert_ok "the firm's allow rules were merged in" has_rule "$S" allow "Bash(firm-new-run:*)"
assert_ok "the new deny rules landed"             has_rule "$S" deny  "Bash(cat .env*)"
assert_ok "Read-tool deny rules landed"           has_rule "$S" deny  "Read(./.env)"

# ---------------------------------------------------------------------------
t_case "--migrate is idempotent and settles to a clean install"
assert_ok "second migrate is a no-op"   install_in "$proj" --migrate
assert_ok "plain install now exits 0"   install_in "$proj"
assert_ok "still no retired rule"       lacks_anywhere "$S" "Bash(cat:*)"
assert_ok "project rule still survives" has_rule "$S" allow "Bash(my-project-tool:*)"

# ---------------------------------------------------------------------------
t_case "a retired rule that drifted into another bucket is still caught"
proj2="$(mk_repo)"; S2="$proj2/.claude/settings.json"
mkdir -p "$proj2/.claude"
printf '%s\n' '{ "permissions": { "allow": [], "ask": ["Bash(cat:*)"], "deny": [] } }' > "$S2"
assert_ok "fixture precondition: rule sits in ask" has_rule "$S2" ask "Bash(cat:*)"

assert_rc "warns about a retired rule sitting in ask" 3 install_in "$proj2"
assert_ok "migrate clears it from ask too"   install_in "$proj2" --migrate
assert_ok "gone from every bucket"           lacks_anywhere "$S2" "Bash(cat:*)"

# ---------------------------------------------------------------------------
t_case "a fresh project installs clean — no blanket cat/jq grant is ever created"
proj3="$(mk_repo)"; S3="$proj3/.claude/settings.json"
assert_ok "fresh install"             install_in "$proj3"
assert_file "settings written"        "$S3"
assert_ok "firm allow rules present"  has_rule "$S3" allow "Bash(firm-validate-verdict:*)"
assert_ok "no blanket cat grant"      lacks_rule "$S3" allow "Bash(cat:*)"
assert_ok "no blanket jq grant"       lacks_rule "$S3" allow "Bash(jq:*)"

# ---------------------------------------------------------------------------
t_case "the migrate suggestion names the RIGHT scope, even for a .claude*-prefixed project path"
# firm-install used to guess scope via `target.startswith(os.path.expanduser('~/.claude'))` — a raw
# string-prefix check that misfires for any project living under a path that textually starts with
# "~/.claude" too, such as ~/.claude-work/<project>/ (a pattern this repo's own .gitignore already
# anticipates: `.claude-*/`). A project-scope fix would be told to run --user, silently migrating the
# WRONG file while the real grant stayed in place. It must use the scope firm-install already knows.
base="$(mktemp -d)"; T_TMPDIRS="$T_TMPDIRS $base"
weird_proj="$base/.claude-work/some-profile"
mkdir -p "$weird_proj/.claude"
printf '%s\n' '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": [], "deny": [] } }' > "$weird_proj/.claude/settings.json"

install_scoped() { d="$1"; h="$2"; shift 2; ( cd "$d" && HOME="$h" "$BIN/firm-install" "$@" ); }

assert_output "project-scope fix suggestion has NO --user" "Remove them with:  firm-install --migrate" \
  install_scoped "$weird_proj" "$base"
out="$(install_scoped "$weird_proj" "$base" 2>&1 || true)"
case "$out" in
  *"firm-install --user --migrate"*) _t_no "does not suggest --user for a project-scope fix" "got: $(_t_ctx "$out")" ;;
  *) _t_ok "does not suggest --user for a project-scope fix" ;;
esac

t_case "the migrate suggestion still says --user for an actual --user install"
user_home="$(mktemp -d)"; T_TMPDIRS="$T_TMPDIRS $user_home"
mkdir -p "$user_home/.claude"
printf '%s\n' '{ "permissions": { "allow": ["Bash(jq:*)"], "ask": [], "deny": [] } }' > "$user_home/.claude/settings.json"
some_cwd="$(mk_repo)"
assert_output "user-scope fix suggestion DOES say --user" "firm-install --user --migrate" \
  install_scoped "$some_cwd" "$user_home" --user

t_summary
