"""Mutate exactly ONE dimension of the published AC-007 mutation evidence.

Driven by tests/test-evidence-seal.sh, which re-runs BOTH the library validator and the independent
golden assertion after each mutation and requires both to refuse.

The semantic mutations deliberately re-sync everything around the lie (`resync` rewrites the family
document, its manifest entry's bytes/digest, and the ledger producer row). A mutation that only
broke a digest would be caught by the digest layer and would prove nothing about whether the
semantic claim -- "this family observed its expected category", "no seal was published", "the ledger
prefix did not move" -- is checked at all. Every one of those is therefore presented as a fully
consistent, fully published, fully digest-bound evidence set whose only defect is that it is wrong.

Usage: ac007-mutation-tamper.py ROOT MATRIX_RUN MUTATION
"""
import copy, hashlib, json, os, pathlib, sys

root = pathlib.Path(sys.argv[1])
run = pathlib.Path(sys.argv[2])
mutation = sys.argv[3]
sys.path.insert(0, str(root / "agent-firm" / "lib"))
import evidence_seal as e

DIR = run / "09-test-evidence" / "mutation-evidence"
MANIFEST = DIR / "ac007-manifest.json"
LEDGER = run / "run.jsonl"
VICTIM = "ac007_seal_tamper"
LEGACY = "ac007_genuine_legacy_reviewable"


def write(path, raw, mode=0o600):
    if path.is_symlink() or path.exists():
        path.unlink()
    with open(path, "wb") as handle:
        handle.write(raw)
    os.chmod(path, mode)


def rows():
    return [json.loads(line) for line in LEDGER.read_text().splitlines() if line.strip()]


def write_rows(items):
    write(LEDGER, "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in items).encode())


def repoint(relative, raw):
    items = rows()
    for item in items:
        if item.get("event") == "evidence_produced" and item.get("path") == relative:
            item["sha256"] = hashlib.sha256(raw).hexdigest()
            item["bytes"] = str(len(raw))
    write_rows(items)


manifest = json.loads(MANIFEST.read_bytes())
entries = {item["family"]: item for item in manifest["families"]}


def publish_manifest(document):
    raw = e.canonical_json_bytes(document)
    write(MANIFEST, raw)
    repoint(e.MUTATION_MANIFEST_PATH, raw)


def resync(family, record):
    """Republish one family record CONSISTENTLY: bytes, digest, manifest entry and ledger row all
    agree, so the only thing wrong is the semantic claim the record makes."""
    raw = e.canonical_json_bytes(record)
    path = DIR / f"{family}.json"
    write(path, raw)
    entries[family]["bytes"] = len(raw)
    entries[family]["sha256"] = hashlib.sha256(raw).hexdigest()
    repoint(entries[family]["path"], raw)
    publish_manifest(manifest)


def record_of(family):
    return json.loads((DIR / f"{family}.json").read_bytes())


if mutation == "removed_family_evidence":
    (DIR / f"{VICTIM}.json").unlink()
elif mutation == "dropped_manifest_family":
    manifest["families"] = [item for item in manifest["families"] if item["family"] != VICTIM]
    publish_manifest(manifest)
elif mutation == "extra_manifest_family":
    extra = copy.deepcopy(entries[VICTIM])
    extra["family"] = "ac007_invented_family"
    extra["path"] = "09-test-evidence/mutation-evidence/ac007_invented_family.json"
    manifest["families"].append(extra)
    publish_manifest(manifest)
elif mutation == "duplicated_manifest_family":
    manifest["families"].append(copy.deepcopy(entries[VICTIM]))
    publish_manifest(manifest)
elif mutation == "duplicated_producer_event":
    items = rows()
    for item in list(items):
        if item.get("event") == "evidence_produced" and item.get("path") == entries[VICTIM]["path"]:
            clone = dict(item)
            clone["event_id"] = "evt-duplicate-mutation-producer"
            items.append(clone)
            break
    write_rows(items)
elif mutation == "unproduced_family_evidence":
    write_rows([item for item in rows()
                if not (item.get("event") == "evidence_produced"
                        and item.get("path") == entries[VICTIM]["path"])])
elif mutation == "unproduced_manifest":
    write_rows([item for item in rows()
                if not (item.get("event") == "evidence_produced"
                        and item.get("path") == e.MUTATION_MANIFEST_PATH)])
elif mutation == "stale_manifest_digest":
    entries[VICTIM]["sha256"] = "0" * 64
    publish_manifest(manifest)
elif mutation == "stale_manifest_bytes":
    entries[VICTIM]["bytes"] += 1
    publish_manifest(manifest)
elif mutation == "changed_after_publication":
    path = DIR / f"{VICTIM}.json"
    raw = path.read_bytes()
    document = json.loads(raw)
    document["cases"] = sorted(set(document["cases"]) | {"appended_after_publication"})
    changed = e.canonical_json_bytes(document)
    write(path, changed)
    entries[VICTIM]["bytes"] = len(changed)
    entries[VICTIM]["sha256"] = hashlib.sha256(changed).hexdigest()
    publish_manifest(manifest)
elif mutation == "producer_event_id_mismatch":
    entries[VICTIM]["producer"]["event_id"] = "evt-not-the-real-producer"
    publish_manifest(manifest)
elif mutation == "mutable_family_evidence":
    os.chmod(DIR / f"{VICTIM}.json", 0o666)
elif mutation == "symlinked_family_evidence":
    path = DIR / f"{VICTIM}.json"
    shadow = DIR / "shadow-copy.json"
    write(shadow, path.read_bytes())
    path.unlink()
    path.symlink_to(shadow.name)
elif mutation == "noncanonical_family_evidence":
    document = record_of(VICTIM)
    raw = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    write(DIR / f"{VICTIM}.json", raw)
    entries[VICTIM]["bytes"] = len(raw)
    entries[VICTIM]["sha256"] = hashlib.sha256(raw).hexdigest()
    repoint(entries[VICTIM]["path"], raw)
    publish_manifest(manifest)
elif mutation == "mismatched_candidate":
    manifest["candidate_sha"] = "0" * 40
    publish_manifest(manifest)
elif mutation == "mismatched_generation":
    manifest["generation"] = manifest["generation"] + 1
    publish_manifest(manifest)
elif mutation == "mismatched_record_candidate":
    document = record_of(VICTIM)
    document["candidate_sha"] = "0" * 40
    resync(VICTIM, document)
elif mutation == "observed_category_drift":
    document = record_of(VICTIM)
    document["observed_category"] = "SOMETHING_ELSE"
    resync(VICTIM, document)
elif mutation == "seal_published":
    document = record_of(VICTIM)
    document["seal_published"] = True
    resync(VICTIM, document)
elif mutation == "reusable_partial_generation":
    document = record_of(VICTIM)
    document["partial_generation_present"] = True
    resync(VICTIM, document)
elif mutation == "ledger_prefix_drift":
    document = record_of(VICTIM)
    document["ledger_prefix_after"] = {"bytes": document["ledger_prefix_after"]["bytes"] + 1,
                                       "sha256": "1" * 64}
    resync(VICTIM, document)
elif mutation == "provider_call_drift":
    document = record_of(VICTIM)
    document["provider_calls_after"] = document["provider_calls_before"] + 1
    resync(VICTIM, document)
elif mutation == "nonlegacy_success":
    document = record_of(VICTIM)
    document["legacy_success"] = True
    document["expected_category"] = "NONE"
    document["observed_category"] = "NONE"
    entries[VICTIM]["expected_category"] = "NONE"
    resync(VICTIM, document)
elif mutation == "legacy_family_not_reviewable":
    document = record_of(LEGACY)
    document["legacy_success"] = False
    resync(LEGACY, document)
elif mutation == "single_orientation":
    for family in (LEGACY, "ac007_both_provider_sealed"):
        document = record_of(family)
        document["orientation"] = "claude"
        entries[family]["orientation"] = "claude"
        resync(family, document)
elif mutation == "empty_case_list":
    document = record_of(VICTIM)
    document["cases"] = []
    resync(VICTIM, document)
elif mutation == "extra_record_field":
    document = record_of(VICTIM)
    document["note"] = "prose is not proof"
    resync(VICTIM, document)
else:
    raise SystemExit(f"unknown mutation {mutation}")
print(mutation)
