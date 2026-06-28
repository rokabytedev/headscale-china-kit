# Client activation — make sure the human can actually use it

The job is **not done when Headscale is up**. It is done when **every device the
user named in the interview is connected, and the user has confirmed the thing
they actually wanted — SSH back home / a service / full-tunnel exit — works from
that device**. Reaching that state is part of the deployment, not a follow-up.
Drive it for the user; don't hand them a server and walk away.

## Principle: automate what you can, hand the user the *minimum*

Per device, pick the path with the fewest manual taps:

- **Any shell the agent can already reach** (the Linux/WSL home base, a laptop you
  can SSH into, the in-China exit box): **the agent runs `tailscale` itself.** Zero
  user steps beyond approving `sudo`.
- **A desktop the user is holding** (Windows, macOS): hand them **one command to
  paste**, not a GUI click-walk — the CLI is identical across OSes and dodges
  version-specific menus.
- **Phones (iOS/Android): GUI is unavoidable.** Give an exact, short tap sequence
  with the URL/key already filled in. This is the *only* place you truly can't
  automate — make it a few lines, not a tutorial.

**Always mint the one-time preauth key yourself** (see `device-enrollment.md`) and
paste it into the command/instruction, so the user never types a `headscale`
command. After each device joins, **you** expire the key and force the tag.

Below, `<HS>` = `https://hs.<their-domain>`, `<KEY>` = the one-time preauth key you
minted for that device.

## Point each client at the self-hosted control plane

### Linux / WSL2 — agent runs this
The home base and Linux laptops: the agent executes it directly (full flags and
the per-device tag/expire flow are in `device-enrollment.md`).

```bash
sudo tailscale up --login-server=<HS> --ssh=false --accept-dns=false \
  --reset --force-reauth --authkey=<KEY>
```

### Windows — hand the user one PowerShell line
Install: the official client — https://tailscale.com/download/windows
Then in an **Administrator PowerShell**:

```powershell
tailscale login --login-server <HS> --auth-key <KEY>
```

A browser opens to finish. Optional, so it survives logout: tray icon →
Preferences → enable **Run unattended**.

### macOS — CLI is simplest
Install the **standalone** client (https://tailscale.com/download/mac). Prefer it
over the Mac App Store build for this: the `tailscale` CLI and the Debug-menu
custom-server option used here are most reliable on the standalone variant.

```bash
tailscale login --login-server <HS> --auth-key <KEY>
```

GUI fallback (no terminal): **Option-click** the Tailscale menu-bar icon → hover
**Debug** → under **Custom Login Server** pick **Add Account…** → enter `<HS>`.

### iOS — user taps (give them these lines verbatim)
1. Install **Tailscale** from the App Store.
2. Open it → tap the **account icon (top-right)** → **"Log in…"**.
3. Tap the **options menu (top-right)** → **"Use custom coordination server"**.
4. Enter `<HS>` → continue, then complete the login it opens.
   - If it stalls on registration, finish it on the VPS:
     `headscale nodes register --user <id> --key <node-key-the-app-shows>`.
5. Turn **ON** "Use Tailscale DNS" in the app — phones are the deliberate exception
   to `--accept-dns=false` (see `device-enrollment.md`), needed to resolve
   `*.<service-domain>` / MagicDNS short names; the config's empty `nameservers.global`
   keeps normal browsing intact.

### Android — user taps
1. Install **Tailscale** (Play Store or F-Droid).
2. Settings menu **(top-right)** → **Accounts** → **⋮ (top-right)** →
   **"Use an alternate server"** → enter `<HS>`.
   - Headless alternative: **⋮ → "Use an auth key"** → paste `<KEY>`.
3. Turn **ON** "Use Tailscale DNS" (same reason as iOS).

After any device joins, on the VPS: **expire the key + force its tag**
(`device-enrollment.md`). An untagged node matches no ACL rule and stays invisible.

## Turn the exit node ON at the client (full-tunnel VPN)

Prereq: the home base advertises an exit node **and** you approved its route on
the VPS (`exit-nodes.md`). The ACL already lets `tag:phone`/`tag:laptop` reach
`autogroup:internet`, so a selected exit actually has internet. Then, on the
device that wants full-tunnel:

- **Linux / WSL / macOS / Windows (CLI):**
  `tailscale set --exit-node=<homebase-name-or-100.x-ip>` ·
  clear with `tailscale set --exit-node=` ·
  add `--exit-node-allow-lan-access` if the user still needs their local LAN.
- **iOS:** Tailscale app → **Exit Node** → pick the home base (None = off).
- **Android:** Tailscale app → **⋮ / Exit Node** → pick the home base.

## Confirm it actually works (verify, don't assume)

Tell the user what "working" looks like, then check it:

- **Reachability:** on the in-China device, `tailscale status` lists the home base;
  the user's real goal (`ssh` in, or open the service) succeeds.
- **Exit node:** test from a **network other than the home base's** (cellular, not
  the same Wi-Fi — shared egress IP makes a same-network test meaningless). Confirm
  the device's public IP becomes the home base's: open a "what's my IP" page, or
  run `curl -4 ifconfig.co`. On a phone, switch it to cellular before testing.

## Hand-off message (template — keep it this short per phone)

> Open Tailscale → account icon → **Log in** → **⋯** menu → **Use custom
> coordination server** → paste **`<HS>`** → finish login → turn on **Use
> Tailscale DNS**. To route all traffic through home: tap **Exit Node →
> `<homebase-name>`** (set it back to **None** to stop).

Source of truth for the per-platform GUI paths: Headscale's official
"Connect a node" docs (`headscale.net/stable/usage/connect/`); re-check if an app
update moves a menu.
