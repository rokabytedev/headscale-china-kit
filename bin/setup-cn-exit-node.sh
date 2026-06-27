#!/usr/bin/env bash
# setup-cn-exit-node.sh — run ONCE inside a Linux box (or WSL2/Ubuntu) physically in China to make it
# a residential exit node on your tailnet. Self-contained, self-checking, prints a REPORT block at the end.
# Touches only this machine; never touches the VPS.
#
# SECURITY MODEL: treat this box as DISPOSABLE / hostile. It gets pubkey-only sshd, RunSSH=false, and
# holds no private keys or secrets. In the ACL it has INBOUND rules only and NO `src` rules -> one-way
# isolation: even if it's fully compromised it can't reach the rest of your mesh.
#
# Required env:
#   HEADSCALE_URL          e.g. https://hs.example.com
#   AUTHORIZED_KEYS_FILE   path to a file containing the PUBLIC keys allowed to SSH in (one per line)
#                          — typically your home base + laptop + phone public keys. NO private keys here.
# Optional env:
#   PREAUTH_KEY            a one-time Headscale preauth key; if unset, the script does interactive
#                          registration (prints a nodekey URL line for you to register server-side).
#   NODE_HOSTNAME          default: cn-exit
set -uo pipefail
HEADSCALE_URL="${HEADSCALE_URL:?set HEADSCALE_URL, e.g. https://hs.example.com}"
AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:?set AUTHORIZED_KEYS_FILE=path to a file of PUBLIC keys}"
NODE_HOSTNAME="${NODE_HOSTNAME:-cn-exit}"

say(){ echo -e "\n[setup-cn-exit] $*"; }
die(){ echo -e "\n[setup-cn-exit][FATAL] $*" >&2; exit 1; }

# 0. preconditions
[ "$(id -u)" -ne 0 ] || die "run as a normal user (the script uses sudo as needed); do not run as root."
command -v sudo >/dev/null || die "no sudo."
[ -s "$AUTHORIZED_KEYS_FILE" ] || die "AUTHORIZED_KEYS_FILE '$AUTHORIZED_KEYS_FILE' missing or empty."
grep -q 'PRIVATE KEY' "$AUTHORIZED_KEYS_FILE" && die "that file contains a PRIVATE key — only PUBLIC keys belong here."
IS_WSL=no; grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=yes

# 1. (WSL only) ensure systemd, needed for tailscaled
if [ "$IS_WSL" = yes ]; then
  sudo tee /etc/wsl.conf >/dev/null <<WSLCONF
[boot]
systemd=true
[network]
hostname=$NODE_HOSTNAME
generateHosts=true
WSLCONF
  if ! systemctl is-system-running 2>/dev/null | grep -qiE 'running|degraded'; then
    die "Enabled systemd in /etc/wsl.conf. In Windows PowerShell run 'wsl --shutdown', reopen Ubuntu, then RUN THIS SCRIPT AGAIN."
  fi
fi

# 2. hostname
sudo hostnamectl set-hostname "$NODE_HOSTNAME" 2>/dev/null || true

# 3. IPv4 forwarding (required for an exit node) + persist + verify
say "enabling and persisting IPv4 forwarding"
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale-exit.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-tailscale-exit.conf || die "sysctl apply failed"
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || die "ip_forward not active"

# 4. install tailscale
command -v tailscale >/dev/null || { say "installing tailscale"; curl -fsSL https://tailscale.com/install.sh | sh || die "tailscale install failed"; }
sudo systemctl enable --now tailscaled || die "tailscaled won't start (is systemd up?)"

# 5. sshd, pubkey only
say "installing + hardening OpenSSH (pubkey only)"
sudo apt-get update -y || say "apt update warned (slow mirror?); continuing"
sudo apt-get install -y openssh-server || die "failed to install openssh-server"
install -d -m 700 "$HOME/.ssh"
install -m 600 "$AUTHORIZED_KEYS_FILE" "$HOME/.ssh/authorized_keys"
sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null <<'SSHD'
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
SSHD
sudo sshd -t || die "sshd config syntax error"
sudo systemctl enable ssh 2>/dev/null || sudo systemctl enable sshd
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd

# 6. join the tailnet + advertise exit (idempotent: skip `up` if already Running)
if tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; then
  say "tailscale already Running, skipping up (idempotent)"
elif [ -n "${PREAUTH_KEY:-}" ]; then
  say "joining with PREAUTH_KEY and advertising exit node"
  sudo tailscale up --login-server="$HEADSCALE_URL" --advertise-exit-node \
    --ssh=false --accept-dns=false --hostname="$NODE_HOSTNAME" \
    --authkey="$PREAUTH_KEY" --reset || die "tailscale up failed (key expired? can it reach the VPS:443?)"
else
  say "===== interactive registration (no input needed) ====="
  say "tailscale will print a line with a nodekey URL (.../register/nodekey:...)."
  say "Register that node on your Headscale server; this command then continues automatically. Keep the window open."
  sudo tailscale up --login-server="$HEADSCALE_URL" --advertise-exit-node \
    --ssh=false --accept-dns=false --hostname="$NODE_HOSTNAME" --reset || die "tailscale up failed (can it reach the VPS:443?)"
fi
# persist the prefs (no --reset side effects) so they survive reboot
sudo tailscale set --advertise-exit-node 2>/dev/null || true
sudo tailscale set --ssh=false 2>/dev/null || true

# 7. SNAT self-check (under WSL2 NAT, an exit node needs MASQUERADE/ts- chains or return traffic is lost)
if sudo iptables -t nat -S 2>/dev/null | grep -qiE 'MASQUERADE|ts-'; then NAT=yes; else NAT='NO (exit traffic may not return!)'; fi

# 8. self-check + REPORT (assert the critical values)
ip4="$(tailscale ip -4 2>/dev/null | head -1)"
fwd="$(cat /proc/sys/net/ipv4/ip_forward)"; FWD_V=$([ "$fwd" = 1 ] && echo OK || echo '*** FATAL ***')
pw="$(sudo sshd -T 2>/dev/null | awk 'tolower($1)=="passwordauthentication"{print $2}')"; PW_V=$([ "$pw" = no ] && echo OK || echo '*** FATAL ***')
runssh="$(tailscale debug prefs 2>/dev/null | grep -o '"RunSSH"[^,]*' | head -1)"
backend="$(tailscale status --json 2>/dev/null | grep -o '"BackendState"[^,]*' | head -1)"
say "===== copy the REPORT block below back to whoever is helping you set up ====="
echo "BEGIN-CN-EXIT-REPORT"
echo "user=$(whoami)              # clients must SSH in as this username"
echo "host=$(hostname)"
echo "backend=$backend            # expect Running"
echo "ts_ip4=$ip4"
echo "runssh=$runssh              # expect false"
echo "ip_forward_v4=$fwd $FWD_V"
echo "snat=$NAT"
echo "sshd_passwordauth=$pw $PW_V"
echo "authkeys_count=$(grep -c . "$HOME/.ssh/authorized_keys")"
echo "--- host key fingerprints (pin these) ---"
for t in ed25519 ecdsa rsa; do f="/etc/ssh/ssh_host_${t}_key.pub"; [ -f "$f" ] && echo "$t: $(ssh-keygen -lf "$f" 2>/dev/null)"; done
echo "--- ed25519 known_hosts line (pin by name '$NODE_HOSTNAME') ---"
f="/etc/ssh/ssh_host_ed25519_key.pub"; [ -f "$f" ] && echo "$NODE_HOSTNAME $(awk '{print $1" "$2}' "$f")"
echo "--- status ---"; tailscale status 2>/dev/null | head -8
echo "END-CN-EXIT-REPORT"
say "Done. The exit route must still be APPROVED server-side (security), then test that a phone can select '$NODE_HOSTNAME' as its exit node."
