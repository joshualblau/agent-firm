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
#
# The second half of this file pins the guards around that deletion, because --migrate is the only
# code in the firm that removes a permission rule from a file the user owns:
#   * SCOPE is enforced — each retired entry names the permission list(s) it may be deleted from, and
#     `deny` may never be one of them. The first version read only entry["rule"] and swept allow, ask
#     AND deny alike, which turned retired-permissions.json into a permission-DELETING channel: one
#     added line naming a deny rule would have stripped that protection from every project migrated.
#   * The write is BACKED UP and ATOMIC — it used to be `json.dump(tgt, open(target, "w"))`, a
#     truncate-then-write with no backup, against (at --user scope) every project's permission policy.
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
# present in ANY bucket. Used to assert a retired GRANT is gone from every list it could have drifted
# into. It is deliberately NOT how the `deny` protection is asserted — deny has its own cases below,
# because "gone from everywhere" is exactly the behaviour those cases forbid.
has_anywhere() { for b in allow ask deny; do rules_of "$1" "$b" | grep -qxF "$2" && return 0; done; return 1; }
lacks_anywhere() { ! has_anywhere "$1" "$2"; }

# ---- fixtures for varying the RETIREMENT POLICY itself ---------------------
# firm-install resolves both the canonical settings.json and the retirement policy relative to its own
# resolved location, so exercising a hostile or malformed policy means giving it a different root.
mk_firm_root() { # <policy-json | MISSING> -> echoes root path
  _r="$(mktemp -d "${TMPDIR:-/tmp}/firm-iroot.XXXXXX")"
  mkdir -p "$_r/bin" "$_r/.claude" "$_r/agent-firm/policy"
  cp "$BIN/firm-install" "$_r/bin/firm-install"
  cp "$FIRM_ROOT/.claude/settings.json" "$_r/.claude/settings.json"
  [ "$1" = MISSING ] || printf '%s\n' "$1" > "$_r/agent-firm/policy/retired-permissions.json"
  printf '%s' "$_r"
}
mk_target() { # <settings-json> -> echoes project path holding .claude/settings.json
  _p="$(mktemp -d "${TMPDIR:-/tmp}/firm-iproj.XXXXXX")"
  mkdir -p "$_p/.claude"
  printf '%s\n' "$1" > "$_p/.claude/settings.json"
  printf '%s' "$_p"
}
install_at() { _r="$1"; _d="$2"; shift 2; ( cd "$_d" && "$_r/bin/firm-install" "$@" ); }
inode_of()   { ls -i "$1" | awk '{print $1}'; }
bak_count()  { find "$1/.claude" -name 'settings.json.*.bak' | wc -l | tr -d ' '; }
tmp_count()  { find "$1/.claude" -name '.firm-install.*' | wc -l | tr -d ' '; }

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

# ===========================================================================
# `deny` IS NEVER DELETED — the supply-chain guard on the firm's one rule-deleting path
# ===========================================================================
t_case "a retirement entry that scopes a DENY rule is REFUSED, not honoured"
# The threat this closes: one line landed in retired-permissions.json naming a deny rule would, under
# the old all-buckets sweep, have deleted that protection from every project someone ran --migrate in,
# printed as a routine "removing retired rules" line. A data file must not be able to grant privilege.
hostile_root="$(mk_firm_root '{ "retired": [ { "rule": "Bash(sudo:*)", "scope": "deny", "since": "2026-08-01", "reason": "hostile entry" } ] }')"
T_TMPDIRS="$T_TMPDIRS $hostile_root"
victim="$(mk_target '{ "permissions": { "allow": [], "ask": [], "deny": ["Bash(sudo:*)", "Bash(rm -rf:*)"] } }')"
T_TMPDIRS="$T_TMPDIRS $victim"
VS="$victim/.claude/settings.json"
cp "$VS" "$victim/before.json"

assert_ok  "fixture precondition: the deny rule is really there" has_rule "$VS" deny "Bash(sudo:*)"
assert_rc  "--migrate REFUSES with exit 4" 4 install_at "$hostile_root" "$victim" --migrate
assert_output "says why: deny is a protection, not a grant" "deny is a PROTECTION, not a grant" \
  install_at "$hostile_root" "$victim" --migrate
assert_ok  "the deny rule is still there"            has_rule "$VS" deny "Bash(sudo:*)"
assert_ok  "the project's other deny rule survives"  has_rule "$VS" deny "Bash(rm -rf:*)"
assert_ok  "the settings file is byte-identical — nothing was written at all" \
  cmp -s "$victim/before.json" "$VS"
assert_eq  "and no backup was taken, because nothing was modified" "0" "$(bak_count "$victim")"
assert_rc  "a plain install refuses on the same policy too (the guard is not --migrate-only)" 4 \
  install_at "$hostile_root" "$victim"

t_case "a retired rule sitting in the target's own \`deny\` list survives --migrate"
# Same rule string, both a retired GRANT and a live protection. Removing it from allow is the fix;
# removing it from deny would be a privilege escalation performed in the name of a security cleanup.
both_proj="$(mk_target '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": [], "deny": ["Bash(cat:*)"] } }')"
T_TMPDIRS="$T_TMPDIRS $both_proj"
BS="$both_proj/.claude/settings.json"
assert_ok "fixture precondition: rule is in allow" has_rule "$BS" allow "Bash(cat:*)"
assert_ok "fixture precondition: rule is in deny"  has_rule "$BS" deny  "Bash(cat:*)"
assert_ok "migrate succeeds"                       install_in "$both_proj" --migrate
assert_ok "the GRANT is gone from allow"           lacks_rule "$BS" allow "Bash(cat:*)"
assert_ok "the PROTECTION is still in deny"        has_rule   "$BS" deny  "Bash(cat:*)"
assert_output "and it says so, rather than deleting quietly" "LEFT IN PLACE" \
  install_in "$both_proj" --migrate

t_case "scope is honoured: a rule is not deleted from a list its entry does not name"
# The `scope` field used to be read and thrown away. Here it names allow only, so the same rule
# sitting in `ask` must be left alone — the deletion authority is exactly what the policy declared.
allow_only_root="$(mk_firm_root '{ "retired": [ { "rule": "Bash(cat:*)", "scope": "allow" } ] }')"
T_TMPDIRS="$T_TMPDIRS $allow_only_root"
scoped_proj="$(mk_target '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": ["Bash(cat:*)"], "deny": [] } }')"
T_TMPDIRS="$T_TMPDIRS $scoped_proj"
PS="$scoped_proj/.claude/settings.json"
assert_ok "migrate succeeds"                          install_at "$allow_only_root" "$scoped_proj" --migrate
assert_ok "deleted from allow — the list scope names" lacks_rule "$PS" allow "Bash(cat:*)"
assert_ok "left in ask — a list scope does NOT name"  has_rule   "$PS" ask   "Bash(cat:*)"

t_case "the shipped policy scopes both GRANT lists, so real allow/ask drift is still cleaned"
# The complement of the case above: strict scope honouring must not quietly narrow the real migration.
# agent-firm/policy/retired-permissions.json names allow AND ask for both entries, which is why the
# "drifted into another bucket" case earlier in this file still passes. Assert that directly, so a
# future edit that drops "ask" from the policy fails here instead of silently leaving grants behind.
assert_ok "every shipped retirement entry names allow AND ask, and never deny" python3 -c "
import json, sys
entries = json.load(open('$FIRM_ROOT/agent-firm/policy/retired-permissions.json'))['retired']
assert entries, 'no retired entries at all'
for e in entries:
    s = e['scope']
    s = [s] if isinstance(s, str) else s
    assert 'deny' not in s, e['rule'] + ' scopes deny'
    assert set(s) == {'allow', 'ask'}, e['rule'] + ' scopes ' + repr(s)
"

t_case "a malformed retirement policy is REFUSED, with nothing written"
noscope_root="$(mk_firm_root '{ "retired": [ { "rule": "Bash(cat:*)" } ] }')"
T_TMPDIRS="$T_TMPDIRS $noscope_root"
ns_proj="$(mk_target '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": [], "deny": [] } }')"
T_TMPDIRS="$T_TMPDIRS $ns_proj"
cp "$ns_proj/.claude/settings.json" "$ns_proj/before.json"
assert_rc "a scope-less entry exits 4" 4 install_at "$noscope_root" "$ns_proj" --migrate
assert_output "refuses to guess" "refusing to guess" install_at "$noscope_root" "$ns_proj" --migrate
assert_ok "nothing was written" cmp -s "$ns_proj/before.json" "$ns_proj/.claude/settings.json"

badbucket_root="$(mk_firm_root '{ "retired": [ { "rule": "Bash(cat:*)", "scope": ["allow","everything"] } ] }')"
T_TMPDIRS="$T_TMPDIRS $badbucket_root"
assert_rc "an unknown permission list in scope exits 4" 4 install_at "$badbucket_root" "$ns_proj" --migrate
assert_ok "still nothing written" cmp -s "$ns_proj/before.json" "$ns_proj/.claude/settings.json"

t_case "--migrate with NO retirement policy says so instead of looking like it cleaned something"
# Not fatal (nothing to delete means nothing unsafe happens), but silence here would let a --migrate
# run against a missing policy read as a successful cleanup. firm-doctor separately FAILs on it.
gone_root="$(mk_firm_root MISSING)"; T_TMPDIRS="$T_TMPDIRS $gone_root"
gone_proj="$(mk_target '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": [], "deny": [] } }')"
T_TMPDIRS="$T_TMPDIRS $gone_proj"
assert_output "says there was nothing to migrate against" "nothing to migrate" \
  install_at "$gone_root" "$gone_proj" --migrate
assert_ok "and it did NOT delete the rule it had no policy for" \
  has_rule "$gone_proj/.claude/settings.json" allow "Bash(cat:*)"

t_case "an unreadable retirement policy is REFUSED (exit 5), with nothing written"
junk_root="$(mk_firm_root 'not json at all')"; T_TMPDIRS="$T_TMPDIRS $junk_root"
assert_rc "exits 5" 5 install_at "$junk_root" "$ns_proj" --migrate
assert_output "names the file it could not read" "cannot read the retirement policy" \
  install_at "$junk_root" "$ns_proj" --migrate
assert_ok "nothing was written" cmp -s "$ns_proj/before.json" "$ns_proj/.claude/settings.json"

# ===========================================================================
# THE WRITE ITSELF — backed up, atomic, and a no-op when there is nothing to change
# ===========================================================================
t_case "--migrate backs the settings file up before deleting, and prints the path"
bk_proj="$(mk_target '{ "permissions": { "allow": ["Bash(cat:*)", "Bash(keep-me:*)"], "ask": [], "deny": [] } }')"
T_TMPDIRS="$T_TMPDIRS $bk_proj"
KS="$bk_proj/.claude/settings.json"
assert_eq "no backups before the run" "0" "$(bak_count "$bk_proj")"
assert_output "prints the backup path" "backed up the previous settings to" install_in "$bk_proj" --migrate
assert_eq "exactly one backup exists" "1" "$(bak_count "$bk_proj")"
bak="$(find "$bk_proj/.claude" -name 'settings.json.*.bak' | head -1)"
assert_ok "the backup holds the PRE-migration content (the deleted rule is recoverable)" \
  has_rule "$bak" allow "Bash(cat:*)"
assert_ok "the live file no longer has it"  lacks_rule "$KS" allow "Bash(cat:*)"
assert_ok "the backup name carries a UTC timestamp" \
  sh -c 'case "$1" in *settings.json.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z*.bak) exit 0;; *) exit 1;; esac' _ "$bak"

t_case "the settings file is renamed into place, never truncated where it stands"
# `json.dump(tgt, open(target, "w"))` truncated the caller's real permission policy before producing a
# single byte of replacement; a crash in that window left an empty settings.json. Two independent
# observable consequences of the temp-file + os.replace() fix are asserted here: the file's identity
# changes (a rename installs a NEW inode; an in-place rewrite keeps the old one), and a write that
# cannot even begin leaves the original completely intact.
at_proj="$(mk_target '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": [], "deny": [] } }')"
T_TMPDIRS="$T_TMPDIRS $at_proj"
AS="$at_proj/.claude/settings.json"
ino_before="$(inode_of "$AS")"
assert_ok "migrate succeeds"           install_in "$at_proj" --migrate
assert_ne "the file was replaced, not rewritten in place" "$ino_before" "$(inode_of "$AS")"
assert_eq "no temp file was left behind" "0" "$(tmp_count "$at_proj")"

if [ "$(id -u)" != "0" ]; then
  fail_proj="$(mk_target '{ "permissions": { "allow": ["Bash(cat:*)"], "ask": [], "deny": [] } }')"
  T_TMPDIRS="$T_TMPDIRS $fail_proj"
  FS="$fail_proj/.claude/settings.json"
  cp "$FS" "$fail_proj/before.json"
  chmod 500 "$fail_proj/.claude"
  assert_fail "a write that cannot start exits non-zero" install_in "$fail_proj" --migrate
  chmod 700 "$fail_proj/.claude"
  assert_ok "and the original settings file is completely intact" cmp -s "$fail_proj/before.json" "$FS"
  assert_eq "no temp file was left behind either" "0" "$(tmp_count "$fail_proj")"
else
  printf '    (skipped: the unwritable-directory case is meaningless as root)\n'
fi

t_case "an install with nothing to change writes nothing and takes no backup"
noop_proj="$(mktemp -d "${TMPDIR:-/tmp}/firm-iproj.XXXXXX")"; T_TMPDIRS="$T_TMPDIRS $noop_proj"
assert_ok "first install creates the file" install_in "$noop_proj"
ino1="$(inode_of "$noop_proj/.claude/settings.json")"
assert_output "second install reports the no-op" "already matches the firm's permissions" install_in "$noop_proj"
assert_eq "the file was not rewritten"  "$ino1" "$(inode_of "$noop_proj/.claude/settings.json")"
assert_eq "and no .bak litter accumulated" "0" "$(bak_count "$noop_proj")"

t_summary
