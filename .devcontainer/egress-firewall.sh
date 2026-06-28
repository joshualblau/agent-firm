#!/usr/bin/env bash
# Phase 5 stub — default-deny outbound egress with an allowlist.
# Wire as a devcontainer postStartCommand once you add "--cap-add=NET_ADMIN" to runArgs.
# This bounds prompt-injection blast radius: even if an agent is tricked, it can't phone home.
#
# Allowlist (edit per project): package registries + model/provider endpoints + your git host.
#   registry.npmjs.org, pypi.org, files.pythonhosted.org,
#   api.anthropic.com, api.openai.com, chatgpt.com (Codex auth),
#   github.com, codeload.github.com
#
# Implementation sketch (Debian, requires iptables + NET_ADMIN):
#   - default OUTPUT policy DROP
#   - ACCEPT loopback + established/related
#   - resolve allowlisted hosts, ACCEPT their IPs on 443/80
#   - DROP everything else; log drops
#
# Left as a documented stub for Phase 0 so the sandbox boots without elevated networking caps.
echo "egress-firewall: Phase 5 stub — not yet enforcing. See comments to enable."
exit 0
