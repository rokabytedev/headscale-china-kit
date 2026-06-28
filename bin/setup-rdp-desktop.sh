#!/usr/bin/env bash
# headscale-china-kit :: remote desktop on the home base (Linux / WSL2)
#
# Turns the home base into an on-demand graphical desktop (xrdp + XFCE) that
# listens ONLY on loopback and is reached over the tailnet via an SSH tunnel.
# Use case: from inside China, RDP into the home base and run a real Chrome under
# the home base's real overseas IP — without turning on a full-tunnel exit node.
#
# Idempotent: safe to re-run. First run installs packages (~1-2 min); later runs
# just (re)apply config and (re)start the service.
#
# Tunables (env-overridable):
#   SSH_USER        login user for the connect hint            (default: $USER)
#   TAILNET_ADDR    this box's tailnet IP/name for the hint    (default: tailscale ip -4)
#   LISTEN_ADDR     bind address — keep loopback-only          (default: 127.0.0.1)
#   RDP_PORT        xrdp port on the home base                 (default: 3389)
#   LOCAL_FWD_PORT  client-side forwarded port (hint only)     (default: 33890)
#   INSTALL_CHROME  set to 1 to also install Google Chrome     (default: 0)
set -uo pipefail

LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1}"
RDP_PORT="${RDP_PORT:-3389}"
LOCAL_FWD_PORT="${LOCAL_FWD_PORT:-33890}"
SSH_USER="${SSH_USER:-$USER}"
TAILNET_ADDR="${TAILNET_ADDR:-$(tailscale ip -4 2>/dev/null | head -1 || true)}"

echo "=== headscale-china-kit :: remote desktop (xrdp + XFCE) ==="

# WSL2 needs systemd to manage xrdp. Catch the common misconfig early.
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
  echo "WARNING: systemd doesn't look active. On WSL2 set '[boot]\\nsystemd=true' in"
  echo "         /etc/wsl.conf, then 'wsl --shutdown' from Windows and reopen. Continuing anyway."
fi

# 1. Install the desktop + RDP server once (idempotent).
if ! dpkg -s xrdp xfce4 >/dev/null 2>&1; then
  echo "Installing xfce4 + xrdp (first run only)..."
  sudo apt-get update && sudo apt-get install -y xfce4 xfce4-goodies xrdp
fi

# 2. A clean ~/.xsession that severs WSLg/systemd cached session env. Without
#    this, RDP logs in to a black screen with only a cursor (XFCE inherits the
#    cached WAYLAND_DISPLAY/DBUS address from WSLg).
cat > "$HOME/.xsession" <<'EOF'
#!/bin/bash
# Force a fresh, isolated session: drop WSLg/systemd cached vars so XFCE spins up
# its own private D-Bus and X display instead of inheriting the broken one.
unset WAYLAND_DISPLAY
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
EOF
chmod +x "$HOME/.xsession"

# 3. Let xrdp read the TLS private key, else connections drop with 0x2104.
if ! groups xrdp 2>/dev/null | grep -qw ssl-cert; then
  echo "Adding xrdp to the ssl-cert group (fixes the 0x2104 TLS error)..."
  sudo usermod -aG ssl-cert xrdp
fi

# 4. Bind loopback-only and force TLS.
#    The 'tcp://' prefix is REQUIRED: a bare 'port=127.0.0.1:3389' hits an atoi()
#    parse bug in xrdp (it reads the port as 127) and the service crash-loops.
sudo sed -i -E "s#^port=(3389|${LISTEN_ADDR}:${RDP_PORT}|tcp://.*)#port=tcp://${LISTEN_ADDR}:${RDP_PORT}#g" /etc/xrdp/xrdp.ini
sudo sed -i 's/^security_layer=negotiate/security_layer=tls/g' /etc/xrdp/xrdp.ini

# 5. Tame key-repeat "storms" on high-latency links (a held Backspace can't brake
#    across 200ms RTT). Longer delay + slower repeat.
[ -f "$HOME/.xsessionrc" ] || echo "xset r rate 500 5" > "$HOME/.xsessionrc"

# 6. (Re)start the service.
echo "Starting xrdp..."
sudo systemctl restart xrdp

# 7. Optional: install Google Chrome (the home base is overseas, so dl.google.com
#    is reachable). amd64 only — on arm64 install chromium yourself.
if ! command -v google-chrome >/dev/null 2>&1 \
   && ! command -v chromium >/dev/null 2>&1 \
   && ! command -v chromium-browser >/dev/null 2>&1; then
  if [ "${INSTALL_CHROME:-0}" = "1" ]; then
    echo "Installing Google Chrome..."
    tmp="$(mktemp -d)"
    if curl -fsSL -o "$tmp/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; then
      sudo apt-get install -y "$tmp/chrome.deb"
    else
      echo "  Chrome download failed — install a browser manually (see references/remote-desktop.md)."
    fi
    rm -rf "$tmp"
  else
    echo "NOTE: no browser found in the desktop. Re-run with INSTALL_CHROME=1, or"
    echo "      install one yourself (see references/remote-desktop.md)."
  fi
fi

# 8. Connect hint.
echo "=============================================="
echo "Remote desktop is up — listening ONLY on ${LISTEN_ADDR}:${RDP_PORT} (no external exposure)."
echo "----------------------------------------------"
echo "From the device in China, open an SSH tunnel over the tailnet:"
echo "  ssh -C -N -L ${LOCAL_FWD_PORT}:${LISTEN_ADDR}:${RDP_PORT} ${SSH_USER}@${TAILNET_ADDR:-<home-base-tailnet-name-or-ip>}"
echo "    -C compresses the stream — keep it for 200ms+ links."
echo "Then point an RDP client at:"
echo "  127.0.0.1:${LOCAL_FWD_PORT}"
echo "  (Windows: mstsc | macOS: 'Windows App' / Microsoft Remote Desktop | phone: an RDP app)"
echo "Log in with your Linux username + password, keep the Xorg session, launch Chrome."
echo "When done: ./bin/stop-rdp-desktop.sh"
echo "=============================================="
