# Architecture

## The problem

Official Tailscale is unreliable from mainland China:

- The coordination servers (`login.tailscale.com`, `controlplane.tailscale.com`) are **DNS-polluted and SNI-blocked** — clients often can't even reach the control plane to get a network map.
- There is **no official DERP relay node in mainland China**. When NAT hole-punching fails (common in China), traffic falls back to a DERP relay abroad → **1000ms+** latency.

So you can't just use Tailscale as-is. You replace the parts that the GFW breaks.

## The solution shape

```
  In China                      Overseas VPS                    Abroad (home)
┌──────────────┐   HTTPS 443  ┌────────────────────┐  routed  ┌──────────────┐
│ laptop/phone │ ───────────> │ Headscale + DERP    │ <──────> │  home base   │
│ stock        │   to YOUR    │ on YOUR domain      │  mesh    │  (the target)│
│ Tailscale    │   domain     │ (assume hostile)    │          │  stock TS    │
└──────────────┘              └────────────────────┘          └──────────────┘
```

1. **Self-host the control plane** with [Headscale](https://headscale.net) (open-source re-implementation of Tailscale's coordination server). It runs on one overseas VPS under **your own domain over HTTPS/443**. To the GFW this looks like an ordinary HTTPS connection to a domain you own — not a connection to `tailscale.com`.
2. **Self-host the relay** using Headscale's **built-in DERP** on the same VPS (no separate `derper` process). Configure clients to use *only* this relay, so nothing detours to far-away official relays. Real-world reports put self-hosted DERP latency from China at tens of ms vs 1000ms+ for official relays abroad.
3. **Clients stay stock Tailscale.** Nothing custom on laptops/phones — they just point `--login-server` at your domain (phones set a custom server in the app).
4. **Security assumes the VPS is hostile** (see `security-model.md`): the VPS holds no key that can log into any device, tailscale-ssh is off, the ACL is minimal. "In the network" is not "into a machine."

## Data flow for remote work

A device in China connects (over the tailnet, relayed through your VPS) to the home base, then does its work **on** the home base over SSH. Anything the home base does to the wider internet (API calls, git, browsing via an exit node) originates from the **home base's** IP abroad — the in-China device is just a terminal. Network-wise this looks like "the user is at home."

## Key design decisions

| # | Decision | Default | Why |
|---|----------|---------|-----|
| Control plane | Self-hosted Headscale | yes | Official is blocked; Headscale is self-contained and fronted by your domain |
| Relay | Headscale built-in DERP, self-only | yes | No official DERP in China; built-in avoids a second daemon |
| Clients | Stock Tailscale | yes | Just change `--login-server`; zero custom client risk |
| Cert | Let's Encrypt **TLS-ALPN-01 on 443** | yes | No port 80 needed → no "renewal fails because 80 is closed" self-lock |
| Domain | Your own, DNS-only (no proxy) | yes | The stable identity; re-point its A record to dodge an IP block |
| VPS lifecycle | On-demand (destroy when not traveling) | optional | Attack surface → 0 when idle; rebuild + re-point DNS before a trip |
| Home base tailnet IP | Pinned | optional | Keeps existing DNS / known_hosts / service configs stable across rebuilds |
| Exit node | Configured but off by default; manual approval | optional | Full-tunnel only when wanted; never auto-approved |

## What you need before starting

- A **domain** you control (one A record).
- One **overseas VPS** (Ubuntu 22.04/24.04). Line choice matters — see `vps-and-line-selection.md`.
- The **home base** machine abroad, reachable while you set things up.
- Stock Tailscale on every device; an SSH client with its own key on phones.
