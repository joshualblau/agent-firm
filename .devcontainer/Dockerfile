# Hardened sandbox for the firm. Pinned base = reproducible runtime AND stable visual-test rendering.
# Phase 0: project-only mount, non-root user, pinned image, no host secrets.
# Phase 5: add the egress firewall (see egress-firewall.sh) and cap-drop tightening.
FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0

# Minimal toolchain the firm needs (git, jq, python for schema validation, ca-certs) plus the egress
# firewall tooling (iptables/ipset/iproute2/dnsutils/aggregate) and sudo for the scoped firewall grant.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq python3 python3-pip ca-certificates curl \
      iptables ipset iproute2 dnsutils aggregate sudo \
 && pip3 install --no-cache-dir --break-system-packages jsonschema pyyaml \
 && rm -rf /var/lib/apt/lists/*

# Non-root user — agents operate without host privileges.
ARG USERNAME=firm
RUN useradd -m -s /bin/bash "$USERNAME"

# Ship the egress firewall + a NOPASSWD sudoers grant scoped to ONLY the firewall scripts (Phase 5).
# The firewall is OPT-IN (enabled via devcontainer.json postStartCommand + NET_ADMIN/NET_RAW caps).
COPY egress-firewall.sh refresh-cdn-allowlist.sh egress-allowlist.conf /workspace/.devcontainer/
RUN chmod +x /workspace/.devcontainer/egress-firewall.sh /workspace/.devcontainer/refresh-cdn-allowlist.sh \
 && printf '%s\n' "${USERNAME} ALL=(root) NOPASSWD: /workspace/.devcontainer/egress-firewall.sh, /workspace/.devcontainer/refresh-cdn-allowlist.sh" \
      > /etc/sudoers.d/firm-firewall \
 && chmod 0440 /etc/sudoers.d/firm-firewall

USER ${USERNAME}
WORKDIR /workspace

# The pinned base digest above is the real multi-arch index digest for node:20-bookworm-slim
# (resolved from Docker Hub 2026-07-06). Refresh it deliberately when you want a newer base:
#   TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/node:pull" | jq -r .token)
#   curl -sI -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.oci.image.index.v1+json" \
#     https://registry-1.docker.io/v2/library/node/manifests/20-bookworm-slim | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
# NOTE: this is a node base, NOT a Playwright browser image — run visual-regression tests in a
# version-matched mcr.microsoft.com/playwright image (see docs/PHASE5.md, "Visual regression").
