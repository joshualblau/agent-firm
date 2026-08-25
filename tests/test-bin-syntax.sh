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
# WHICH BASH PARSES THE MUTANT MATTERS, and the original form of this case did not say so.
# The 2026-08-23 breakage is a bash 3.2 parser limitation: an apostrophe inside a heredoc body that
# lives in a $(...) substitution terminates the quote early THERE, and does not on bash 4+. Measured:
# bash 3.2.57 rejects it (rc 2) and bash 5.3.15 parses the same bytes clean. The exact 3.2 wording
# is `unexpected EOF while looking for matching "'"` followed by `syntax error: unexpected end of
# file` -- NOT the `unexpected token '('` this comment claimed before it was checked, which matters
# because it is the message a future reader will be grepping for. Re-measured against the mutant
# this case builds. The limitation is also narrower than "an apostrophe": 3.2 does track double
# quotes, so it breaks only on an apostrophe OUTSIDE a double-quoted span -- which is exactly what
# the mutant appends, and exactly what the editor note in bin/firm-run-evals now says. Asserting the failure against whatever `bash` happens to be first on PATH therefore pins a
# platform behaviour as if it were universal — it passes on the macOS 3.2 leg and can NEVER pass on
# a Linux runner, which is what turned this suite red on ubuntu.
#
# macOS Bash 3.2 is a supported target, so the check is worth keeping. It is run against a bash that
# actually exhibits the limitation, and where none is available it SKIPS OUT LOUD rather than passing
# quietly — an assertion that cannot fail is worse than one that is visibly not run.
bash32=""
for _b in /bin/bash "$(command -v bash 2>/dev/null)"; do
  [ -n "$_b" ] && [ -x "$_b" ] || continue
  case "$("$_b" --version 2>/dev/null | head -1)" in *"version 3."*) bash32="$_b"; break ;; esac
done
if [ -n "$bash32" ]; then
  assert_fail "an apostrophe in that heredoc body is a parse error under bash 3.2, not a silent exit 2" \
    "$bash32" -n "$work/mutant"
else
  printf '      SKIP (no bash 3.2 on this host; the 2026-08-23 heredoc breakage was NOT checked)\n'
fi

t_summary
