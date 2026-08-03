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
head -60 "$GUARD" > "$SCRATCH_HEADER"
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
assert_output "the message offers the exact git config remedy" "git config --global user.email" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "the remedy names an email read FROM the allowlist" "$ALLOWED_EMAIL" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'
assert_output "the message repeats the client-side caveat" "CLIENT-SIDE" mg "$TREE" "$GH_OK" "$LREPO" --command 'git push origin main'

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
assert_rc "and the booby-trapped PATH still BLOCKS a gated command (not a silent pass)" 2 \
  mg "$TREE" "$EXPLODE" "$REPO_OK" --command 'git push origin main'
t_case "AC-022 the same holds through the hook adapter, on a real payload"
hook_explode() { ( cd "$REPO_OK" && printf '%s' "$(mk_payload "$1")" | PATH="$EXPLODE:$PATH" "$TREE/bin/firm-merge-guard" --hook ); }
assert_rc "hook + benign command -> 0" 0 hook_explode 'ls -la'
assert_eq "hook + benign command spawned no gh/git/python3" "" "$(hook_explode 'ls -la' 2>&1)"

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
assert_output "--surface lists the covered forms" "git push (every form" mg_env "$TREE" "$PATH" "$REPO_OK" --surface
assert_output "--surface lists the KNOWN GAPS honestly" "KNOWN GAPS" mg_env "$TREE" "$PATH" "$REPO_OK" --surface
assert_output "--surface names the alias gap" "ALIAS" mg_env "$TREE" "$PATH" "$REPO_OK" --surface
assert_output "--surface names the non-shell gap" "Non-shell surfaces" mg_env "$TREE" "$PATH" "$REPO_OK" --surface
assert_output "--help prints the exit contract" "EXIT CONTRACT" mg_env "$TREE" "$PATH" "$REPO_OK" --help

t_case "known gaps are asserted as gaps, so a future fix has a test to flip"
# These are NOT wins. They are recorded so the gap list in the script header cannot drift away from
# the behaviour: if someone closes one of them, this assertion fails and the docs get updated.
assert_rc "GAP: a git alias for push is invisible" 0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'git ps origin main'
assert_rc "GAP: a variable-indirected git is invisible" 0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'g=git; $g push origin main'
assert_rc "GAP: hub/glab are not covered" 0 mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'hub push origin main'
assert_rc "GAP: a push from python is not covered" 0 \
  mg "$TREE" "$GH_OK" "$REPO_BAD" --command 'python3 -c "import subprocess;subprocess.run([chr(103)+chr(105)+chr(116)])"'

t_summary
