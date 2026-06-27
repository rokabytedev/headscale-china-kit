# Device enrollment

Headscale has **no built-in device-approval toggle**. The safe equivalent is:
**mint a one-time, short-lived preauth key → enroll → expire the key immediately
→ force a tag on the node from the server.** Do this per device.

## The per-device flow

On the VPS, mint a one-time 1-hour key for your user (numeric ID, e.g. `1`):

```bash
headscale preauthkeys create -u 1 --expiration 1h | tail -1     # prints the key
```

On the device, join your control plane:

```bash
sudo tailscale up --login-server=https://hs.example.com \
  --ssh=false --accept-dns=false --reset --force-reauth --authkey=<key>
```

- `--ssh=false` — no tailscale-ssh (use traditional pubkey sshd; see `security-model.md`).
- `--accept-dns=false` on the home base/laptop — prevents control-plane DNS hijack and keeps China DNS working. (Phones are the exception — see below.)
- `--reset --force-reauth` — required when pointing at a new `--login-server`.

Back on the VPS, **expire the key now** and **force a tag** on the new node:

```bash
headscale preauthkeys list                 # NOTE: no -u on list; find the ID column of the key you used
headscale preauthkeys expire --id <ID>     # revoke it immediately (expire takes --id, NOT the key string)
headscale nodes list                       # find the node id
headscale nodes tag -i <id> -t tag:homebase   # force the tag (forced tags ignore advertise-tags)
```

Tagging is **required** — the ACL is tag-based, so an untagged node matches no
rule and can't see or be seen. The tag must already be declared in the ACL's
`tagOwners` or you'll get "tag invalid/not permitted." A forced (admin-set) tag
also stops that node's key from expiring.

Finally confirm no keys remain active:

```bash
headscale preauthkeys list                 # all expired / 0 active
```

## Pin the home base IP (recommended)

Pinning keeps existing DNS records, `known_hosts`, and any service configs that
reference the home base's tailnet IP valid across rebuilds:

```bash
systemctl stop headscale
sqlite3 /var/lib/headscale/db.sqlite "UPDATE nodes SET ipv4='100.64.0.10' WHERE id=<HOMEBASE_ID>;"
systemctl start headscale
```

Use the same IP you passed as `HOMEBASE_TAILNET_IP` to the installer (for
split-DNS). `bin/tnip <name>` resolves any peer's current IP live, so scripts
don't need to hardcode it.

## SSH hardening per device (do this, then verify)

For the home base and laptop, **before** turning tailscale-ssh off:

1. Put the laptop/phone **public** keys into the device's `~/.ssh/authorized_keys`.
2. Run `bin/harden-sshd.sh`, then its printed manual steps (pubkey-only sshd).
3. From a **separate** terminal, confirm you can still log in.
4. Only then: `tailscale set --ssh=false`.
5. **Pin host keys:** record each device's `ssh_host_ed25519_key.pub` fingerprint and use `StrictHostKeyChecking=yes` on clients.
6. Run `bin/redteam-check` (FAIL=0).

Socket-activated sshd (systemd `ssh.socket`, or launchd on macOS) ignores
`ListenAddress`, so restrict "who can reach :22" via the tailnet ACL (and
optionally local iptables on `tailscale0`), not via `ListenAddress`.

## Phones

- **Tailscale app:** add a custom control server (`https://hs.example.com`), enroll with a one-time key. To resolve `*.<service domain>` / MagicDNS short names, turn **on** "Use Tailscale DNS" in the app (this is the phone exception to `accept-dns=false`; the config's empty `global` keeps normal browsing intact).
- **SSH:** use a reputable SSH client app that generates its **own** keypair (private key stays on the phone). Add its public key to the home base / laptop `authorized_keys`. Do **not** rely on tailscale-ssh.

## Switch order (avoid locking yourself out)

When migrating between control planes, **switch the home base first** (while you
can reliably reach it), verify, then switch laptops/phones. Never switch the home
base when you can't reach it. `bin/tailnet-mode {china|usa}` encodes this for the
home base/laptop; phones switch in the app.
