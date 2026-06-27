# Headscale setup: config, ACL, DNS, and the gotchas

Use `vps/install-headscale.sh` to deploy. This explains what it lands and the
non-obvious traps (each one cost real debugging time).

## Install

On a fresh Ubuntu 22.04/24.04 VPS, copy `install-headscale.sh`,
`headscale-config.yaml.tmpl`, and `acl.hujson.tmpl` together, then:

```bash
HS_HOSTNAME=hs.example.com VPS_IP=<public-ip> HS_USER=<name> \
  [HOMEBASE_TAILNET_IP=100.64.0.10] bash install-headscale.sh
```

Prereq: the DNS A record `hs.example.com → <public-ip>` is already live
(DNS-only). The script issues the cert over 443 via TLS-ALPN-01 at the end.

## config.yaml — what matters

- **`listen_addr: 0.0.0.0:443`** — control plane + DERP-over-HTTPS on the one public port.
- **TLS-ALPN-01** (not HTTP-01): issuance and renewal both use 443. You never need port 80, so there's no "renewal fails because 80 is closed" self-lock.
- **Built-in DERP, self-only** (`urls: []`, `paths: []`): clients relay only through your VPS, never detouring to official relays abroad. `ipv4` is the VPS public IP.
- **STUN bound to `127.0.0.1:3478`** and not opened in the firewall: a public STUN endpoint emits a cleartext magic-cookie the GFW can fingerprint as a personal relay. Hiding it costs nothing — hole-punching into China usually fails anyway, so traffic rides the 443 relay.
- **DNS:** `magic_dns: true`, `base_domain: tailnet.internal` (the ICANN-reserved private TLD — never collides), and crucially **`override_local_dns: false`** with **`nameservers.global: []`**. This means a device with `accept-dns` on sends only your split domain + MagicDNS short names through Tailscale; all other DNS stays on the device's local (China-usable) resolver. If you instead set `override_local_dns: true` or put `1.1.1.1`/`8.8.8.8` in `global`, the device forces *all* DNS through them — and those are commonly tampered with in China, so normal browsing breaks.
- **split-DNS + `extra_records`:** hand a private service domain (the template uses `pc`) to the home base's local DNS, and also add static A records so `<name>.pc` resolves **locally without forwarding** — which keeps `.pc` working even when an exit node is on (an exit node captures the split-DNS forwarding). `extra_records` has no wildcard; list each name.

## ACL — what matters

`acl.hujson.tmpl` is a **named-tag, minimal-allow** policy:

- Tags: `homebase`, `laptop`, `phone`, `vps`, `cn-exit`. Owner is your Headscale username (`__OWNER__@`, substituted by the installer).
- Only the ports the home base actually serves are allowed (22/53/80 + your app ports), and only from your own devices. No `src:* dst:*`.
- **No `ssh` block** (tailscale-ssh is off everywhere) and **no autoApprovers** (exit/subnet routes are approved by hand).
- **One-way isolation for `cn-exit`:** it appears only as a *destination* (others may SSH into it); it has **no `src` rule anywhere**, so it cannot initiate to anything. Even if that box is compromised it can't reach the rest of the mesh. See `exit-nodes.md`.

Remember: under "control plane compromised," tag/user ACLs are not a hard
boundary (an attacker who owns Headscale can re-tag their node). The hard
boundary is device-local pubkey-only sshd. The ACL is defense in depth.

## Gotchas (all encoded in the installer — keep them if you edit it)

1. **Pin the Headscale version.** GitHub "latest" can point at a beta. The template pins a known-good stable (`v0.28.0`); bump deliberately, not blindly.
2. **Data dir ownership.** Any `headscale` command run as root (including `configtest`) writes **root-owned** derp/noise keys under `/var/lib/headscale`; the service runs as `User=headscale` and then can't read them → crash loop. Fix: `chown -R headscale:headscale /var/lib/headscale` before starting (the installer does this).
3. **Use `systemctl restart`, not `enable --now`.** The `.deb` postinst may already have started headscale once with the **default** config (127.0.0.1:8080, no TLS, DERP off). `enable --now` won't restart an already-running service, so your config never loads. An explicit `restart` forces it.
4. **Verify health at the end:** `curl https://<host>/health` should return 200 (the installer does this; it also triggers first cert issuance).

## v0.28 CLI specifics (version-sensitive — verify against your version)

- `headscale preauthkeys create -u <N>` takes a **numeric user ID** (e.g. `-u 1`). `-u` exists only on `create`; `preauthkeys list` and `expire` do NOT accept it, and `expire` takes `--id <ID>` (the key's numeric ID from `list`), not the key string.
- `headscale nodes register --user <name>` takes the **username string**.
- There is **no `headscale routes` command**; use `headscale nodes list-routes` and `headscale nodes approve-routes -i <id> -r <cidr,...>`.
- **Pin a node's IP:** `systemctl stop headscale` → `sqlite3 /var/lib/headscale/db.sqlite "UPDATE nodes SET ipv4='100.64.0.10' WHERE id=<N>;"` → `systemctl start headscale` (column is `ipv4`).
- **Policy hot reload:** after editing `/etc/headscale/acl.hujson`, validate with `headscale policy check --file /etc/headscale/acl.hujson` and reload **without** restarting the process (`systemctl reload headscale` / `SIGHUP`) — additive ACL changes apply with zero disruption. Avoid full restarts when someone is depending on the link.
