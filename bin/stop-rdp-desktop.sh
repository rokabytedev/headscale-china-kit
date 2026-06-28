#!/usr/bin/env bash
# headscale-china-kit :: tear down the remote desktop and free its memory.
#
# Stops xrdp (closes the loopback RDP port) and kills the leftover GUI/browser
# processes for THIS user. Uses exact-name matching (pkill -x), NOT 'pkill -f',
# so it can never kill your SSH tunnel / tmux / tailscaled just because their
# command line happens to contain "xfce" or "xrdp".
set -uo pipefail

echo "=== headscale-china-kit :: closing remote desktop ==="

echo "Stopping xrdp service..."
sudo systemctl stop xrdp || true

echo "Releasing desktop + browser memory (exact-match kills only)..."
for proc in \
  chrome chrome-sandbox google-chrome chromium chromium-browser \
  xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd \
  xrdp-sesman xrdp-chansrv Xorg Xvnc at-spi2-registryd; do
  pkill -u "$USER" -x "$proc" 2>/dev/null || true
done

# Confirm the RDP port is actually gone.
RDP_PORT="${RDP_PORT:-3389}"
if ss -tuln 2>/dev/null | grep -q ":${RDP_PORT} "; then
  echo "WARNING: port ${RDP_PORT} still bound — forcing it closed..."
  sudo fuser -k "${RDP_PORT}/tcp" || true
else
  echo "Confirmed: port ${RDP_PORT} is closed."
fi

echo "Done — RDP stopped, desktop/Chrome memory freed, no listener left."
