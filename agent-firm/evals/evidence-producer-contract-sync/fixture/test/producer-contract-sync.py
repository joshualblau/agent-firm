#!/usr/bin/env python3
"""Golden check: the documented `evidence_produced` producer contract still matches the writer.

Three independent properties, each of which fails LOUDLY and by name:

  P1 (AC-019)  The field set documented in agent-firm/contracts/evidence-producer-contract.md is
               identical to bin/firm-ledger-log's live EVIDENCE_CURRENT_FIELDS, and the producer
               role surface that delegates to that document still actually links to it and still
               states the non-strict silent-failure semantics.

  P2 (AC-017)  The writer's accept/refuse decision for a table of evidence shapes is exactly the
               table below. This item is documentation-only, so every row here is expected to hold
               unchanged; the row's purpose is to catch an accidental code change, not to re-derive
               the classifier.

  P3 (AC-018)  A run that published evidence under the PREVIOUS (undocumented-contract) rules is
               still readable through the current classifier and still appendable, with the existing
               bytes untouched -- no rewrite, no migration.

WHY THE CONSTANT IS PARSED AND NOT COPIED
bin/firm-ledger-log is a bash wrapper around an embedded python program, so it cannot be imported.
The constant is therefore read STATICALLY out of the writer's own source and evaluated, exactly the
way bin/firm-merge-guard reads SHELL_OBSERVATION_FIELDS. A second hand-maintained copy of the field
list inside this eval would drift silently, which is the very failure this eval exists to detect.

WHAT P2 IS AND IS NOT
A single checkout cannot literally diff "before" against "after". The accept/refuse expectations
below ARE the before-state, written down. If a change to the writer alters any of them, this fails
and names the row. That is the strongest form of the assertion available from one working tree, and
it is stated here rather than implied so nobody reads more into a green run than it earns.

Exit 0 = all three properties hold. Exit 1 = a property failed (reason printed). Exit 2 = the check
could not be evaluated at all (fail closed -- never reported as a pass).
"""

import ast
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

DOC_RELATIVE = "agent-firm/contracts/evidence-producer-contract.md"
ROLE_RELATIVE = "agent-firm/contracts/roles/qa-tester.md"
WRITER_RELATIVE = "bin/firm-ledger-log"

failures = []


def fail(message):
    failures.append(message)
    print("FAIL: " + message)


def ok(message):
    print("ok  : " + message)


def cannot(message):
    print("CANNOT EVALUATE: " + message, file=sys.stderr)
    raise SystemExit(2)


# --------------------------------------------------------------------------------------------
# Locate the firm under test.
# --------------------------------------------------------------------------------------------
def firm_root():
    override = os.environ.get("FIRM_CONTRACT_SYNC_ROOT")
    candidates = []
    if override:
        candidates.append(override)
    tool = shutil.which("firm-ledger-log")
    if tool:
        candidates.append(os.path.dirname(os.path.dirname(os.path.realpath(tool))))
    for candidate in candidates:
        if os.path.isfile(os.path.join(candidate, WRITER_RELATIVE)):
            return candidate
    cannot(
        "could not locate the firm checkout under test. Put bin/ on PATH (so `firm-ledger-log` "
        "resolves) or set FIRM_CONTRACT_SYNC_ROOT to the checkout root. Refusing to guess."
    )


ROOT = firm_root()
WRITER = os.path.join(ROOT, WRITER_RELATIVE)
DOC = os.path.join(ROOT, DOC_RELATIVE)
ROLE = os.path.join(ROOT, ROLE_RELATIVE)
LEDGER_LOG = WRITER
NEW_RUN = os.path.join(ROOT, "bin", "firm-new-run")
MODEL_RESOLVE = os.path.join(ROOT, "bin", "firm-model-resolve")
print("firm root under test: " + ROOT)


# --------------------------------------------------------------------------------------------
# P1 -- documented field set vs. the writer's live constant.
# --------------------------------------------------------------------------------------------
def writer_constant(source, name, bound):
    """Evaluate a module-level set constant out of the writer's source. Fails closed."""
    match = re.search(r"^%s = " % re.escape(name), source, re.M)
    if match is None:
        cannot("%s no longer declares %s at module level" % (WRITER_RELATIVE, name))
    index = match.end()
    depth = 0
    end = None
    while index < len(source):
        char = source[index]
        if char in "{([":
            depth += 1
        elif char in "})]":
            depth -= 1
        elif char == "\n" and depth == 0:
            end = index
            break
        index += 1
    if end is None:
        cannot("could not delimit %s in %s" % (name, WRITER_RELATIVE))
    expression = source[match.end():end]

    def evaluate(node):
        if isinstance(node, ast.Set):
            return {ast.literal_eval(element) for element in node.elts}
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
            return evaluate(node.left) | evaluate(node.right)
        if isinstance(node, ast.Name):
            if node.id not in bound:
                cannot("%s references unknown constant %s" % (name, node.id))
            return set(bound[node.id])
        cannot(
            "%s is no longer a set literal / union of set literals in %s; this checker will not "
            "guess at its value" % (name, WRITER_RELATIVE)
        )

    try:
        tree = ast.parse(expression.strip(), mode="eval")
    except SyntaxError as exc:
        cannot("could not parse %s out of %s: %s" % (name, WRITER_RELATIVE, exc))
    value = evaluate(tree.body)
    if not isinstance(value, set) or not value:
        cannot("%s evaluated to something that is not a non-empty set" % name)
    return value


def documented_fields(text):
    """Field names in the first column of the tables between the doc's own markers."""
    begin = text.find("<!-- EVIDENCE_FIELDS:BEGIN")
    end = text.find("<!-- EVIDENCE_FIELDS:END", begin + 1) if begin >= 0 else -1
    if begin < 0 or end < 0 or end < begin:
        cannot(
            "%s no longer carries the EVIDENCE_FIELDS:BEGIN/END markers this eval reads. Restore "
            "them (see the comment at the marker) rather than deleting this assertion."
            % DOC_RELATIVE
        )
    block = text[begin:end]
    return set(re.findall(r"^\|\s*`([A-Za-z_][A-Za-z0-9_]*)`\s*\|", block, re.M))


try:
    writer_source = open(WRITER, encoding="utf-8").read()
    doc_text = open(DOC, encoding="utf-8").read()
    role_text = open(ROLE, encoding="utf-8").read()
except OSError as exc:
    cannot(
        "could not read a required surface under %s: %s. If that is not the checkout you meant to "
        "test (PATH's firm-ledger-log may resolve to a different one), set "
        "FIRM_CONTRACT_SYNC_ROOT to the checkout root." % (ROOT, exc)
    )

common = writer_constant(writer_source, "COMMON_FIELDS", {})
live = writer_constant(
    writer_source, "EVIDENCE_CURRENT_FIELDS", {"COMMON_FIELDS": common}
)
documented = documented_fields(doc_text)

missing = sorted(live - documented)
extra = sorted(documented - live)
if missing or extra:
    detail = []
    if missing:
        detail.append(
            "the writer requires but %s does not document: %s" % (DOC_RELATIVE, ", ".join(missing))
        )
    if extra:
        detail.append(
            "%s documents but the writer does not require: %s" % (DOC_RELATIVE, ", ".join(extra))
        )
    fail("P1 evidence_produced field set has drifted -- " + "; ".join(detail))
else:
    ok("P1 documented field set == EVIDENCE_CURRENT_FIELDS (%s)" % ", ".join(sorted(live)))

if DOC_RELATIVE not in role_text:
    fail(
        "P1 %s no longer links to %s, so the producer role surface names no field set at all "
        "(AC-013)" % (ROLE_RELATIVE, DOC_RELATIVE)
    )
else:
    ok("P1 %s still delegates to %s" % (ROLE_RELATIVE, DOC_RELATIVE))

role_flat = " ".join(role_text.split())
if "exits 0" not in role_flat or "no ledger row" not in role_flat:
    fail(
        "P1 %s no longer states the non-strict silent-failure semantics in its own words "
        "(AC-016 requires the phrase, not just a link): expected it to say a non-strict "
        "publication 'exits 0' and writes 'no ledger row'" % ROLE_RELATIVE
    )
else:
    ok("P1 %s still states the non-strict exit-0/no-row semantics" % ROLE_RELATIVE)


# --------------------------------------------------------------------------------------------
# Shared fixture machinery for P2 and P3.
# --------------------------------------------------------------------------------------------
WORK = tempfile.mkdtemp(prefix="producer-contract-sync.")


def run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def git(repo, *args):
    return run(["git", "-C", repo] + list(args))


def make_repo():
    repo = tempfile.mkdtemp(prefix="repo.", dir=WORK)
    git(repo, "init", "-q", "-b", "main")
    with open(os.path.join(repo, "seed.txt"), "w") as handle:
        handle.write("seed\n")
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=eval@firm", "-c", "user.name=eval", "commit", "-qm", "seed")
    return repo, git(repo, "rev-parse", "main").stdout.strip()


def make_current_run(repo, sha, slug):
    result = run([NEW_RUN, "--primary", "codex", "--base", sha, slug, "full_track"], cwd=repo)
    if result.returncode != 0:
        cannot("firm-new-run failed: %s%s" % (result.stdout, result.stderr))
    run_dir = os.path.join(repo, result.stdout.strip().splitlines()[-1])
    os.makedirs(os.path.join(run_dir, "09-test-evidence"), exist_ok=True)
    os.makedirs(os.path.join(run_dir, "role-contracts"), exist_ok=True)
    common_dir = git(repo, "rev-parse", "--git-common-dir").stdout.strip()
    if not os.path.isabs(common_dir):
        common_dir = os.path.join(repo, common_dir)
    candidate = {
        "schema_version": 2, "run_id": os.path.basename(run_dir), "repository_root": repo,
        "git_common_dir": common_dir, "checkout_path": repo, "source_ref": "refs/heads/main",
        "source_ref_sha": sha, "base_sha": sha, "candidate_sha": sha, "generation": 1,
    }
    candidate_path = os.path.join(run_dir, "09-test-evidence", "qa-candidate.json")
    with open(candidate_path, "w") as handle:
        handle.write(json.dumps(candidate, sort_keys=True) + "\n")
    os.chmod(candidate_path, 0o600)
    contract_path = os.path.join(run_dir, "role-contracts", "Q-01-qa-tester.md")
    with open(contract_path, "w") as handle:
        handle.write("# sync eval qa contract\n")
    os.chmod(contract_path, 0o644)
    return run_dir


def open_role_window(run_dir, repo, sha):
    with open(os.path.join(run_dir, "run.jsonl"), encoding="utf-8") as handle:
        first = json.loads(handle.readline())
    run_id = os.path.basename(run_dir)
    authority = json.dumps([{
        "source_run": ".agent-firm/runs/" + run_id,
        "event_id": first["event_id"],
        "expect": {"event": "run_started", "run_id": run_id, "fields": {"base_sha": sha}},
    }], separators=(",", ":"))
    activation = run(
        [MODEL_RESOLVE, "--provider", "codex", "--role", "qa-tester", "--format", "activation"]
    )
    if activation.returncode != 0:
        cannot("firm-model-resolve failed: %s" % activation.stderr)
    started = run([
        LEDGER_LOG, "--run", run_dir, "--strict", "--role-start", "--stage", "qa/Q-01",
        "--role", "qa-tester", "--contract", "role-contracts/Q-01-qa-tester.md",
        "--event", "qa_started", "--authority-json", authority,
        "--agent", "/root/producer_contract_sync", "--activation-json", activation.stdout.strip(),
    ])
    if started.returncode != 0:
        cannot("could not open a role window: %s%s" % (started.stdout, started.stderr))
    return json.loads(started.stdout)["event_id"]


def write_artifact(run_dir, relative, payload):
    path = os.path.join(run_dir, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(payload)
    os.chmod(path, 0o644)
    return {"sha256": hashlib.sha256(payload).hexdigest(), "bytes": str(len(payload))}


def publish(run_dir, fields):
    return run(
        [LEDGER_LOG, "--run", run_dir, "--strict", "evidence_produced"]
        + ["%s=%s" % (key, value) for key, value in fields.items()]
    )


def ledger_bytes(run_dir):
    with open(os.path.join(run_dir, "run.jsonl"), "rb") as handle:
        return handle.read()


try:
    repo, base_sha = make_repo()
    current_run = make_current_run(repo, base_sha, "producer-sync")
    role_start = open_role_window(current_run, repo, base_sha)

    # ----------------------------------------------------------------------------------------
    # P2 -- accept/refuse table. Each row is (label, expected_accepted, mutate).
    # ----------------------------------------------------------------------------------------
    def base_fields(relative, identity):
        return {
            "sha": base_sha, "generation": "1", "path": relative,
            "sha256": identity["sha256"], "bytes": identity["bytes"],
            "stage": "qa/Q-01", "role": "qa-tester", "role_start_event_id": role_start,
        }

    def shape_exact(fields):
        return fields

    def shape_drop_role_start(fields):
        fields.pop("role_start_event_id")
        return fields

    def shape_drop_stage_role_and_start(fields):
        for key in ("stage", "role", "role_start_event_id"):
            fields.pop(key)
        return fields

    def shape_extra_field(fields):
        fields["provider"] = "codex"
        return fields

    def shape_stale_candidate(fields):
        fields["sha"] = "0" * 40
        return fields

    def shape_zero_generation(fields):
        fields["generation"] = "0"
        return fields

    table = [
        ("current 12-key shape", True, shape_exact),
        ("current shape minus role_start_event_id (11 keys)", False, shape_drop_role_start),
        ("legacy 9-key shape on a current run", False, shape_drop_stage_role_and_start),
        ("current shape plus one extension field (13 keys)", False, shape_extra_field),
        ("current shape with a stale candidate sha", False, shape_stale_candidate),
        ("current shape with generation 0", False, shape_zero_generation),
    ]

    for index, (label, expected_accepted, mutate) in enumerate(table):
        relative = "09-test-evidence/shape-%02d.json" % index
        identity = write_artifact(
            current_run, relative, json.dumps({"case": index}).encode("utf-8") + b"\n"
        )
        result = publish(current_run, mutate(base_fields(relative, identity)))
        accepted = result.returncode == 0
        if accepted != expected_accepted:
            fail(
                "P2 accept/refuse changed for %r: expected %s, got exit %d (%s). "
                "bin/firm-ledger-log's accepted shapes are supposed to be unchanged by this item."
                % (label, "ACCEPT" if expected_accepted else "REFUSE", result.returncode,
                   (result.stderr or result.stdout or "").strip() or "no output")
            )
        else:
            ok("P2 %r -> %s" % (label, "accepted" if accepted else "refused"))

    # The duplicate rule is a property of an ALREADY-published row, so it is asserted after the
    # accepted row above actually landed.
    duplicate_relative = "09-test-evidence/shape-00.json"
    duplicate_identity = {
        "sha256": hashlib.sha256(
            open(os.path.join(current_run, duplicate_relative), "rb").read()
        ).hexdigest(),
        "bytes": str(os.path.getsize(os.path.join(current_run, duplicate_relative))),
    }
    duplicate = publish(current_run, base_fields(duplicate_relative, duplicate_identity))
    if duplicate.returncode == 0:
        fail(
            "P2 a duplicate path+sha+generation publication was ACCEPTED; the writer is supposed "
            "to refuse it, and the producer contract documents that refusal as a retry hazard"
        )
    else:
        ok("P2 'duplicate path+sha+generation' -> refused")

    # ----------------------------------------------------------------------------------------
    # P3 -- a run published under the PREVIOUS rules stays readable and appendable.
    # ----------------------------------------------------------------------------------------
    legacy_run = make_current_run(repo, base_sha, "producer-sync-legacy")
    legacy_id = os.path.basename(legacy_run)
    legacy_payload = b"legacy evidence artifact\n"
    legacy_relative = "legacy-artifact.txt"
    legacy_identity = write_artifact(legacy_run, legacy_relative, legacy_payload)
    with open(os.path.join(legacy_run, "run.jsonl"), encoding="utf-8") as handle:
        legacy_first = json.loads(handle.readline())
    legacy_first.pop("evidence_seal_protocol", None)
    legacy_rows = [
        json.dumps(legacy_first, separators=(",", ":")),
        json.dumps({
            "ts": "2024-01-01T00:00:01Z", "event": "evidence_produced",
            "event_id": "evt-legacy-evidence", "run_id": legacy_id,
            "sha": "a" * 40, "generation": "1", "path": legacy_relative,
            "sha256": legacy_identity["sha256"], "bytes": legacy_identity["bytes"],
        }, separators=(",", ":")),
    ]
    legacy_ledger = os.path.join(legacy_run, "run.jsonl")
    with open(legacy_ledger, "w", encoding="utf-8") as handle:
        handle.write("\n".join(legacy_rows) + "\n")
    os.chmod(legacy_ledger, 0o600)

    before = ledger_bytes(legacy_run)
    classify = run([LEDGER_LOG, "--classify-ledger-file", legacy_id, legacy_ledger])
    if classify.returncode != 0:
        fail(
            "P3 a historical ledger published under the previous rules is no longer READABLE "
            "through the current classifier (exit %d: %s). AC-018 requires it to stay readable "
            "with no rewrite." % (classify.returncode, (classify.stderr or "").strip())
        )
    else:
        ok("P3 historical (genuine-legacy) ledger still classifies: " + classify.stdout.strip())

    appended = run([LEDGER_LOG, "--run", legacy_run, "--strict", "note", "source=sync_eval"])
    after = ledger_bytes(legacy_run)
    if appended.returncode != 0:
        fail(
            "P3 a historical ledger published under the previous rules is no longer APPENDABLE "
            "(exit %d: %s). AC-018 requires it to stay appendable with no rewrite."
            % (appended.returncode, (appended.stderr or "").strip())
        )
    elif not after.startswith(before):
        fail(
            "P3 appending to a historical ledger REWROTE its existing bytes; AC-018 requires no "
            "historical ledger to need rewriting"
        )
    elif b'"source":"sync_eval"' not in after and b'"source": "sync_eval"' not in after:
        fail("P3 the append to the historical ledger reported success but wrote no row")
    else:
        ok("P3 historical ledger appended to, existing bytes preserved byte-for-byte")
finally:
    shutil.rmtree(WORK, ignore_errors=True)

print()
if failures:
    print("%d propert%s FAILED" % (len(failures), "y" if len(failures) == 1 else "ies"))
    raise SystemExit(1)
print("all three properties hold (P1 field-set sync, P2 accept/refuse table, P3 legacy readability)")
