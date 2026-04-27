# Seerr Migration (Overseerr → Seerr)

Run these on the Unraid host. The repo-side changes (compose file, `.env.example`, CLAUDE.md, cspell dictionary) are already done — pull `main` on the host before starting.

## Background

The old `lscr.io/linuxserver/overseerr` image is being replaced with the upstream `ghcr.io/seerr-team/seerr` image. Major differences that drive these steps:

- New image runs as `node` (UID 1000), not as `nobody:users` (99:100). Appdata must be re-owned.
- Container config path moved from `/config` to `/app/config`.
- Image no longer ships an init process — `init: true` is set in compose.
- `PUID`/`PGID` env vars are gone.

## Migration steps

### 1. Back up Overseerr appdata

```sh
tar czf /mnt/user/backup/overseerr-pre-seerr-$(date +%F).tgz -C /mnt/user/appdata overseerr
```

### 2. Stop the old container (don't remove it yet)

From the Unraid Docker tab, stop `overseerr`. Leaving it in place gives a clean rollback path if migration fails.

### 3. Pull the updated repo on the host

```sh
cd /boot/config/plugins/compose.manager/projects/media   # or wherever this repo is checked out
git pull
```

Make sure the local `.env` next to `docker-compose.media.yml` is updated:

- Rename `OVERSEERR_LOG_LEVEL` → `SEERR_LOG_LEVEL`
- Rename `OVERSEERR_HOST_PORT` → `SEERR_HOST_PORT`

### 4. Copy appdata to the new location

```sh
cp -a /mnt/user/appdata/overseerr /mnt/user/appdata/seerr
```

`-a` preserves perms/timestamps. The directory must not already exist.

### 5. Re-own the new appdata to UID 1000

```sh
docker run --rm -v /mnt/user/appdata/seerr:/data alpine chown -R 1000:1000 /data
```

### 6. Update the SWAG reverse-proxy conf

The proxy-conf for Overseerr lives on the host, not in this repo. It sits at:

```
/mnt/user/appdata/swag/nginx/proxy-confs/overseerr.subdomain.conf
```

**Keep the filename as `overseerr.subdomain.conf`** — that file's `server_name overseerr.*;` directive is what makes `overseerr.antarctican.tv` resolve, and we want to keep that URL. Don't rename the file.

**Gotcha — the file has TWO `set $upstream_app` lines.** The default linuxserver template has one in `location /` and a second one in `location ~ (/overseerr)?/api { ... }` for the subpath case. Both must be updated, or the page will load but every API call will 502 (with symptoms like "Plex login button missing" because the frontend can't fetch `/api/v1/settings/public`).

One-liner to catch both:

```sh
sed -i 's|set $upstream_app overseerr;|set $upstream_app seerr;|g' \
  /mnt/user/appdata/swag/nginx/proxy-confs/overseerr.subdomain.conf
```

Reload SWAG (or let `SWAG_AUTORELOAD=true` pick it up):

```sh
docker exec swag nginx -s reload
```

### 7. Pull and start the Seerr container

From the Unraid Compose Manager plugin UI, hit **Update Stack** (pulls images) then **Start** for the `media` stack. Or from the host:

```sh
cd /boot/config/plugins/compose.manager/projects/media
docker compose -f docker-compose.media.yml pull seerr
docker compose -f docker-compose.media.yml up -d seerr
```

### 8. First login + Application URL

Seerr's Plex OAuth flow is gated by two settings that interact awkwardly on first run after a migration:

- **CSRF protection** — on by default; rejects the OAuth roundtrip unless the request comes over HTTPS.
- **Application URL** — drives the OAuth callback target and several UI gating decisions (including whether the Plex sign-in button is shown).

After migration, Application URL still holds the value from the old Overseerr install, which may not match how you want to access Seerr now. And if your owner account is Plex-only (typical), you can't log in to *change* Application URL until Plex OAuth works — chicken and egg.

The workaround:

1. Stop seerr: `docker stop seerr`
2. Edit `/mnt/user/appdata/seerr/settings.json` and set `"csrfProtection": false` (add the field if missing).
3. Start seerr: `docker start seerr`
4. Open `http://<unraid-ip>:<SEERR_HOST_PORT>` (default `5055`) and log in with Plex. CSRF is off so OAuth completes.
5. Settings → General → set **Application URL** to exactly `https://overseerr.antarctican.tv` (no trailing slash, must be HTTPS).
6. Re-enable **Enable CSRF Protection** on the same screen. Save.
7. `docker restart seerr` to pick up the settings cleanly.
8. Test by loading `https://overseerr.antarctican.tv` in an **incognito window** — Plex sign-in button should appear and the OAuth flow should complete without a CSRF error.

### 9. Verify

```sh
docker logs -f seerr
```

Look for the automatic config migration to complete and the web UI to come up on `http://<host>:<SEERR_HOST_PORT>` (default `5055`). Hit it through SWAG too to confirm the proxy-conf change.

If the Plex button is missing on the SWAG URL but present on the LAN IP, the cause is almost always one of:

- Application URL doesn't match the URL you're loading (step 8.5).
- One of the two `set $upstream_app` lines in the proxy-conf wasn't updated (step 6 gotcha) — check the browser dev tools Network tab for 502s on `/api/...`.
- Stale cookies from a prior LAN-IP login — incognito.

### 10. Remove the old Overseerr container

Once Seerr is confirmed working, from the Unraid Docker tab remove the `overseerr` container. Leave `/mnt/user/appdata/overseerr` in place for a few days as an extra rollback layer, then delete when comfortable.

## Rollback

If Seerr fails to come up:

1. Stop `seerr`.
2. Revert the compose file (`git revert` the migration commit) and the local `.env` rename.
3. Revert the SWAG proxy-conf upstream change and reload SWAG.
4. Start the old `overseerr` container again. Its `/mnt/user/appdata/overseerr` was untouched.
