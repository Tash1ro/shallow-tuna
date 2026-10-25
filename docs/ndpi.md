# Block BitTorrent through the VPN (nDPI / xt_ndpi)

Drops BitTorrent traffic transiting the VPN using **nDPI deep packet
inspection**. Detection is flow-based, so it catches **encrypted (MSE/PE)**
torrents and DHT/uTP — not just plaintext handshakes or well-known ports.

> **Target:** Ubuntu 24.04. The `xt_ndpi` kernel module ships as a DKMS package
> (see [`../ndpi`](../ndpi)); DKMS builds it against the running kernel and
> rebuilds it **automatically** on kernel upgrades.

## How it works

```
VPN client ──▶ wg0 (inside container) ──▶ MASQUERADE (inside container)
          ──▶ docker bridge ──▶ host FORWARD ──▶ uplink
                                      ▲
                          DOCKER-USER chain: -m ndpi --proto bittorrent -j DROP
```

Two pieces, split by what can be containerized:

- **`xt_ndpi.ko` — on the host** (`xt-ndpi-dkms`). A kernel module can't live in
  a container; DKMS builds it against the host kernel and auto-loads it at boot.
- **The DROP rule — the `xt-ndpi-rules` compose service.** A `network_mode:
  host` container (mirroring `host-routing`) that bundles `libxt_ndpi.so` and
  runs `manage.sh attach`/`detach` to add/remove the `-m ndpi` rule on the
  host's **`DOCKER-USER`** chain — the supported hook for user rules, not
  flushed on container restart. It must be a Debian/Ubuntu image (the glibc
  `libxt_ndpi.so` can't load under Alpine/musl).

The rule (which protocols, which chain) is service config in
`compose.yml` — `NDPI_DROP` / `NDPI_CHAIN` — not a host file.

## Install

```bash
# 1. Build the .deb packages (no root needed)
./setup-host/ndpi-setup.sh build            # -> ../ndpi/artifacts/*.deb

# 2. Install the host kernel module (DKMS builds + auto-loads xt_ndpi)
sudo ./setup-host/ndpi-setup.sh install

# 3. Bring up the rule service (builds its image from the iptables .deb)
docker compose up -d --build xt-ndpi-rules
```

`build` produces `xt-ndpi-dkms` (installed on the host) and `xt-ndpi-iptables`
(its `libxt_ndpi.so` is baked into the `xt-ndpi-rules` image). The nDPI revision
is pinned in [`../ndpi/NDPI_REF`](../ndpi/NDPI_REF); override per build with
`NDPI_REF=<tag|commit> ./setup-host/ndpi-setup.sh build`.

## Configure the rule

On the `xt-ndpi-rules` service in `compose.yml`:

```yaml
environment:
  - NDPI_CHAIN=DOCKER-USER                       # chain to apply rules to
  - NDPI_DROP=bittorrent                         # nDPI protocols (comma list)
  - NDPI_SOURCE=172.100.0.0/24                   # exit subnets to enforce on (comma list)
```

`NDPI_SOURCE` is a comma-separated list of **source subnets**; one rule is
installed per subnet, so the drop only touches VPN traffic, not everything
forwarded. Because traffic is MASQUERADEd to its exit subnet inside the
container, the source seen on `DOCKER-USER` is the exit network — so each
subnet = one exit:

| Exit  | Subnet            | Defined in          |
|-------|-------------------|---------------------|
| exit1 | `172.100.0.0/24`  | `compose.yml`       |
| exit2 | `172.101.0.0/24`  | `compose.exit2.yml` |

**Choose which exits enforce blocking** by listing their subnets:

- exit1 only (the default) → `NDPI_SOURCE=172.100.0.0/24`
- both exits (default once `compose.exit2.yml` is loaded) → `NDPI_SOURCE=172.100.0.0/24,172.101.0.0/24`
- everything forwarded (not just VPN) → `NDPI_SOURCE=` (empty)

After changing any of these, `docker compose up -d xt-ndpi-rules` to re-apply.

## Maintenance — kernel upgrades

Nothing to do. DKMS rebuilds `xt_ndpi` for the new kernel automatically on
upgrade (via `/etc/kernel/postinst.d/dkms`), so it keeps loading across reboots.

## Verify it's working

```bash
sudo ./setup-host/ndpi-setup.sh status          # module + package + service
docker logs xt-ndpi-rules                        # "dropping [bittorrent] on DOCKER-USER"

# rule counters should climb while a test torrent runs:
sudo iptables -n -L DOCKER-USER -v --line-numbers | grep ndpi
```

Functional test: connect a client to the VPN, start a well-seeded torrent
(e.g. a Linux ISO), confirm peers fail to connect / transfer stalls. nDPI
classifies a flow after its first few packets, so the very first packets of
each connection pass before the flow is tagged — the connection still dies,
it's just not a packet-1 block.

> **Backend note:** `manage.sh` auto-detects which iptables backend owns the
> target chain (legacy vs nft) and uses that, so it follows whatever dockerd
> chose for `DOCKER-USER`. If the chain exists in neither backend it fails
> loudly (the container exits) rather than silently doing nothing.

## Remove

```bash
docker compose down xt-ndpi-rules          # detaches the rule, stops the service
sudo ./setup-host/ndpi-setup.sh uninstall  # unloads + purges the kernel module
```

## Commands (`ndpi-setup.sh`)

| Command     | Action                                                        |
|-------------|---------------------------------------------------------------|
| `build`     | Build the `.deb` packages with Docker Compose (no root)       |
| `install`   | Install `xt-ndpi-dkms` (the host kernel module)               |
| `status`    | Show package / module / rule-service state                    |
| `uninstall` | Unload and purge the kernel module                            |

The rule itself is brought up/down with `docker compose up/down xt-ndpi-rules`.