# Exit nodes

Two independent, optional capabilities:

1. **Home exit node** — route a device's *all* internet traffic out through the home base abroad (full-tunnel "VPN").
2. **In-China residential exit node** — a disposable box physically in China whose residential IP you can route through (e.g. to reach things that want a China IP), kept isolated so it can't endanger the mesh.

Both are **off by default** and require **manual route approval** on the VPS (no autoApprovers).

## Home exit node

On the home base:

```bash
sudo tailscale set --advertise-exit-node     # advertise (no --reset; persists across reboots)
```

Persist IP forwarding so it survives reboot (Linux):

```bash
# /etc/sysctl.d/99-tailscale-exit.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

Approve the route on the VPS (manual = safe):

```bash
headscale nodes list-routes
headscale nodes approve-routes -i <homebase_id> -r 0.0.0.0/0,::/0
```

The ACL already allows `tag:phone`/`tag:laptop` → `autogroup:internet:*` so an
exit selection actually has internet. Turn it on per device: phones pick the exit
node in the Tailscale app; laptops use `tailscale set --exit-node=<name>` /
`--exit-node=` to clear.

**Verifying is tricky:** if your device and the home base share the same public
IP (e.g. both on the home Wi-Fi), you can't see a change. Test from a **different
network** (cellular / another site) and confirm your public IP becomes the home
base's, or check the exit-node marker in `tailscale status`.

## In-China residential exit node (disposable, isolated)

Use `bin/setup-cn-exit-node.sh` on a Linux box or WSL2/Ubuntu instance that lives
in China. Treat it as **hostile/disposable**.

```bash
HEADSCALE_URL=https://hs.example.com \
AUTHORIZED_KEYS_FILE=/path/to/pubkeys.txt \
[PREAUTH_KEY=<one-time-key>] bash setup-cn-exit-node.sh
```

It enables + persists IPv4 forwarding, installs pubkey-only sshd, sets
`RunSSH=false`, joins the tailnet, advertises an exit node, runs a SNAT
self-check, and prints a REPORT block (including host-key fingerprints to pin).
On Windows, run `bin/setup-cn-exit-node-windows.ps1` first for WSL autostart (pass `-Distro` if your
WSL distro isn't named `Ubuntu`).

`AUTHORIZED_KEYS_FILE` becomes the box's `authorized_keys` (overwrite, not append), so include every
public key you'll need (home base, laptop, phone) in that one file.

Then approve its route on the VPS:

```bash
headscale nodes approve-routes -i <cn_exit_id> -r 0.0.0.0/0
```

### Why it's safe even if compromised — one-way isolation

In the ACL, `tag:cn-exit` appears **only as a destination** (your devices may SSH
*into* it) and has **no `src` rule anywhere**. So it can receive admin SSH and
serve as an exit, but it **cannot initiate connections to any other node**. If
that box is taken over, the attacker still can't reach the home base / laptop /
phone / VPS. This is the deliberate trade for putting a machine in a hostile
environment.

### Operational notes

- **SNAT under WSL2:** an exit node needs `MASQUERADE`/`ts-` NAT chains or return traffic is dropped. The setup script asserts this; if it reports `snat=NO`, fix NAT before relying on it.
- **IPv6 blackhole:** if you advertise `::/0` but only enable IPv4 forwarding, IPv6 can black-hole. Either also enable IPv6 forwarding or advertise IPv4 only.
- **Reliability:** if the box is at someone's home, you can accept occasional downtime and manual reboots. For unattended reboot recovery on Windows, the `.ps1` sets a logon-triggered task — you must also enable Windows auto-logon (`netplwiz`) so a session exists at boot to start WSL.
- **Interop:** by default WSL keeps Windows interop, which is fine if you want to SSH into the Linux side and then help with the Windows host. Harden further if you don't need it.
