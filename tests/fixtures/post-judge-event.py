#!/usr/bin/env python3
"""Append ONE post-judge-phase event to a sealed fixture run, through the real ledger writer.

usage: post-judge-event.py <firm-root> <run> <event> [key=value | -key | @tamper] ...

The event is built in exactly the well-formed shape the closed post-judge grammar admits for the
run's CURRENT sealed generation, so a test names only the one dimension it is changing:

  final_decision_required        writes 09-test-evidence/final-decision-required.<event-id>.json the
                                 way bin/firm-final-qa-check does, then logs path/sha/generation/
                                 sha256/bytes/kind (kind defaults to secondary_objections). The state
                                 names the attempt it is about: the latest reviewer-state attempt, or
                                 `state_attempt=<id>`, or none with `state_attempt=@none`;
                                 `state_objection=<text>` puts one objection text in it.
  final_gate_pending             logs sha/generation.
  post_judge_artifact_published  needs path=<run-relative file>, kind=<kind>, and
                                 secondary_attempt_id=<attempt>; logs the file's exact digest/size
                                 and the seal's publication event id and projection digest.
  anything else                  logs exactly the fields given (e.g. lead_note, qa_checkout).

Overrides: `key=value` sets (or replaces) a field, `-key` removes one, and `@tamper` rewrites the
artifact after the event is logged, so its bytes no longer match the digest the event states.
`@window` publishes inside a fresh native primary-QA role window (a `qa_started` role start for
`qa-tester` on a new stage, then the event, then its `qa_completed`), which is how primary QA's own
post-judge kinds must be produced; without it (or after a later `@nowindow`),
`stage`/`role`/`role_start_event_id` are whatever the caller passes. `@raw` appends the row straight
to run.jsonl instead of through the writer. The event id is printed on success; the writer's own exit
status is returned.
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
window = False
raw_append = False
for operation in operations:
    if operation == "@tamper":
        tamper = True
    elif operation == "@window":
        window = True
    elif operation == "@nowindow":
        window = False
    elif operation == "@raw":
        raw_append = True
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
    state_attempt = overrides.pop("state_attempt", None)
    if state_attempt is None:
        for provider in ("gpt", "claude"):
            state_path = os.path.join(run, "09-test-evidence", f"reviewer-state.{provider}.json")
            if os.path.exists(state_path):
                state_attempt = json.load(open(state_path))["attempt_id"]
    state = {"schema_version": 1, "status": "decision_required", "run_id": os.path.basename(run),
             "candidate_sha": sha, "generation": generation, "kind": kind, "objections": [],
             "permitted_record_types": ["human_decision"], "event_id": event_id,
             "created_at": "2026-10-01T00:00:00Z"}
    if state_attempt != "@none":
        state["secondary_attempt_id"] = state_attempt
    state_objection = overrides.pop("state_objection", None)
    if state_objection is not None:
        state["objections"] = [{"id": "obj-fixture", "text": state_objection}]
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
def open_window():
    """Open a fresh native qa-tester window through the writer's role-start mode."""
    first = json.loads(open(os.path.join(run, "run.jsonl")).readline())
    run_id = os.path.basename(run)
    authority = json.dumps([{"source_run": ".agent-firm/runs/" + run_id, "event_id": first["event_id"],
                             "expect": {"event": "run_started", "run_id": run_id,
                                        "fields": {"base_sha": first["base_sha"]}}}], separators=(",", ":"))
    activation = subprocess.run(
        [os.path.join(root, "bin", "firm-model-resolve"), "--provider", "codex", "--role", "qa-tester",
         "--format", "activation"], stdout=subprocess.PIPE, check=True, text=True).stdout.strip()
    stage = "test/pj-" + secrets.token_hex(6)
    started = subprocess.run(
        [writer, "--run", run, "--strict", "--role-start", "--stage", stage, "--role", "qa-tester",
         "--contract", "role-contracts/Q-01-qa-tester.md", "--event", "qa_started",
         "--authority-json", authority, "--agent", "/root/post_judge_qa", "--activation-json", activation],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if started.returncode != 0:
        sys.stderr.write(started.stderr)
        raise SystemExit(started.returncode)
    return stage, json.loads(started.stdout)["event_id"]


if window:
    stage, start_id = open_window()
    fields.update({"stage": stage, "role": "qa-tester", "role_start_event_id": start_id})
fields.update(overrides)
for key in drops:
    fields.pop(key, None)

if raw_append:
    # Bypass the writer: the row lands exactly as given, the way a row the writer would refuse could
    # still reach the file by another route. Only the verifier stands between it and trust.
    import datetime
    row = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "event": event, "event_id": event_id, "run_id": os.path.basename(run), **fields}
    with open(os.path.join(run, "run.jsonl"), "a") as handle:
        handle.write(json.dumps(row, separators=(",", ":")) + "\n")
else:
    done = subprocess.run(
        [writer, "--run", run, "--strict", "--event-id", event_id, event]
        + [f"{key}={value}" for key, value in fields.items()],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
    )
    if done.returncode != 0:
        sys.stderr.write(done.stderr)
        raise SystemExit(done.returncode)
if window and raw_append:
    # The row above bypassed the writer, so the writer would rightly refuse anything after it; the
    # window closes the same way it was written into.
    import datetime
    with open(os.path.join(run, "run.jsonl"), "a") as handle:
        handle.write(json.dumps({
            "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "event": "qa_completed", "event_id": f"evt-qa-completed-{secrets.token_hex(6)}",
            "run_id": os.path.basename(run), "stage": stage, "role": "qa-tester",
            "role_start_event_id": start_id}, separators=(",", ":")) + "\n")
elif window:
    closed = subprocess.run(
        [writer, "--run", run, "--strict", "qa_completed", f"stage={stage}", "role=qa-tester",
         f"role_start_event_id={start_id}"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if closed.returncode != 0:
        sys.stderr.write(closed.stderr)
        raise SystemExit(closed.returncode)
if tamper and artifact is not None:
    with open(os.path.join(run, artifact), "a") as handle:
        handle.write("tampered after publication\n")
print(event_id)
