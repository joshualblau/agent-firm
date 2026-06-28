# Hardened sandbox for the firm. Pinned base = reproducible runtime AND stable visual-test rendering.
# Phase 0: project-only mount, non-root user, pinned image, no host secrets.
# Phase 5: add the egress firewall (see egress-firewall.sh) and cap-drop tightening.
FROM node:20-bookworm-slim@sha256:6e2c6e0e1a7e0e9b0e3f4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c

# Minimal toolchain the firm needs (git, jq, python for schema validation, ca-certs).
RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq python3 python3-pip ca-certificates curl \
 && pip3 install --no-cache-dir --break-system-packages jsonschema \
 && rm -rf /var/lib/apt/lists/*

# Non-root user — agents operate without host privileges.
ARG USERNAME=firm
RUN useradd -m -s /bin/bash "$USERNAME"
USER ${USERNAME}
WORKDIR /workspace

# NOTE: the pinned base digest above is a placeholder example — pin to a real digest
# (`docker pull node:20-bookworm-slim && docker inspect ...`) when you build for real.
