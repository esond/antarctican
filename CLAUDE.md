# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Configuration repo for an Unraid home server named `antarctican`. Contains Docker Compose stacks (deployed via the Unraid **Docker Compose Manager** plugin) and shell/Python scripts (deployed via the Unraid **User Scripts** plugin). There is no build system, no tests, no CI — edits land on the Unraid host by being copied/pulled there and then started from the corresponding plugin UI.

## Layout convention

Each top-level directory is one independently-deployable stack:

- `docker-compose.<stack>.yml` — the compose file for that stack (filename includes the stack name, not the default `docker-compose.yml`)
- `.env.example` — template; the real `.env` lives next to it on the Unraid host and is gitignored

Stacks present: `media/` (arrs + qbittorrentvpn + swag + seerr + notifiarr + unpackerr), `plex/` (plex + tautulli + tunarr), `pihole/`, `notes/` (couchdb), `urbackup/`, `utils/` (krusader). `shared/` is intentionally empty (a placeholder mount point on the host). `user-scripts/` is **not** compose — it holds scripts for the User Scripts plugin.

When adding a new stack, follow the same shape: new dir, `docker-compose.<name>.yml`, matching `.env.example`.

## Conventions baked into every compose file

- **User/group:** for images that support it, containers run as `PUID=99` / `PGID=100` (Unraid's `nobody:users`) — pass these through by default. Some upstream images run as a fixed non-root UID and don't honor `PUID`/`PGID` (e.g. `seerr` runs as `node` / UID 1000); follow the upstream image's user model in those cases instead of forcing the vars in.
- **Path variables:** `${APPDATA}` → `/mnt/user/appdata` (per-container config), `${DATA}` → `/mnt/user/data` (media + torrents using the [TRaSH guides](https://trash-guides.info/) layout), `${BACKUP}` → backup share. Volumes use these — never hardcode `/mnt/user/...` paths.
- **Timezone:** `${TZ}` is passed to every container.
- **Ports:** host ports come from env vars (`${SERVICE_HOST_PORT}`), container-internal ports stay literal. This keeps port remapping a one-line `.env` change.
- **Networks:** each stack defines its own bridge network named `<stack>-net` (e.g. `media-net`). `plex` and `urbackup` use `network_mode: host` instead — don't "fix" that, it's intentional (Plex discovery, UrBackup client discovery).
- **Restart policy:** `unless-stopped` everywhere.
- **Unraid WebUI labels:** some services set `net.unraid.docker.webui` / `net.unraid.docker.icon` labels so the Unraid Docker tab links work — preserve these when editing.
- **`.env.example` discipline:** when you add an env var to a compose file, also add it to that stack's `.env.example` with a placeholder/default. Real secrets only ever live in the local `.env` (gitignored).

## Notable cross-cutting pieces

- **SWAG** (in `media/`) is the reverse proxy / TLS terminator for the `antarctican.tv` wildcard via Cloudflare DNS-01. It owns ports 80/443/81 on the host. Other stacks expose their UIs on non-standard ports and SWAG fronts them — keep that in mind when changing ports.
- **qbittorrentvpn** runs `privileged: true` with WireGuard via ProtonVPN and exposes its WebUI + torrent ports through the VPN tunnel. The `arr`s and unpackerr depend on it (via `depends_on`) and reach it on the `media-net` bridge.
- **Notifiarr** mounts `/var/run/utmp` and `/etc/machine-id` from the host — required for its hardware/host fingerprinting; don't drop those mounts.
- **Tunarr** uses `tmpfs` for `/transcode` (RAM transcoding) and passes `/dev/dri` for Intel QuickSync. Plex transcodes to `/tmp/plex` on the host.

## user-scripts/

Shell scripts intended to be pasted into the Unraid User Scripts plugin and run on a schedule (not via cron in this repo, not via compose).

- `clean-empty-share-directories.sh` — prunes empty dirs across array disks for a given share. Ships with the `find ... -delete` line **commented out** as a safety default; uncomment when you actually want it to delete.
- `qbittorrent-mover/` — pauses torrents on the cache mount, runs Unraid's `mover`, then resumes them. Setup is three steps documented in its README: install `qbittorrent-api` via pip (`install-qbittorrent-api.sh`), drop `mover.py` somewhere on the host, and schedule `orchestrator.sh`. The hardcoded creds/IP at the top of `orchestrator.sh` are placeholders — they're meant to be edited on the host, not committed.

## Editing workflow

- Compose changes are validated by deploying — there is no local lint step. If you want a quick syntax check, `docker compose -f <stack>/docker-compose.<stack>.yml config` works (requires a populated `.env` next to the file).
- Don't add a root-level `docker-compose.yml`; the per-stack split is the whole point — each stack is started/stopped independently from the Unraid Compose plugin.
