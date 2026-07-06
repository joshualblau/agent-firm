#!/usr/bin/env bash
# Re-resolve CDN-fronted hosts and top-up the ipset. Mitigation (a) for the rotating Cloudflare IPs of
# the OpenAI/Codex endpoints. Run every ~2 min (cron/systemd timer) ONLY if you use option (a) in
# egress-allowlist.conf. The set only GROWS here (stale IPs linger); re-run egress-firewall.sh to prune.
set -euo pipefail
for domain in chatgpt.com api.openai.com auth.openai.com; do
  dig +noall +answer A "$domain" | awk '$4=="A"{print $5}' | while read -r ip; do
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && ipset add allowed-domains "$ip" -exist
  done
done
# Cron form (install only if you opt in):
#   */2 * * * * root /workspace/.devcontainer/refresh-cdn-allowlist.sh >/dev/null 2>&1
