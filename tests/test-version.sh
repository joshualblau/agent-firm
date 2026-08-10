#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/firm-version-test.XXXXXX")"; t_track "$WORK"

mk_version_root() {
  _d="$(mktemp -d "${TMPDIR:-/tmp}/firm-version-root.XXXXXX")"; t_track "$_d"
  mkdir -p "$_d/bin" "$_d/.claude-plugin" "$_d/.codex-plugin"
  cp "$BIN/firm-version" "$_d/bin/firm-version"
  cp "$FIRM_ROOT/VERSION" "$_d/VERSION"
  cp "$FIRM_ROOT/.claude-plugin/plugin.json" "$_d/.claude-plugin/plugin.json"
  cp "$FIRM_ROOT/.codex-plugin/plugin.json" "$_d/.codex-plugin/plugin.json"
  printf '%s' "$_d"
}

hash_targets() {
  shasum -a 256 "$1/VERSION" "$1/.claude-plugin/plugin.json" "$1/.codex-plugin/plugin.json" |
    awk '{print $1}' | tr '\n' ' '
}

set_manifest_version() {
  python3 - "$1" "$2" <<'PY'
import json, sys
p, v = sys.argv[1:]
d = json.load(open(p, encoding="utf-8")); d["version"] = v
with open(p, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2); f.write("\n")
PY
}

t_case "complete SemVer and provider cachebuster validation"
V="$(mk_version_root)"
assert_ok "current canonical and provider manifests validate" "$V/bin/firm-version" --check
for bad in '01.2.3' '1.02.3' '1.2.03' '1.2' '1.2.3-' '1.2.3-alpha..1' '1.2.3-01' '1.2.3+build'; do
  R="$(mk_version_root)"; printf '%s\n' "$bad" > "$R/VERSION"
  assert_rc "canonical rejects malformed SemVer: $bad" 2 "$R/bin/firm-version" --check
done
for bad in '0.8.0+claude.' '0.8.0+claude..x' '0.8.0+claude' '0.8.0+codex.x' \
           '0.8.0+claude.x+again' '0.8.0+claude.x_y'; do
  R="$(mk_version_root)"; set_manifest_version "$R/.claude-plugin/plugin.json" "$bad"
  assert_rc "Claude manifest rejects malformed/wrong cache version: $bad" 2 "$R/bin/firm-version" --check
done
for bad in '1.2' '01.2.3' '1.2.3-' '1.2.3-alpha..1' '1.2.3-01' '1.2.3+release'; do
  R="$(mk_version_root)"
  assert_rc "release rejects malformed SemVer: $bad" 2 "$R/bin/firm-version" --release "$bad"
done
for bad in '' '.' '.x' 'x.' 'x..y' 'x_y' 'x+y'; do
  R="$(mk_version_root)"
  assert_rc "cachebuster rejects malformed identifier sequence: ${bad:-<empty>}" 2 \
    env FIRM_VERSION_SKIP_INSTALL=1 "$R/bin/firm-version" --local-refresh "$bad"
done

t_case "successful three-target release and local-refresh transactions"
R="$(mk_version_root)"
before_claude="$(cat "$R/.claude-plugin/plugin.json")"
before_codex="$(cat "$R/.codex-plugin/plugin.json")"
mode_v="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$R/VERSION")"
mode_c="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$R/.claude-plugin/plugin.json")"
assert_ok "release replaces all three targets" "$R/bin/firm-version" --release 1.2.3-rc.1
assert_eq "canonical release updated" "1.2.3-rc.1" "$(tr -d '\n' < "$R/VERSION")"
assert_output "Claude release updated" '"version": "1.2.3-rc.1"' cat "$R/.claude-plugin/plugin.json"
assert_output "Codex release updated" '"version": "1.2.3-rc.1"' cat "$R/.codex-plugin/plugin.json"
assert_eq "VERSION mode preserved" "$mode_v" "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$R/VERSION")"
assert_eq "manifest mode preserved" "$mode_c" "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$R/.claude-plugin/plugin.json")"
assert_ok "local refresh stages VERSION and both manifests" env FIRM_VERSION_SKIP_INSTALL=1 \
  "$R/bin/firm-version" --local-refresh cache.007-alpha
assert_output "Claude gets its exact cachebuster" '"version": "1.2.3-rc.1+claude.cache.007-alpha"' cat "$R/.claude-plugin/plugin.json"
assert_output "Codex gets its exact cachebuster" '"version": "1.2.3-rc.1+codex.cache.007-alpha"' cat "$R/.codex-plugin/plugin.json"
assert_eq "canonical stays at the release base" "1.2.3-rc.1" "$(tr -d '\n' < "$R/VERSION")"
assert_ok "unrelated Claude manifest bytes survive the targeted version replacement" python3 -c \
  "a='''$before_claude'''; b=open('$R/.claude-plugin/plugin.json').read(); assert a.replace('0.8.0','TOKEN') == b.replace('1.2.3-rc.1+claude.cache.007-alpha','TOKEN').rstrip('\\n')"
assert_ok "unrelated Codex manifest bytes survive the targeted version replacement" python3 -c \
  "a='''$before_codex'''; b=open('$R/.codex-plugin/plugin.json').read(); assert a.replace('0.8.0','TOKEN') == b.replace('1.2.3-rc.1+codex.cache.007-alpha','TOKEN').rstrip('\\n')"

t_case "preflight failures write nothing"
for target in version claude codex; do
  R="$(mk_version_root)"
  case "$target" in
    version) path="$R/VERSION" ;;
    claude) path="$R/.claude-plugin/plugin.json" ;;
    codex) path="$R/.codex-plugin/plugin.json" ;;
  esac
  before="$(hash_targets "$R")"
  chmod 000 "$path"
  assert_rc "unreadable $target target is rejected" 2 "$R/bin/firm-version" --release 1.2.3
  chmod 644 "$path"
  assert_eq "unreadable $target leaves every byte unchanged" "$before" "$(hash_targets "$R")"

  chmod 444 "$path"
  assert_rc "unwritable $target target is rejected" 2 "$R/bin/firm-version" --release 1.2.3
  chmod 644 "$path"
  assert_eq "unwritable $target leaves every byte unchanged" "$before" "$(hash_targets "$R")"
done
R="$(mk_version_root)"; before="$(hash_targets "$R")"; chmod 500 "$R/.codex-plugin"
assert_rc "unwritable target directory is rejected even for a privileged test user" 2 \
  "$R/bin/firm-version" --release 1.2.3
chmod 700 "$R/.codex-plugin"
assert_eq "unwritable directory leaves every byte unchanged" "$before" "$(hash_targets "$R")"

t_case "every staged-write and rename failure restores all original bytes"
for point in stage:version stage:claude stage:codex rename:version rename:claude rename:codex; do
  R="$(mk_version_root)"; before="$(hash_targets "$R")"
  assert_rc "$point fails the source transaction" 1 env FIRM_VERSION_TESTING=1 \
    FIRM_VERSION_TEST_FAIL_POINT="$point" "$R/bin/firm-version" --release 2.0.0
  assert_eq "$point restores VERSION and both manifests byte-for-byte" "$before" "$(hash_targets "$R")"
  assert_eq "$point leaves no staged files" "0" \
    "$(find "$R" -name '.firm-version.*.tmp' -type f | wc -l | tr -d ' ')"
done

t_case "paired cache refresh is claimed only after bootstrap succeeds"
R="$(mk_version_root)"; before="$(hash_targets "$R")"
printf '#!/bin/sh\nprintf "fixture bootstrap failed\\n" >&2\nexit 7\n' > "$R/bin/firm-bootstrap"; chmod +x "$R/bin/firm-bootstrap"
assert_rc "failed bootstrap propagates its status" 7 "$R/bin/firm-version" --local-refresh pending
assert_eq "failed cache refresh restores all source bytes" "$before" "$(hash_targets "$R")"
assert_output "failure reports source recovery" "RECOVERY COMPLETE" "$R/bin/firm-version" --local-refresh pending

R="$(mk_version_root)"; BLOG="$R/bootstrap.log"
printf '#!/bin/sh\nprintf "called\\n" >> "$FIRM_VERSION_BOOTSTRAP_LOG"\nexit 0\n' > "$R/bin/firm-bootstrap"; chmod +x "$R/bin/firm-bootstrap"
assert_ok "successful bootstrap completes the paired refresh" env FIRM_VERSION_BOOTSTRAP_LOG="$BLOG" \
  "$R/bin/firm-version" --local-refresh ready
assert_eq "bootstrap ran exactly once" "1" "$(wc -l < "$BLOG" | tr -d ' ')"
assert_ok "post-refresh versions check" "$R/bin/firm-version" --check

t_summary
