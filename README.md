# antarctican

Settings, configurations, and scripts for the `antarctican` Unraid home server. Significant acknowledgements made to [TRaSH Guides](https://trash-guides.info/File-and-Folder-Structure/How-to-set-up/Unraid/) for folder setup and other guidelines.

Each top-level directory is one independently-deployable stack via the Unraid Docker Compose Manager plugin. Compose stacks ship `docker-compose.<stack>.yml` plus an `.env.example` template; the real `.env` lives next to it on the host and is gitignored.

## Stacks

| Directory | What it runs |
|---|---|
| [`media/`](media/) | Media management: sonarr / radarr / prowlarr, qBittorrent (VPN), SWAG reverse proxy, Seerr, Notifiarr, Unpackerr |
| [`plex/`](plex/) | Plex, Tautulli, Tunarr |
| [`pihole/`](pihole/) | Pi-hole DNS |
| [`notes/`](notes/) | Obsidian LiveSync setup (CouchDB) |
| [`urbackup/`](urbackup/) | UrBackup server |
| [`utils/`](utils/) | Krusader |
| [`user-scripts/`](user-scripts/) | Shell/Python scripts for the User Scripts plugin (not compose) |

## Conventions

- Containers run as Unraid `nobody:users` (`PUID=99` / `PGID=100`) unless an upstream image dictates otherwise (e.g. Seerr runs as `node` / UID 1000).
- Path env vars: `${APPDATA}` → `/mnt/user/appdata`, `${DATA}` → `/mnt/user/data` ([TRaSH layout](https://trash-guides.info/)), `${BACKUP}` → backup share. Volumes use these — `/mnt/user/...` is never hardcoded.
- Host ports come from `.env` (`${SERVICE_HOST_PORT}`); container-internal ports stay literal. Remap by editing `.env`, never the compose file.
- Each stack has its own `<stack>-net` bridge network. `plex` and `urbackup` use `network_mode: host` (intentional — Plex/UrBackup discovery).
- `restart: unless-stopped` everywhere.
- SWAG (in `media/`) owns 80/443/81 on the host and reverse-proxies the `antarctican.tv` wildcard via Cloudflare DNS-01. Other UIs live on non-standard ports behind it.

## Requirements

Unraid plugins:

- **[Docker Compose Manager](https://forums.unraid.net/topic/114415-plugin-docker-compose-manager/)** — runs the compose stacks.
- **[User Scripts](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/)** — runs scripts under `user-scripts/`.
