"""AC-007 mutation-matrix driver: EXECUTE every family, then publish its immutable evidence.

Driven by tests/test-evidence-seal.sh. Nothing here is a description of a mutation: every family
below runs the real production code path (create_seal / verify_seal / the canonical ledger
classifier) against a real run fixture and records the category it ACTUALLY raised. A family whose
observed category differs from the expected one fails this script -- an expectation table that
quietly absorbs whatever happened would be the "enum mutation" non-proof AC-010 rules out.

Around every attempt it captures the four AC-011 dimensions -- exact fail-closed category, no seal
and no NEWLY created (reusable) generation, byte-identical tested ledger prefix, and unchanged
provider-call count -- and writes them into one canonical, immutable per-family document. Note the
partial-generation dimension is measured as "did this attempt CREATE a generation directory", not
"does one exist": ac007_partial_no_fallback deliberately plants a partial generation first, and the
property being proven is that the refusal did not make that partial reusable or add another.

Local fixtures only: no provider is launched, no credential is read, and no network is touched.
Usage: ac007-mutation-matrix.py ROOT MATRIX_RUN PRE_RUN PUBLISHED_RUN CODEX_RUN LEGACY_RUN
                                STAGE ROLE ROLE_START_EVENT_ID
"""
import copy, hashlib, json, os, pathlib, shutil, subprocess, sys

root = pathlib.Path(sys.argv[1])
matrix_run = pathlib.Path(sys.argv[2])
pre_run = pathlib.Path(sys.argv[3])
published_run = pathlib.Path(sys.argv[4])
codex_run = pathlib.Path(sys.argv[5])
legacy_run = pathlib.Path(sys.argv[6])
stage, role, role_start_event_id = sys.argv[7:10]
sys.path.insert(0, str(root / "agent-firm" / "lib"))
import evidence_seal as e

POLICY = str(root / "agent-firm" / "policy" / "evidence-privacy.yaml")
LEDGER_LOG = str(root / "bin" / "firm-ledger-log")
EXPECTED = {
    "ac007_opted_in_no_fallback": "ARTIFACT_MISSING",
    "ac007_partial_no_fallback": "MULTIPLE_SEALS",
    "ac007_both_provider_sealed": "SEAL_IDENTITY",
    "ac007_privacy_category_misuse": "PRIVACY_MATCH",
    "ac007_privacy_surface_misuse": "PRIVACY_MATCH",
    "ac007_placeholder_argv": "COMMAND_EVIDENCE",
    "ac007_unexpected_ledger_append": "LEDGER_SUFFIX",
    "ac007_producer_window_defect": "PRODUCER_WINDOW",
    "ac007_integration_index_duplicate": "DUPLICATE_DECLARATION",
    "ac007_integration_index_malformed": "INTEGRATION_INDEX",
    "ac007_pr_marker_malformed": "PR_MARKERS",
    "ac007_seal_tamper": "NONCANONICAL_JSON",
    "ac007_evidence_tamper": "ARTIFACT_STALE",
    "ac007_synchronized_toctou": "ARTIFACT_MOVED",
    "ac007_genuine_legacy_reviewable": "NONE",
}


def prefix(run):
    raw = (run / "run.jsonl").read_bytes()
    return {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def provider_calls(run):
    total = 0
    for line in (run / "run.jsonl").read_text().splitlines():
        if line.strip() and json.loads(line).get("event") == "reviewer_attempt_started":
            total += 1
    return total


def generations(run):
    root_dir = run / "09-test-evidence" / "final-evidence"
    return {item.name for item in root_dir.iterdir()} if root_dir.is_dir() else set()


def observe(run, action):
    """Run one mutation attempt and capture every AC-011 dimension around it."""
    before_prefix, before_calls, before_gens = prefix(run), provider_calls(run), generations(run)
    try:
        action()
        category = "NONE"
    except e.SealError as exc:
        category = exc.category
    after_gens = generations(run)
    fresh = after_gens - before_gens
    return {
        "observed_category": category,
        "seal_published": any((run / "09-test-evidence" / "final-evidence" / name / "seal.json").exists()
                              for name in fresh),
        "partial_generation_present": bool(fresh),
        "ledger_prefix_before": before_prefix,
        "ledger_prefix_after": prefix(run),
        "provider_calls_before": before_calls,
        "provider_calls_after": provider_calls(run),
    }


def restore(path, raw, mode=0o644):
    with open(path, "wb") as handle:
        handle.write(raw)
    os.chmod(path, mode)


def create(run):
    e.create_seal(str(run), POLICY, ["firm-seal-qa-evidence", "--run", str(run)], str(run.parents[2]))


def verify(run, phase="publication"):
    e.verify_seal(str(run), POLICY, phase)


families = {}
cases = {}


def record(family, orientation, result, sub_cases, legacy_success=False):
    families[family] = dict(result)
    families[family]["orientation"] = orientation
    families[family]["legacy_success"] = legacy_success
    cases[family] = sub_cases
    if os.environ.get("FIRM_MATRIX_TRACE"):
        print(f"  {family}: observed={result['observed_category']} "
              f"expected={EXPECTED.get(family)}", file=sys.stderr)


# --------------------------------------------------------------------------------------------
# pre_run families: every one of these must fail BEFORE any publication.
# --------------------------------------------------------------------------------------------
handoff = pre_run / "10-handoff.md"
handoff_raw = handoff.read_bytes()
verdict = pre_run / "08-qa-verdict.json"
verdict_raw = verdict.read_bytes()
summary = pre_run / "06-implementation-summary.md"
summary_body = summary.read_bytes()
ledger = pre_run / "run.jsonl"
ledger_raw = ledger.read_bytes()


def republish(run, relative, raw):
    """Re-point the ONE existing producer row at the artifact's new bytes.

    A fixture that mutates an artifact whose publication the run already recorded is otherwise
    rejected as PRODUCER_STALE before the mutation under test is ever reached -- correct behaviour,
    but it would mask the family. Rewriting the single row keeps exactly one producer publication
    for the path (no duplicate, no second window) so the family's own defect is what fails.
    """
    path = run / "run.jsonl"
    rows = [json.loads(line) for line in path.read_bytes().decode().splitlines() if line.strip()]
    hit = 0
    for row in rows:
        if row.get("event") == "evidence_produced" and row.get("path") == relative:
            row["sha256"] = hashlib.sha256(raw).hexdigest()
            row["bytes"] = str(len(raw))
            hit += 1
    assert hit == 1, (relative, hit)
    restore(path, "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows).encode(), 0o600)

# 1. privacy category misuse
policy_doc = e.parse_json_unique(pathlib.Path(POLICY).read_bytes())
patterns = e._privacy_patterns(policy_doc)
category_cases = []
samples = {
    "private_key": b"-----BEGIN PRIVATE KEY-----",
    "secret_assignment": b"pass" + b"word=supersecret",
    "connection_uri": b"postgre" + b"sql://dbuser:dbpass@database.example/app",
    "numeric_endpoint": b"https://10." + b"20.30.40:443",
    "jwt": b"eyJabcdefgh.ijklmnopq.rstuvwxyz",
}
for name, sample in samples.items():
    try:
        e._scan(sample, "06-implementation-summary.md", patterns)
    except e.SealError as exc:
        assert exc.category == "PRIVACY_MATCH", (name, exc.category)
        category_cases.append(name)
    else:
        raise AssertionError(("privacy category accepted", name))
restore(summary, summary_body + b"\n" + samples["secret_assignment"] + b"\n")
result = observe(pre_run, lambda: create(pre_run))
restore(summary, summary_body)
record("ac007_privacy_category_misuse", "claude", result,
       ["end_to_end_secret_assignment_in_summary"] + sorted(category_cases))

# 2. privacy surface misuse
users = "/" + "Users"
operator_repo = users + "/operator/fixture-repository"
bindings = {
    ("run-metadata.json", "repository_root"): operator_repo,
    ("run-metadata.json", "git_common_dir"): operator_repo + "/.git",
    ("09-test-evidence/qa-candidate.json", "repository_root"): operator_repo,
    ("09-test-evidence/qa-candidate.json", "git_common_dir"): operator_repo + "/.git",
    ("09-test-evidence/qa-candidate.json", "checkout_path"): operator_repo + "/.agent-firm/qa-checkout/x",
}
field_json = lambda field, value: json.dumps({field: value}, ensure_ascii=True, separators=(",", ":")).encode()
surface_cases = []
surface_negatives = [
    ("allowed_field_wrong_artifact", field_json("repository_root", operator_repo), "run-baseline.json"),
    ("allowed_value_wrong_field", field_json("unrelated", operator_repo), "run-metadata.json"),
    ("declared_field_wrong_surface", operator_repo.encode(), "10-handoff.md"),
    ("command_output_surface", operator_repo.encode(), "09-test-evidence/command.stdout"),
    ("provider_visible_surface", operator_repo.encode(),
     "09-test-evidence/reviewer-attempts/gpt-a1/controlled-input.json"),
    ("nested_not_top_level",
     json.dumps({"identity": {"repository_root": operator_repo}}, separators=(",", ":")).encode(),
     "run-metadata.json"),
    ("escaped_solidus", field_json("repository_root", operator_repo).replace(b"/", b"\\/", 1),
     "run-metadata.json"),
    ("duplicate_field",
     b'{"repository_root":"' + operator_repo.encode() + b'","repository_root":"'
     + operator_repo.encode() + b'"}', "run-metadata.json"),
]
for name, payload, path in surface_negatives:
    try:
        e._scan(payload, path, patterns, bindings)
    except e.SealError as exc:
        assert exc.category == "PRIVACY_MATCH", (name, exc.category)
        surface_cases.append(name)
    else:
        raise AssertionError(("privacy surface accepted", name))
restore(summary, summary_body + b"\n" + operator_repo.encode() + b"\n")
result = observe(pre_run, lambda: create(pre_run))
restore(summary, summary_body)
record("ac007_privacy_surface_misuse", "claude", result,
       ["end_to_end_operator_home_on_summary_surface"] + sorted(surface_cases))

# 3. placeholder argv
command_rel = "09-test-evidence/mutation-command.json"
command_path = pre_run / command_rel
command_doc = {
    "schema_version": 1, "argv": ["firm-final-qa-check", "<run-directory>"],
    "cwd": os.path.realpath(str(pre_run.parents[2])),
    "started_at": "2026-09-01T00:00:00.000Z", "finished_at": "2026-09-01T00:00:01.000Z",
    "duration_ms": 1000, "exit_code": 0, "result": "pass", "inputs": [], "outputs": [],
    "stdout": {"kind": "not_applicable", "reason": "stream_not_emitted"},
    "stderr": {"kind": "not_applicable", "reason": "stream_not_emitted"},
}
restore(command_path, (json.dumps(command_doc, sort_keys=True, indent=2) + "\n").encode(), 0o600)
poisoned_verdict = json.loads(verdict_raw)
poisoned_verdict["commands_run"] = [{"artifact": command_rel}]
poisoned_raw = (json.dumps(poisoned_verdict, sort_keys=True, indent=2) + "\n").encode()
restore(verdict, poisoned_raw)
republish(pre_run, "08-qa-verdict.json", poisoned_raw)
result = observe(pre_run, lambda: create(pre_run))
restore(verdict, verdict_raw)
republish(pre_run, "08-qa-verdict.json", verdict_raw)
command_path.unlink()
record("ac007_placeholder_argv", "claude", result, ["angle_bracket_placeholder_in_command_argv"])

# 4. producer window defect
rows = [json.loads(line) for line in ledger_raw.decode().splitlines() if line.strip()]
unclosed = [row for row in rows if row.get("event") != "qa_completed"]
restore(ledger, "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in unclosed).encode(), 0o600)
result = observe(pre_run, lambda: create(pre_run))
restore(ledger, ledger_raw, 0o600)
record("ac007_producer_window_defect", "claude", result, ["role_window_never_completed"])

# 5/6. integration history index
summaries = pre_run / "integration-summaries"
summaries.mkdir(exist_ok=True)
summary_raw = b"# integration\n"
restore(summaries / "I-01.md", summary_raw)
index_path = summaries / "index.json"
entry = {"stage": "integrate/I-01", "path": "integration-summaries/I-01.md",
         "bytes": len(summary_raw), "sha256": hashlib.sha256(summary_raw).hexdigest()}
duplicate_index = {"schema_version": 1, "run_id": pre_run.name, "current_stage": "integrate/I-01",
                   "entries": [entry, copy.deepcopy(entry)]}
restore(index_path, (json.dumps(duplicate_index, indent=2, sort_keys=True) + "\n").encode())
result = observe(pre_run, lambda: create(pre_run))
index_cases = ["end_to_end_repeated_stage_and_path_entry"]
stage_duplicate = {"schema_version": 1, "run_id": pre_run.name, "current_stage": "integrate/I-01",
                   "entries": [entry, {**copy.deepcopy(entry), "path": "integration-summaries/I-02.md"}]}
stage_raw = (json.dumps(stage_duplicate, indent=2, sort_keys=True) + "\n").encode()
try:
    e._integration_index_references(pre_run, "integration-summaries/index.json", stage_raw, stage_duplicate)
except e.SealError as exc:
    assert exc.category == "INTEGRATION_INDEX", exc.category
    index_cases.append("repeated_stage_with_mismatched_path")
else:
    raise AssertionError("duplicate integration stage accepted")
record("ac007_integration_index_duplicate", "claude", result, index_cases)

malformed_index = {"schema_version": 1, "run_id": pre_run.name, "current_stage": "integrate/I-01",
                   "entries": [entry], "extra": "unknown"}
restore(index_path, (json.dumps(malformed_index, indent=2, sort_keys=True) + "\n").encode())
result = observe(pre_run, lambda: create(pre_run))
shutil.rmtree(summaries)
record("ac007_integration_index_malformed", "claude", result, ["unknown_top_level_field"])

# 7. the complete malformed complete-PR marker family
begin = e.BEGIN_PR
end = e.END_PR
marker_cases = []
body = b"# 10 \xc2\xb7 Handoff\n"
marker_negatives = [
    ("missing_begin", body + end),
    ("missing_end", body + begin + b"x\n"),
    ("duplicate_begin", body + begin + begin + b"x\n" + end),
    ("duplicate_end", body + begin + b"x\n" + end + end),
    ("reversed_order", body + end + begin),
    ("nested_marker", body + begin + begin.rstrip(b"\n") + b" nested\n" + end),
    ("crlf_line_endings", body + begin.replace(b"\n", b"\r\n") + b"x\r\n" + end.replace(b"\n", b"\r\n")),
    ("invalid_utf8", body + begin + b"\xff\xfe\n" + end),
    ("marker_not_line_terminated", body + begin.rstrip(b"\n") + b" trailing\n" + end),
]
for name, payload in marker_negatives:
    try:
        e.extract_pr_body(payload)
    except e.SealError as exc:
        assert exc.category == "PR_MARKERS", (name, exc.category)
        marker_cases.append(name)
    else:
        raise AssertionError(("pr marker negative accepted", name))
restore(handoff, handoff_raw + begin)
result = observe(pre_run, lambda: create(pre_run))
restore(handoff, handoff_raw)
record("ac007_pr_marker_malformed", "claude", result,
       ["end_to_end_duplicate_begin_marker"] + sorted(marker_cases))

# 8. synchronized TOCTOU through the actual no-follow read
race_dir = pre_run / "09-test-evidence"
race_rel = "09-test-evidence/mutation-race.txt"
race_path = pre_run / race_rel
restore(race_path, b"old", 0o600)
original_lstat = e.os.lstat
counter = {"n": 0}


def raced(path, *rest, **kwargs):
    counter["n"] += 1
    try:
        same = os.path.samestat(original_lstat(path), original_lstat(race_path))
    except (OSError, TypeError):
        same = False
    if same and counter["n"] >= 3:
        with open(race_path, "wb") as handle:
            handle.write(b"new")
        os.chmod(race_path, 0o600)
    return original_lstat(path, *rest, **kwargs)


def toctou():
    e.os.lstat = raced
    try:
        e._safe_read(pre_run, race_rel)
    finally:
        e.os.lstat = original_lstat


result = observe(pre_run, toctou)
race_path.unlink()
record("ac007_synchronized_toctou", "claude", result,
       ["deterministic_final_lstat_substitution"])

# 9. partial generation is never reusable
partial = pre_run / "09-test-evidence" / "final-evidence" / "g1"
partial.mkdir(parents=True)
result = observe(pre_run, lambda: create(pre_run))
shutil.rmtree(pre_run / "09-test-evidence" / "final-evidence")
record("ac007_partial_no_fallback", "claude", result, ["preexisting_partial_generation_directory"])

# 10. an opted-in/current run never falls back to legacy reviewability
state = e.seal_state(pre_run)
assert state["required"] and not state["legacy"], state
result = observe(pre_run, lambda: verify(pre_run))
record("ac007_opted_in_no_fallback", "claude", result,
       ["current_marked_run_without_seal", "seal_state_required_not_legacy"])

# --------------------------------------------------------------------------------------------
# published_run families: a real published seal, then post-publication tampering.
# --------------------------------------------------------------------------------------------
published_handoff = published_run / "10-handoff.md"
published_handoff_raw = published_handoff.read_bytes()
seal_path = published_run / "09-test-evidence" / "final-evidence" / "g1" / "seal.json"
seal_raw = seal_path.read_bytes()

restore(published_handoff, published_handoff_raw + b"\nmutation\n")
result = observe(published_run, lambda: verify(published_run))
restore(published_handoff, published_handoff_raw)
record("ac007_evidence_tamper", "claude", result, ["sealed_handoff_changed_after_publication"])

os.chmod(seal_path, 0o600)
restore(seal_path, seal_raw.replace(b'"schema_version":1', b'"schema_version": 1'), 0o600)
result = observe(published_run, lambda: verify(published_run))
restore(seal_path, seal_raw, 0o600)
record("ac007_seal_tamper", "claude", result, ["seal_bytes_reencoded_after_publication"])

# --------------------------------------------------------------------------------------------
# both-provider sealed fixtures, and the cross-orientation identity tamper. This runs BEFORE the
# unexpected-append family, which deliberately leaves the claude ledger permanently suffixed.
# --------------------------------------------------------------------------------------------
claude_paths = e.verify_seal(str(published_run), POLICY, "publication")["ordinary_paths"]
codex_paths = e.verify_seal(str(codex_run), POLICY, "publication")["ordinary_paths"]
assert claude_paths == codex_paths, (claude_paths, codex_paths)
codex_metadata = codex_run / "run-metadata.json"
codex_metadata_raw = codex_metadata.read_bytes()
flipped = json.loads(codex_metadata_raw)
flipped["primary_provider"] = "claude"
restore(codex_metadata, (json.dumps(flipped, sort_keys=True, indent=2) + "\n").encode(), 0o600)
result = observe(codex_run, lambda: verify(codex_run))
restore(codex_metadata, codex_metadata_raw, 0o600)
record("ac007_both_provider_sealed", "both", result,
       ["identical_sealed_path_set_in_both_orientations", "orientation_flipped_after_publication"])

with open(published_run / "run.jsonl", "ab") as handle:
    handle.write(json.dumps({"ts": "2026-09-01T00:00:00Z", "event": "unexpected_append",
                             "event_id": "evt-unexpected-append",
                             "run_id": published_run.name}, separators=(",", ":")).encode() + b"\n")
result = observe(published_run, lambda: verify(published_run))
record("ac007_unexpected_ledger_append", "claude", result, ["unexpected_event_appended_after_seal"])

# --------------------------------------------------------------------------------------------
# genuine-legacy-only success.
# --------------------------------------------------------------------------------------------
def classify(run):
    done = subprocess.run([LEDGER_LOG, "--classify-ledger-file", run.name,
                           os.path.realpath(str(run / "run.jsonl"))],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return done.returncode, done.stdout


rc, out = classify(legacy_run)
if rc != 0:
    raise AssertionError(("genuine legacy evidence was refused", rc, out))
legacy_ledger_raw = (legacy_run / "run.jsonl").read_bytes()
expected_out = f"valid:{len(legacy_ledger_raw)}:{hashlib.sha256(legacy_ledger_raw).hexdigest()}\n".encode()
assert out == expected_out, (out, expected_out)
legacy_row = None
for line in legacy_ledger_raw.decode().splitlines():
    row = json.loads(line)
    if row.get("event") == "evidence_produced":
        legacy_row = row
# The same legacy-shaped row must be refused inside a CURRENT run -- proven under BOTH primary
# orientations, so genuine-legacy acceptance is not an orientation-specific accident.
for current_run in (pre_run, codex_run):
    current_ledger = current_run / "run.jsonl"
    current_raw = current_ledger.read_bytes()
    smuggled = dict(legacy_row)
    smuggled["run_id"] = current_run.name
    smuggled["event_id"] = "evt-smuggled-legacy-row"
    restore(current_ledger,
            current_raw + json.dumps(smuggled, separators=(",", ":")).encode() + b"\n", 0o600)
    rc_current, _ = classify(current_run)
    restore(current_ledger, current_raw, 0o600)
    if rc_current == 0:
        raise AssertionError(f"a legacy-shaped row was accepted inside current run {current_run.name}")
legacy_result = {
    "observed_category": "NONE", "seal_published": False, "partial_generation_present": False,
    "ledger_prefix_before": prefix(legacy_run), "ledger_prefix_after": prefix(legacy_run),
    "provider_calls_before": provider_calls(legacy_run), "provider_calls_after": provider_calls(legacy_run),
}
record("ac007_genuine_legacy_reviewable", "both", legacy_result,
       ["genuine_legacy_history_remains_reviewable",
        "same_row_rejected_in_claude_primary_current_run",
        "same_row_rejected_in_codex_primary_current_run"],
       legacy_success=True)

# --------------------------------------------------------------------------------------------
# Write one immutable evidence document per family. Publication is the caller's job.
# --------------------------------------------------------------------------------------------
mismatch = {name: value["observed_category"] for name, value in families.items()
            if value["observed_category"] != EXPECTED.get(name)}
candidate = json.loads((matrix_run / "09-test-evidence" / "qa-candidate.json").read_text())
target = matrix_run / "09-test-evidence" / "mutation-evidence"
target.mkdir(parents=True, exist_ok=True)
os.chmod(target, 0o700)
written = {}
for name in sorted(families):
    value = families[name]
    document = {
        "schema_version": 1, "kind": "mutation_family_evidence", "criterion": "AC-007",
        "family": name, "orientation": value["orientation"], "run_id": matrix_run.name,
        "candidate_sha": candidate["candidate_sha"], "generation": candidate["generation"],
        "expected_category": EXPECTED[name], "observed_category": value["observed_category"],
        "legacy_success": value["legacy_success"], "seal_published": value["seal_published"],
        "partial_generation_present": value["partial_generation_present"],
        "ledger_prefix_before": value["ledger_prefix_before"],
        "ledger_prefix_after": value["ledger_prefix_after"],
        "provider_calls_before": value["provider_calls_before"],
        "provider_calls_after": value["provider_calls_after"],
        "cases": sorted(cases[name]),
    }
    raw = e.canonical_json_bytes(document)
    e.validate_schema(document, "mutation-evidence.schema.json", name)
    path = target / f"{name}.json"
    if path.exists():
        path.unlink()
    restore(path, raw, 0o600)
    written[name] = {"family": name, "orientation": value["orientation"],
                     "expected_category": EXPECTED[name],
                     "path": f"09-test-evidence/mutation-evidence/{name}.json",
                     "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
if mismatch:
    print(json.dumps({"mismatch": mismatch}, sort_keys=True))
    raise SystemExit(f"observed categories differ from the expected matrix: {mismatch}")


def publish(relative, raw):
    """Publish one artifact through the ordinary producer entry point and return its event id."""
    done = subprocess.run(
        [LEDGER_LOG, "--run", str(matrix_run), "--strict", "evidence_produced",
         f"sha={candidate['candidate_sha']}", f"generation={candidate['generation']}",
         f"path={relative}", f"sha256={hashlib.sha256(raw).hexdigest()}", f"bytes={len(raw)}",
         f"stage={stage}", f"role={role}", f"role_start_event_id={role_start_event_id}"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if done.returncode != 0:
        raise SystemExit(f"publication of {relative} failed: {done.stderr.decode('utf-8', 'replace')}")
    rows = [json.loads(line) for line in (matrix_run / "run.jsonl").read_text().splitlines() if line.strip()]
    published = [row for row in rows
                 if row.get("event") == "evidence_produced" and row.get("path") == relative]
    if len(published) != 1:
        raise SystemExit(f"publication of {relative} produced {len(published)} rows")
    return published[0]["event_id"]


producer_of = {"event": "evidence_produced", "stage": stage, "role": role,
               "role_start_event_id": role_start_event_id}
for name in sorted(written):
    entry = written[name]
    entry["producer"] = dict(
        producer_of, event_id=publish(entry["path"], (target / f"{name}.json").read_bytes()))
manifest = {
    "schema_version": 1, "kind": "mutation_matrix_manifest", "criterion": "AC-007",
    "run_id": matrix_run.name, "candidate_sha": candidate["candidate_sha"],
    "generation": candidate["generation"],
    "families": [written[name] for name in sorted(written)],
}
e.validate_schema(manifest, "mutation-evidence.schema.json", "manifest")
manifest_raw = e.canonical_json_bytes(manifest)
manifest_path = target / "ac007-manifest.json"
if manifest_path.exists():
    manifest_path.unlink()
restore(manifest_path, manifest_raw, 0o600)
manifest_event = publish(e.MUTATION_MANIFEST_PATH, manifest_raw)
print(json.dumps({"observed": {k: v["observed_category"] for k, v in families.items()},
                  "manifest_event_id": manifest_event,
                  "manifest_sha256": hashlib.sha256(manifest_raw).hexdigest(),
                  "families": len(written)}, sort_keys=True))
