#!/usr/bin/env bash
# return-home.sh — runbook + helper to switch the whole setup from your self-hosted Headscale back to
# the official Tailscale cloud after you're done traveling. Scripts what it safely can (the home base
# switch); clearly lists the manual steps (laptop/phone apps, official console, destroying the VPS).
#
# Run this ON THE HOME BASE:  bash return-home.sh
#
# IRON RULE (avoid lockout): switch the home base FIRST, while you can reliably reach it; verify; THEN
# switch laptops/phones. Never switch the home base when you can't reach it.
# The load-bearing wall is unaffected: pubkey-only sshd / RunSSH=false / pinned host keys are OS-level
# and survive a control-plane switch.
#
# Env (optional):
#   HEADSCALE_URL      your self-hosted control plane (for the "switch back to China" hint at the end)
#   HOMEBASE_HOSTNAME  expected hostname of this machine (sanity check; default: current hostname)
set -uo pipefail
OFFICIAL_URL="https://controlplane.tailscale.com"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/headscale-china-kit/headscale-url"
HEADSCALE_URL="${HEADSCALE_URL:-$( [[ -f "$CFG" ]] && head -n1 "$CFG" || echo 'https://hs.example.com' )}"
HOMEBASE_HOSTNAME="${HOMEBASE_HOSTNAME:-$(hostname)}"

cat <<'INTRO'
============================================================
  Return home: switch from self-hosted Headscale back to the official Tailscale cloud
============================================================
Prereq: you're back home / on a reliable link and can reach the home base.
Order: home base -> laptop -> phone -> (official console DNS/ACL) -> (optional) destroy the VPS.

[Option A - easiest: change nothing]
  Self-hosted Headscale works fine at home too (low latency, direct or via your DERP).
  If the VPS is already paid for, you can just keep using it. Only continue below if you want to
  drop the VPS cost and return to the free official cloud.
============================================================
INTRO

if [[ "$(hostname)" != "$HOMEBASE_HOSTNAME" ]]; then
  echo "WARNING: run this on the home base (hostname expected '$HOMEBASE_HOSTNAME', got '$(hostname)')."
fi

echo
read -r -p ">> Switch back to the official cloud (Option B)? Start by switching the home base now? [y/N] " ans
if [[ "${ans:-}" == "y" || "${ans:-}" == "Y" ]]; then
  echo
  echo ">> Step 1/5  switch the home base to the official Tailscale cloud"
  echo "   (asks for sudo; opens a login.tailscale.com browser login to re-auth this machine)"
  sudo tailscale up --login-server="$OFFICIAL_URL" --ssh=false --accept-dns=false --reset --force-reauth || {
    echo "   failed: on Linux, retry with sudo if it's a permissions issue."; }
  echo "   state after switch:"
  tailscale status 2>/dev/null | head -5
  HOME_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  echo "   This machine's OFFICIAL-cloud IP = ${HOME_IP:-unknown}  <- you'll need it for split-DNS in Step 4"
  runssh="$(tailscale debug prefs 2>/dev/null | grep -o '"RunSSH":[^,]*' | grep -o 'true\|false' || echo unknown)"
  [[ "$runssh" == "false" ]] && echo "   OK: RunSSH=false (load-bearing wall intact)" \
    || echo "   WARNING: RunSSH=$runssh -- run 'sudo tailscale set --ssh=false' now!"
else
  echo "cancelled. nothing changed."; exit 0
fi

cat <<MANUAL

------------------------------------------------------------
  Remaining steps (manual, in order)
------------------------------------------------------------
>> Step 2/5 (on the laptop)  switch it back to the official cloud
   Tailscale app: switch the account/server back to the default official login
   (or remove the custom server, then reopen the app and log in).

>> Step 3/5 (on the phone)  Tailscale app -> account -> switch back to the default official server -> log in.

>> Step 4/5 (official console https://login.tailscale.com/admin)
   - DNS page: add split-DNS  <your-service-domain> -> ${HOME_IP:-<home base official IP>}  (the IP from Step 1).
   - Disable key expiry for your devices (so a key never expires while you're behind the GFW = lockout).
   - ACL: confirm there is NO ssh block (load-bearing wall: devices still use traditional pubkey-only sshd).

>> Step 5/5 (optional, save money)  After the official cloud has run fine for a few days, stop/cancel the VPS.
   WARNING: once destroyed, rebuild before the next trip (see references/lifecycle-and-recovery.md +
   vps/install-headscale.sh). Re-point the DNS record to the new IP; devices reconnect without re-enrolling.

------------------------------------------------------------
  Verify (all green = success)
------------------------------------------------------------
  - all devices on the official cloud and reachable: ssh works to home base / laptop; phone client connects
  - your private service domain resolves on laptop/phone
  - red-team still green:  bin/redteam-check  (FAIL=0)
  - to go back to China mode later:  bin/tailnet-mode china  (then set the apps back to ${HEADSCALE_URL})
============================================================
MANUAL
