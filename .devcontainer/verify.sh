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

# --- Egress firewall proof (only if enforcing; opt-in) ---
if ipset list allowed-domains >/dev/null 2>&1; then
  echo "egress firewall: ACTIVE"
  if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    echo "FAIL egress: reached un-allowlisted example.com (firewall NOT enforcing deny)"; exit 1
  else
    echo "ok   egress: example.com blocked as expected"
  fi
  curl --connect-timeout 5 -s -o /dev/null -w "ok   egress: api.anthropic.com reachable (HTTP %{http_code})\n" \
    https://api.anthropic.com/v1/models || echo "WARN egress: api.anthropic.com unreachable"
else
  echo "egress firewall: not active (opt-in — add NET_ADMIN/NET_RAW caps + the postStartCommand to enable)"
fi
echo "sandbox verify complete."
