# Lifecycle, recovery & emergencies

## The stable-identity model

- **Permanent identity** = your **domain** (`hs.example.com`) + the **node keys** stored on each device.
- **Swappable outer layer** = the **VPS public IP** (and the VPS itself).

Because of this split, you can destroy/rebuild the VPS or change its IP and
devices reconnect **without re-enrollment** — you only re-point the domain's A
record. Pinning the home base's tailnet IP keeps DNS / `known_hosts` / service
configs stable too.

## On-demand lifecycle

**When you stop traveling (optional, saves money + zeroes attack surface):**
1. Switch devices back to the official cloud if you want (`bin/return-home.sh`), or just keep using Headscale (it works fine at home).
2. Snapshot the VPS (optional), then **destroy** it. Idle attack surface → 0.

**Before the next trip (do this while still abroad / on a reliable link):**
1. Rebuild the VPS (or restore a snapshot — prefer a **clean rebuild** for security), get its new IP.
2. `bin/cf-dns set hs.example.com <new-ip>` (or update DNS manually).
3. Re-run `vps/install-headscale.sh`; verify cert + `/health` = 200.
4. Devices: `bin/tailnet-mode china` (home base first), phones set the custom server. Re-pin the home base IP if you rebuilt the DB.
5. Run the pre-departure checklist below.

## Switch-order iron rule

Switch the **home base first**, while you can reliably reach it; verify; then
laptops/phones. **Never** switch the home base when you can't reach it (e.g.
already in China with no fallback). The load-bearing wall (pubkey-only sshd /
`RunSSH=false` / pinned host keys) is OS-level and is unaffected by control-plane
switches.

## Monitoring (always-on deployments)

`bin/vpn-watchdog.sh` (cron, e.g. every 5 min, on a machine that can reach the
VPS over the tailnet) probes `/health` and, only after several consecutive
failures, does a **read-only** check of whether the process is actually dead. In
`monitor` mode it just logs; in `recover` mode it will `systemctl start` a
**dead** service (never restarts a live one, never edits config). It rides out
short GFW jitter via the failure threshold.

## Emergencies

| Situation | Action |
|-----------|--------|
| **VPS IP appears blocked** | Re-point the domain to a fresh IP: rebuild/spin a new VPS → `install-headscale.sh` → `cf-dns set hs.example.com <new-ip>`. Devices auto-reconnect (identity = domain + keys). Short DNS TTL (60s) makes this fast. |
| **Headscale process down** | Watchdog (recover mode) or manual `systemctl start headscale` over the tailnet; out-of-band fallback = the provider's web console. |
| **Can't reach the control plane at all from a device** | Switch that device back to the official cloud if it's reachable (`tailnet-mode usa`), or use a fallback path (overseas-roaming phone hotspot). |
| **Totally locked out of the home base** | Have someone power-cycle the home base / router; keep an emergency auth path. This is why you never switch the home base from inside China without a fallback. |

## What NOT to do (investigated, negative — see vps-and-line-selection.md)

- Don't orange-cloud (proxy) the DNS record — it breaks Headscale/DERP. DNS-only always.
- Don't rely on reserved/floating IPs for anti-block — wrong direction; re-point the domain instead.
- Don't chase "clean" IPs across clouds when blocked — blocking is content-triggered and per-3-tuple; harden the connection + re-point.

## Pre-departure verification checklist

Run through this before you rely on the link / leave:

- [ ] All devices reach each other on Headscale; SSH to the home base works (pubkey).
- [ ] Your private service domain (`*.pc` or similar) resolves on laptop/phone.
- [ ] `tailscale netcheck` shows traffic using **your** DERP region, not an official one.
- [ ] `bin/tailnet-mode usa` ↔ `china` round-trips cleanly at least once.
- [ ] Exit node toggles on/off once and actually changes egress IP (test from a different network).
- [ ] Key expiry **disabled** for all devices (a lapsed key behind the GFW = lockout).
- [ ] **`bin/redteam-check` → FAIL=0** (hard gate).
- [ ] VPS public SSH 22 closed (manage over the tailnet); out-of-band console access confirmed.
- [ ] Hosting + DNS-provider accounts have hardware 2FA.
