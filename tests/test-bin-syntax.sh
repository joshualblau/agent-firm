#!/usr/bin/env bash
# Every executable in bin/ must PARSE. Nothing runs; this is `bash -n` and `python -m py_compile`.
#
# Why this exists. On 2026-08-23 a single apostrophe in a comment inside a heredoc -- a heredoc that
# happens to live inside a $(...) substitution, where bash scans for the closing paren without fully
# honouring heredoc quoting -- made bin/firm-run-evals unparseable. Bash reported the error at line
# 379, hundreds of lines from the edit, and the harness exited 2 with NO message at all, because it
# never began executing. A behavioural eval run was spent discovering that. `bash -n` on the file
# would have said so in nine milliseconds.
#
# It is deliberately the cheapest possible check on the widest possible surface: it needs no fixture,
# no provider, no network and no spend, and it covers every current and future file in bin/ without
# anyone remembering to add one.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

t_case "every executable in bin/ parses"
checked=0
for candidate in "$FIRM_ROOT"/bin/*; do
  [ -f "$candidate" ] || continue
  [ -x "$candidate" ] || continue
  name="$(basename "$candidate")"
  interpreter="$(head -1 "$candidate")"
  case "$interpreter" in
    *bash*|*/sh|*"env sh"*)
      checked=$((checked+1))
      assert_ok "bin/$name parses as shell" bash -n "$candidate" ;;
    *python*)
      checked=$((checked+1))
      assert_ok "bin/$name parses as python" python3 -m py_compile "$candidate" ;;
    *)
      _t_no "bin/$name has a recognised interpreter" "unrecognised shebang: $interpreter" ;;
  esac
done
# A loop that silently matched nothing would report a clean pass over an empty set, which is the
# failure mode this whole file is arguing against.
if [ "$checked" -ge 10 ]; then
  _t_ok "the scan covered $checked executables rather than silently matching none"
else
  _t_no "the scan covered enough executables" "only $checked matched; bin/ has $(ls "$FIRM_ROOT"/bin | wc -l | tr -d ' ') entries"
fi

t_case "the exact 2026-08-23 breakage is caught"
# An apostrophe inside the heredoc body that lives in a $(...) substitution. Reproduced against a
# COPY, so the check is proved to bite without touching a tracked file.
work="$(mktemp -d "${TMPDIR:-/tmp}/firm-bin-syntax.XXXXXX")"; t_track "$work"
python3 - "$FIRM_ROOT/bin/firm-run-evals" "$work/mutant" <<'PY'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
marker = "# tolerated, and only when real events follow it."
assert marker in source, "the anchor comment moved; update this mutant"
open(sys.argv[2], "w", encoding="utf-8").write(
    source.replace(marker, marker + "\n# reintroduce the provider" + chr(39) + "s prose apostrophe"))
PY
assert_fail "an apostrophe in that heredoc body is a parse error, not a silent exit 2" \
  bash -n "$work/mutant"

t_summary
