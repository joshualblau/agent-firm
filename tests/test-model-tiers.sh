#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVE="$BIN/firm-model-resolve"
POLICY="$FIRM_ROOT/agent-firm/policy/model-tiers.yaml"
W="$(mktemp -d "${TMPDIR:-/tmp}/firm-model-tiers.XXXXXX")"; t_track "$W"

t_case "canonical policy resolves every tier, role, alias, provider, and field exactly"
assert_ok "complete canonical resolution matrix" python3 - "$RESOLVE" "$POLICY" <<'PY'
import json, pathlib, subprocess, sys, yaml
resolve, policy_path = sys.argv[1:]
policy = yaml.safe_load(pathlib.Path(policy_path).read_text())
cells = {
    "ceiling": {"claude": ("fable", "Fable 5", "max"), "codex": ("gpt-5.6-sol", "GPT-5.6 sol", "ultra")},
    "heavyweight": {"claude": ("opus", "Opus 5", "xhigh"), "codex": ("gpt-5.6-sol", "GPT-5.6 sol", "xhigh")},
    "workhorse": {"claude": ("sonnet", "Sonnet 5", "high"), "codex": ("gpt-5.6-terra", "GPT-5.6 terra", "high")},
    "fast": {"claude": ("haiku", "Haiku 4.5", "low"), "codex": ("gpt-5.6-terra", "GPT-5.6 terra", "low")},
}
roles = {
    "lead": "heavyweight", "intake-analyst": "heavyweight", "architect": "heavyweight",
    "implementer": "heavyweight", "integrator": "heavyweight", "reviewer": "heavyweight",
    "recruiter": "workhorse", "packager": "workhorse", "qa-tester": "workhorse",
    "specialist": "workhorse", "scout": "fast",
}
aliases = {"fable": "ceiling", "opus": "heavyweight", "sonnet": "workhorse", "haiku": "fast", "codex": "heavyweight"}
assert policy["role_tiers"] == roles
assert policy["legacy_aliases"] == aliases

def run(*args):
    done = subprocess.run([resolve, *args], text=True, capture_output=True)
    assert done.returncode == 0, (args, done.returncode, done.stderr)
    return json.loads(done.stdout)

for tier, providers in cells.items():
    for provider, expected in providers.items():
        got = run("--provider", provider, "--tier", tier)
        assert (got["tier"], got["model"], got["display"], got["effort"]) == (tier, *expected), got
        assert len(got["policy_sha256"]) == 64
for role, tier in roles.items():
    for provider, expected in cells[tier].items():
        got = run("--provider", provider, "--role", role)
        assert (got["selected_by"], got["selector"], got["tier"], got["model"], got["display"], got["effort"]) == ("role", role, tier, *expected), got
for alias, tier in aliases.items():
    for provider, expected in cells[tier].items():
        got = run("--provider", provider, "--alias", alias)
        assert (got["selected_by"], got["selector"], got["tier"], got["model"], got["display"], got["effort"]) == ("alias", alias, tier, *expected), got
PY

t_case "unknown selectors and noncanonical launch overrides fail closed"
assert_rc "unknown role" 2 "$RESOLVE" --provider codex --role mystery
assert_rc "named judge is not a hidden role alias" 2 "$RESOLVE" --provider codex --role gpt-judge
assert_rc "unknown tier" 2 "$RESOLVE" --provider codex --tier mystery
assert_rc "unknown alias" 2 "$RESOLVE" --provider codex --alias mystery
assert_rc "wrong model" 2 "$RESOLVE" --provider codex --role reviewer --expect-model unknown-model
assert_rc "wrong display" 2 "$RESOLVE" --provider codex --role reviewer --expect-display unknown-display
assert_rc "wrong effort" 2 "$RESOLVE" --provider codex --role reviewer --expect-effort ultra
assert_output "override failure says no fallback" "no fallback applied" \
  "$RESOLVE" --provider codex --role reviewer --expect-effort ultra

t_case "closed policy schema rejects duplicate, missing, unknown, and dangling entries"
assert_ok "all policy-shape mutations fail with rc 2" python3 - "$RESOLVE" "$POLICY" "$W" <<'PY'
import copy, pathlib, subprocess, sys, yaml
resolve, policy_path, workspace = sys.argv[1:]
raw = pathlib.Path(policy_path).read_text()
base = yaml.safe_load(raw)
cases = {}
cases["duplicate-role"] = raw.replace("  lead: heavyweight\n", "  lead: heavyweight\n  lead: fast\n", 1)
cases["duplicate-tier"] = raw + "\ntiers: {}\n"
cases["duplicate-alias"] = raw.replace("  opus: heavyweight\n", "  opus: heavyweight\n  opus: fast\n", 1)

def variant(name, mutate):
    data = copy.deepcopy(base); mutate(data)
    cases[name] = yaml.safe_dump(data, sort_keys=False)

variant("missing-role", lambda d: d["role_tiers"].pop("lead"))
variant("unknown-role", lambda d: d["role_tiers"].__setitem__("mystery", "fast"))
variant("dangling-role", lambda d: d["role_tiers"].__setitem__("lead", "mystery"))
variant("missing-tier", lambda d: d["tiers"].pop("fast"))
variant("unknown-tier", lambda d: d["tiers"].__setitem__("mystery", copy.deepcopy(d["tiers"]["fast"])))
variant("missing-provider", lambda d: d["tiers"]["fast"].pop("codex"))
variant("unknown-tier-field", lambda d: d["tiers"]["fast"].__setitem__("fallback", True))
variant("missing-alias", lambda d: d["legacy_aliases"].pop("opus"))
variant("unknown-alias", lambda d: d["legacy_aliases"].__setitem__("mystery", "fast"))
variant("dangling-alias", lambda d: d["legacy_aliases"].__setitem__("opus", "mystery"))
variant("empty-model", lambda d: d["tiers"]["heavyweight"]["codex"].__setitem__("model", ""))
variant("extra-provider-field", lambda d: d["tiers"]["heavyweight"]["codex"].__setitem__("fallback", "fast"))
for name, text in cases.items():
    path = pathlib.Path(workspace, name + ".yaml"); path.write_text(text)
    done = subprocess.run([resolve, "--policy", str(path), "--provider", "codex", "--role", "reviewer"], capture_output=True, text=True)
    assert done.returncode == 2, (name, done.returncode, done.stdout, done.stderr)
PY

t_case "mutation of every provider field, role mapping, and alias mapping is detected"
assert_ok "all canonical mapping mutations fail an exact expectation" python3 - "$RESOLVE" "$POLICY" "$W" <<'PY'
import copy, pathlib, subprocess, sys, yaml
resolve, policy_path, workspace = sys.argv[1:]
base = yaml.safe_load(pathlib.Path(policy_path).read_text())
cells = {
    "ceiling": {"claude": ("fable", "Fable 5", "max"), "codex": ("gpt-5.6-sol", "GPT-5.6 sol", "ultra")},
    "heavyweight": {"claude": ("opus", "Opus 5", "xhigh"), "codex": ("gpt-5.6-sol", "GPT-5.6 sol", "xhigh")},
    "workhorse": {"claude": ("sonnet", "Sonnet 5", "high"), "codex": ("gpt-5.6-terra", "GPT-5.6 terra", "high")},
    "fast": {"claude": ("haiku", "Haiku 4.5", "low"), "codex": ("gpt-5.6-terra", "GPT-5.6 terra", "low")},
}
counter = 0
def check(data, args, expected):
    global counter
    counter += 1
    path = pathlib.Path(workspace, f"mapping-{counter}.yaml")
    path.write_text(yaml.safe_dump(data, sort_keys=False))
    model, display, effort = expected
    done = subprocess.run([resolve, "--policy", str(path), *args, "--expect-model", model,
                           "--expect-display", display, "--expect-effort", effort], capture_output=True, text=True)
    assert done.returncode == 2, (counter, args, done.returncode, done.stdout, done.stderr)
for tier, providers in cells.items():
    for provider, expected in providers.items():
        for index, field in enumerate(("model", "display", "effort")):
            data = copy.deepcopy(base); data["tiers"][tier][provider][field] = "MUTATED"
            check(data, ["--provider", provider, "--tier", tier], expected)
for role, tier in base["role_tiers"].items():
    changed = next(name for name in cells if name != tier)
    data = copy.deepcopy(base); data["role_tiers"][role] = changed
    check(data, ["--provider", "codex", "--role", role], cells[tier]["codex"])
for alias, tier in base["legacy_aliases"].items():
    changed = next(name for name in cells if name != tier)
    data = copy.deepcopy(base); data["legacy_aliases"][alias] = changed
    check(data, ["--provider", "claude", "--alias", alias], cells[tier]["claude"])
assert counter == 40, counter
PY

t_case "native adapters parse to exact resolver and reviewer launch envelopes"
assert_ok "Claude frontmatter and both native launch adapters match policy" python3 - "$FIRM_ROOT" <<'PY'
import json, pathlib, re, subprocess, sys, yaml
root = pathlib.Path(sys.argv[1])
resolve = root / "bin/firm-model-resolve"
roles = ["lead", "intake-analyst", "architect", "implementer", "integrator", "reviewer",
         "recruiter", "packager", "qa-tester", "specialist", "scout"]
for role in [r for r in roles if r != "lead"]:
    text = (root / "agents" / f"{role}.md").read_text()
    front = yaml.safe_load(text.split("---", 2)[1])
    got = json.loads(subprocess.check_output([resolve, "--provider", "claude", "--role", role], text=True))
    assert front["name"] == role
    assert (front["model"], front["effort"]) == (got["model"], got["effort"]), (role, front, got)
for rel, provider in (("commands/start.md", "claude"), ("codex-skills/start/SKILL.md", "codex")):
    text = (root / rel).read_text()
    matches = re.findall(r"<!-- firm-model-adapter-v1\n(.*?)\n-->", text, re.S)
    assert len(matches) == 1, (rel, len(matches))
    adapter = yaml.safe_load(matches[0])
    assert adapter == {"provider": provider, "resolver": "firm-model-resolve", "selector": "role",
                       "apply_fields": ["model", "display", "effort"], "failure": "block", "roles": roles}, adapter
PY
assert_ok "reviewer wrappers consume resolver and apply literal heavyweight/xhigh envelopes" python3 - "$BIN/firm-reviewer-common" <<'PY'
import ast, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
source = text.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
tree = ast.parse(source)
lists = [node for node in ast.walk(tree) if isinstance(node, ast.List)]

def literal_values(node):
    return [item.value if isinstance(item, ast.Constant) and isinstance(item.value, str) else None for item in node.elts]

resolver = [literal_values(node) for node in lists if "firm-model-resolve" in ast.unparse(node)]
assert len(resolver) == 1, resolver
assert resolver[0][1:] == ["--provider", None, "--role", "reviewer", "--format", "json"], resolver[0]
codex = [node for node in lists if 'model_reasoning_effort="xhigh"' in ast.unparse(node)]
claude = [node for node in lists if any(isinstance(x, ast.Constant) and x.value == "--effort" for x in node.elts)
          and any(isinstance(x, ast.Constant) and x.value == "--permission-mode" for x in node.elts)]
assert len(codex) == 1 and len(claude) == 1
cv, av = literal_values(codex[0]), literal_values(claude[0])
assert cv[cv.index("-m") + 1] is None and cv[cv.index("-c") + 1] == 'model_reasoning_effort="xhigh"'
assert av[av.index("--model") + 1] is None and av[av.index("--effort") + 1] == "xhigh"
PY

t_summary
