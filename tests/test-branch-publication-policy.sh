#!/usr/bin/env bash
# Agent Firm 0.9.0: topic branches are publishable; direct default-branch writes are not.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$BIN/firm-merge-guard"
SETTINGS="$FIRM_ROOT/.claude/settings.json"

policy_repo() {
  _r="$(mk_repo)"
  git clone --bare -q "$_r" "$_r/remote.git"
  git -C "$_r" remote add origin "$_r/remote.git"
  git -C "$_r" update-ref refs/remotes/origin/main "$(git -C "$_r" rev-parse HEAD)"
  git -C "$_r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf '%s' "$_r"
}

check() { (cd "$1" && "$GUARD" --command "$2"); }
hook() {
  _payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$2")"
  (cd "$1" && printf '%s' "$_payload" | "$GUARD" --hook)
}

t_case "0.9.0 release identity is semantic, not only a cachebuster"
assert_output "canonical version is 0.9.0" "0.9.0" tr -d '\n' < "$FIRM_ROOT/VERSION"
assert_ok "both provider manifests have the 0.9.0 base" "$BIN/firm-version" --check

t_case "policy distinguishes the reviewable path from the merge decision"
assert_ok "action scopes carry the closed branch/PR split" t_python - "$FIRM_ROOT" <<'PY'
import sys,yaml
root=sys.argv[1]
p=yaml.safe_load(open(root+'/agent-firm/policy/action-scopes.yaml'))
local=p['local_repository']; external=p['external_systems']
assert local['commit']=='allowed_in_worktree',local
assert local['push_topic_branch']=='allowed',local
assert local['delete_topic_branch']=='allowed_after_verified_merge',local
assert local['push_default_branch']=='prohibited',local
assert local['merge_to_default_branch']=='human_gate',local
assert 'push' not in local and 'merge_to_main' not in local,local
assert external['pr_create_or_edit']=='allowed',external
assert external['issue_creation']=='human_gate',external
assert 'pr_or_issue_creation' not in external,external
PY
assert_ok "never-rules prohibit only direct default-branch publication" t_python - "$FIRM_ROOT" <<'PY'
import sys,yaml
rules='\n'.join(yaml.safe_load(open(sys.argv[1]+'/agent-firm/policy/never-rules.yaml'))['never_rules'])
assert 'never push to a remote without explicit human approval' not in rules,rules
assert 'remote default branch directly' in rules,rules
PY

t_case "Claude permission precedence cannot turn PR allows back into prompts"
assert_ok "specific PR operations are allowed and no broader ask shadows them" t_python - "$SETTINGS" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))['permissions']
for rule in ('Bash(gh pr create:*)','Bash(gh pr edit:*)','Bash(gh pr comment:*)',
             'Bash(gh pr ready:*)'):
    assert rule in p['allow'],rule
assert 'Bash(gh:*)' not in p['ask'],p['ask']
for rule in ('Bash(gh issue:*)','Bash(gh api:*)','Bash(gh release:*)'):
    assert rule in p['ask'],rule
assert 'Bash(git push:*)' not in p['deny'],p['deny']
for rule in ('Bash(git push --all:*)','Bash(git push --mirror:*)','Bash(gh pr merge:*)'):
    assert rule in p['deny'],rule
PY

t_case "explicit topic branches are ordinary work without GitHub identity resolution"
repo="$(policy_repo)"
assert_rc "topic branch" 0 check "$repo" "git push origin feature/branch-policy"
assert_rc "forced topic branch" 0 check "$repo" "git push --force-with-lease origin feature/branch-policy"
assert_rc "topic deletion" 0 check "$repo" "git push --delete origin feature/old"
assert_rc "explicit HEAD to topic" 0 check "$repo" "git push origin HEAD:refs/heads/feature/head"
assert_rc "git -C topic push" 0 check "$repo" "git -C $repo push origin feature/from-c"
assert_rc "literal cd topic push" 0 check "$repo" "cd $repo && git push origin feature/from-cd"

t_case "direct default-branch writes are prohibited for every ordinary refspec spelling"
assert_rc "named default" 1 check "$repo" "git push origin main"
assert_rc "HEAD to default" 1 check "$repo" "git push origin HEAD:main"
assert_rc "full ref" 1 check "$repo" "git push origin HEAD:refs/heads/main"
assert_rc "forced default" 1 check "$repo" "git push origin +HEAD:main"
assert_rc "delete default" 1 check "$repo" "git push --delete origin main"
assert_rc "all includes default" 1 check "$repo" "git push --all origin"
assert_rc "mirror includes default" 1 check "$repo" "git push --mirror origin"
assert_output "block explains the reviewable alternative" "open a pull request" \
  check "$repo" "git push origin main"

t_case "remote-advertised HEAD, not mutable local cache, defines the default"
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feature/forged
assert_rc "forged local origin/HEAD cannot make main publishable" 1 \
  check "$repo" "git push origin main"
trunk_repo="$(policy_repo)"
git --git-dir="$trunk_repo/remote.git" update-ref refs/heads/trunk \
  "$(git --git-dir="$trunk_repo/remote.git" rev-parse refs/heads/main)"
git --git-dir="$trunk_repo/remote.git" symbolic-ref HEAD refs/heads/trunk
assert_rc "non-main remote default is prohibited" 1 check "$trunk_repo" "git push origin trunk"
assert_rc "main is an ordinary topic when remote HEAD is trunk" 0 check "$trunk_repo" "git push origin main"

t_case "ambiguous pushes fail closed and never fall back to blanket identity authority"
assert_rc "unknown remote" 2 check "$repo" "git push other feature/x"
assert_rc "wrapper-owned push" 2 check "$repo" "env git push origin feature/x"
assert_rc "unknown flag" 2 check "$repo" "git push --invented origin feature/x"
assert_rc "wildcard refspec" 2 check "$repo" "git push origin 'refs/heads/*:refs/heads/*'"
assert_rc "compound default push is prioritised over a preceding merge" 1 \
  check "$repo" "git merge feature/x && git push origin main"
assert_rc "multiple push invocations exceed the bounded proof surface" 2 \
  check "$repo" "git push origin feature/one && git push origin feature/two"

t_case "bare pushes use the actual push destination"
git -C "$repo" switch -q -c feature/upstream
git -C "$repo" update-ref refs/remotes/origin/feature/upstream "$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" config branch.feature/upstream.remote origin
git -C "$repo" config branch.feature/upstream.merge refs/heads/feature/upstream
assert_rc "bare topic push" 0 check "$repo" "git push"
git -C "$repo" switch -q main
git -C "$repo" config branch.main.remote origin
git -C "$repo" config branch.main.merge refs/heads/main
assert_rc "bare default push" 1 check "$repo" "git push"

t_case "hook adapter maps policy refusal to a blocking exit"
assert_rc "topic through hook" 0 hook "$repo" "git push origin feature/hook"
assert_rc "default through hook" 2 hook "$repo" "git push origin main"

t_case "non-push merge authority and benign command behavior remain intact"
assert_rc "benign command" 0 check "$repo" "git status --short"
assert_rc "push text in a commit message is benign" 0 check "$repo" "git commit -m 'document git push policy'"

t_case "both provider adapters state the same worktree/publication contract"
assert_ok "lifecycle and adapters carry the required policy" t_python - "$FIRM_ROOT" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
required=('dedicated `firm-new-worktree`','explicit non-default branch','remote default branch')
for rel in ('agent-firm/contracts/lifecycle.md','codex-skills/start/SKILL.md','commands/start.md'):
    text=(root/rel).read_text()
    for phrase in required:
        assert phrase in text,(rel,phrase)
PY

t_case "firm-new-worktree accepts a non-implementer writing role"
role_repo="$(mk_repo)"
(cd "$role_repo" && "$BIN/firm-new-run" role-worktree fast_path >/dev/null)
(cd "$role_repo" && "$BIN/firm-new-worktree" architect plan >/dev/null)
run_id="$(basename "$(cat "$role_repo/.agent-firm/CURRENT_RUN")")"
env_file="$role_repo/.agent-firm/worktrees/${run_id}-architect-plan/.agent-firm-worktree.env"
assert_output "architect role is preserved" "WORKTREE_ROLE=architect" cat "$env_file"

t_summary
