# WireGuard VPN with Multi-IP Exit Routing

Deploy WireGuard and AmneziaWG VPN servers with per-client exit IP routing.

## Features

- **awg-easy** — wg-easy v15 in AmneziaWG mode (obfuscated WireGuard) with web UI
- **wg-easy** — Standard WireGuard with web UI
- **Multi-IP exit routing** — Route different clients through different external IPs
  (one exit by default; `compose.exit2.yml` adds a second)
- **Persistent client assignments** — Survive container restarts
- **Automatic host SNAT** — `host-routing` service manages iptables rules via Docker Compose
- **DPI filtering (nDPI)** — Drop BitTorrent (or other nDPI-classified protocols)
  **per-exit**, via the `xt_ndpi` kernel module + an `xt-ndpi-rules` Compose service

## Prerequisites

- Docker and Docker Compose
- Multiple external IPs on the host (for multi-IP routing with a second exit)
- SSH access for admin panel tunneling

## Quick Start

### 1. Clone and configure

```bash
git clone <repo>
cp .env.example .env
```

Edit `.env`:

```bash
# Custom AmneziaWG port (optional, default 51820; must match the WireGuard
# port set later in the awg-easy web UI)
# AWG_PORT=3127

# Exit routing: gateway:external_ip pairs (one per exit network)
# Tables auto-assigned: 100, 101, 102...
EXIT_ROUTES=172.100.0.1:1.2.3.4
```

Server host, DNS, allowed IPs, the admin account and AmneziaWG obfuscation
params are configured in the awg-easy web UI on first run.

### 2. Configure additional IPs on the host

Only needed with more than one exit (see [Adding a second exit](#adding-a-second-exit)).
Add a secondary IP to your network interface. Example for netplan (`/etc/netplan/01-netcfg.yaml`):

```yaml
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - "1.2.3.4/24"
        - "2.3.4.5/24"
      routes:
        - to: default
          via: 1.2.3.1
```

Apply: `sudo netplan apply`

### 3. Start containers

```bash
docker compose up -d
```

The `host-routing` service automatically attaches SNAT rules and detaches them on `docker compose down`.

### 4. Access admin panels

Admin panels are bound to localhost. Use SSH tunnels:

```bash
# AmneziaWG (port 51821)
ssh -L 51821:127.0.0.1:51821 user@server

# wg-easy (port 51831)
ssh -L 51831:127.0.0.1:51831 user@server
```

Then open:
- http://localhost:51821 — AmneziaWG
- http://localhost:51831 — WireGuard

## Multi-IP Exit Routing

### How it works

1. Each exit is a Docker network: `exit1` (`172.100.0.0/24`) in `compose.yml`,
   `exit2` (`172.101.0.0/24`) in the `compose.exit2.yml` overlay
2. `services/wg-easy/routing-init.sh` creates routing tables inside containers (100, 101, ...)
3. `host-routing` service adds SNAT rules on the host to map subnets to external IPs
4. Per-client routing rules send traffic through specific tables

### Assign a client to exit IP

```bash
# Route client 10.8.0.3 through exit2 network
./assign-exit.sh add 10.8.0.3 exit2

# Remove assignment
./assign-exit.sh remove 10.8.0.3

# List available networks and current assignments
./assign-exit.sh list
```

The container is detected automatically (`awg-easy` or `wg-easy`). When both run,
name it explicitly: `./assign-exit.sh wg-easy list`.

### Check current SNAT rules

```bash
docker compose exec host-routing sh /app/manage.sh status
```

### Adding a second exit

The base stack has a single exit (`exit1`). `compose.exit2.yml` is an overlay
that adds `exit2` (`172.101.0.0/24`): it attaches `awg-easy` to the network,
extends the default `NDPI_SOURCE` to both exits and adds the `ndpi-probe-exit2`
verify helper. Load it together with `compose.yml`:

```bash
# .envrc (direnv) or exported in the shell
export COMPOSE_FILE=compose.yml:compose.exit2.yml

# plus the plain-WireGuard overlay, if used
export COMPOSE_FILE=compose.yml:compose.wg.yml:compose.exit2.yml
```

Then give the second exit its own external IP in `.env` (the host must have it,
see [step 2](#2-configure-additional-ips-on-the-host)) and recreate the stack:

```bash
EXIT_ROUTES=172.100.0.1:1.2.3.4,172.101.0.1:2.3.4.5
```

```bash
docker compose up -d
./assign-exit.sh list      # exit2 is now available
```

`compose.exit2.yml` only attaches `awg-easy`. To put `wg-easy` on `exit2` as well,
add the same `networks` entry for it in a `compose.override.yml` (gitignored):

```yaml
services:
  wg-easy:
    networks:
      - exit2
```

A third exit follows the same pattern: copy `compose.exit2.yml`, rename the
network, pick the next subnet (`172.102.0.0/24`) and append one more
`gateway:external_ip` pair to `EXIT_ROUTES`.

## DPI filtering — block BitTorrent (and other protocols)

Drop traffic that **nDPI** deep-packet-inspection classifies as a given protocol
(BitTorrent by default) on the VPN exits — this catches **encrypted (MSE/PE)**
torrents and DHT/uTP, not just plaintext or well-known ports. Blocking is
**per-exit**: you choose which exits enforce it.

### How it works

1. **`xt-ndpi-dkms`** — the out-of-tree `xt_ndpi` netfilter kernel module,
   installed on the host via DKMS (auto-rebuilt on kernel upgrades). It provides
   the iptables `-m ndpi` match.
2. **`xt-ndpi-rules`** — a Compose service (host netns, mirrors `host-routing`)
   that applies `-m ndpi --proto <p> -j DROP` to Docker's **`DOCKER-USER`** chain,
   scoped to the chosen exit subnets, and re-applies on Docker restart. It bundles
   the userspace `libxt_ndpi.so` match.

Because VPN traffic is MASQUERADEd to its exit subnet *inside* the container, the
source seen on `DOCKER-USER` is the exit network — so a source-scoped rule acts as
a **per-exit on/off switch**. (`DOCKER-USER` is in `FORWARD`, before host SNAT, so
this composes cleanly with `host-routing`.)

### Setup

```bash
# 1. Build the .deb packages (Docker; no root)
./setup-host/ndpi-setup.sh build

# 2. Install the host kernel module (DKMS builds xt_ndpi for the running kernel)
sudo ./setup-host/ndpi-setup.sh install

# 3. Bring up the rule service (or `docker compose up -d` the whole stack)
docker compose up -d --build xt-ndpi-rules
```

> The `xt-ndpi-rules` image bundles `libxt_ndpi.so` from the `.deb`s, so run
> step 1 (`ndpi-setup.sh build`) before any `docker compose up -d` — otherwise
> that service's image build fails on the missing package.

### Configure

On the `xt-ndpi-rules` service in `compose.yml` (or via `.env`):

```yaml
environment:
  - NDPI_DROP=bittorrent                       # protocols (comma list)
  - NDPI_CHAIN=DOCKER-USER                      # chain to apply rules to
  - NDPI_SOURCE=172.100.0.0/24                  # exit subnets to enforce on (comma list)
```

Choose which exits enforce blocking (exit1 = `172.100.0.0/24`, exit2 = `172.101.0.0/24`):

- only exit1 → `NDPI_SOURCE=172.100.0.0/24` (the default; with `compose.exit2.yml` this leaves exit2 open)
- both exits → `NDPI_SOURCE=172.100.0.0/24,172.101.0.0/24` (the default once `compose.exit2.yml` is loaded)
- all forwarded traffic → `NDPI_SOURCE=` (empty)

Re-apply with `docker compose up -d xt-ndpi-rules`.

### Verify

```bash
./services/xt-ndpi-rules/verify.sh   # end-to-end checks (no sudo, all via docker compose)
docker logs xt-ndpi-rules        # "dropping [bittorrent] from [...] on DOCKER-USER"
docker exec xt-ndpi-rules iptables-legacy -nvL DOCKER-USER | grep ndpi   # live counters
```

See [`docs/ndpi.md`](docs/ndpi.md) for the full details.

## Junk packet generator (`awg-junk-gen.py`)

Generates AmneziaWG **I1–I5** special junk packets that are byte-valid **QUIC v1
Initial** packets carrying a real TLS ClientHello. AmneziaWG sends them before the
WireGuard handshake, so the first thing a DPI box sees on the UDP flow is an
ordinary HTTP/3 connection attempt.

Requires `pip install cryptography`.

### Generate

```bash
# One packet, default SNI (bag.itunes.apple.com)
./awg-junk-gen.py

# Pick the hostname the packet appears to connect to
./awg-junk-gen.py --sni cdn.jsdelivr.net

# Three packets for I1, I2, I3
./awg-junk-gen.py --sni www.microsoft.com --count 3
```

Output is ready to paste:

```
I1 = <b 0xc60000000108589ec1b628078cc30000449e0bec2f18...>
I2 = <b 0xc60000000108b3a1a3ef41ed4e5d0000449e9b790755...>
```

### Use it

Put the lines in the `[Interface]` section of the config — **server and client
must carry identical I1–I5 values**, or the handshake never completes. In this
stack the obfuscation params are set in the awg-easy web UI (see
[Quick Start](#1-clone-and-configure)), which propagates them into generated
client configs.

### Options

| Flag | Default | Purpose |
|---------------|------------------------|--------------------------------------------|
| `--sni` | `bag.itunes.apple.com` | Hostname advertised in the ClientHello |
| `--alpn` | `h3` | Comma-separated ALPN list |
| `--count` | `1` | Packets to emit (`I1`, `I2`, …) |
| `--size` | `1200` | Datagram size in bytes |
| `--param` | `I` | Config key prefix (`I` or `J`) |
| `--start` | `1` | First parameter index |
| `--template` | built-in | Clone the fingerprint of your own capture |
| `--format` | `awg` | `awg` / `hex` / `raw` |

Every packet is self-checked before printing: the script decrypts its own output
the way a DPI engine would and aborts if the observed SNI doesn't match.

The built-in ClientHello template is from an iOS HTTP/3 request, so the JA3/JA4
fingerprint reads as an Apple client. `--template file.hex` takes a raw
ClientHello or a full captured Initial packet (as `<b 0x…>`, `0x…` or bare hex)
and clones that fingerprint instead.

### Caveats

- **`<b 0x…>` is a literal byte string**, so one generated packet is replayed
  verbatim on every handshake for that config. What this buys you is a blob
  nobody else is using — unlike one copied from a forum post — plus the ability
  to rotate. It does not make each handshake unique on the wire.
- Pick an SNI plausible for your server's hosting; a CDN hostname is usually
  safer than a first-party domain, since CDN IP space is broad and shared.
- I1–I5 need AmneziaWG **1.5+** on both ends. Older builds silently lack them
  (the `amneziawg-dkms` 1.0.0 kernel module, for instance, has no I-packet
  support even though `awg set` lists the keys).

## File Structure

```
.env                          # Configuration (not committed)
.env.example                  # Example configuration
compose.yml                   # Container definitions (AmneziaWG stack)
compose.wg.yml                # Optional overlay: plain WireGuard wg-easy service
compose.exit2.yml             # Optional overlay: second exit network (exit2)
.envrc.example                # direnv example selecting the compose files
services/
  wg-easy/routing-init.sh     # Container entrypoint for routing tables
  host-routing/               # Host SNAT rule management (Compose service)
    Dockerfile
    daemon.sh                 # Lifecycle: attach on start, detach on stop
    manage.sh                 # attach/detach/status commands
  xt-ndpi-rules/              # nDPI DROP rules on DOCKER-USER (Compose service)
    Dockerfile                # bundles libxt_ndpi.so
    daemon.sh                 # Lifecycle: attach on start, detach on stop
    manage.sh                 # config-driven, per-exit, backend auto-detect
    verify.sh                 # end-to-end verification (via docker compose)
  backup/backup.sh            # workdir/{awg,wg} -> workdir/backups archive (Compose service)
remote/                       # Client-side scripts (run from your machine)
  tuna-adm.sh                 # SSH tunnels to the admin panels
  tuna-backup.sh              # Run the backup service, download archive via pipe
ndpi/                         # nDPI .deb packaging (xt-ndpi-dkms + iptables ext)
  debian/                     # built with Docker Compose into ndpi/artifacts
assign-exit.sh                # Per-client exit IP assignment
awg-junk-gen.py               # Generate AmneziaWG I1-I5 junk packets (QUIC Initials)
backup.sh                     # Cron wrapper: run the backup service, log to workdir/backup.log
setup-host/                   # Host setup scripts
  docker-setup.sh
  wireguard-setup.sh
  amneziawg-setup.sh          # install/fix-dkms/status/uninstall the amneziawg module
  patches/                    # amneziawg-dkms compat fix for newer kernels (auto-applied)
  ndpi-setup.sh               # build/install the xt_ndpi DKMS kernel module
docs/
  ndpi.md                     # DPI filtering docs
```

## Ports

| Service              | Port           | Protocol | Description          |
|----------------------|----------------|----------|----------------------|
| awg-easy (AmneziaWG) | AWG_PORT/udp  | WG       | VPN tunnel           |
| awg-easy (AmneziaWG) | 51821/tcp     | HTTP     | Admin panel (local)  |
| wg-easy  (WireGuard) | WG_PORT/udp   | WG       | VPN tunnel           |
| wg-easy  (WireGuard) | 51831/tcp     | HTTP     | Admin panel (local)  |

## Troubleshooting

### `amneziawg-dkms` fails to build (`setup_udp_tunnel_sock` incompatible pointer type)

The PPA's `amneziawg-dkms` 1.0.0 doesn't compile against kernels that backported
the 7.1.5 `udp_tunnel` API change without bumping the version (Ubuntu
`7.0.0-38+`, 24.04 HWE). `apt` then leaves `amneziawg-dkms` unconfigured and
every later `apt-get install` fails. `amneziawg-setup.sh install` handles this
itself; for a host that is already broken (or after an `amneziawg-dkms` update
replaced the sources):

```bash
sudo ./setup-host/amneziawg-setup.sh fix-dkms   # patch /usr/src/amneziawg-*, dpkg --configure -a, dkms install
sudo ./setup-host/amneziawg-setup.sh status
```

The fix is the upstream (not yet released) [PR #265](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/pull/265),
vendored in `setup-host/patches/`. It is a no-op once the PPA ships a fixed build.

### VPN connected but no internet

1. Check container logs: `docker compose logs awg-easy`
2. Verify routing tables: `docker exec awg-easy ip route show table 100`
3. Check SNAT rules: `docker compose exec host-routing sh /app/manage.sh status`

### Client not using expected exit IP

1. Verify assignment: `./assign-exit.sh list`
2. Check rule inside container: `docker exec awg-easy ip rule show`
3. Toggle VPN on client to force new connection