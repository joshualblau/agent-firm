"""Agent Firm final-evidence seal protocol.

This module is the one implementation used by the Lead finalizer and by both
provider reviewer orientations.  Protocol JSON is AF-CJSON-1: strict JSON,
sorted keys, no whitespace, UTF-8, and one terminal LF.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import time


PROTOCOL = "agent-firm-final-evidence-seal/v1"
SUFFIX_GRAMMAR = "agent-firm-sealed-reviewer/v1"
SCHEMA_VERSION = 1
PROTOCOL_VERSION = 1
MAX_FILE = 2 * 1024 * 1024
MAX_LEDGER = 4 * 1024 * 1024
MAX_ORDINARY = 8 * 1024 * 1024
MAX_ENTRIES = 1024
MAX_PATH_BYTES = 512
BEGIN_PR = b"<!-- BEGIN COMPLETE LOCAL PR BODY -->\n"
END_PR = b"<!-- END COMPLETE LOCAL PR BODY -->\n"
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
EVENT_ID = re.compile(r"evt-[A-Za-z0-9._:-]{1,128}\Z")
SAFE_RUN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
ALLOWED_FILE_MODES = {0o400, 0o600, 0o644}
CURRENT_PRODUCER_FIELDS = {
    "ts", "event", "event_id", "run_id", "sha", "generation", "path", "sha256",
    "bytes", "stage", "role", "role_start_event_id",
}
SCHEMAS = Path(__file__).resolve().parent.parent / "schemas"
RFC3339_UTC = re.compile(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z\Z"
)
OPERATOR_HOME_FIELDS = {
    "run-metadata.json": frozenset(("repository_root", "git_common_dir")),
    "09-test-evidence/qa-candidate.json": frozenset(
        ("repository_root", "git_common_dir", "checkout_path")
    ),
}

# ---------------------------------------------------------------------------------------------
# AC-007 mutation matrix.  The preflight mutation families are a CLOSED set: the manifest must
# carry every one of them exactly once, and it may carry nothing else.  An open set would let a
# matrix that silently dropped a family still report "all declared families proven", which is the
# aggregate-count proof AC-010 forbids.  Exactly one family -- the genuine-legacy one -- may record
# a success; every other family must record an exact fail-closed category.
# ---------------------------------------------------------------------------------------------
MUTATION_EVIDENCE_DIR = "09-test-evidence/mutation-evidence"
MUTATION_MANIFEST_PATH = MUTATION_EVIDENCE_DIR + "/ac007-manifest.json"
MUTATION_LEGACY_FAMILY = "ac007_genuine_legacy_reviewable"
MUTATION_ORIENTATIONS = ("claude", "codex")
REQUIRED_MUTATION_FAMILIES = (
    "ac007_opted_in_no_fallback",
    "ac007_partial_no_fallback",
    "ac007_both_provider_sealed",
    "ac007_privacy_category_misuse",
    "ac007_privacy_surface_misuse",
    "ac007_placeholder_argv",
    "ac007_unexpected_ledger_append",
    "ac007_producer_window_defect",
    "ac007_integration_index_duplicate",
    "ac007_integration_index_malformed",
    "ac007_pr_marker_malformed",
    "ac007_seal_tamper",
    "ac007_evidence_tamper",
    "ac007_synchronized_toctou",
    MUTATION_LEGACY_FAMILY,
)


class SealError(Exception):
    """A stable fail-closed protocol error."""

    def __init__(self, category: str, detail: str):
        super().__init__(f"{category}: {detail}")
        self.category = category
        self.detail = detail


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def _validate_json_value(value, depth=0):
    if depth > 128:
        raise SealError("CANONICAL_JSON", "nesting exceeds 128")
    if value is None or isinstance(value, (str, bool)):
        return
    if isinstance(value, int):
        if value < -(2**63) or value > 2**63 - 1:
            raise SealError("CANONICAL_JSON", "integer is outside signed 64-bit range")
        return
    if isinstance(value, float):
        raise SealError("CANONICAL_JSON", "floating-point values are forbidden")
    if isinstance(value, list):
        for item in value:
            _validate_json_value(item, depth + 1)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise SealError("CANONICAL_JSON", "object key is not a string")
            _validate_json_value(item, depth + 1)
        return
    raise SealError("CANONICAL_JSON", f"unsupported value type {type(value).__name__}")


def canonical_json_bytes(value):
    """Return AF-CJSON-1 bytes."""
    _validate_json_value(value)
    try:
        text = json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError) as exc:
        raise SealError("CANONICAL_JSON", "value is not encodable") from exc
    # Python's encoder uses lowercase hexadecimal escapes and surrogate pairs.
    return text.encode("utf-8") + b"\n"


def parse_json_unique(raw, label="JSON"):
    try:
        value = json.loads(raw.decode("utf-8", "strict"), object_pairs_hook=_unique_object)
    except (UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise SealError("MALFORMED_JSON", label) from exc
    _validate_json_value(value)
    return value


def parse_canonical_json(raw, label="protocol JSON"):
    value = parse_json_unique(raw, label)
    if canonical_json_bytes(value) != raw:
        raise SealError("NONCANONICAL_JSON", label)
    return value


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def _schema_validate(value, schema_name, label):
    try:
        import jsonschema
        schema = parse_json_unique((SCHEMAS / schema_name).read_bytes(), schema_name)
        jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker()).validate(value)
    except SealError:
        raise
    except BaseException as exc:
        raise SealError("SCHEMA_INVALID", f"{label}:{type(exc).__name__}") from exc


def validate_schema(value, schema_name, label="protocol artifact"):
    """Validate against the repository's canonical Draft 2020-12 schema."""
    _schema_validate(value, schema_name, label)


def _parse_rfc3339_utc(value, label):
    if not isinstance(value, str) or not RFC3339_UTC.fullmatch(value):
        raise SealError("TIMESTAMP_INVALID", label)
    try:
        parsed = datetime.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise SealError("TIMESTAMP_INVALID", label) from exc
    if parsed.utcoffset() != datetime.timedelta(0):
        raise SealError("TIMESTAMP_INVALID", label)
    return parsed


def _format_rfc3339_ms(value):
    value = value.astimezone(datetime.timezone.utc)
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _safe_relative(relative):
    if not isinstance(relative, str) or not relative or len(relative.encode("ascii", "strict")) > MAX_PATH_BYTES:
        raise SealError("PATH_INVALID", "path must be bounded nonempty ASCII")
    if os.path.isabs(relative) or "\\" in relative or any(ord(ch) < 32 or ord(ch) == 127 for ch in relative):
        raise SealError("PATH_INVALID", relative[:160])
    parts = relative.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise SealError("PATH_INVALID", relative[:160])
    return parts


def _safe_read(run, relative, maximum=MAX_FILE):
    parts = _safe_relative(relative)
    current = run
    for part in parts:
        current = current / part
        try:
            info = os.lstat(current)
        except OSError as exc:
            raise SealError("ARTIFACT_MISSING", relative) from exc
        if stat.S_ISLNK(info.st_mode):
            raise SealError("ARTIFACT_SYMLINK", relative)
    info = os.lstat(current)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise SealError("ARTIFACT_UNSAFE", relative)
    mode = stat.S_IMODE(info.st_mode)
    if mode not in ALLOWED_FILE_MODES:
        raise SealError("ARTIFACT_MODE", relative)
    if info.st_size > maximum:
        raise SealError("ARTIFACT_OVERSIZE", relative)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(current, flags)
    try:
        before = os.fstat(fd)
        chunks = []
        total = 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise SealError("ARTIFACT_OVERSIZE", relative)
            chunks.append(chunk)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
                             item.st_size, item.st_mtime_ns, item.st_ctime_ns)
    if identity(before) != identity(after) or identity(after) != identity(os.lstat(current)):
        raise SealError("ARTIFACT_MOVED", relative)
    return b"".join(chunks), mode, (info.st_dev, info.st_ino)


def _atomic_exclusive(path, raw, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    parent_info = os.lstat(path.parent)
    if stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid != os.getuid():
        raise SealError("OUTPUT_UNSAFE", str(path.parent))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags, mode)
    except FileExistsError as exc:
        raise SealError("MULTIPLE_SEALS", path.name) from exc
    try:
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(raw):
            offset += os.write(fd, raw[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)
    directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def extract_pr_body(raw):
    """Extract exact bytes between the one canonical marker pair."""
    try:
        raw.decode("utf-8", "strict")
    except UnicodeError as exc:
        raise SealError("PR_MARKERS", "handoff is not strict UTF-8") from exc
    if b"\r" in raw:
        raise SealError("PR_MARKERS", "handoff is not LF-only")
    begin_token = BEGIN_PR.rstrip(b"\n")
    end_token = END_PR.rstrip(b"\n")
    if raw.count(begin_token) != 1 or raw.count(end_token) != 1:
        raise SealError("PR_MARKERS", "marker is missing, duplicated, or embedded")
    begin = raw.find(BEGIN_PR)
    end = raw.find(END_PR)
    if begin < 0 or end < 0:
        raise SealError("PR_MARKERS", "marker is not an exact LF-terminated line")
    body_start = begin + len(BEGIN_PR)
    if end < body_start:
        raise SealError("PR_MARKERS", "markers are reversed or overlapping")
    body = raw[body_start:end]
    if begin_token in body or end_token in body:
        raise SealError("PR_MARKERS", "nested marker")
    return body, body_start, end


def _ledger(raw, run_id, ledger_path):
    if not raw or len(raw) > MAX_LEDGER or not raw.endswith(b"\n") or b"\n\n" in raw:
        raise SealError("LEDGER_PREFIX", "ledger must be nonempty, bounded, and newline-complete")
    classifier = Path(__file__).resolve().parents[2] / "bin" / "firm-ledger-log"
    try:
        checked = subprocess.run(
            [str(classifier), "--classify-ledger-file", run_id, os.path.realpath(ledger_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise SealError("LEDGER_PREFIX", "canonical classifier unavailable") from exc
    expected = f"valid:{len(raw)}:{sha256(raw)}\n".encode("ascii")
    if checked.returncode != 0 or checked.stdout != expected:
        detail = checked.stderr.decode("utf-8", "replace").strip()[:160]
        raise SealError("LEDGER_PREFIX", "canonical classifier rejected ledger" + (":" + detail if detail else ""))
    records = []
    seen = set()
    for number, line in enumerate(raw.splitlines(), 1):
        item = parse_json_unique(line, f"ledger line {number}")
        if not isinstance(item, dict):
            raise SealError("LEDGER_PREFIX", f"line {number} is not an object")
        event_id = item.get("event_id")
        if event_id is not None:
            if event_id in seen:
                raise SealError("LEDGER_PREFIX", f"line {number} has duplicate event id")
            seen.add(event_id)
        records.append(item)
    return records


def _load_data(raw, relative):
    try:
        if relative.endswith(".json"):
            return parse_json_unique(raw, relative)
        if relative.endswith((".yaml", ".yml")):
            import yaml
            return yaml.safe_load(raw.decode("utf-8", "strict"))
    except BaseException as exc:
        raise SealError("STRUCTURED_ARTIFACT", relative) from exc
    return None


def _walk_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from _walk_strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from _walk_strings(item)


def _discover_references(relative, raw, value):
    found = []
    def declare(path, source):
        if path in found:
            raise SealError("DUPLICATE_DECLARATION", f"{relative}:{source}:{path}")
        found.append(path)
    text = raw.decode("utf-8", "ignore")
    for match in re.finditer(r"evidence://run/([A-Za-z0-9._/-]+)", text):
        declare(match.group(1), "evidence_token")
    if relative == "08-qa-verdict.json" and isinstance(value, dict):
        artifacts = value.get("artifacts", [])
        if not isinstance(artifacts, list):
            raise SealError("REFERENCE_INVALID", "primary artifacts is not a list")
        for item in artifacts:
            if not isinstance(item, str):
                raise SealError("REFERENCE_INVALID", "primary artifact is not a path")
            declare(item, "artifacts")
        for command in value.get("commands_run", []):
            if isinstance(command, dict) and isinstance(command.get("artifact"), str):
                declare(command["artifact"], "commands_run")
    if isinstance(value, dict):
        def visit(item):
            if isinstance(item, dict):
                if {"path", "candidate_sha", "sha256", "bytes", "producer"}.issubset(item):
                    if not isinstance(item["path"], str):
                        raise SealError("REFERENCE_INVALID", relative)
                    declare(item["path"], "structured_reference")
                for nested in item.values():
                    visit(nested)
            elif isinstance(item, list):
                declared_paths = [nested.get("path") for nested in item
                                  if isinstance(nested, dict) and isinstance(nested.get("path"), str)]
                if len(declared_paths) != len(set(declared_paths)):
                    raise SealError("DUPLICATE_DECLARATION", f"{relative}:structured_list")
                for nested in item:
                    visit(nested)
        visit(value)
    return found


def _integration_index_references(run, relative, raw, value):
    if relative != "integration-summaries/index.json":
        return []
    expected_top = {"schema_version", "run_id", "current_stage", "entries"}
    if not isinstance(value, dict) or set(value) != expected_top:
        raise SealError("INTEGRATION_INDEX", "invalid top-level fields")
    if value.get("schema_version") != 1 or value.get("run_id") != run.name:
        raise SealError("INTEGRATION_INDEX", "identity mismatch")
    canonical = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if raw != canonical:
        raise SealError("INTEGRATION_INDEX", "encoding is not canonical")
    entries = value.get("entries")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 64:
        raise SealError("INTEGRATION_INDEX", "history must contain 1 through 64 entries")
    stages = set()
    paths = set()
    references = []
    for item in entries:
        if not isinstance(item, dict) or set(item) != {"stage", "path", "bytes", "sha256"}:
            raise SealError("INTEGRATION_INDEX", "entry fields are invalid")
        stage = item.get("stage")
        if not isinstance(stage, str) or re.fullmatch(r"integrate/[A-Za-z0-9][A-Za-z0-9._-]{0,63}", stage) is None:
            raise SealError("INTEGRATION_INDEX", "stage is invalid")
        expected_path = "integration-summaries/" + stage.split("/", 1)[1] + ".md"
        if item.get("path") != expected_path or stage in stages or expected_path in paths:
            raise SealError("INTEGRATION_INDEX", "stage/path is duplicated or mismatched")
        stages.add(stage)
        paths.add(expected_path)
        if (isinstance(item.get("bytes"), bool) or not isinstance(item.get("bytes"), int)
                or not 1 <= item["bytes"] <= 1024 * 1024
                or not isinstance(item.get("sha256"), str) or HEX64.fullmatch(item["sha256"]) is None):
            raise SealError("INTEGRATION_INDEX", "entry identity is invalid")
        summary, mode, _ = _safe_read(run, expected_path, 1024 * 1024)
        if mode != 0o644 or len(summary) != item["bytes"] or sha256(summary) != item["sha256"]:
            raise SealError("INTEGRATION_INDEX", f"summary is stale:{expected_path}")
        references.append(expected_path)
    if value.get("current_stage") != entries[-1]["stage"]:
        raise SealError("INTEGRATION_INDEX", "current_stage is not final")
    return references


def _validate_command_result(value, expected_artifact, run):
    _schema_validate(value, "command-result.schema.json", expected_artifact)
    argv = value.get("argv")
    if not isinstance(argv, list) or not argv or not all(isinstance(x, str) and x for x in argv):
        raise SealError("COMMAND_EVIDENCE", "actual argv is absent")
    placeholder = re.compile(r"(?:<[^>]+>|\$\{?[A-Za-z_]|\.\.\.|\{\{[^}]+\}\})")
    if any(placeholder.search(item) or "\x00" in item or "\n" in item for item in argv):
        raise SealError("COMMAND_EVIDENCE", "argv contains a placeholder")
    cwd = value.get("cwd")
    if not isinstance(cwd, str) or not os.path.isabs(cwd) or os.path.realpath(cwd) != cwd:
        raise SealError("COMMAND_EVIDENCE", "cwd is not canonical")
    started = _parse_rfc3339_utc(value.get("started_at"), "command started_at")
    finished = _parse_rfc3339_utc(value.get("finished_at"), "command finished_at")
    elapsed_ms = int((finished - started).total_seconds() * 1000)
    if elapsed_ms < 0 or value.get("duration_ms") != elapsed_ms:
        raise SealError("COMMAND_EVIDENCE", "timestamp order/duration mismatch")
    exit_code = value.get("exit_code")
    relation = {
        "pass": exit_code == 0,
        "fail": isinstance(exit_code, int) and not isinstance(exit_code, bool) and exit_code > 0 and exit_code not in (124, 125),
        "timeout": exit_code == 124,
        "signal": isinstance(exit_code, int) and not isinstance(exit_code, bool) and exit_code < 0,
    }
    if relation.get(value.get("result")) is not True:
        raise SealError("COMMAND_EVIDENCE", "exit/result relation is invalid")
    for name in ("inputs", "outputs"):
        items = value.get(name)
        paths = [item["path"] for item in items]
        if len(set(paths)) != len(paths):
            raise SealError("COMMAND_EVIDENCE", f"{name} inventory is invalid")
        for item in items:
            raw, mode, _ = _safe_read(run, item["path"])
            if (item["bytes"] != len(raw) or item["sha256"] != sha256(raw)
                    or item["mode"] != f"{mode:04o}" or item["sanitizer"] not in ("identity", "redacted_utf8_v2")):
                raise SealError("COMMAND_EVIDENCE", f"{name} identity is stale")
    for name in ("stdout", "stderr"):
        item = value.get(name)
        if item["kind"] == "not_applicable":
            continue
        raw, mode, _ = _safe_read(run, item["path"])
        if (item["bytes"] != len(raw) or item["sha256"] != sha256(raw)
                or item["mode"] != f"{mode:04o}" or item["sanitizer"] not in ("identity", "redacted_utf8_v2")):
            raise SealError("COMMAND_EVIDENCE", f"{name} identity is stale")
    if not value["outputs"] and all(value[name]["kind"] == "not_applicable" for name in ("stdout", "stderr")):
        raise SealError("COMMAND_EVIDENCE", "load-bearing raw result was disposed")


def _privacy_patterns(policy):
    if not isinstance(policy, dict) or set(policy) != {"schema_version", "version", "categories", "allow_rules"}:
        raise SealError("PRIVACY_POLICY", "policy shape is invalid")
    if policy["schema_version"] != 1 or policy["version"] != 2 or not isinstance(policy["categories"], list):
        raise SealError("PRIVACY_POLICY", "policy version/categories are invalid")
    patterns = []
    for item in policy["categories"]:
        if not isinstance(item, dict) or set(item) != {"id", "pattern", "surfaces"}:
            raise SealError("PRIVACY_POLICY", "category shape is invalid")
        try:
            if (not isinstance(item["surfaces"], list) or not item["surfaces"]
                    or len(item["surfaces"]) != len(set(item["surfaces"]))):
                raise ValueError("invalid category surfaces")
            patterns.append((item["id"], re.compile(item["pattern"], re.I), tuple(item["surfaces"])))
        except (TypeError, ValueError, re.error) as exc:
            raise SealError("PRIVACY_POLICY", "category regex is invalid") from exc
    rules = []
    category_ids = {item[0] for item in patterns}
    structured_rules = 0
    base_fields = {"id", "pattern_id", "pattern", "surfaces"}
    structured_fields = base_fields | {"selectors", "value_binding", "unescaped_json_string"}
    for item in policy["allow_rules"]:
        if not isinstance(item, dict) or set(item) not in (base_fields, structured_fields):
            raise SealError("PRIVACY_POLICY", "allow rule shape is invalid")
        if item["pattern_id"] not in category_ids or not isinstance(item["surfaces"], list) or not item["surfaces"]:
            raise SealError("PRIVACY_POLICY", "allow rule target/surfaces are invalid")
        if len(item["surfaces"]) != len(set(item["surfaces"])):
            raise SealError("PRIVACY_POLICY", "allow rule surfaces are duplicated")
        try:
            rule = {
                "id": item["id"], "pattern_id": item["pattern_id"],
                "pattern": re.compile(item["pattern"]), "surfaces": tuple(item["surfaces"]),
                "selectors": None,
            }
        except (TypeError, re.error) as exc:
            raise SealError("PRIVACY_POLICY", "allow regex is invalid") from exc
        if set(item) == structured_fields:
            structured_rules += 1
            selectors = item.get("selectors")
            if (item.get("id") != "declared_operator_home_identity"
                    or item.get("pattern_id") != "operator_home"
                    or item.get("surfaces") != ["declared_metadata"]
                    or item.get("value_binding") != "proven_canonical_identity"
                    or item.get("unescaped_json_string") is not True
                    or not isinstance(selectors, list)):
                raise SealError("PRIVACY_POLICY", "operator-home rule boundary is invalid")
            compiled_selectors = {}
            for selector in selectors:
                if (not isinstance(selector, dict) or set(selector) != {"path", "fields"}
                        or not isinstance(selector.get("path"), str)
                        or not isinstance(selector.get("fields"), list)
                        or not selector["fields"]
                        or len(selector["fields"]) != len(set(selector["fields"]))
                        or selector["path"] in compiled_selectors):
                    raise SealError("PRIVACY_POLICY", "operator-home selectors are invalid")
                compiled_selectors[selector["path"]] = frozenset(selector["fields"])
            if compiled_selectors != OPERATOR_HOME_FIELDS:
                raise SealError("PRIVACY_POLICY", "operator-home selectors exceed the approved fields")
            rule["selectors"] = frozenset(
                (path, field) for path, fields in compiled_selectors.items() for field in fields
            )
        elif item["pattern_id"] == "operator_home":
            raise SealError("PRIVACY_POLICY", "operator-home allowance requires exact selectors")
        rules.append(rule)
    if structured_rules != 1:
        raise SealError("PRIVACY_POLICY", "exactly one operator-home rule is required")
    return patterns, rules


def _top_level_json_string_fields(raw):
    """Return exact raw spans for unique top-level JSON string fields, or no fields."""
    try:
        text = raw.decode("utf-8", "strict")
        parsed = parse_json_unique(raw, "privacy metadata")
        if not isinstance(parsed, dict):
            return {}
        decoder = json.JSONDecoder()
        length = len(text)

        def whitespace(offset):
            while offset < length and text[offset] in " \t\r\n":
                offset += 1
            return offset

        offset = whitespace(0)
        if offset >= length or text[offset] != "{":
            return {}
        offset = whitespace(offset + 1)
        fields = {}
        if offset < length and text[offset] == "}":
            return fields if whitespace(offset + 1) == length else {}
        while offset < length:
            key_start = offset
            key, key_end = decoder.raw_decode(text, key_start)
            if not isinstance(key, str) or text[key_start] != '"':
                return {}
            offset = whitespace(key_end)
            if offset >= length or text[offset] != ":":
                return {}
            value_start = whitespace(offset + 1)
            value, value_end = decoder.raw_decode(text, value_start)
            if (isinstance(value, str) and text[value_start] == '"'
                    and value_end > value_start and text[value_end - 1] == '"'):
                fields[key] = {
                    "value": value,
                    "content_start": value_start + 1,
                    "content_end": value_end - 1,
                    "unescaped": "\\" not in text[value_start + 1:value_end - 1],
                }
            offset = whitespace(value_end)
            if offset < length and text[offset] == ",":
                offset = whitespace(offset + 1)
                continue
            if offset < length and text[offset] == "}":
                return fields if whitespace(offset + 1) == length else {}
            return {}
    except (SealError, UnicodeError, ValueError, json.JSONDecodeError):
        return {}
    return {}


def _canonical_operator_home(value):
    prefix = "/" + "Users" + "/"
    suffix = value[len(prefix):] if isinstance(value, str) and value.startswith(prefix) else ""
    operator, separator, remainder = suffix.partition("/")
    return bool(
        separator and remainder and re.fullmatch(r"[A-Za-z0-9._-]+", operator)
        and os.path.isabs(value) and os.path.normpath(value) == value
        and os.path.realpath(value) == value
    )


def _surface_class(relative):
    if relative == "10-handoff.md":
        return "handoff"
    if relative.endswith("/complete-local-pr-body.md"):
        return "pr_body"
    if relative == "08-qa-verdict.json":
        return "primary_verdict"
    if relative == "traceability.yaml":
        return "traceability"
    if relative == "run.jsonl#prefix":
        return "ledger_prefix"
    if relative.endswith("/candidate.diff"):
        return "source_diff"
    if relative in ("run-metadata.json", "run-baseline.json", "09-test-evidence/qa-candidate.json") or relative.endswith("/normalized-run-metadata.json"):
        return "declared_metadata"
    if relative.startswith("09-test-evidence/"):
        return "test_evidence"
    if relative.startswith("integration-summaries/") or relative in ("integration-summary.md", "06-implementation-summary.md"):
        return "summary"
    return "run_artifact"


def _scan(raw, relative, privacy, identity_bindings=None):
    patterns, rules = privacy
    text = raw.decode("utf-8", "replace")
    matches = []
    allowances = []
    surface = _surface_class(relative)
    identity_bindings = identity_bindings or {}
    string_fields = None
    for pattern_id, pattern, surfaces in patterns:
        # Deny categories apply to every final-byte surface. The declared surface set is
        # policy inventory; only an exact allow rule may narrow a match on a named surface.
        for match in pattern.finditer(text):
            token = match.group(0).encode("utf-8", "replace")
            allowed = None
            for rule in rules:
                if (rule["pattern_id"] != pattern_id or surface not in rule["surfaces"]
                        or rule["pattern"].fullmatch(match.group(0)) is None):
                    continue
                if rule["selectors"] is None:
                    allowed = {
                        "rule_id": rule["id"],
                        "offset": len(text[:match.start()].encode("utf-8")),
                        "token_sha256": sha256(token),
                    }
                    break
                if string_fields is None:
                    string_fields = _top_level_json_string_fields(raw)
                for field, descriptor in string_fields.items():
                    if ((relative, field) not in rule["selectors"]
                            or descriptor["unescaped"] is not True
                            or not (descriptor["content_start"] <= match.start()
                                    and match.end() <= descriptor["content_end"])):
                        continue
                    value = descriptor["value"]
                    expected = identity_bindings.get((relative, field))
                    if (not isinstance(expected, str) or value != expected
                            or not _canonical_operator_home(value)):
                        continue
                    allowed = {
                        "rule_id": rule["id"],
                        "offset": len(text[:match.start()].encode("utf-8")),
                        "token_sha256": sha256(token),
                        "artifact_path": relative,
                        "surface_class": surface,
                        "json_field": field,
                        "value_sha256": sha256(value.encode("utf-8")),
                    }
                    break
                if allowed is not None:
                    break
            if allowed is not None:
                allowances.append(allowed)
                continue
            matches.append({"pattern_id": pattern_id, "offset": len(text[:match.start()].encode("utf-8")),
                            "token_sha256": sha256(token)})
    if matches:
        raise SealError("PRIVACY_MATCH", f"{relative}:{matches[0]['pattern_id']}:{matches[0]['offset']}")
    return {"path": relative, "surface_class": surface, "bytes": len(raw), "sha256": sha256(raw),
            "matches": [], "allowances": allowances}


def _producer(records, path, raw, sha, generation, required):
    publications = [item for item in records if item.get("event") == "evidence_produced"]
    for item in publications:
        try:
            _safe_relative(item.get("path"))
        except (SealError, UnicodeError, AttributeError) as exc:
            raise SealError("PRODUCER_SHAPE", "non-canonical evidence path") from exc
        if (set(item) != CURRENT_PRODUCER_FIELDS
                or EVENT_ID.fullmatch(str(item.get("event_id", ""))) is None
                or EVENT_ID.fullmatch(str(item.get("role_start_event_id", ""))) is None
                or HEX40.fullmatch(str(item.get("sha", ""))) is None
                or HEX64.fullmatch(str(item.get("sha256", ""))) is None
                or re.fullmatch(r"[1-9][0-9]*", str(item.get("generation", ""))) is None
                or re.fullmatch(r"0|[1-9][0-9]*", str(item.get("bytes", ""))) is None
                or not isinstance(item.get("stage"), str) or not item["stage"]
                or not isinstance(item.get("role"), str) or not item["role"]):
            raise SealError("PRODUCER_SHAPE", str(item.get("path", "evidence"))[:160])
    matches = [item for item in publications if item["path"] == path]
    if not matches:
        if required:
            raise SealError("PRODUCER_MISSING", path)
        return None
    if len(matches) != 1:
        raise SealError("PRODUCER_DUPLICATE", path)
    event = matches[0]
    if (event.get("sha256") != sha256(raw) or str(event.get("bytes")) != str(len(raw)) or
            event.get("sha") != sha or str(event.get("generation")) != str(generation)):
        raise SealError("PRODUCER_STALE", path)
    start_id = event.get("role_start_event_id")
    if not isinstance(start_id, str) or EVENT_ID.fullmatch(start_id) is None:
        raise SealError("PRODUCER_WINDOW", f"{path}:missing role_start_event_id")
    if start_id:
        start_indexes = [i for i, item in enumerate(records)
                         if item.get("event_id") == start_id and str(item.get("event", "")).endswith("_started")]
        complete_indexes = [i for i, item in enumerate(records)
                            if item.get("role_start_event_id") == start_id
                            and str(item.get("event", "")).endswith("_completed")]
        event_index = records.index(event)
        if len(start_indexes) != 1 or len(complete_indexes) != 1 or not (start_indexes[0] < event_index < complete_indexes[0]):
            raise SealError("PRODUCER_WINDOW", path)
        start = records[start_indexes[0]]
        complete = records[complete_indexes[0]]
        if not {"contract", "authority", "activation"}.issubset(start):
            raise SealError("PRODUCER_WINDOW", f"{path}:role start is not native")
        stage = event.get("stage")
        role = event.get("role")
        if (not isinstance(stage, str) or not isinstance(role, str) or
                start.get("stage") != stage or start.get("role") != role or
                complete.get("stage") != stage or complete.get("role") != role):
            raise SealError("PRODUCER_WINDOW", f"{path}:stage/role mismatch")
        start_ts = _parse_rfc3339_utc(start.get("ts"), f"{path}:role start")
        produced_ts = _parse_rfc3339_utc(event.get("ts"), f"{path}:producer")
        complete_ts = _parse_rfc3339_utc(complete.get("ts"), f"{path}:role completion")
        if not start_ts <= produced_ts <= complete_ts:
            raise SealError("PRODUCER_WINDOW", f"{path}:back-stamped timestamp")
    return {"event_id": event["event_id"], "event": "evidence_produced",
            "role_start_event_id": start_id, "stage": event.get("stage"), "role": event.get("role")}


def validate_mutation_matrix(run, sha, generation, records):
    """Validate the closed AC-007 mutation-evidence manifest for the CURRENT candidate.

    Every required family must be present exactly once, bound to this run/candidate/generation, and
    backed by its own immutable AF-CJSON-1 evidence document whose exact no-follow bytes, lowercase
    digest, byte count and single `evidence_produced` producer event all agree.  Each family record
    must prove, for its own execution, that the expected fail-closed category was the observed one,
    that no seal and no reusable partial generation were produced, that the tested ledger prefix
    stayed byte-identical, and that the provider-call count did not move.  A missing, stale, mutable,
    duplicated, mismatched, unproduced, or post-publication-changed dimension raises; there is no
    aggregate count or prose that can substitute for any of it.
    """
    run = Path(run)
    manifest_raw, _, _ = _safe_read(run, MUTATION_MANIFEST_PATH)
    manifest = parse_canonical_json(manifest_raw, MUTATION_MANIFEST_PATH)
    _schema_validate(manifest, "mutation-evidence.schema.json", MUTATION_MANIFEST_PATH)
    if manifest.get("kind") != "mutation_matrix_manifest":
        raise SealError("MUTATION_MANIFEST", "artifact is not the mutation matrix manifest")
    if (manifest.get("run_id") != run.name or manifest.get("candidate_sha") != sha
            or str(manifest.get("generation")) != str(generation)):
        raise SealError("MUTATION_MANIFEST", "manifest is not bound to the current candidate")
    entries = manifest["families"]
    declared = [item["family"] for item in entries]
    if len(declared) != len(set(declared)):
        raise SealError("MUTATION_MANIFEST", "a family is declared more than once")
    if set(declared) != set(REQUIRED_MUTATION_FAMILIES):
        missing = sorted(set(REQUIRED_MUTATION_FAMILIES) - set(declared))
        extra = sorted(set(declared) - set(REQUIRED_MUTATION_FAMILIES))
        raise SealError("MUTATION_MANIFEST",
                        f"family set is not the closed AC-007 set (missing={missing} extra={extra})")
    manifest_producer = _producer(records, MUTATION_MANIFEST_PATH, manifest_raw, sha, generation, True)
    covered = set()
    proven = {}
    for entry in entries:
        family = entry["family"]
        expected_path = f"{MUTATION_EVIDENCE_DIR}/{family}.json"
        if entry["path"] != expected_path:
            raise SealError("MUTATION_FAMILY", f"{family}:path is not the canonical family path")
        raw, _, _ = _safe_read(run, entry["path"])
        if entry["bytes"] != len(raw) or entry["sha256"] != sha256(raw):
            raise SealError("MUTATION_EVIDENCE", f"{family}:manifest identity is stale")
        record = parse_canonical_json(raw, entry["path"])
        _schema_validate(record, "mutation-evidence.schema.json", entry["path"])
        if record.get("kind") != "mutation_family_evidence":
            raise SealError("MUTATION_EVIDENCE", f"{family}:artifact is not a family record")
        if (record.get("family") != family or record.get("run_id") != run.name
                or record.get("candidate_sha") != sha
                or str(record.get("generation")) != str(generation)
                or record.get("orientation") != entry["orientation"]
                or record.get("expected_category") != entry["expected_category"]):
            raise SealError("MUTATION_EVIDENCE", f"{family}:record identity does not match the manifest")
        if record["observed_category"] != record["expected_category"]:
            raise SealError("MUTATION_FAMILY",
                            f"{family}:observed {record['observed_category']} != expected "
                            f"{record['expected_category']}")
        if record["seal_published"] or record["partial_generation_present"]:
            raise SealError("MUTATION_FAMILY", f"{family}:left a seal or a reusable partial generation")
        if record["ledger_prefix_before"] != record["ledger_prefix_after"]:
            raise SealError("MUTATION_FAMILY", f"{family}:tested ledger prefix is not byte-identical")
        if record["provider_calls_before"] != record["provider_calls_after"]:
            raise SealError("MUTATION_FAMILY", f"{family}:provider-call count changed")
        if record["legacy_success"]:
            if family != MUTATION_LEGACY_FAMILY:
                raise SealError("MUTATION_FAMILY", f"{family}:only the genuine-legacy family may succeed")
            if record["expected_category"] != "NONE":
                raise SealError("MUTATION_FAMILY", f"{family}:legacy success must declare NONE")
        else:
            if family == MUTATION_LEGACY_FAMILY:
                raise SealError("MUTATION_FAMILY",
                                f"{family}:genuine legacy reviewability was not retained")
            if record["expected_category"] == "NONE":
                raise SealError("MUTATION_FAMILY", f"{family}:a mutation must name a fail-closed category")
        producer = _producer(records, entry["path"], raw, sha, generation, True)
        if producer != entry["producer"]:
            raise SealError("MUTATION_EVIDENCE", f"{family}:producer binding does not match the ledger")
        covered.update(MUTATION_ORIENTATIONS if entry["orientation"] == "both" else (entry["orientation"],))
        proven[family] = {"orientation": entry["orientation"], "category": record["observed_category"],
                          "cases": list(record["cases"]), "producer": producer}
    if covered != set(MUTATION_ORIENTATIONS):
        raise SealError("MUTATION_MANIFEST",
                        f"matrix does not cover both primary orientations (covered={sorted(covered)})")
    return {"schema_version": 1, "path": MUTATION_MANIFEST_PATH, "run_id": run.name,
            "candidate_sha": sha, "generation": generation,
            "bytes": len(manifest_raw), "sha256": sha256(manifest_raw),
            "producer": manifest_producer, "families": proven}


def _identity(run):
    run = Path(os.path.realpath(os.path.abspath(run)))
    if not SAFE_RUN.fullmatch(run.name) or run.parent.name != "runs" or run.parent.parent.name != ".agent-firm":
        raise SealError("RUN_INVALID", "run is not <repo>/.agent-firm/runs/<safe-id>")
    repo = run.parent.parent.parent
    for component in (repo, repo / ".agent-firm", run.parent, run):
        info = os.lstat(component)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise SealError("RUN_INVALID", str(component))
    top = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
                                  stderr=subprocess.DEVNULL, text=True, timeout=10).strip()
    canonical_repo = os.path.realpath(repo)
    if top != canonical_repo:
        raise SealError("RUN_IDENTITY", "repository root mismatch")
    common = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "--git-common-dir"],
        stderr=subprocess.DEVNULL, text=True, timeout=10,
    ).strip()
    if not os.path.isabs(common):
        common = os.path.join(str(repo), common)
    canonical_common = os.path.realpath(common)
    metadata_raw, _, _ = _safe_read(run, "run-metadata.json")
    candidate_raw, _, _ = _safe_read(run, "09-test-evidence/qa-candidate.json")
    metadata = parse_json_unique(metadata_raw, "run metadata")
    candidate = parse_json_unique(candidate_raw, "candidate metadata")
    sha = candidate.get("candidate_sha")
    generation = candidate.get("generation")
    if (metadata.get("run_id") != run.name or candidate.get("run_id") != run.name or
            not isinstance(sha, str) or not HEX40.fullmatch(sha) or
            isinstance(generation, bool) or not isinstance(generation, int) or generation < 1 or
            candidate.get("base_sha") != metadata.get("accepted_base_sha") or
            metadata.get("repository_root") != canonical_repo or
            candidate.get("repository_root") != canonical_repo or
            metadata.get("git_common_dir") != canonical_common or
            candidate.get("git_common_dir") != canonical_common):
        raise SealError("RUN_IDENTITY", "metadata/candidate identity mismatch")
    checkout = candidate.get("checkout_path")
    expected_checkout = os.path.join(canonical_repo, ".agent-firm", "qa-checkout", run.name)
    if checkout != expected_checkout or os.path.realpath(str(checkout)) != expected_checkout:
        raise SealError("RUN_IDENTITY", "QA checkout identity is noncanonical")
    for component in (repo / ".agent-firm" / "qa-checkout", Path(expected_checkout)):
        try:
            info = os.lstat(component)
        except OSError as exc:
            raise SealError("RUN_IDENTITY", "QA checkout identity is missing") from exc
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise SealError("RUN_IDENTITY", "QA checkout identity is unsafe")
    checkout_top = subprocess.check_output(
        ["git", "-C", expected_checkout, "rev-parse", "--show-toplevel"],
        stderr=subprocess.DEVNULL, text=True, timeout=10,
    ).strip()
    checkout_sha = subprocess.check_output(
        ["git", "-C", expected_checkout, "rev-parse", "HEAD"],
        stderr=subprocess.DEVNULL, text=True, timeout=10,
    ).strip()
    checkout_common = subprocess.check_output(
        ["git", "-C", expected_checkout, "rev-parse", "--git-common-dir"],
        stderr=subprocess.DEVNULL, text=True, timeout=10,
    ).strip()
    if not os.path.isabs(checkout_common):
        checkout_common = os.path.join(expected_checkout, checkout_common)
    if (checkout_top != expected_checkout or checkout_sha != sha
            or os.path.realpath(checkout_common) != canonical_common):
        raise SealError("RUN_IDENTITY", "QA checkout repository identity mismatch")
    primary = metadata.get("primary_provider")
    if primary not in ("claude", "codex"):
        raise SealError("RUN_IDENTITY", "primary provider invalid")
    return run, repo, metadata, candidate


def _operator_home_identity_bindings(metadata, candidate):
    return {
        ("run-metadata.json", "repository_root"): metadata["repository_root"],
        ("run-metadata.json", "git_common_dir"): metadata["git_common_dir"],
        ("09-test-evidence/qa-candidate.json", "repository_root"): candidate["repository_root"],
        ("09-test-evidence/qa-candidate.json", "git_common_dir"): candidate["git_common_dir"],
        ("09-test-evidence/qa-candidate.json", "checkout_path"): candidate["checkout_path"],
    }


def _privacy_command_cwd(repo, cwd):
    """Project `cwd` the way argv[0] and `--run` are already projected.

    The privacy report is self-scanned with NO identity bindings, and it classifies as
    `test_evidence`, a surface the `operator_home` deny category covers. So any absolute cwd beneath
    an operator home aborted seal creation with a PRIVACY_MATCH naming the sealer's own report --
    on the exact `/Users/<operator>/...` shape AC-003 exists to support, from anywhere but the
    repository root. This firm's own agents work in `.agent-firm/worktrees/...`, so that was the
    normal path, not an edge case. `repository_relative/v1` therefore covers the whole repository
    subtree, not just its root; `.` is still `.` so the pinned root case is unchanged.
    `canonical_absolute/v1` keeps its declared meaning: a cwd genuinely OUTSIDE the repository.
    """
    real_cwd = os.path.realpath(cwd)
    real_repo = os.path.realpath(repo)
    if real_cwd == real_repo:
        return ".", "repository_relative/v1"
    if real_cwd.startswith(real_repo + os.sep):
        return os.path.relpath(real_cwd, real_repo), "repository_relative/v1"
    return real_cwd, "canonical_absolute/v1"


def _privacy_command_argv(cli_argv, run, cwd):
    if not cli_argv:
        raise SealError("COMMAND_EVIDENCE", "privacy command argv is empty")
    projected = [Path(cli_argv[0]).name]
    run_relative = f".agent-firm/runs/{run.name}"
    index = 1
    while index < len(cli_argv):
        item = cli_argv[index]
        if item == "--run" and index + 1 < len(cli_argv):
            target = cli_argv[index + 1]
            absolute = target if os.path.isabs(target) else os.path.join(cwd, target)
            projected.extend((item, run_relative if os.path.realpath(absolute) == str(run) else target))
            index += 2
            continue
        if item.startswith("--run="):
            target = item[len("--run="):]
            absolute = target if os.path.isabs(target) else os.path.join(cwd, target)
            if os.path.realpath(absolute) == str(run):
                item = "--run=" + run_relative
        projected.append(item)
        index += 1
    return projected


def seal_state(run):
    run = Path(run)
    ledger_raw, _, _ = _safe_read(run, "run.jsonl", MAX_LEDGER)
    if not ledger_raw or not ledger_raw.endswith(b"\n"):
        raise SealError("LEDGER_PREFIX", "ledger is not newline-complete")
    records = []
    for number, line in enumerate(ledger_raw.splitlines(), 1):
        item = parse_json_unique(line, f"ledger line {number}")
        if not isinstance(item, dict) or item.get("run_id") != run.name:
            raise SealError("LEDGER_PREFIX", f"line {number} has foreign or missing run identity")
        records.append(item)
    marker = records[0].get("evidence_seal_protocol") if records else None
    opted = [item for item in records if item.get("event") == "evidence_seal_required"]
    final_root = run / "09-test-evidence" / "final-evidence"
    present = final_root.exists()
    if marker not in (None, "1"):
        raise SealError("PROTOCOL_VERSION", "unknown run marker")
    if opted and any(item.get("protocol") != "1" for item in opted):
        raise SealError("PROTOCOL_VERSION", "unknown opt-in marker")
    required = marker == "1" or bool(opted) or present
    if required:
        records = _ledger(ledger_raw, run.name, run / "run.jsonl")
    return {"required": required, "legacy": not required, "marker": marker,
            "opted_in": bool(opted), "records": records, "ledger_raw": ledger_raw}


def _create_seal_in_place(run_path, policy_path, cli_argv, cwd):
    privacy_started = datetime.datetime.now(datetime.timezone.utc)
    privacy_started_ns = time.monotonic_ns()
    run, repo, metadata, candidate = _identity(run_path)
    identity_bindings = _operator_home_identity_bindings(metadata, candidate)
    state = seal_state(run)
    if not state["required"]:
        raise SealError("LEGACY_NOT_OPTED_IN", "use --opt-in-legacy")
    sha = candidate["candidate_sha"]
    generation = candidate["generation"]
    bundle_rel = f"09-test-evidence/final-evidence/g{generation}"
    canonical_bundle = run / bundle_rel
    if canonical_bundle.exists():
        raise SealError("MULTIPLE_SEALS", f"generation {generation}")
    physical_bundle_rel = bundle_rel + f".staging-{os.getpid()}-{os.urandom(6).hex()}"
    bundle = run / physical_bundle_rel
    bundle.mkdir(parents=True, mode=0o700)
    os.chmod(bundle, 0o700)

    def physical(relative):
        if relative.startswith(bundle_rel + "/"):
            return physical_bundle_rel + relative[len(bundle_rel):]
        return relative

    def build_read(relative, maximum=MAX_FILE):
        return _safe_read(run, physical(relative), maximum)

    handoff_raw, _, _ = _safe_read(run, "10-handoff.md")
    pr_raw, pr_start, pr_end = extract_pr_body(handoff_raw)
    pr_rel = bundle_rel + "/complete-local-pr-body.md"
    _atomic_exclusive(run / physical(pr_rel), pr_raw)

    normalized_rel = bundle_rel + "/normalized-run-metadata.json"
    normalized = {
        "schema_version": 1, "run_id": run.name, "track": metadata.get("track"),
        "primary_provider": metadata["primary_provider"], "accepted_base_sha": metadata["accepted_base_sha"],
        "candidate_sha": sha, "generation": generation,
        "repository_identity_sha256": sha256((os.path.realpath(repo) + "\n" +
                                               os.path.realpath(str(metadata.get("git_common_dir"))) + "\n").encode()),
    }
    _atomic_exclusive(run / physical(normalized_rel), canonical_json_bytes(normalized))

    diff_rel = bundle_rel + "/candidate.diff"
    diff_argv = ["git", "-C", str(repo), "diff", "--no-ext-diff", "--no-color",
                 candidate["base_sha"], sha, "--"]
    started = time.monotonic_ns()
    done = subprocess.run(diff_argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    duration_ms = (time.monotonic_ns() - started) // 1_000_000
    if done.returncode != 0 or done.stderr:
        raise SealError("CANDIDATE_DIFF", "git diff did not complete cleanly")
    if len(done.stdout) > MAX_FILE:
        raise SealError("CANDIDATE_DIFF", "candidate diff is oversized")
    _atomic_exclusive(run / physical(diff_rel), done.stdout)

    fixed = [
        "01-acceptance-criteria.yaml", "traceability.yaml", "09-test-evidence/qa-candidate.json",
        "run-metadata.json", "run-baseline.json", "07-review-findings.yaml",
        "06-implementation-summary.md", "08-qa-verdict.json", "10-handoff.md",
        pr_rel, diff_rel, normalized_rel,
    ]
    if (run / "integration-summaries/index.json").exists():
        fixed.append("integration-summaries/index.json")
    elif (run / "integration-summary.md").exists():
        fixed.append("integration-summary.md")
    pending = list(fixed)
    declared = set(fixed)
    entries = []
    inode_paths = {}
    total = 0
    records = state["records"]
    command_artifacts = set()
    primary_raw, _, _ = _safe_read(run, "08-qa-verdict.json")
    primary_doc = parse_json_unique(primary_raw, "primary verdict")
    for item in primary_doc.get("commands_run", []):
        if isinstance(item, dict) and isinstance(item.get("artifact"), str):
            command_artifacts.add(item["artifact"])
    while pending:
        relative = pending.pop(0)
        _safe_relative(relative)
        if any(item["path"] == relative for item in entries):
            continue
        raw, mode, inode = build_read(relative)
        if inode in inode_paths:
            raise SealError("PATH_ALIAS", f"{relative} aliases {inode_paths[inode]}")
        inode_paths[inode] = relative
        total += len(raw)
        if total > MAX_ORDINARY:
            raise SealError("ORDINARY_OVERSIZE", "ordinary entry bytes exceed 8 MiB")
        value = _load_data(raw, relative)
        if relative in command_artifacts:
            _validate_command_result(value, relative, run)
        required_producer = relative in ("08-qa-verdict.json", "traceability.yaml", "10-handoff.md")
        producer = _producer(records, relative, raw, sha, generation, required_producer)
        entry = {
            "kind": "derived_file" if relative.startswith(bundle_rel + "/") else "file",
            "path": relative, "bytes": len(raw), "sha256": sha256(raw),
            "mode": f"{mode:04o}", "transform": "identity",
            "candidate_sha": sha, "generation": generation,
            "content_class": "final_evidence",
            "producer": producer,
            "referenced_by": sorted(["fixed_root"] if relative in fixed else ["transitive_reference"]),
        }
        if entry["kind"] == "derived_file":
            entry["algorithm"] = ("agent-firm-pr-body/v1" if relative == pr_rel else
                                  "agent-firm-candidate-diff/v1" if relative == diff_rel else
                                  "agent-firm-normalized-metadata/v1")
            entry["source_entries"] = (["10-handoff.md"] if relative == pr_rel else
                                       ["09-test-evidence/qa-candidate.json", "run-metadata.json"])
        entries.append(entry)
        references = _discover_references(relative, raw, value)
        references.extend(_integration_index_references(run, relative, raw, value))
        if len(references) != len(set(references)):
            raise SealError("DUPLICATE_DECLARATION", relative)
        for reference in sorted(references):
            _safe_relative(reference)
            declared.add(reference)
            if not any(item["path"] == reference for item in entries) and reference not in pending:
                pending.append(reference)
        if len(declared) > MAX_ENTRIES:
            raise SealError("ENTRY_BOUND", "more than 1024 entries")

    policy_raw = Path(policy_path).read_bytes()
    policy = parse_json_unique(policy_raw, "privacy policy")
    patterns = _privacy_patterns(policy)
    scanned = []
    for entry in entries:
        raw, _, _ = build_read(entry["path"])
        scanned.append(_scan(raw, entry["path"], patterns, identity_bindings))
    ledger_scan = _scan(state["ledger_raw"], "run.jsonl#prefix", patterns)
    scanned.append(ledger_scan)
    privacy_rel = bundle_rel + "/privacy.json"
    privacy_command_finished = datetime.datetime.now(datetime.timezone.utc)
    projected_cwd, projected_cwd_kind = _privacy_command_cwd(repo, cwd)
    privacy = {
        "schema_version": 1, "protocol": PROTOCOL,
        "command": {
            "argv": _privacy_command_argv(cli_argv, run, cwd),
            "argv_projection": "logical_tool_and_run_relative/v1",
            "cwd": projected_cwd,
            "cwd_projection": projected_cwd_kind,
            "started_at": _format_rfc3339_ms(privacy_started),
            "finished_at": _format_rfc3339_ms(privacy_command_finished),
            "duration_ms": int((privacy_command_finished - privacy_started).total_seconds() * 1000),
            "exit_code": 0, "result": "pass",
        },
        "policy": {"path": "agent-firm/policy/evidence-privacy.yaml", "bytes": len(policy_raw), "sha256": sha256(policy_raw)},
        "categories": [item["id"] for item in policy["categories"]],
        "inputs": sorted(scanned, key=lambda item: item["path"]),
        "result": "pass", "allow_count": sum(len(item["allowances"]) for item in scanned), "deny_count": 0,
    }
    _schema_validate(privacy, "evidence-privacy.schema.json", privacy_rel)
    privacy_raw = canonical_json_bytes(privacy)
    privacy_report_scan = _scan(privacy_raw, privacy_rel, patterns)
    privacy_finished = datetime.datetime.now(datetime.timezone.utc)
    privacy_duration_ms = (time.monotonic_ns() - privacy_started_ns + 999_999) // 1_000_000
    privacy_duration_ms = max(
        privacy_duration_ms,
        int((privacy_finished - privacy_started).total_seconds() * 1000) + 1,
    )
    _atomic_exclusive(run / physical(privacy_rel), privacy_raw)
    privacy_entry = {
        "kind": "derived_file", "path": privacy_rel, "bytes": len(privacy_raw), "sha256": sha256(privacy_raw),
        "mode": "0600", "transform": "identity", "candidate_sha": sha, "generation": generation,
        "content_class": "closed_privacy_report", "producer": None,
        "referenced_by": ["seal_privacy"], "algorithm": "agent-firm-evidence-privacy/v1",
        "source_entries": sorted([item["path"] for item in entries] + ["run.jsonl#prefix"]),
    }
    entries.append(privacy_entry)
    declared.add(privacy_rel)
    entries.sort(key=lambda item: item["path"])

    ledger_entry = {
        "kind": "ledger_prefix", "path": "run.jsonl#prefix", "bytes": len(state["ledger_raw"]),
        "sha256": sha256(state["ledger_raw"]), "mode": "0600", "transform": "identity",
        "candidate_sha": sha, "generation": generation, "content_class": "ledger_prefix",
        "producer": None, "referenced_by": ["seal_ledger"], "record_count": len(records),
        "terminal_lf": True,
    }
    entries.append(ledger_entry)
    declared.add("run.jsonl#prefix")
    entries.sort(key=lambda item: item["path"])
    event_id = "evt-evidence-seal-published-g%d-%d-%s" % (generation, os.getpid(), os.urandom(6).hex())
    seal_rel = bundle_rel + "/seal.json"
    ordinary_paths = sorted(item["path"] for item in entries)
    seal = {
        "schema_version": 1, "protocol": PROTOCOL,
        "identity": {
            "run_id": run.name, "repository_root": os.path.realpath(repo),
            "git_common_dir": os.path.realpath(str(metadata["git_common_dir"])),
            "accepted_base_sha": metadata["accepted_base_sha"], "candidate_sha": sha,
            "generation": generation, "primary_provider": metadata["primary_provider"],
            "secondary_provider": "gpt" if metadata["primary_provider"] == "claude" else "claude",
        },
        "entries": entries,
        "ordinary_declared_paths": ordinary_paths,
        "ordinary_resolved_paths": ordinary_paths,
        "ordinary_declared_count": len(entries), "ordinary_resolved_count": len(entries),
        "unresolved": [], "excluded": [], "not_yet_produced": [],
        "self_count": 1, "total_count": len(entries) + 1,
        "pr_body": {"algorithm": "agent-firm-pr-body/v1", "source_path": "10-handoff.md",
                    "path": pr_rel, "start_offset": pr_start, "end_offset": pr_end,
                    "bytes": len(pr_raw), "sha256": sha256(pr_raw)},
        "privacy": {"policy_path": "agent-firm/policy/evidence-privacy.yaml", "policy_sha256": sha256(policy_raw),
                    "report_path": privacy_rel, "report_bytes": len(privacy_raw), "report_sha256": sha256(privacy_raw),
                    "report_scan": privacy_report_scan,
                    "started_at": _format_rfc3339_ms(privacy_started),
                    "finished_at": _format_rfc3339_ms(privacy_finished),
                    "duration_ms": int(privacy_duration_ms)},
        "ledger": {
            "prefix": {"bytes": len(state["ledger_raw"]), "sha256": sha256(state["ledger_raw"]),
                       "record_count": len(records), "terminal_lf": True},
            "publication": {"event_id": event_id},
            "suffix_grammar": SUFFIX_GRAMMAR,
        },
        "self": {"path": seal_rel, "protocol_version": 1, "schema_version": 1},
    }
    projection = canonical_json_bytes(seal)
    seal["self"]["projection_sha256"] = sha256(projection)
    _schema_validate(seal, "evidence-seal.schema.json", seal_rel)
    seal_raw = canonical_json_bytes(seal)
    if len(seal_raw) > 1024 * 1024:
        raise SealError("SEAL_OVERSIZE", "seal exceeds 1 MiB")
    _atomic_exclusive(run / physical(seal_rel), seal_raw)
    artifacts = []
    for relative, kind in ((pr_rel, "pr_body"), (diff_rel, "candidate_diff"),
                           (normalized_rel, "normalized_metadata"), (privacy_rel, "privacy"),
                           (seal_rel, "seal")):
        raw, _, _ = build_read(relative, 1024 * 1024 if relative.endswith((".json", ".md")) else MAX_FILE)
        artifacts.append({"path": relative, "kind": kind, "bytes": len(raw), "sha256": sha256(raw)})
    artifacts.sort(key=lambda item: item["path"])
    publication = {
        "event_id": event_id, "sha": sha, "generation": str(generation), "seal_path": seal_rel,
        "seal_sha256": sha256(seal_raw), "seal_bytes": str(len(seal_raw)),
        "projection_sha256": seal["self"]["projection_sha256"],
        "prefix_sha256": sha256(state["ledger_raw"]), "prefix_bytes": str(len(state["ledger_raw"])),
        "prefix_records": str(len(records)), "artifacts": artifacts,
    }
    os.rename(bundle, canonical_bundle)
    parent_fd = os.open(canonical_bundle.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
    return publication


def create_seal(run_path, policy_path, cli_argv, cwd):
    """Create one generation and remove any unchanged partial bundle on pre-publication failure."""
    run, _, _, candidate = _identity(run_path)
    bundle = run / "09-test-evidence" / "final-evidence" / f"g{candidate['generation']}"
    if bundle.exists():
        raise SealError("MULTIPLE_SEALS", f"generation {candidate['generation']}")
    staging_parent = bundle.parent
    staging_prefix = bundle.name + ".staging-"
    before = {item.name for item in staging_parent.iterdir()} if staging_parent.exists() else set()
    try:
        return _create_seal_in_place(run_path, policy_path, cli_argv, cwd)
    except BaseException:
        if bundle.exists() and not bundle.is_symlink() and bundle.is_dir():
            shutil.rmtree(bundle)
        if staging_parent.exists():
            for item in staging_parent.iterdir():
                if item.name not in before and item.name.startswith(staging_prefix) and item.is_dir() and not item.is_symlink():
                    shutil.rmtree(item)
        raise


def _validate_publish_record(item, seal, seal_raw, publication):
    required = {"ts", "event", "event_id", "run_id", "sha", "generation", "seal_path",
                "seal_sha256", "seal_bytes", "projection_sha256", "prefix_sha256", "prefix_bytes",
                "prefix_records", "artifacts"}
    if set(item) != required or item.get("event") != "evidence_seal_published":
        raise SealError("LEDGER_SUFFIX", "publication field set is not closed")
    expected = publication
    comparisons = {
        "event_id": expected["event_id"], "sha": seal["identity"]["candidate_sha"],
        "generation": str(seal["identity"]["generation"]), "seal_path": seal["self"]["path"],
        "seal_sha256": sha256(seal_raw), "seal_bytes": str(len(seal_raw)),
        "projection_sha256": seal["self"]["projection_sha256"],
        "prefix_sha256": seal["ledger"]["prefix"]["sha256"],
        "prefix_bytes": str(seal["ledger"]["prefix"]["bytes"]),
        "prefix_records": str(seal["ledger"]["prefix"]["record_count"]),
    }
    for key, value in comparisons.items():
        if str(item.get(key)) != str(value):
            raise SealError("LEDGER_SUFFIX", f"publication {key} mismatch")
    try:
        artifacts = parse_json_unique(item["artifacts"].encode(), "publication artifacts")
    except Exception as exc:
        raise SealError("LEDGER_SUFFIX", "publication artifacts invalid") from exc
    if artifacts != expected["artifacts"]:
        raise SealError("LEDGER_SUFFIX", "publication artifacts mismatch")


def _attempt_document(run, item):
    raw, _, _ = _safe_read(run, item["attempt"])
    value = parse_json_unique(raw, item["attempt"])
    required = {
        "schema_version": 1, "attempt_id": item["attempt_id"], "provider": item["provider"],
        "run_id": item["run_id"], "candidate_sha": item["sha"],
    }
    if not isinstance(value, dict) or any(value.get(key) != expected for key, expected in required.items()):
        raise SealError("LEDGER_SUFFIX", "attempt document identity mismatch")
    if str(value.get("generation")) != str(item["generation"]) or value.get("started_event_id") is None:
        raise SealError("LEDGER_SUFFIX", "attempt generation/start identity mismatch")
    return raw, value


def _validate_terminal_attempt(run, item, start):
    raw, attempt = _attempt_document(run, item)
    expected_status = {
        "reviewer_approve": "approve", "reviewer_block": "block", "reviewer_invalid": "invalid",
        "reviewer_timeout": "timeout", "reviewer_unavailable": "unavailable",
    }[item["event"]]
    if (attempt.get("started_event_id") != start.get("event_id")
            or attempt.get("outcome_event_id") != item.get("event_id")
            or attempt.get("status") != expected_status
            or str(attempt.get("exit_code")) != str(item.get("exit_code"))
            or item.get("sha256") != sha256(raw) or str(item.get("bytes")) != str(len(raw))):
        raise SealError("LEDGER_SUFFIX", "terminal attempt artifact/outcome mismatch")
    if item["event"] == "reviewer_unavailable" and attempt.get("trusted_reason") != item.get("reason"):
        raise SealError("LEDGER_SUFFIX", "unavailable reason mismatch")
    if "verdict" in item:
        verdict_raw, _, _ = _safe_read(run, item["verdict"])
        if (item.get("verdict_sha256") != sha256(verdict_raw)
                or str(item.get("verdict_bytes")) != str(len(verdict_raw))
                or attempt.get("verdict") != item["verdict"]
                or attempt.get("canonical") != item.get("canonical")):
            raise SealError("LEDGER_SUFFIX", "terminal verdict identity mismatch")


def _validate_suffix(run, records, seal, seal_raw, publication, phase, provider=None, attempt_id=None):
    prefix_count = seal["ledger"]["prefix"]["record_count"]
    suffix = records[prefix_count:]
    if not suffix:
        if phase == "pre-publication":
            return None
        raise SealError("LEDGER_SUFFIX", "publication is missing")
    _validate_publish_record(suffix[0], seal, seal_raw, publication)
    open_attempt = None
    for item in suffix[1:]:
        event = item.get("event")
        common = {"ts", "event", "event_id", "run_id", "provider", "generation", "sha", "attempt",
                  "attempt_id", "seal_event_id", "seal_projection_sha256"}
        if item.get("seal_event_id") != publication["event_id"] or item.get("seal_projection_sha256") != seal["self"]["projection_sha256"]:
            raise SealError("LEDGER_SUFFIX", "reviewer seal identity mismatch")
        if (str(item.get("generation")) != str(seal["identity"]["generation"]) or
                item.get("sha") != seal["identity"]["candidate_sha"] or
                item.get("provider") != seal["identity"]["secondary_provider"]):
            raise SealError("LEDGER_SUFFIX", "reviewer candidate/provider mismatch")
        if event == "reviewer_attempt_started":
            if set(item) != common or open_attempt is not None:
                raise SealError("LEDGER_SUFFIX", "duplicate/open reviewer start")
            _, attempt_doc = _attempt_document(run, item)
            if attempt_doc.get("started_event_id") != item["event_id"]:
                raise SealError("LEDGER_SUFFIX", "reviewer START artifact mismatch")
            open_attempt = item
            continue
        if event == "reviewer_attempt_abandoned":
            expected = common | {"started_event_id", "reason"}
            if (set(item) != expected or open_attempt is None or item.get("attempt_id") != open_attempt.get("attempt_id") or
                    item.get("started_event_id") != open_attempt.get("event_id") or item.get("reason") != "wrapper_death_before_terminal"):
                raise SealError("LEDGER_SUFFIX", "invalid abandoned attempt")
            _, attempt_doc = _attempt_document(run, item)
            if attempt_doc.get("status") != "started" or attempt_doc.get("outcome_event_id") is not None:
                raise SealError("LEDGER_SUFFIX", "abandoned attempt artifact is not open")
            open_attempt = None
            continue
        terminal_base = common | {"exit_code", "sha256", "bytes"}
        terminal_shapes = {
            "reviewer_approve": (terminal_base | {"phase", "verdict", "canonical", "verdict_sha256", "verdict_bytes"},),
            "reviewer_block": (terminal_base | {"phase"}, terminal_base | {"phase", "verdict", "canonical", "verdict_sha256", "verdict_bytes"}),
            "reviewer_invalid": (terminal_base | {"phase"},),
            "reviewer_timeout": (terminal_base | {"phase"},),
            "reviewer_unavailable": (terminal_base | {"reason"},),
        }
        if event in terminal_shapes:
            if (set(item) not in terminal_shapes[event] or open_attempt is None
                    or item.get("attempt_id") != open_attempt.get("attempt_id")):
                raise SealError("LEDGER_SUFFIX", "invalid reviewer terminal")
            expected_exit = "0" if event == "reviewer_approve" else "3" if event == "reviewer_unavailable" else "1"
            if str(item.get("exit_code")) != expected_exit:
                raise SealError("LEDGER_SUFFIX", "reviewer terminal exit mismatch")
            if event in ("reviewer_approve", "reviewer_block") and item.get("phase") != "judge":
                raise SealError("LEDGER_SUFFIX", "reviewer verdict phase mismatch")
            _validate_terminal_attempt(run, item, open_attempt)
            open_attempt = None
            continue
        raise SealError("LEDGER_SUFFIX", f"unexpected event {event}")
    if phase == "reviewer-snapshot":
        if open_attempt is None:
            raise SealError("LEDGER_SUFFIX", "snapshot lacks current reviewer start")
        if provider is not None and open_attempt.get("provider") != provider:
            raise SealError("LEDGER_SUFFIX", "snapshot provider mismatch")
        if attempt_id is not None and open_attempt.get("attempt_id") != attempt_id:
            raise SealError("LEDGER_SUFFIX", "snapshot attempt mismatch")
    elif phase == "wrapper-preflight":
        pass
    elif open_attempt is not None:
        raise SealError("LEDGER_SUFFIX", "prior reviewer start is not terminal/abandoned")
    return open_attempt


def verify_seal(run_path, policy_path, phase="publication", provider=None, attempt_id=None):
    run, repo, metadata, candidate = _identity(run_path)
    identity_bindings = _operator_home_identity_bindings(metadata, candidate)
    state = seal_state(run)
    if not state["required"]:
        return {"schema_version": 1, "state": "legacy_unsealed", "manifest_version": 3,
                "run_id": run.name}
    generation = candidate["generation"]
    seal_rel = f"09-test-evidence/final-evidence/g{generation}/seal.json"
    seal_raw, _, _ = _safe_read(run, seal_rel, 1024 * 1024)
    seal = parse_canonical_json(seal_raw, "final evidence seal")
    _schema_validate(seal, "evidence-seal.schema.json", seal_rel)
    top_keys = {"schema_version", "protocol", "identity", "entries", "ordinary_declared_paths",
                "ordinary_resolved_paths", "ordinary_declared_count", "ordinary_resolved_count",
                "unresolved", "excluded", "not_yet_produced", "self_count", "total_count",
                "pr_body", "privacy", "ledger", "self"}
    if set(seal) != top_keys or seal.get("schema_version") != 1 or seal.get("protocol") != PROTOCOL:
        raise SealError("SEAL_SCHEMA", "top-level shape/version mismatch")
    if (seal["identity"].get("run_id") != run.name or seal["identity"].get("candidate_sha") != candidate["candidate_sha"] or
            seal["identity"].get("generation") != generation or seal["identity"].get("accepted_base_sha") != metadata["accepted_base_sha"] or
            seal["identity"].get("primary_provider") != metadata["primary_provider"]):
        raise SealError("SEAL_IDENTITY", "run/candidate identity mismatch")
    self_value = seal.get("self")
    if not isinstance(self_value, dict) or set(self_value) != {"path", "protocol_version", "schema_version", "projection_sha256"}:
        raise SealError("SELF_PROJECTION", "self descriptor shape invalid")
    projected = json.loads(json.dumps(seal))
    projection_digest = projected["self"].pop("projection_sha256")
    if projection_digest != sha256(canonical_json_bytes(projected)) or self_value["path"] != seal_rel:
        raise SealError("SELF_PROJECTION", "projection digest mismatch")
    entries = seal.get("entries")
    if not isinstance(entries, list) or not entries or len(entries) > MAX_ENTRIES:
        raise SealError("SEAL_ENTRIES", "entry set invalid")
    paths = [item.get("path") for item in entries if isinstance(item, dict)]
    if paths != sorted(paths) or len(paths) != len(entries) or len(set(paths)) != len(paths):
        raise SealError("SEAL_ENTRIES", "entry paths are unsorted/duplicated")
    if (seal["ordinary_declared_paths"] != paths or seal["ordinary_resolved_paths"] != paths or
            seal["ordinary_declared_count"] != len(paths) or seal["ordinary_resolved_count"] != len(paths) or
            seal["self_count"] != 1 or seal["total_count"] != len(paths) + 1 or
            seal["unresolved"] or seal["excluded"]):
        raise SealError("SEAL_ACCOUNTING", "declared/resolved/self counts disagree")
    for entry in entries:
        if entry["kind"] == "ledger_prefix":
            continue
        raw, mode, _ = _safe_read(run, entry["path"])
        if entry.get("bytes") != len(raw) or entry.get("sha256") != sha256(raw) or entry.get("mode") != f"{mode:04o}":
            raise SealError("ARTIFACT_STALE", entry["path"])
    handoff_raw, _, _ = _safe_read(run, "10-handoff.md")
    pr_raw, start, end = extract_pr_body(handoff_raw)
    pr = seal["pr_body"]
    materialized, _, _ = _safe_read(run, pr["path"])
    if materialized != pr_raw or pr.get("start_offset") != start or pr.get("end_offset") != end or pr.get("sha256") != sha256(pr_raw):
        raise SealError("PR_BODY_STALE", "materialized PR body differs")
    policy_raw = Path(policy_path).read_bytes()
    if sha256(policy_raw) != seal["privacy"].get("policy_sha256"):
        raise SealError("PRIVACY_STALE", "policy digest differs")
    patterns = _privacy_patterns(parse_json_unique(policy_raw, "privacy policy"))
    privacy_raw, _, _ = _safe_read(run, seal["privacy"]["report_path"], 1024 * 1024)
    privacy_doc = parse_canonical_json(privacy_raw, "privacy report")
    _schema_validate(privacy_doc, "evidence-privacy.schema.json", seal["privacy"]["report_path"])
    if (len(privacy_raw) != seal["privacy"]["report_bytes"]
            or sha256(privacy_raw) != seal["privacy"]["report_sha256"]
            or _scan(privacy_raw, seal["privacy"]["report_path"], patterns) != seal["privacy"]["report_scan"]):
        raise SealError("PRIVACY_STALE", "privacy report identity/scan differs")
    privacy_started_at = _parse_rfc3339_utc(seal["privacy"]["started_at"], "privacy started_at")
    privacy_finished_at = _parse_rfc3339_utc(seal["privacy"]["finished_at"], "privacy finished_at")
    if (privacy_finished_at < privacy_started_at
            or seal["privacy"]["duration_ms"] < int((privacy_finished_at - privacy_started_at).total_seconds() * 1000)):
        raise SealError("PRIVACY_STALE", "privacy duration does not cover operation")
    for entry in entries:
        if entry["kind"] != "ledger_prefix":
            raw, _, _ = _safe_read(run, entry["path"])
            _scan(raw, entry["path"], patterns, identity_bindings)
    prefix_bytes = seal["ledger"]["prefix"]["bytes"]
    current_raw, _, _ = _safe_read(run, "run.jsonl", MAX_LEDGER)
    if current_raw[:prefix_bytes] != state["ledger_raw"][:prefix_bytes] or sha256(current_raw[:prefix_bytes]) != seal["ledger"]["prefix"]["sha256"]:
        raise SealError("LEDGER_PREFIX", "sealed prefix changed")
    records = _ledger(current_raw, run.name, run / "run.jsonl")
    bundle_rel = f"09-test-evidence/final-evidence/g{generation}"
    expected_artifacts = []
    for relative, kind in ((seal["pr_body"]["path"], "pr_body"),
                           (bundle_rel + "/candidate.diff", "candidate_diff"),
                           (bundle_rel + "/normalized-run-metadata.json", "normalized_metadata"),
                           (seal["privacy"]["report_path"], "privacy"), (seal_rel, "seal")):
        raw, _, _ = _safe_read(run, relative, 1024 * 1024 if relative.endswith((".json", ".md")) else MAX_FILE)
        expected_artifacts.append({"path": relative, "kind": kind, "bytes": len(raw), "sha256": sha256(raw)})
    expected_artifacts.sort(key=lambda item: item["path"])
    publication = {"event_id": seal["ledger"]["publication"]["event_id"], "artifacts": expected_artifacts}
    open_attempt = _validate_suffix(run, records, seal, seal_raw, publication, phase, provider, attempt_id)
    receipt = {
        "schema_version": 1, "state": "sealed", "manifest_version": 4,
        "run_id": run.name, "candidate_sha": candidate["candidate_sha"], "generation": generation,
        "seal_path": seal_rel, "seal_sha256": sha256(seal_raw), "seal_bytes": len(seal_raw),
        "projection_sha256": self_value["projection_sha256"],
        "publication_event_id": seal["ledger"]["publication"]["event_id"],
        "ordinary_paths": paths, "ordinary_count": len(paths), "total_count": len(paths) + 1,
        "pr_body": pr, "ledger_prefix": seal["ledger"]["prefix"],
    }
    if open_attempt is not None:
        receipt["open_attempt"] = {
            key: open_attempt[key] for key in ("event_id", "provider", "generation", "sha", "attempt", "attempt_id")
        }
    return receipt


def manifest_v4_fields(receipt, seen_origins, provider):
    """Derive the sealed fields for reviewer manifest v4 from copied origins."""
    if receipt.get("state") != "sealed" or receipt.get("manifest_version") != 4:
        raise SealError("MANIFEST_VERSION", "manifest v4 requires a verified seal receipt")
    if provider not in ("gpt", "claude"):
        raise SealError("MANIFEST_PROVIDER", "provider is invalid")
    sealed_paths = list(receipt["ordinary_paths"])
    resolved_paths = sorted(origin for origin in sealed_paths
                            if origin == "run.jsonl#prefix" or origin in seen_origins)
    if resolved_paths != sealed_paths:
        missing = sorted(set(sealed_paths) - set(resolved_paths))
        raise SealError("MANIFEST_OMISSION", missing[0] if missing else "sealed set mismatch")
    return {
        "seal": {
            "path": receipt["seal_path"], "sha256": receipt["seal_sha256"],
            "bytes": receipt["seal_bytes"], "projection_sha256": receipt["projection_sha256"],
            "publication_event_id": receipt["publication_event_id"],
        },
        "sealed_ordinary_paths": sealed_paths,
        "sealed_declared_count": receipt["ordinary_count"],
        "sealed_resolved_count": len(resolved_paths),
        "sealed_self_count": 1,
        "sealed_total_count": receipt["total_count"],
        "pr_body": receipt["pr_body"],
        "ledger_prefix": receipt["ledger_prefix"],
        "not_yet_produced": [{
            "origin_path": f"08-qa-verdict.{provider}.json",
            "reason": "current_secondary_verdict_is_structurally_future",
        }],
    }
