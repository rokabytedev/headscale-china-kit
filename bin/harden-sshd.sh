#!/usr/bin/env bash
# harden-sshd.sh — land "traditional sshd, public-key only" and turn OFF tailscale-ssh on this device.
# Implements the core of the security model: once the VPS/control plane is compromised, an attacker who
# is in the tailnet but lacks your SSH private key still cannot log in here.
#
# IRREVERSIBLE-RISK NOTE: changing sshd can lock you out. This script does NOT restart sshd or change
#   network state on its own — it generates the config + self-checks, then prints the commands for you
#   to run after confirming. ALWAYS keep an escape hatch open (a second terminal, a local console, or
#   the provider's web console) until you've verified you can still log in.
#
# Env (optional):
#   SSH_USER         login user for the self-test hint (default: current user)
#   ALLOW_SRC        space-separated tailnet IPs allowed to reach :22 (for the optional iptables hints)
set -euo pipefail
SSH_USER="${SSH_USER:-$(id -un)}"
ALLOW_SRC="${ALLOW_SRC:-}"

echo "== 1) Turn off tailscale-ssh (switch to traditional sshd) =="
echo "    will run: tailscale set --ssh=false"
echo "    (printed only — see the summary at the end; not auto-run since it can interrupt the network)"

echo "== 2) Confirm the keys that should be allowed in are already in ~/.ssh/authorized_keys =="
if [[ -f ~/.ssh/authorized_keys ]]; then
  awk '{print "    - "$1, substr($2,1,20)"...", $3}' ~/.ssh/authorized_keys
else
  echo "    MISSING authorized_keys — add your laptop/phone PUBLIC keys FIRST, or you'll be locked out"
  echo "    after tailscale-ssh is disabled."
fi

echo "== 3) Generate hardened sshd drop-in (pubkey only) =="
# Note: if sshd is socket-activated (systemd ssh.socket, or launchd on macOS), sshd_config's
# ListenAddress is ignored. So we do NOT set ListenAddress here; restrict "who can reach :22" at
# the network layer instead — via the tailnet tag ACL, and optionally local iptables (below).
cat > /tmp/99-tailnet-hardening.conf <<'EOF'
# headscale-china-kit: pubkey-only sshd (the load-bearing wall)
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
echo "    wrote /tmp/99-tailnet-hardening.conf:"
sed 's/^/      /' /tmp/99-tailnet-hardening.conf

echo "== 4) (Optional, Linux) local firewall: allow only your own devices' tailnet IPs to :22 =="
if [[ -n "$ALLOW_SRC" ]]; then
  for ip in $ALLOW_SRC; do
    echo "      iptables -A INPUT -i tailscale0 -p tcp --dport 22 -s ${ip} -j ACCEPT"
  done
  echo "      iptables -A INPUT -i tailscale0 -p tcp --dport 22 -j DROP"
else
  echo "      (set ALLOW_SRC=\"100.64.0.x 100.64.0.y\" to print per-source iptables rules)"
fi

cat <<NEXT

== Run manually after confirming (keep an escape-hatch terminal open) ==
  1) Ensure your laptop/phone PUBLIC keys are in ~/.ssh/authorized_keys (step 2 above)
  2) sudo cp /tmp/99-tailnet-hardening.conf /etc/ssh/sshd_config.d/
  3) sudo sshd -t && sudo systemctl restart ssh      # validate, then restart (Linux)
     (macOS: toggle Remote Login off/on in System Settings; sshd_config.d still applies)
  4) From a SEPARATE terminal, confirm you can still: ssh ${SSH_USER}@<this device's tailnet IP>
     (do NOT close your current session until this works!)
  5) Once verified: tailscale set --ssh=false
  6) Run bin/redteam-check to confirm a stranger key is rejected
NEXT
