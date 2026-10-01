#!/usr/bin/env python3
"""Append ONE post-judge-phase event to a sealed fixture run, through the real ledger writer.

usage: post-judge-event.py <firm-root> <run> <event> [key=value | -key | @tamper] ...

The event is built in exactly the well-formed shape the closed post-judge grammar admits for the
run's CURRENT sealed generation, so a test names only the one dimension it is changing:

  final_decision_required        writes 09-test-evidence/final-decision-required.<event-id>.json the
                                 way bin/firm-final-qa-check does, then logs path/sha/generation/
                                 sha256/bytes/kind (kind defaults to secondary_objections).
  final_gate_pending             logs sha/generation.
  post_judge_artifact_published  needs path=<run-relative file>, kind=<kind>, and
                                 secondary_attempt_id=<attempt>; logs the file's exact digest/size
                                 and the seal's publication event id and projection digest.
  anything else                  logs exactly the fields given (e.g. lead_note, qa_checkout).

Overrides: `key=value` sets (or replaces) a field, `-key` removes one, and `@tamper` rewrites the
artifact after the event is logged, so its bytes no longer match the digest the event states.
The event id is printed on success; the writer's own exit status is returned.
"""
import hashlib
import json
import os
import secrets
import subprocess
import sys

root, run, event = sys.argv[1:4]
operations = sys.argv[4:]
writer = os.path.join(root, "bin", "firm-ledger-log")
candidate = json.load(open(os.path.join(run, "09-test-evidence", "qa-candidate.json")))
sha = candidate["candidate_sha"]
generation = candidate["generation"]

overrides = {}
drops = set()
tamper = False
for operation in operations:
    if operation == "@tamper":
        tamper = True
    elif operation.startswith("-"):
        drops.add(operation[1:])
    else:
        key, value = operation.split("=", 1)
        overrides[key] = value


def digest(relative):
    raw = open(os.path.join(run, relative), "rb").read()
    return hashlib.sha256(raw).hexdigest(), str(len(raw))


event_id = overrides.pop("event_id", None) or (
    f"evt-{event.replace('_', '-')}-g{generation}-{os.getpid()}-{secrets.token_hex(6)}"
)
fields = {}
artifact = None
if event in ("final_decision_required", "final_gate_pending", "post_judge_artifact_published"):
    fields.update({"sha": sha, "generation": str(generation)})
if event == "final_decision_required":
    kind = overrides.get("kind", "secondary_objections")
    artifact = overrides.get("path", f"09-test-evidence/final-decision-required.{event_id}.json")
    state = {"schema_version": 1, "status": "decision_required", "run_id": os.path.basename(run),
             "candidate_sha": sha, "generation": generation, "kind": kind, "objections": [],
             "permitted_record_types": ["human_decision"], "event_id": event_id,
             "created_at": "2026-10-01T00:00:00Z"}
    target = os.path.join(run, artifact)
    with open(target, "w") as handle:
        handle.write(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.chmod(target, 0o600)
    fields["path"] = artifact
    fields["sha256"], fields["bytes"] = digest(artifact)
    fields["kind"] = kind
elif event == "post_judge_artifact_published":
    seal_path = os.path.join(run, "09-test-evidence", "final-evidence", f"g{generation}", "seal.json")
    seal = json.load(open(seal_path))
    artifact = overrides["path"]
    fields["path"] = artifact
    fields["sha256"], fields["bytes"] = digest(artifact)
    fields["kind"] = overrides["kind"]
    fields["secondary_attempt_id"] = overrides["secondary_attempt_id"]
    fields["seal_event_id"] = seal["ledger"]["publication"]["event_id"]
    fields["seal_projection_sha256"] = seal["self"]["projection_sha256"]
fields.update(overrides)
for key in drops:
    fields.pop(key, None)

done = subprocess.run(
    [writer, "--run", run, "--strict", "--event-id", event_id, event]
    + [f"{key}={value}" for key, value in fields.items()],
    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
)
if done.returncode != 0:
    sys.stderr.write(done.stderr)
    raise SystemExit(done.returncode)
if tamper and artifact is not None:
    with open(os.path.join(run, artifact), "a") as handle:
        handle.write("tampered after publication\n")
print(event_id)
