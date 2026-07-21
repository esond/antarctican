# qbittorrentvpn — ProtonVPN over WireGuard

Setup notes for the `qbittorrentvpn` service in `docker-compose.media.yml`. The compose
side is already done (`VPN_PROV=protonvpn`, `VPN_CLIENT=wireguard`, `privileged: true`,
the `net.ipv4.conf.all.src_valid_mark` sysctl). The missing piece is the WireGuard config
file itself, which binhex only auto-generates for PIA — for ProtonVPN you place it by hand.

## 1. Generate the config at Proton

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

## 2. Place it on the host

```sh
mkdir -p /mnt/user/appdata/qbittorrentvpn/wireguard
cp /path/to/proton-download.conf /mnt/user/appdata/qbittorrentvpn/wireguard/wg0.conf
chown 99:100 /mnt/user/appdata/qbittorrentvpn/wireguard/wg0.conf
chmod 600 /mnt/user/appdata/qbittorrentvpn/wireguard/wg0.conf
```

The filename must be exactly `wg0.conf`, and it should be the only `.conf` in that
directory.

## 3. Check the compose/env values

- `LAN_NETWORK` is hardcoded to `192.168.1.0/24` in `docker-compose.media.yml`. If that
  isn't the host's subnet, the kill-switch iptables rules will lock you out of the WebUI.
- `QBITTORRENT_VPN_USER` / `QBITTORRENT_VPN_PASS` are only consumed by the OpenVPN code
  path. Under WireGuard, auth is entirely key-based out of `wg0.conf`, so the `+pmp`
  suffix on the username (the OpenVPN way of requesting port forwarding) does nothing
  here. Harmless, just inert — leave them or blank them, it makes no difference.

## 4. Restart and verify

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

## Gotchas

- **The forwarded port is ephemeral and rotates.** Incoming peer connections arrive over
  the tunnel on whatever port NAT-PMP hands out, so the published
  `QBITTORRENT_TORRENTING_PORT` mapping in compose does nothing for them — qBittorrent
  isn't listening on that port. It's vestigial under this setup; changing it won't fix a
  connectivity problem.
- **NAT-PMP renewal fails silently.** Long-standing issue with Proton on these images
  ([#265](https://github.com/binhex/arch-qbittorrentvpn/issues/265),
  [#298](https://github.com/binhex/arch-qbittorrentvpn/issues/298)): port forwarding stops
  after some hours or days, and the container has to be restarted to recover. Symptom is
  torrents going from healthy to zero incoming connections with the VPN still up. If it
  becomes a regular annoyance, a scheduled `docker restart qbittorrentvpn` from the User
  Scripts plugin is the usual workaround.
- **Server changes need a new config.** A Proton WireGuard config is pinned to one server.
  To move to a different one, regenerate at Proton and replace `wg0.conf`.
- **The arrs depend on this container.** `sonarr-uhd`, `radarr-uhd`, and `unpackerr` reach
  qBittorrent over `media-net`, so a restart briefly breaks their download-client
  connection. They recover on their own.

## References

- [Proton VPN — manual port forwarding setup](https://protonvpn.com/support/port-forwarding-manual-setup)
- [binhex/arch-qbittorrentvpn README](https://github.com/binhex/arch-qbittorrentvpn)
- [binhex VPN FAQ](https://github.com/binhex/documentation/blob/master/docker/faq/vpn.md)
