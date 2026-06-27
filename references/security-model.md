# Security model

## One-line goal

**Even if an attacker fully compromises the VPS (the Headscale control plane)
and gets into the tailnet, they still cannot log into the home base / laptop /
phone, and cannot hijack the user's DNS.** The VPS is a dumb relay — it holds no
key capable of logging into any user device.

Why assume the VPS is hostile? Headscale is open-source software exposed to the
public internet, and (unlike Tailscale's cloud) has **no Tailnet Lock** — there
is no cryptographic mechanism stopping a compromised control plane from signing
new nodes into the network. So the design must hold *after* the control plane
falls.

## Threat model

| # | Threat | Countermeasure | Layer |
|---|--------|----------------|-------|
| T1 | Public brute-force of VPS SSH | pubkey-only, no root password, fail2ban; **close public 22** once the VPS is in the tailnet | host |
| T2 | Stranger gets an auth key and joins | one-time short-lived keys; **expire immediately after enrollment**; no reusable keys | control plane |
| T3 | **VPS compromised → attacker signs in their own node → lateral SSH into devices** | **CORE: disable tailscale-ssh; devices use traditional pubkey-only sshd; private keys only on user devices, none on the VPS → "in the network" ≠ "into a machine"** | device |
| T4 | Headscale 0-day | on-demand teardown (idle = 0 attack surface); if compromised while up, T3 still holds | ops + device |
| T5 | Over-broad ACL (in-network = reach everything) | named-tag minimal ACL, no `src:* dst:*`; service ports only to your own devices | control plane |
| T6 | GFW probing / blocking | own domain on 443; TLS-ALPN-01 (no port 80); STUN bound to localhost (no public 3478 fingerprint); re-point domain if an IP is blocked | network |
| T7 | Sensitive material left on the VPS | never put DNS-provider tokens or any device-login private key on the VPS; DERP/noise keys are headscale-owned and local-only | host |
| T8 | Forgetting a security step during a switch | scripts encode the steps (`tailnet-mode`, `return-home.sh`) | ops |
| T9 | **Compromised control plane pushes malicious DNS to MITM `api.anthropic.com`/provider/`github.com`** | `--accept-dns=false` on trusted devices; `override_local_dns: false`; config ships no abusable records | device |
| T10 | **Hosting-provider account compromise → out-of-band root via web console, or restore a snapshot to revive a "legit" control plane** | hardware 2FA on the provider account; minimal-scope API tokens kept out of snapshots; prefer a clean rebuild over restoring an old snapshot. **Acknowledged: provider-account compromise = control-plane compromise; the only backstop is the device layer (pubkey-only).** | ops |

## Why tailscale-ssh must be OFF (the core argument)

`tailscale ssh` authenticates as **"from the tailnet + allowed by ACL" → allow,
with no SSH key check.** So whoever can get into the tailnet can get into the
machine. *Who* can get into the tailnet is decided by the VPS (Headscale).
Therefore: **VPS compromised ⇒ attacker adds their node ⇒ tailscale-ssh lets
them straight into your devices.** That violates the one-line goal.

**Fix:** `tailscale set --ssh=false` on every device, and use **traditional
sshd, public-key only**. The login credential is the SSH private key on the
user's device — which **never exists on the VPS**. After the VPS falls, an
attacker reaches `homebase:22` but has no key → cannot log in.

**Load-bearing detail:** the off-switch is the **device-local** pref
`RunSSH=false`. It can only be changed on the device itself (`tailscale set/up`);
the control plane only pushes the network map/policy and **cannot flip it
remotely**. That's what makes this hold even against a malicious control plane.
The ACL having no `ssh` block is *defense in depth*, not the hard wall.

## Key distribution (the VPS must hold nothing that can log in)

| Key | Lives on | On the VPS? |
|-----|----------|-------------|
| laptop/phone → home base login private key | the user device only (public key in `authorized_keys`) | ❌ |
| home base → laptop login private key (if used) | the home base only | ❌ |
| VPS management private key | the home base (used to manage the VPS) | ❌ (VPS has only the matching *public* key) |
| Headscale noise / DERP private keys | VPS `/var/lib/headscale/` (headscale-owned, 0600) | ✅ but only for DERP/control plane — **cannot log into any device** |
| DNS-provider API token | the home base, `~/.config/...` (chmod 600) | ❌ never uploaded |
| Headscale preauth keys | minted on the VPS, **expired right after enrollment** | transient |

**Iron rule:** no key capable of SSH-ing into any user device exists on the VPS.
A review must verify this.

## Hardening checklist

**Host (VPS):** pubkey-only sshd, no root password, fail2ban, unattended
security upgrades; ufw default-deny, only 443 public (22 only until in tailnet,
then restrict to tailnet source); no port 80 (TLS-ALPN-01); STUN on localhost.
Make sure the home base's management public key is in the VPS's `authorized_keys`
(provider-injected at create time, or pass `ADMIN_PUBKEY=` to the installer) so you can manage over
the tailnet after closing public 22; if the provider disables root SSH, manage as the sudo user and
set `VPS_SSH_USER` for the watchdog.

**Control plane:** one-time keys expired after enrollment; force a tag on each
node from the server; minimal named-tag ACL; no autoApprovers; pinned Headscale
version.

**Device (home base / laptop):** `--ssh=false`; pubkey-only sshd; laptop/phone
public keys in `authorized_keys` *before* turning tailscale-ssh off; pin host
keys + `StrictHostKeyChecking=yes`; disable key expiry so a key can't lapse while
you're behind the GFW (= lockout).

**Ops:** destroy the VPS when not traveling; hardware 2FA on the hosting +
DNS-provider accounts; keep an out-of-band path (provider web console).

## Red-team verification (the go/no-go gate)

Before relying on the link, run `bin/redteam-check` on the home base. It
generates a **stranger** SSH key and proves it is **rejected**, asserts
`RunSSH=false` and pubkey-only sshd, and (optionally) checks host-key pinning.
**Treat FAIL=0 as a hard gate** — if any check fails, fix it before depending on
the setup or traveling.

## Residual risks (be honest with the user)

- **No Tailnet Lock in Headscale** — can't cryptographically stop a compromised control plane from signing nodes. Compensated by the device layer (pubkey-only) + on-demand teardown. This is the main security gap vs. official Tailscale.
- **Can't truly test GFW behavior from abroad** — the firewall is dynamic; verify as much as possible before departure; a trusted contact inside China testing once helps.
- **Laptop physical security** — full-disk encryption + lockscreen; if lost, revoke its node + `authorized_keys` entry.
- **Phone SSH client trust** — pick a reputable app; protect the private key with a passcode/biometrics.
- **DERP sees metadata** — traffic is end-to-end encrypted, but the VPS can see connection metadata (who talks to whom, when); it cannot see SSH contents.
