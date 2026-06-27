# VPS & line selection for China

The single most important deployment choice. A perfect Headscale setup on a
badly-routed VPS is unusable from China. Measure before you commit.

## How the GFW actually blocks (this reframes everything)

Research (gfw.report; USENIX Security 2023) shows the common case is **temporary,
per-(your IP + server IP + port) residual blocking** that lasts only ~120–180s
after a triggering connection, then auto-clears. Implications:

- "Change to another IP in the same block — the whole range is permanently blacklisted" is **mostly a misconception** for the common case.
- Blocking is triggered by **connection content** (ESNI/SNI/protocol fingerprints), not by which cloud owns the IP or its "reputation."
- **Hardening the connection** (DERP over plain TLS 443 to your own domain; no public STUN fingerprint) matters more than hunting for a "clean" IP.
- The GFW *also* has full-IP RST blocks and occasional 443 blocks, but those are not the main mechanism.

**Anti-block escape hatch:** treat the **domain + node keys** as the permanent
identity and the **VPS public IP** as a swappable outer layer. If an IP does get
blocked, re-point the domain's A record to a new IP — devices reconnect with no
re-enrollment. (See `lifecycle-and-recovery.md`.)

## Routing reality by China ISP

The bottleneck is usually the **route from the user's ISP to the VPS**, not the cloud brand.

| ISP | Reality |
|-----|---------|
| **China Telecom** | Routes to mass-market clouds (DigitalOcean, Vultr, Linode, etc.) are frequently congested — high latency and timeouts, especially at peak. The reliable Telecom path is **CN2 GIA** (premium AS4809 end-to-end). |
| **China Unicom** | Generally good to Japan/Korea/Singapore (AS4837/9929). Most mass clouds in East Asia work acceptably. |
| **China Mobile** | Variable; Korea (Seoul) regions often test best among mass clouds. |

If you don't know which ISP/route the user will be on (e.g. a cable/broadband
provider that borrows Telecom *or* Unicom transit unpredictably), **CN2 GIA
removes that uncertainty** because all three networks get a premium path.

## Provider guidance

- **Prefer a provider with a premium China route if Telecom is in the mix.** CN2 GIA hosts are the dependable Telecom answer (typically billed quarterly/yearly, not hourly — good as an always-on or primary line).
- **For non-Telecom, mass clouds in JP/KR/SG** (e.g. a Seoul region) are often the best all-around hourly/on-demand option.
- **Avoid China-company clouds** (e.g. mainland-affiliated "HK lite" offerings) for this purpose: privacy exposure, monthly-only billing that defeats on-demand, and account-suspension reports for "cross-border access" use.
- **A phone on an overseas roaming/eSIM plan** (traffic egresses abroad) is a useful fallback and emergency back door, unaffected by domestic routing.

## Measure before committing — itdog.cn

Most providers publish a free **test IP** you can probe without buying anything.

1. Open `https://www.itdog.cn/ping/<TEST_IP>` (or the TCP-port test for 443).
2. **Confirm the input box shows YOUR target IP** — the page can show cached example data for a different IP. Match results by the responding IP.
3. Run a single test; wait for 100%; read the per-province, three-network results.
4. Compare **timeout rate** and **latency** for the user's ISP/region. A good CN2 GIA line shows low timeout rate and ~150ms-ish across all three networks; a poorly-routed mass cloud can show 40–50% timeouts on Telecom.

`check-host.net` is a secondary option (has an API) but has very few China nodes.

## On-demand vs always-on

- **On-demand** (destroy when not traveling, rebuild before a trip): lowest cost and zero attack surface while idle. Best paired with a pinned home-base IP + domain re-point so devices reconnect automatically. CN2 GIA's quarterly billing makes it more of an always-on choice; mass clouds bill hourly and suit on-demand.
- **Always-on**: simpler; keep it hardened and monitored (`bin/vpn-watchdog.sh`).

## Don't bother with (already investigated, negative)

- **Cloudflare orange-cloud proxy to hide the origin:** doesn't work — CF's proxy can't carry Headscale's TS2021 Noise/HTTP2 handshake and won't relay DERP's UDP STUN; CF is also targeted in China. Use Cloudflare as **plain DNS only**.
- **Reserved/floating IPs for anti-block:** wrong direction — they keep an IP stable across backend swaps; you want the opposite (swap the blocked outer IP). The fix is domain re-pointing.
