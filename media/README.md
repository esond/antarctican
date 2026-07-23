# media stack

The main media-management stack: the *arr* apps plus qBittorrent (behind a VPN) for
acquiring content, SWAG terminating TLS for everything on `antarctican.tv`, and Seerr for
requests. Deployed from `docker-compose.media.yml` via the Docker Compose Manager plugin.

## Services

| Service | Image | Purpose | UI port |
|---|---|---|---|
| `qbittorrentvpn` | binhex/arch-qbittorrentvpn | Torrent client routed through ProtonVPN (WireGuard) | `${QBITTORRENT_WEBUI_PORT}` |
| `prowlarr` | linuxserver/prowlarr | Indexer manager, feeds the arrs | `${PROWLARR_HOST_PORT}` |
| `flaresolverr` | 21hsmw/flaresolverr | Cloudflare challenge solver for Prowlarr | `${FLARESOLVERR_HOST_PORT}` |
| `sonarr-uhd` | linuxserver/sonarr | TV management | `${SONARR_UHD_HOST_PORT}` |
| `radarr-uhd` | linuxserver/radarr | Movie management | `${RADARR_UHD_HOST_PORT}` |
| `unpackerr` | golift/unpackerr | Extracts completed archives for the arrs | — |
| `notifiarr` | golift/notifiarr | Notifications / Discord integration | `${NOTIFIARR_HOST_PORT}` |
| `seerr` | seerr-team/seerr | Media request UI | `${SEERR_HOST_PORT}` |
| `swag` | linuxserver/swag | Reverse proxy + TLS (`antarctican.tv` wildcard) | `81` (dashboard) |
| `dockersocket` | tecnativa/docker-socket-proxy | Scoped Docker API for healarr | — |
| `healarr` | binhex/arch-healarr | Restarts qbittorrentvpn when its VPN port stalls | — |

The arrs and `unpackerr` `depends_on` `qbittorrentvpn` and reach it over the `media-net`
bridge. SWAG fronts the other UIs and owns 80/443/81 on the host.

## Deploying

1. Copy `.env.example` to `.env` and fill it in.
2. Place the ProtonVPN WireGuard config (below) — the one manual step compose can't do.
3. Start the stack from the Compose Manager plugin.

## qBittorrent — ProtonVPN over WireGuard

The compose side is already done (`VPN_PROV=protonvpn`, `VPN_CLIENT=wireguard`,
`privileged: true`, the `net.ipv4.conf.all.src_valid_mark` sysctl). The missing piece is
the WireGuard config file itself, which binhex only auto-generates for PIA — for ProtonVPN
you place it by hand.

### 1. Generate the config at Proton

1. Sign in at [account.protonvpn.com](https://account.protonvpn.com) → **Downloads** →
   **WireGuard configuration**.
2. Name it something identifiable (e.g. `antarctican-qbt`), platform **GNU/Linux**.
3. Under **Select VPN options**, turn **NAT-PMP (port forwarding)** on. Leave VPN
   Accelerator on.
4. Pick a **P2P server** — the ones marked with the double-arrow icon.
5. Download the `.conf`.

Both of those options matter. A config generated without NAT-PMP connects fine but never
gets a forwarded port, and a non-P2P server silently drops torrent traffic. Neither
failure is obvious from the logs.

### 2. Place it on the host

```sh
mkdir -p /mnt/user/appdata/qbittorrentvpn/wireguard
cp /path/to/proton-download.conf /mnt/user/appdata/qbittorrentvpn/wireguard/wg0.conf
chown 99:100 /mnt/user/appdata/qbittorrentvpn/wireguard/wg0.conf
chmod 600 /mnt/user/appdata/qbittorrentvpn/wireguard/wg0.conf
```

The filename must be exactly `wg0.conf`, and it should be the only `.conf` in that
directory.

### 3. Check the compose/env values

- `LAN_NETWORK` is hardcoded to `192.168.1.0/24` in `docker-compose.media.yml`. If that
  isn't the host's subnet, the kill-switch iptables rules will lock you out of the WebUI.
- `QBITTORRENT_VPN_USER` / `QBITTORRENT_VPN_PASS` are only consumed by the OpenVPN code
  path. Under WireGuard, auth is entirely key-based out of `wg0.conf`, so the `+pmp`
  suffix on the username (the OpenVPN way of requesting port forwarding) does nothing
  here. Harmless, just inert — leave them or blank them, it makes no difference.

### 4. Restart and verify

```sh
docker restart qbittorrentvpn
tail -f /mnt/user/appdata/qbittorrentvpn/supervisord.log
```

Watch for the WireGuard interface coming up, then a line reporting the NAT-PMP assigned
incoming port. binhex writes that port into qBittorrent's config automatically.

Then confirm:

- WebUI reachable on `${QBITTORRENT_WEBUI_PORT}`.
- Tools → Options → Connection shows the Proton-assigned port — a random high port, **not**
  `QBITTORRENT_TORRENTING_PORT`.
- Traffic is actually leaving through the tunnel:

  ```sh
  docker exec qbittorrentvpn curl -s ifconfig.io
  ```

  Should return the Proton exit IP, not the house IP.

## Self-healing the forwarded port

NAT-PMP renewal fails silently on Proton with these images
([#265](https://github.com/binhex/arch-qbittorrentvpn/issues/265),
[#298](https://github.com/binhex/arch-qbittorrentvpn/issues/298)): after some hours or days
port forwarding stops, torrents go from healthy to zero incoming connections with the VPN
still up, and the container has to be restarted to recover.

The stack handles this automatically. `qbittorrentvpn` has a `healthcheck` that curls its
own WebUI on localhost and goes **unhealthy** when qBittorrent reports
`connection_status: firewalled` (the closed-port symptom). `healarr` watches that health
status and `docker restart`s the container to force a fresh VPN reconnect + port
negotiation. healarr reaches the Docker API only through `dockersocket`, a
`docker-socket-proxy` scoped to container read + POST, so nothing in the stack touches the
raw `docker.sock`. End to end a stall self-heals in roughly two minutes.

## Notes

- **The forwarded port is ephemeral and rotates.** Incoming peer connections arrive over
  the tunnel on whatever port NAT-PMP hands out, so the published
  `QBITTORRENT_TORRENTING_PORT` mapping in compose does nothing for them — qBittorrent
  isn't listening on that port. It's vestigial under this setup; changing it won't fix a
  connectivity problem.
- **Server changes need a new config.** A Proton WireGuard config is pinned to one server.
  To move to a different one, regenerate at Proton and replace `wg0.conf`.
- **The arrs depend on this container.** `sonarr-uhd`, `radarr-uhd`, and `unpackerr` reach
  qBittorrent over `media-net`, so a restart (including healarr's) briefly breaks their
  download-client connection. They recover on their own.

## References

- [Proton VPN — manual port forwarding setup](https://protonvpn.com/support/port-forwarding-manual-setup)
- [binhex/arch-qbittorrentvpn README](https://github.com/binhex/arch-qbittorrentvpn)
- [binhex VPN FAQ](https://github.com/binhex/documentation/blob/master/docker/faq/vpn.md)
