# headscale-china-kit

An **AI agent skill** for building a private mesh VPN that stays usable across
China's Great Firewall — so your own devices inside China (laptop, phone) can
reliably reach a home/work machine abroad, with an optional full-tunnel exit.

It is meant to be **driven by an AI coding agent** (e.g. Claude Code). You tell
the agent what you have and what you need; the agent reads `SKILL.md`, asks a
short interview, then provisions and hardens everything for you.

## What it builds

- **Self-hosted [Headscale](https://headscale.net)** (open-source Tailscale control plane) on one overseas VPS.
- **Built-in DERP relay** on the same VPS — no separate relay needed, and no detour through far-away official relays.
- Fronted by **your own domain over HTTPS / 443**, so the wire looks like an ordinary HTTPS connection to a domain you own (sidesteps the DNS pollution + SNI blocking that breaks official Tailscale in China).
- **Stock Tailscale clients** — nothing custom on your laptop/phone; they just point at your control plane.
- A **security model that assumes the VPS can be compromised**: even an attacker who fully owns the VPS cannot log into your devices or hijack your DNS, because the VPS holds no key that can log into anything.
- Optional **full-tunnel exit node** at home, and an optional **disposable residential exit node inside China**, isolated so it can't endanger the rest of the mesh.
- **On-demand lifecycle**: destroy the VPS when you're not traveling (attack surface → zero), rebuild before the next trip; devices reconnect automatically because the "identity" is the domain + node keys, not the VPS IP.

## Why

In mainland China, official Tailscale is unreliable: the coordination servers
are DNS-polluted and SNI-blocked, and there is no official DERP relay in
country, so relayed traffic detours abroad at 1000ms+. Self-hosting the control
plane and relay under your own domain restores a fast, private mesh.

## Install the skill

Copy this repo into your agent's skills directory, e.g. for Claude Code:

```bash
git clone https://github.com/rokabytedev/headscale-china-kit.git ~/.claude/skills/headscale-china-kit
```

Then just ask your agent something like *"help me set up a Headscale mesh so I
can reach my home server from China"* and it will pick up the skill.

## Use it

The agent reads `SKILL.md` and runs an **interview-first deployment**: it asks
about your devices, domain, VPS/budget, China ISP, and whether you need a
full-tunnel exit — then recommends a line, installs and hardens Headscale,
enrolls your devices, and runs a red-team check before you rely on it.

## Layout

```
SKILL.md                      # entry point the agent reads
references/                   # deep-dive docs (read on demand)
  architecture.md             # why this design
  vps-and-line-selection.md   # China line selection (CN2 GIA, itdog, GFW facts)
  security-model.md           # threat model + hardening + red-team verify
  headscale-setup.md          # config.yaml + ACL + DNS, with gotchas
  device-enrollment.md        # one-time keys, tagging, IP pin, pubkey sshd
  client-activation.md        # connect each client (desktop+phone), exit-node toggle, verify
  exit-nodes.md               # home exit node + in-China disposable exit node
  remote-desktop.md           # xrdp+XFCE desktop on the home base (run a browser there)
  lifecycle-and-recovery.md   # teardown / rebuild / emergencies / return home
vps/                          # server-side (run on the VPS)
  install-headscale.sh
  headscale-config.yaml.tmpl
  acl.hujson.tmpl
bin/                          # client-side helper scripts
  tnip  tailnet-mode  cf-dns  harden-sshd.sh  redteam-check
  setup-cn-exit-node.sh  setup-cn-exit-node-windows.ps1
  setup-rdp-desktop.sh  stop-rdp-desktop.sh
  vpn-watchdog.sh  return-home.sh
```

All templates use placeholders (`__HS_HOSTNAME__`, `__VPS_IP__`, …) and only
non-identifying example values — **no real secrets, keys, IPs, or hostnames are
in this repo.** Secrets live outside it (see `.gitignore`).

## Security model in one line

The VPS is a dumb relay. Your devices use traditional SSH with public-key-only
auth and pinned host keys; the private keys never touch the VPS; tailscale-ssh
is disabled; the ACL is minimal and grants no auto-approval. So "getting into
the network" is not "getting into a machine." See `references/security-model.md`.

## Disclaimer

This kit connects **your own devices** for personal remote access. You are
responsible for complying with all applicable laws and the terms of service of
your network and hosting providers. It ships **as-is, without warranty** (see
[LICENSE](LICENSE)). It is not a commercial circumvention service and must not
be used to provide one.

## License

[MIT](LICENSE)
