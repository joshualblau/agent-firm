#!/usr/bin/env bash
# Default-deny outbound egress with an allowlist, for the firm's hardened sandbox.
# OPT-IN: needs NET_ADMIN + NET_RAW (see devcontainer.json). Runs INSIDE the container (Debian bash).
#
# Threat model: a prompt-injected/compromised agent should not be able to phone home or exfiltrate.
# Default OUTPUT policy is DROP; only DNS + established + an explicit allowlist (on 80/443) get out.
#
# FAILS SAFE: if the firewall can't be built, this exits non-zero and the container start fails loudly
# — it never silently boots with open networking.
#
# Wire as a devcontainer `postStartCommand` (re-applies every start; iptables state is not persisted).
set -euo pipefail
IFS=$'\n\t'
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="${SELF}/egress-allowlist.conf"   # per-project host/CIDR allowlist (format documented below)

# 0. Require capabilities; fail SAFE if missing (do NOT silently boot open).
if ! iptables -L >/dev/null 2>&1; then
  echo "ERROR: iptables unavailable (missing NET_ADMIN?). Add --cap-add=NET_ADMIN --cap-add=NET_RAW." >&2
  echo "       Refusing to boot without egress control." >&2
  exit 1
fi

# 1. Preserve Docker's embedded DNS (127.0.0.11) NAT rules BEFORE flushing, else name resolution dies.
DOCKER_DNS_RULES="$(iptables-save -t nat | grep '127\.0\.0\.11' || true)"
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
if [ -n "$DOCKER_DNS_RULES" ]; then
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# 2. Baseline allows BEFORE flipping to DROP: DNS, SSH, loopback.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
ipset create allowed-domains hash:net

# 3. GitHub published CIDRs (web+api+git covers github.com, api.github.com, clone/push over https).
gh_ranges="$(curl -s https://api.github.com/meta)"
[ -z "$gh_ranges" ] && { echo "ERROR: failed to fetch GitHub /meta" >&2; exit 1; }
echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null \
  || { echo "ERROR: GitHub /meta missing web/api/git" >&2; exit 1; }
while read -r cidr; do
  [[ "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] \
    || { echo "ERROR: bad CIDR from GitHub meta: $cidr" >&2; exit 1; }
  ipset add allowed-domains "$cidr" -exist
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q 2>/dev/null || echo "$gh_ranges" | jq -r '(.web + .api + .git)[]')
# NOTE: IPv4-only regex; an IPv6 CIDR in /meta would abort (web/api/git are IPv4 today). `aggregate`
# (apt package) coalesces ranges; the `|| echo` fallback runs unaggregated if aggregate is absent.

# 4. Resolve static allowlist hosts (from egress-allowlist.conf) at startup.
#    Directives: `host <fqdn>` resolve+add A records; `cidr <a.b.c.d/nn>` add literally; `# ...` comment.
if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs || true)"; [ -z "$line" ] && continue
    kind="${line%% *}"; val="${line#* }"
    case "$kind" in
      cidr) ipset add allowed-domains "$val" -exist ;;
      host)
        ips="$(dig +noall +answer A "$val" | awk '$4=="A"{print $5}')"
        [ -z "$ips" ] && { echo "ERROR: failed to resolve $val" >&2; exit 1; }
        while read -r ip; do
          [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "ERROR: bad IP $ip" >&2; exit 1; }
          ipset add allowed-domains "$ip" -exist
        done < <(echo "$ips") ;;
      *) echo "WARN: unknown allowlist directive: $line" >&2 ;;
    esac
  done < "$ALLOWLIST"
fi

# 5. Allow the Docker host / LAN gateway (approx /24 off the default route) for host-service access.
HOST_IP="$(ip route | grep default | cut -d' ' -f3)"
if [ -n "$HOST_IP" ]; then
  HOST_NET="$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')"
  iptables -A INPUT  -s "$HOST_NET" -j ACCEPT
  iptables -A OUTPUT -d "$HOST_NET" -j ACCEPT
fi

# 6. Flip to default-deny; allow established + allowlisted dst on 80/443 only; LOG+DROP the rest.
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -p tcp -m multiport --dports 80,443 -j ACCEPT
# Hostile-agent posture: silently DROP (an agent's exfil attempt hangs/times out) + a rate-limited LOG
# for audit. Swap the DROP below for `-j REJECT --reject-with icmp-admin-prohibited` if you prefer fast
# failures during legit misconfig debugging (trades away the "exfil stalls silently" property).
iptables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "EGRESS-DENY: " --log-level 4
iptables -A OUTPUT -j DROP

# 7. Fail-SAFE verify: a blocked host MUST fail; an allowed host MUST succeed. Else exit 1.
if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
  echo "ERROR: firewall verify FAILED — reached un-allowlisted example.com" >&2; exit 1
fi
if ! curl --connect-timeout 5 -s https://api.github.com/zen >/dev/null 2>&1; then
  echo "ERROR: firewall verify FAILED — cannot reach allowlisted api.github.com" >&2; exit 1
fi
echo "egress-firewall: default-deny active; allowlist enforced; verify passed."
