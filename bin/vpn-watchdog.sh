#!/usr/bin/env bash
# vpn-watchdog.sh — conservative watchdog: probe the control plane /health, and only act if the
# process is genuinely dead. Meant for cron every ~5 min on a machine that can reach the VPS over the
# tailnet (e.g. the home base). Needs no sudo on the local side (just curl + ssh).
# It NEVER restarts a live service and NEVER edits config.
#
# Required env:
#   HEALTH_URL      e.g. https://hs.example.com/health
#   VPS_TAILNET_IP  the VPS's tailnet IP (e.g. 100.64.0.20)
#   SSH_KEY         path to the private key used to manage the VPS over the tailnet
#   KNOWN_HOSTS     path to a known_hosts file pinning the VPS host key
# Optional env:
#   VPS_SSH_USER        VPS management login user (default root; some providers disable root SSH)
#   WATCHDOG_MODE       monitor (default, log only) | recover (allow `systemctl start` of a dead service)
#   WATCHDOG_THRESHOLD  consecutive failures before acting (default 3, ~15 min — rides out GFW jitter)
set -uo pipefail
HEALTH_URL="${HEALTH_URL:?set HEALTH_URL, e.g. https://hs.example.com/health}"
VPS_TAILNET_IP="${VPS_TAILNET_IP:?set VPS_TAILNET_IP}"
SSH_KEY="${SSH_KEY:?set SSH_KEY=path to VPS management private key}"
KNOWN_HOSTS="${KNOWN_HOSTS:?set KNOWN_HOSTS=path to pinned known_hosts}"
VPS_SSH_USER="${VPS_SSH_USER:-root}"
STATE="$HOME/.cache/vpn-watchdog.fails"; LOG="$HOME/.cache/vpn-watchdog.log"
THRESHOLD="${WATCHDOG_THRESHOLD:-3}"
MODE="${WATCHDOG_MODE:-monitor}"
mkdir -p "$(dirname "$STATE")"
note(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
sshv(){ ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$SSH_KEY" "${VPS_SSH_USER}@${VPS_TAILNET_IP}" "$@"; }

code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$HEALTH_URL" 2>/dev/null || echo 000)"
if [ "$code" = "200" ]; then rm -f "$STATE"; exit 0; fi
fails=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )); echo "$fails" > "$STATE"
note "health=$code consecutive_failures=$fails/$THRESHOLD mode=$MODE"
[ "$fails" -lt "$THRESHOLD" ] && exit 0

# threshold reached: read-only probe of whether the process is actually dead (totally safe)
active="$(sshv 'systemctl is-active headscale' 2>/dev/null || echo SSH_UNREACHABLE)"
note "VPS headscale is-active=$active"
case "$active" in
  active)
    note "process still alive -> fault is network/cert/path, not the control plane. Do NOT restart." ;;
  inactive|failed|activating|deactivating|"")
    if [ "$MODE" = "recover" ]; then
      note "process confirmed dead -> systemctl start (starting a dead service only; safe)"
      sshv 'systemctl start headscale; sleep 3; systemctl is-active headscale' >>"$LOG" 2>&1 || note "start failed"
      sleep 5; c2="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$HEALTH_URL" 2>/dev/null || echo 000)"
      note "post-recovery health=$c2"; [ "$c2" = "200" ] && rm -f "$STATE"
    else note "monitor mode: process dead but taking no action (left for a human / agent)."; fi ;;
  SSH_UNREACHABLE)
    note "tailnet SSH unreachable -> cannot recover remotely; needs the provider's web console." ;;
esac
