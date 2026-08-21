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

t_case "native adapters consume an executable resolver-bound launch object"
assert_ok "Claude frontmatter projections match policy" python3 - "$FIRM_ROOT" <<'PY'
import json, pathlib, subprocess, sys, yaml
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
PY
assert_ok "both provider adapters reject every resolver, role-start, and apply mutation" python3 - "$FIRM_ROOT" "$W" <<'PY'
import copy, json, pathlib, re, shutil, subprocess, sys, yaml

root, workspace = map(pathlib.Path, sys.argv[1:])
sources = {"claude": "commands/start.md", "codex": "codex-skills/start/SKILL.md"}
instruction = "apply_exact_model_display_effort_immediately_before_native_launch"
native_launches = {"claude": "claude_native_agent", "codex": "codex_native_subagent"}
additive_fields = (
    "resolve_timing", "role_start_argv", "role_start_optional_argv",
    "result_required_fields", "result_optional_fields", "native_launch",
    "native_launch_fields", "retain_result_field", "failure_conditions",
)

def run(root_dir, provider, output_format):
    return subprocess.run(
        [root_dir / "bin/firm-model-resolve", "--provider", provider, "--role", "lead",
         "--format", output_format],
        capture_output=True, text=True)

def verify(root_dir, provider):
    canonical_run = run(root_dir, provider, "json")
    assert canonical_run.returncode == 0, (provider, canonical_run.stderr)
    canonical = json.loads(canonical_run.stdout)
    activation_run = run(root_dir, provider, "activation")
    assert activation_run.returncode == 0, (provider, activation_run.stderr)
    activation = json.loads(activation_run.stdout)
    assert activation == {
        "action": "native_role_launch",
        "adapter_source": sources[provider],
        "apply": {
            "display": canonical["display"],
            "effort": canonical["effort"],
            "model": canonical["model"],
        },
        "apply_instruction": instruction,
        "failure": "block",
        "policy_sha256": canonical["policy_sha256"],
        "provider": provider,
        "resolver_argv": ["firm-model-resolve", "--provider", provider, "--role", "lead",
                          "--format", "activation"],
        "schema_version": 1,
        "selected_by": "role",
        "selector": "lead",
        "tier": canonical["tier"],
    }, activation
    return activation

def copied_root(provider, mutation):
    target = workspace / f"activation-{provider}-{mutation}"
    for relative in ("bin/firm-model-resolve", "agent-firm/policy/model-tiers.yaml",
                     "commands/start.md", "codex-skills/start/SKILL.md"):
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, destination)
    return target

def load_adapter(root_dir, provider):
    text = (root_dir / sources[provider]).read_text()
    matches = re.findall(r"^```firm-native-role-adapter\n(.*?)^```$", text, re.M | re.S)
    assert len(matches) == 1, (provider, len(matches))
    return yaml.safe_load(matches[0])

def provider_neutral(adapter):
    normalized = copy.deepcopy(adapter)
    normalized["provider"] = "<provider>"
    normalized["resolver_argv"][2] = "<provider>"
    normalized["native_launch"] = "<provider-native-launch>"
    return normalized

def mutate_adapter(target, provider, mutation):
    adapter_path = target / sources[provider]
    text = adapter_path.read_text()
    match = re.search(r"^```firm-native-role-adapter\n(.*?)^```$", text, re.M | re.S)
    assert match, (provider, mutation)
    adapter = yaml.safe_load(match.group(1))
    if mutation == "resolver-removed":
        adapter.pop("resolver_argv")
    elif mutation == "resolver-contradicted":
        adapter["resolver_argv"][0] = "not-firm-model-resolve"
    elif mutation == "instruction-removed":
        adapter.pop("apply_instruction")
    elif mutation == "instruction-changed":
        adapter["apply_instruction"] = "inherit_or_guess"
    elif mutation.startswith("apply-field-"):
        adapter["apply_fields"].remove(mutation.removeprefix("apply-field-"))
    elif mutation.startswith("additive-removed-"):
        adapter.pop(mutation.removeprefix("additive-removed-"))
    elif mutation.startswith("additive-changed-"):
        field = mutation.removeprefix("additive-changed-")
        value = adapter[field]
        adapter[field] = value + ["MUTATED"] if isinstance(value, list) else "MUTATED"
    else:
        raise AssertionError(mutation)
    rendered = "```firm-native-role-adapter\n" + yaml.safe_dump(adapter, sort_keys=False) + "```"
    adapter_path.write_text(text[:match.start()] + rendered + text[match.end():])

def mutate_activation_output(target, field):
    resolver = target / "bin/firm-model-resolve"
    text = resolver.read_text()
    original = f'"{field}": result["{field}"],'
    replacement = f'"{field}": "MUTATED",'
    assert text.count(original) == 1, (field, text.count(original))
    resolver.write_text(text.replace(original, replacement, 1))

def require_rejection(provider, mutation, mutate):
    target = copied_root(provider, mutation)
    mutate(target)
    try:
        verify(target, provider)
    except (AssertionError, json.JSONDecodeError) as exc:
        print(f"MUTATION_PASS provider={provider} mutation={mutation} rejected={type(exc).__name__}")
        return
    raise AssertionError((provider, mutation, "mutation survived"))

adapters = {provider: load_adapter(root, provider) for provider in sources}
assert adapters["claude"]["native_launch"] == native_launches["claude"]
assert adapters["codex"]["native_launch"] == native_launches["codex"]
assert provider_neutral(adapters["claude"]) == provider_neutral(adapters["codex"]), adapters

for provider in sources:
    baseline = verify(root, provider)
    print(f"ACTIVATION_PASS provider={provider} adapter={baseline['adapter_source']}")
    for mutation in ("resolver-removed", "resolver-contradicted", "instruction-removed",
                     "instruction-changed", "apply-field-model", "apply-field-display",
                     "apply-field-effort"):
        require_rejection(provider, mutation,
                          lambda target, mutation=mutation: mutate_adapter(target, provider, mutation))
    for field in additive_fields:
        for kind in ("removed", "changed"):
            mutation = f"additive-{kind}-{field}"
            require_rejection(provider, mutation,
                              lambda target, mutation=mutation: mutate_adapter(target, provider, mutation))
    for field in ("model", "display", "effort"):
        require_rejection(provider, "output-" + field,
                          lambda target, field=field: mutate_activation_output(target, field))
PY
cat > "$W/reviewer-envelope-check.py" <<'PY'
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
# TWO separate claims, because they are separate and one of them was briefly lost.
#
# IDENTIFICATION — find the launch envelopes by NAMING the function that builds them. The original
# search was "the single module-level ast.List mentioning --effort and --permission-mode"; that
# stopped identifying the launch line uniquely once the wrapper also DECLARED those controls as
# required capabilities (CAPABILITY_CONTRACT, 2026-08-21), and this assertion then failed for a
# reason with nothing to do with model envelopes.
#
# UNIQUENESS — function-scoping is stronger on identification and, on its own, WEAKER on uniqueness.
# It asserts only "there is exactly one function with this name", never "there is no other
# construction". Review demonstrated the gap by adding a plausible fallback launch path outside the
# function (`if os.environ.get("FIRM_JUDGE_FALLBACK"): command = [executable, "exec", ...]`) carrying
# an undeclared control: it passed the function-scoped check and the drift check, and would have
# failed the original module-wide one. Uniqueness is therefore restored at the bottom of this block,
# on a marker the capability declaration cannot collide with — a list literal containing the
# `executable` NAME. Only the readiness probes may build one outside the judge constructors.
definitions = [node for node in ast.walk(tree)
               if isinstance(node, ast.FunctionDef) and node.name in ("judge_plan", "judge_invocation")]
assert sorted(node.name for node in definitions) == ["judge_invocation", "judge_plan"], \
    [node.name for node in definitions]
builder = [node for node in definitions if node.name == "judge_plan"][0]
assembler = [node for node in definitions if node.name == "judge_invocation"][0]
returns = [node.value for node in ast.walk(builder) if isinstance(node, ast.Return)]
assert len(returns) == 2, [ast.dump(n) for n in returns]
# The `options` lists specifically: every element is a (flag, value) tuple. Without this the outer
# segment list matches too and every count below doubles.
segment_lists = [node for node in ast.walk(builder)
                 if isinstance(node, ast.List) and node.elts
                 and all(isinstance(item, ast.Tuple) for item in node.elts)]
codex = [node for node in segment_lists if 'model_reasoning_effort="xhigh"' in ast.unparse(node)]
claude = [node for node in segment_lists
          if "'--effort'" in ast.unparse(node) and "'--permission-mode'" in ast.unparse(node)]
assert len(codex) == 1 and len(claude) == 1, (len(codex), len(claude))

def option_pairs(node):
    """{flag: literal-or-None} for each ("flag", value) tuple in a judge_plan options list."""
    pairs = {}
    for item in ast.walk(node):
        if isinstance(item, ast.Tuple) and len(item.elts) == 2 and isinstance(item.elts[0], ast.Constant):
            value = item.elts[1]
            pairs[item.elts[0].value] = value.value if isinstance(value, ast.Constant) else None
    return pairs

cv, av = option_pairs(codex[0]), option_pairs(claude[0])
assert cv["-m"] is None and cv["-c"] == 'model_reasoning_effort="xhigh"', cv
assert av["--model"] is None and av["--effort"] == "xhigh", av

# Uniqueness, module-wide. A second launch site anywhere — fallback, retry, env-gated branch —
# builds its own [executable, ...] list, and is caught here rather than shipping unprobed controls.
inside = {id(node) for scope in (builder, assembler) for node in ast.walk(scope)}
parents = {}
for node in ast.walk(tree):
    for child in ast.iter_child_nodes(node):
        parents[id(child)] = node

def enclosing(node):
    """The function a construction lives in — 'where', not just 'what'."""
    current = parents.get(id(node))
    while current is not None:
        if isinstance(current, ast.FunctionDef):
            return current.name
        current = parents.get(id(current))
    return "<module>"

# MEMBERSHIP, not position. An earlier revision of this test required elts[0] to be `executable`,
# reasoning that a provider argv begins with the executable. Review demonstrated the escape in one
# line: a second launch site written as ["/usr/bin/env", executable, "models", "list"] — or through
# any interpreter, sandbox or nice/timeout prefix — has a Constant first, is invisible to the
# positional rule, and would ship an unprobed argv. The membership rule catches it, and the mutant
# below keeps it caught. (The stated reason for narrowing was also wrong: the list it was aimed at,
# [Path(executable).name], is an ast.List and did register — it stopped existing because the BLOCK
# message was rewritten not to build a list, so the narrowing bought nothing on any source.)
executable_lists = [node for node in ast.walk(tree)
                    if isinstance(node, ast.List) and id(node) not in inside
                    and any(isinstance(x, ast.Name) and x.id == "executable" for x in ast.walk(node))]
rendered = sorted((enclosing(node), ast.unparse(node)) for node in executable_lists)
# CHANGED 2026-08-21, and STRENGTHENED while changing. This list used to name three probe argvs
# built inline: `login status --json`, `auth status --json` and `models list --json`. Two of those
# commands do not exist on any real CLI (`codex login status --json` exits 2; `codex models list`
# and `claude models list` are not subcommands at all — on claude it is a PROMPT that bills a model
# turn), so the model gate was removed outright and the authentication probe now has exactly ONE
# construction, readiness_invocation(), built from READINESS_CONTRACT. Pinning the literal argvs
# here is what let the wrapper keep three impossible commands written down and passing tests.
#
# Each entry is now (enclosing function, source), so this pins WHERE each provider argv is built as
# well as what it looks like — strictly more than the previous string-only comparison. A second
# launch site anywhere, including one that copies an existing argv verbatim, adds an entry.
assert rendered == [
    ("<module>", "[executable]"),            # capability discovery probe base: + subcommand + --help
    ("readiness_invocation", "[executable]"),  # the single readiness argv, + READINESS_CONTRACT command
], rendered   # ...and nothing else in the module builds a provider argv
PY

t_case "reviewer launch envelopes are resolver-bound, uniquely constructed, and literal"
assert_ok "reviewer wrappers consume resolver and apply literal heavyweight/xhigh envelopes" \
  python3 "$W/reviewer-envelope-check.py" "$BIN/firm-reviewer-common"
# Prove the restored module-wide uniqueness assertion BITES. Review defeated the function-scoped
# version with exactly this mutant: a second, env-gated launch site outside the judge constructors
# carrying an undeclared control. It passed the function-scoped check AND the drift check. It must
# not pass now — a launch line built anywhere else is a launch line no capability probe has seen.
cp "$BIN/firm-reviewer-common" "$W/mutant-second-launch-site"
python3 - "$W/mutant-second-launch-site" <<'MUT'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
anchor = '    attempt["launch"] = {'
assert text.count(anchor) == 1, "mutation anchor is not unique; update this test"
fallback = (
    '    if os.environ.get("FIRM_JUDGE_FALLBACK"):\n'
    '        command = [executable, "exec", "--ephemeral", "--search", "-m", model, prompt]\n'
)
open(path, "w", encoding="utf-8").write(text.replace(anchor, fallback + anchor))
MUT
chmod +x "$W/mutant-second-launch-site"
assert_fail "a second launch site outside the judge constructors is caught" \
  python3 "$W/reviewer-envelope-check.py" "$W/mutant-second-launch-site"

t_case "it bites: a second launch site hidden behind a prefix argument"
# Review's defeat of the positional predicate. `env` (or any wrapper binary) in front of the
# executable makes the argv invisible to a first-element rule while still launching a provider with
# controls no capability probe has seen.
cp "$BIN/firm-reviewer-common" "$W/mutant-prefixed-launch-site"
python3 - "$W/mutant-prefixed-launch-site" <<'MUT'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
anchor = '    attempt["launch"] = {'
assert text.count(anchor) == 1, "mutation anchor is not unique; update this test"
prefixed = (
    '    if os.environ.get("FIRM_JUDGE_PREFIX"):\n'
    '        command = ["/usr/bin/env", executable, "models", "list"]\n'
)
open(path, "w", encoding="utf-8").write(text.replace(anchor, prefixed + anchor))
MUT
assert_fail "a launch site behind a prefix argument is caught" \
  python3 "$W/reviewer-envelope-check.py" "$W/mutant-prefixed-launch-site"

t_summary
