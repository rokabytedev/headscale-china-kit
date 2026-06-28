# Remote desktop on the home base (Linux / WSL2)

**Goal:** give the user a graphical desktop on the home base that they reach over
the tailnet from inside China, so they can run a real **Chrome** (log into sites,
pass verifications) under the home base's **real overseas IP** — without turning
on a full-tunnel exit node.

This is the common "I just need a browser at home, not all my traffic routed"
case. It stays consistent with the kit's model: the desktop listens **only on
loopback** and is reached through an **SSH tunnel over the tailnet**, so there is
no RDP port on any network interface and no new attack surface.

**Scope:** a **Linux** or **WSL2** home base. RDP (xrdp), not VNC — RDP stays
usable on 200ms+ China links where VNC gets sluggish.

## The stack

xrdp (RDP server) + XFCE4 (lightweight desktop) + a browser (Chrome). xrdp binds
`127.0.0.1:3389`; the client in China runs an SSH tunnel to it over the tailnet
and points a normal RDP client at `localhost`.

## Setup (the agent runs this on the home base)

```bash
# idempotent; first run installs xfce4+xrdp (~1-2 min), later runs just restart
INSTALL_CHROME=1 ./bin/setup-rdp-desktop.sh
```

Tunables (env vars): `SSH_USER`, `TAILNET_ADDR` (this box's tailnet IP/name, used
only for the printed hint), `LISTEN_ADDR` (keep `127.0.0.1`), `RDP_PORT`,
`LOCAL_FWD_PORT`, `INSTALL_CHROME`. The script prints the exact connect command
at the end, filled in with the home base's tailnet IP.

### WSL2 prerequisites

- **systemd must be on.** `/etc/wsl.conf` needs `[boot]\nsystemd=true`; then
  `wsl --shutdown` from Windows and reopen. xrdp is a systemd service.
- For **unattended reboot** (the box should come back without a human), set a
  logon-triggered task that starts WSL + this script, and enable Windows
  auto-logon — same pattern as `bin/setup-cn-exit-node-windows.ps1`.

## Connect from China (hand the user this)

```bash
# 1. open the tunnel over the tailnet (replace name/IP with the home base's)
ssh -C -N -L 33890:127.0.0.1:3389 <user>@<home-base-tailnet-name-or-ip>
# 2. point an RDP client at  127.0.0.1:33890
#    Windows: mstsc   |   macOS: "Windows App" / Microsoft Remote Desktop   |   phone: any RDP app
# 3. log in with the Linux username + password, keep the Xorg session, launch Chrome
```

`-C` (compression) matters on high-latency links. `33890` is just a local port
that avoids clashing with a local Windows RDP on 3389.

## Tear down when done

```bash
./bin/stop-rdp-desktop.sh   # stops xrdp + frees all desktop/Chrome memory
```

On-demand is the intended mode: start it for a session, stop it after. Nothing is
left listening.

## The four gotchas these scripts encode (do not undo them)

1. **`port=tcp://127.0.0.1:3389` — the `tcp://` prefix is required.** A bare
   `port=127.0.0.1:3389` hits an `atoi()` parse bug (xrdp reads the port as
   `127`) and the service crash-loops.
2. **xrdp must be in the `ssl-cert` group**, or TLS connections drop with
   **`0x2104`** ("cannot read private key"). `usermod -aG ssl-cert xrdp`.
3. **Black screen with only a cursor** = XFCE inherited WSLg/systemd cached
   session vars. The `~/.xsession` **unsets `WAYLAND_DISPLAY`, `SESSION_MANAGER`,
   `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`** before `exec startxfce4`.
4. **Cleanup uses `pkill -x` (exact name), never `pkill -f`.** `-f` matches the
   whole command line and would kill your SSH tunnel / tmux / tailscaled just for
   containing "xfce"/"xrdp" — i.e. it would cut you off.

## Chrome in this desktop

- **Non-root user → no `--no-sandbox` needed** (keep the sandbox on).
- **No GPU:** if Chrome misbehaves, launch with
  `google-chrome --disable-gpu --disable-software-rasterizer` (software/LLVMpipe
  rendering).
- **Tiny fonts on a hi-DPI client:** XFCE → Settings → Appearance → Fonts →
  Custom DPI → `120` or `144`.
- **Key-repeat storms:** the setup writes `xset r rate 500 5`; `xset r off` in a
  desktop terminal disables repeat entirely.
- **Chinese input:** not installed by default; `sudo apt-get install fcitx5 fcitx5-chinese-addons` if the user types Chinese.

## Security notes

- **Loopback-only + tailnet SSH tunnel** ⇒ the RDP port is on no network
  interface; reaching it already requires being in the tailnet *and* holding the
  SSH key.
- Login is the **Linux PAM password**. Because the only path in is the tunnel,
  brute-force surface is minimal. Optional extra hardening (off by default):
  disable the RDP clipboard so a China-side password-manager copy doesn't sync to
  the remote (`cliprdr=false` in `xrdp.ini`), `pam_faillock`, `light-locker`
  autolock, `crypt_level=high`.
- **This runs on the home base (trusted) — never on the VPS.**

## Relation to the rest of the kit

- Prerequisite: the home base is already enrolled and reachable on the tailnet
  (`device-enrollment.md`, `client-activation.md`).
- It's the lightweight alternative to the **home exit node** (`exit-nodes.md`)
  when the user only needs a browser at home, not their whole device's traffic
  routed.
- If you'd rather skip the tunnel, you *can* bind it to the tailnet IP
  (`LISTEN_ADDR=<tailnet-ip>`) and rely on the ACL — but **loopback + SSH tunnel
  is the default** because it adds no listening surface.
