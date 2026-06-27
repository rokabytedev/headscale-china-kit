#!/usr/bin/env bash
# install-headscale.sh — one-shot hardened Headscale + built-in DERP on a fresh VPS (Ubuntu 22.04/24.04).
#
# Usage (run on the VPS as root, with the two .tmpl files sitting next to this script):
#   HS_HOSTNAME=hs.example.com VPS_IP=<public-ip> HS_USER=<name> \
#     [HOMEBASE_TAILNET_IP=100.64.0.10] [ADMIN_PUBKEY="ssh-ed25519 AAAA... mgmt"] bash install-headscale.sh
#
# Prereq: DNS A record  $HS_HOSTNAME -> this VPS's public IP  is already live (DNS-only / no proxy).
#         (TLS-ALPN-01 issues the cert over 443.)
#
# Security (hardened by design): only 443 is public; Headscale version is pinned; the data dir is
#   owned by the headscale user; STUN is not exposed publicly; no long-lived/reusable keys are
#   pre-generated; SSH 22 stays open only until the VPS joins the tailnet, then the caller closes it.
set -euo pipefail

HS_HOSTNAME="${HS_HOSTNAME:?set HS_HOSTNAME, e.g. hs.example.com}"
VPS_IP="${VPS_IP:?set VPS_IP=this VPS public IP}"
HS_USER="${HS_USER:?set HS_USER=your headscale username, e.g. tailnet}"
# The tailnet IP you will PIN the home base to (used for *.pc split-DNS). Must match what you pin at
# enrollment time (see references/device-enrollment.md). Safe default; change to taste.
HOMEBASE_TAILNET_IP="${HOMEBASE_TAILNET_IP:-100.64.0.10}"
HS_VERSION="${HS_VERSION:-v0.28.0}"   # pin a known-good stable release; GitHub "latest" may be a beta
CFGDIR="/etc/headscale"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "run as root / sudo" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/headscale-config.yaml.tmpl" && -f "$SCRIPT_DIR/acl.hujson.tmpl" ]] \
  || { echo "missing headscale-config.yaml.tmpl / acl.hujson.tmpl next to this script" >&2; exit 1; }

echo "==> 1) Base packages + firewall (only 443 public; 22 temporary for management)"
apt-get update -y
apt-get install -y curl jq sqlite3 ufw ca-certificates fail2ban unattended-upgrades
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp   >/dev/null   # temporary: after the VPS joins the tailnet, restrict 22 to the tailnet
ufw allow 443/tcp  >/dev/null   # Headscale control plane + DERP-over-HTTPS (the only required public port)
# No 80 (TLS-ALPN-01 uses 443); no public 3478 (STUN bound to localhost, no fingerprint)
yes | ufw enable   >/dev/null || true
ufw status verbose || true
# sshd hardening
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
# fail2ban + automatic security updates
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 4
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1 || true
echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
# Optional: add a management public key to root so you can SSH in over the tailnet AFTER public 22 is
# closed (e.g. the home base's management key). Provider-injected keys are kept. If your provider
# disables root SSH and uses a sudo user instead, manage as that user (set VPS_SSH_USER for the watchdog).
if [[ -n "${ADMIN_PUBKEY:-}" ]]; then
  install -d -m 700 /root/.ssh
  grep -qxF "$ADMIN_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$ADMIN_PUBKEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  echo "    added ADMIN_PUBKEY to /root/.ssh/authorized_keys"
fi

echo "==> 2) Install Headscale ${HS_VERSION} (pinned)"
ARCH="$(dpkg --print-architecture)"   # amd64 / arm64
DEB="headscale_${HS_VERSION#v}_linux_${ARCH}.deb"
curl -fsSL -o "/tmp/$DEB" "https://github.com/juanfont/headscale/releases/download/${HS_VERSION}/${DEB}"
DEBIAN_FRONTEND=noninteractive apt-get install -y "/tmp/$DEB"

echo "==> 3) Land config (inject hostname / IPs / owner); data dir owned by headscale user"
mkdir -p "$CFGDIR"
install -d -o headscale -g headscale -m 0750 /var/lib/headscale
install -d -o headscale -g headscale -m 0750 /var/lib/headscale/cache
mkdir -p /var/run/headscale
sed -e "s|__HS_HOSTNAME__|${HS_HOSTNAME}|g" \
    -e "s|__VPS_IP__|${VPS_IP}|g" \
    -e "s|__HOMEBASE_TAILNET_IP__|${HOMEBASE_TAILNET_IP}|g" \
    "$SCRIPT_DIR/headscale-config.yaml.tmpl" > "$CFGDIR/config.yaml"
chmod 0644 "$CFGDIR/config.yaml"
sed -e "s|__OWNER__|${HS_USER}|g" \
    "$SCRIPT_DIR/acl.hujson.tmpl" > "$CFGDIR/acl.hujson"
chmod 0644 "$CFGDIR/acl.hujson"

echo "==> 4) Validate config"
headscale configtest || { echo "configtest failed: check Headscale version vs config schema" >&2; exit 1; }

echo "==> 4.5) Fix data-dir ownership (REQUIRED — easy to miss)"
# configtest / any headscale command run as root writes root-owned derp/noise keys under
# /var/lib/headscale; the service runs as User=headscale and then can't read them -> crash loop.
# Reclaim the whole data dir for the headscale user to avoid this.
chown -R headscale:headscale /var/lib/headscale

echo "==> 5) Start with restart (NOT enable --now — easy to miss)"
# The .deb postinst may have already started headscale once with the DEFAULT config
# (127.0.0.1:8080, no TLS, DERP off). `enable --now` won't restart an already-running service,
# so this config (443 + TLS + DERP) would never load. An explicit restart forces it.
systemctl enable headscale >/dev/null 2>&1 || true
systemctl restart headscale
sleep 5
systemctl --no-pager --full status headscale | head -12 || true

echo "==> 6) Create the headscale user (NO key pre-generated here — mint one-time keys per device)"
# The headscale CLI talks to the running daemon over its unix socket, so the user is created AFTER the
# service is up (step 5). configtest (step 4) passes on an empty DB because policy owner resolution is
# deferred until nodes enroll.
headscale users create "$HS_USER" 2>/dev/null || echo "    user $HS_USER already exists"
echo
echo "Security: do NOT create reusable/long-lived keys. Enroll each device with a freshly minted"
echo "one-time, short-lived key, then expire it immediately. See references/device-enrollment.md."

echo "==> 7) Self-check: HTTPS + cert (also triggers first TLS-ALPN-01 issuance)"
sleep 2
code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' "https://${HS_HOSTNAME}/health" 2>/dev/null || echo 000)
if [[ "$code" == "200" ]]; then
  echo "    OK: https://${HS_HOSTNAME}/health = 200. Cert issued + verified, service ready."
else
  echo "    WARN: https://${HS_HOSTNAME}/health = ${code} (not 200). Check: (1) DNS points to this IP;" >&2
  echo "          (2) ufw allows 443; (3) journalctl -u headscale for cert/startup errors." >&2
fi
echo "Done. Next: enroll devices (references/device-enrollment.md), then close public 22 once the VPS is in the tailnet."
