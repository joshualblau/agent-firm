#!/usr/bin/env bash
# Sanity-check the sandbox after creation. Confirms non-root + the firm toolchain, and that no
# obvious host secret paths leaked into the container.
set -uo pipefail
echo "user: $(id -un) (uid $(id -u))   [expected: firm, non-zero uid]"
for t in git jq python3 node; do
  command -v "$t" >/dev/null 2>&1 && echo "ok   $t $("$t" --version 2>/dev/null | head -1)" || echo "MISSING $t"
done
python3 -c "import jsonschema; print('ok   jsonschema', jsonschema.__version__)" 2>/dev/null || echo "MISSING jsonschema"
for leak in "$HOME/.ssh" "$HOME/.aws" "$HOME/.codex/auth.json" "$HOME/.claude.json"; do
  [[ -e "$leak" ]] && echo "WARN host secret present in container: $leak" || true
done
echo "sandbox verify complete."
