# otel stack

Observability for the whole server: an OpenTelemetry Collector as the single telemetry
intake, VictoriaMetrics (metrics), Tempo (traces) and Loki (logs) behind it, and Grafana on
top. Deployed from `docker-compose.otel.yml` via the Docker Compose Manager plugin.

## Services

| Service | Image | Purpose | UI port |
|---|---|---|---|
| `otel-collector` | otel/opentelemetry-collector-contrib | OTLP intake, host + container metrics, Prometheus scraping | `${OTEL_COLLECTOR_HOST_PORT}` (OTLP/HTTP, not a UI) |
| `dockersocket-otel` | tecnativa/docker-socket-proxy | Read-only Docker API for the collector's container stats | — |
| `victoriametrics` | victoriametrics/victoria-metrics | Metrics store, Prometheus-compatible | `${VICTORIAMETRICS_HOST_PORT}` (`/vmui`) |
| `tempo` | grafana/tempo | Trace store | — |
| `loki` | grafana/loki | Log store | — |
| `grafana` | grafana/grafana | Dashboards, trace and log explorer | `${GRAFANA_HOST_PORT}` |

Every service runs as `${PUID}:${PGID}` via `user:`. None of these images honor
`PUID`/`PGID` env vars, and unlike the linuxserver and binhex images they have no init step
that chowns their data directory before dropping privileges: they start straight away as a
fixed non-root user (Tempo, Loki and the collector as 10001, Grafana as 472). So the
directories they write to must be owned by `99:100` before first start, the same
situation as OpenClaw in the claw stack. Config files can stay root-owned; they only need
to be readable.

## How telemetry gets in

Two paths, both ending at the collector:

- **Push (OTLP).** Clients that speak OpenTelemetry send to
  `http://<unraid-ip>:${OTEL_COLLECTOR_HOST_PORT}` over OTLP/HTTP. OpenClaw is the first;
  see the claw README's Telemetry section.
- **Pull (Prometheus scrape).** Services that only expose a `/metrics` endpoint are scraped
  by the collector's `prometheus` receiver. Each one lives in another stack and is reached
  on its **published host port** through `host.docker.internal`, so this stack never joins
  another stack's network and every stack still starts and stops on its own. Adding a
  target is four edits:

  1. Publish the port in the other stack with a `${SERVICE_METRICS_HOST_PORT}` var.
  2. Add the matching port var to this stack's `.env` and `.env.example`.
  3. Pass that var into the collector's `environment:` in `docker-compose.otel.yml`.
  4. Add a `scrape_configs` job in `otel-collector/config.yaml`.

  Step 3 is the one that's easy to miss and fails quietly: `${env:...}` in the collector
  config resolves against the container's environment, so a var that isn't passed through
  becomes an empty string and that one scrape job dies while everything else keeps working.

The collector also reads the Unraid host itself (`hostmetrics` receiver over the `/:/hostfs`
mount) and every container's CPU, memory, network and block IO (`docker_stats` receiver
through `dockersocket-otel`).

Metrics leave the collector as Prometheus remote-write into VictoriaMetrics, with resource
attributes (`container.name`, `host.name`, `service.name`, ...) turned into labels. Traces go
to Tempo over OTLP/gRPC and logs to Loki's native OTLP endpoint, both on `otel-net` only.

## What's wired today

| Source | Signal | How |
|---|---|---|
| OpenClaw (`claw/`) | metrics, traces, logs | `diagnostics-otel` plugin pushing OTLP |
| Unraid host | metrics | `hostmetrics` receiver: CPU, load, memory, paging, network, disk, filesystems |
| All containers | metrics | `docker_stats` receiver |
| Unpackerr (`media/`) | metrics | native `/metrics`, `UN_WEBSERVER_METRICS=true` |
| FlareSolverr (`media/`) | metrics | native `/metrics`, `PROMETHEUS_ENABLED=true` |
| cloudflared (`claw/`) | metrics | native `/metrics` via `--metrics 0.0.0.0:20241` |
| CouchDB (`notes/`) | metrics | native `/_node/_local/_prometheus` on the normal port, admin basic auth |
| qBittorrent (`media/`) | metrics | `qbittorrent-exporter` sidecar, WebUI credentials |
| Sonarr / Radarr / Prowlarr (`media/`) | metrics | `scraparr` sidecar, one endpoint for all three, per-app API keys |
| Pi-hole (`pihole/`) | metrics | `pihole-exporter` sidecar (v6 session API), admin password |
| UrBackup (`urbackup/`) | metrics | `urbackup-exporter` sidecar, admin login |

## Exporter sidecars

Four of the sources above have no native Prometheus endpoint and get an exporter instead.
Each one follows the same rule: the exporter lives in the stack that owns the service, on
that stack's network, with the credentials in that stack's `.env` — so the service and its
exporter start, stop and redeploy together, and this stack only ever sees a host port.

| Exporter | Stack | Reaches the service via | Credential |
|---|---|---|---|
| `qbittorrent-exporter` | `media` | `qbittorrentvpn` on `media-net` | `QBITTORRENT_WEBUI_USER` / `_PASSWORD` |
| `scraparr` | `media` | `sonarr-uhd`, `radarr-uhd`, `prowlarr` on `media-net` | each app's API key |
| `pihole-exporter` | `pihole` | `pihole` on `pihole-net`, container port 80 | `PIHOLE_FTLCONF_webserver_api_password` |
| `urbackup-exporter` | `urbackup` | `host.docker.internal:55414` | `URBACKUP_SERVER_USERNAME` / `_PASSWORD` |

Two of these need explaining:

- **qBittorrent's exporter needs real credentials**, unlike the container's own
  healthcheck — binhex bypasses auth for localhost only, and the exporter is a separate
  host on the bridge. It also deliberately sits on `media-net` rather than sharing
  `qbittorrentvpn`'s network namespace: healarr restarts that container, and those
  restarts are the thing the exporter exists to make visible. `qbittorrent_firewalled` is
  the NAT-PMP stall itself, so the stall is now a metric rather than only an inferred
  restart.
- **UrBackup's exporter is the one bridge exception.** The server is `network_mode: host`
  for client discovery, but the exporter stays on a bridge with `extra_hosts:
  host-gateway` so its metrics port remains a one-line `.env` change like every other.

Not instrumented: Plex, Tautulli and Tunarr (the whole `plex/` stack), Notifiarr, Seerr,
Ollama, SWAG, and Unraid's temperatures, array and parity state. Where something is worth
knowing before reaching for one of these: the Plex exporters are all dead, Seerr's is the
Overseerr one and untested against it, Tunarr has none, Ollama's upstream `/metrics` PR is
unmerged, SWAG means manual `stub_status` surgery for connection counts only, and the
Unraid figures are invisible to `hostmetrics` — reaching them needs a bespoke GraphQL
scraper. Tautulli and Notifiarr are the exceptions: both are straightforward to scrape
(`mm503/tautulli-exporter` and Notifiarr's native `/metrics` behind an "Extra Key"), they
just aren't wanted here.

## Deploying

1. Create the appdata tree and hand the four data directories to `nobody:users`:

   ```sh
   mkdir -p /mnt/user/appdata/{otel-collector,victoriametrics,tempo/data,loki/data,grafana/data,grafana/provisioning/{datasources,dashboards}}
   chown 99:100 /mnt/user/appdata/{victoriametrics,tempo/data,loki/data,grafana/data}
   ```

2. Copy the tracked configs into place (repeat after editing any of them):

   ```sh
   cp /path/to/repo/otel/otel-collector/config.yaml /mnt/user/appdata/otel-collector/config.yaml
   cp /path/to/repo/otel/tempo/tempo.yaml /mnt/user/appdata/tempo/tempo.yaml
   cp /path/to/repo/otel/loki/loki.yaml /mnt/user/appdata/loki/loki.yaml
   cp /path/to/repo/otel/grafana/provisioning/datasources/datasources.yaml /mnt/user/appdata/grafana/provisioning/datasources/datasources.yaml
   cp /path/to/repo/otel/grafana/provisioning/dashboards/* /mnt/user/appdata/grafana/provisioning/dashboards/
   ```

   Do this **before** the first start: a bind mount whose source is missing makes Docker
   create a directory at that path, and the container then fails to read its config.

3. Copy `.env.example` to `.env` and fill it in. The scrape-target ports and the CouchDB
   credentials must match the values in the other stacks' `.env` files.

4. Redeploy every stack that publishes a metrics port — `media`, `claw`, `pihole` and
   `urbackup` — so the new ports and env vars take effect, then start this stack from the
   Compose Manager plugin. Each of those stacks needs its own new `.env` values first
   (API keys and metrics ports); see its `.env.example`.

5. Enable OpenClaw's exporter (claw README, Telemetry).

## Verifying

- Collector is up and scraping:

  ```sh
  docker logs otel-collector 2>&1 | grep -iE 'error|failed' | head
  ```

  A failed scrape shows as `Failed to scrape Prometheus endpoint` with the job name.
  If **every** host-port target fails, `host.docker.internal` did not resolve to a host
  address; replace it in `config.yaml` with the server's LAN IP.

- Metrics arrived: `http://<unraid-ip>:${VICTORIAMETRICS_HOST_PORT}/vmui`, query `up`.
  One series per scrape job, value `1`. `system_cpu_time_seconds_total` and
  `container_cpu_utilization_ratio` confirm the host and Docker receivers.

  `up == 0` narrows the problem to one job: the target is reachable but returning an
  error, usually bad credentials. `up` missing a job entirely means the target never
  resolved — check that its port var reached the collector's environment (step 3 of the
  four edits above).

- Each exporter answers on the host directly, which separates "the exporter is broken"
  from "the collector can't reach it":

  ```sh
  curl -s localhost:${QBITTORRENT_METRICS_PORT}/metrics | head
  curl -s localhost:${SCRAPARR_METRICS_PORT}/metrics | head
  ```

- Grafana: `http://<unraid-ip>:${GRAFANA_HOST_PORT}`, log in with the admin values from
  `.env`. Connections → Data sources should list VictoriaMetrics, Tempo and Loki, each
  passing **Test**. Explore → Tempo → Search shows OpenClaw runs once the plugin is on.

## Dashboards

Datasources and the dashboards under `grafana/provisioning/dashboards/` are provisioned
and read-only in the UI: edit the JSON here, copy it to the host, and Grafana picks the
change up within 30 seconds. To iterate in the UI first, **Save as** a copy, then export
its JSON back into the repo. Ad-hoc dashboards imported in the UI still persist in
`${APPDATA}/grafana/data`.

Each stack that feeds this one has a dashboard, tagged with the stack name so Grafana's
dashboard list groups them. All four are upstream dashboards imported and rebound.

| Dashboard | File | Tags | Source |
|---|---|---|---|
| qBittorrent | `qbittorrent.json` | `media` | exporter repo's `grafana/dashboard.json` |
| Arrs (scraparr) | `scraparr.json` | `media` | [22934](https://grafana.com/grafana/dashboards/22934) |
| Pi-hole | `pihole.json` | `pihole` | [21043](https://grafana.com/grafana/dashboards/21043) |
| UrBackup | `urbackup.json` | `urbackup` | exporter repo's `grafana/grafana_dashboard.json` |

Importing an upstream dashboard into this stack means two mechanical changes, the same
ones `openclaw.json` got. An upstream file is built to be *imported through the UI*: it
carries an `__inputs` block that prompts for a datasource, and its panels reference that
answer as `${DS_PROMETHEUS}`. A provisioned dashboard never sees that prompt, so both have
to go — drop `__inputs`/`__requires` and the datasource-picker template variable, and
rewrite every datasource reference to the concrete provisioned uid (`victoriametrics`,
`tempo`, `loki`). Annotation queries pointing at the built-in `-- Grafana --` datasource
are correct as they are; leave them.

Two things to expect on first look:

- **The panel queries are unverified.** They were written against each exporter's
  documented metric names, and nothing had scraped these targets yet when they were
  committed. A panel reading "No data" is as likely to be a name that shifted through the
  collector's remote-write naming as a genuinely idle service — check the metric exists in
  vmui before rewriting the query.
- **The scraparr dashboard covers arrs this server doesn't run** (Bazarr, Readarr,
  Lidarr, Jellyseerr/Overseerr). Those rows stay empty and their template variables show
  "None". It was imported whole rather than trimmed, so it stays diffable against upstream.

- **OpenClaw** (`openclaw.json`): community dashboard
  [25068](https://grafana.com/grafana/dashboards/25068-openclaw-diagnostics-otel/) with
  its datasources bound to the provisioned uids. The 22 metrics panels are upstream's;
  the five log and trace panels were written for OpenSearch and are rebuilt here on Loki
  (`{service_name="openclaw"}`, levels from the OTLP `severity_text` metadata) and on Tempo
  TraceQL metrics (`{resource.service.name="openclaw"} | rate() by (name)`), which Tempo 3
  serves without extra config. Metric names follow the collector's remote-write naming
  (`openclaw_*_total`, `openclaw_*_ms_milliseconds_bucket`), which is what upstream's
  queries already use.
- Host: any `hostmetrics`-receiver dashboard; the metric names are OpenTelemetry's
  (`system_*`), not node_exporter's (`node_*`), so node_exporter dashboards will not work.
- Containers: `container_*` metrics from the `docker_stats` receiver, labelled by
  `container_name`.

## Notes

- **Ports are the contract between stacks.** The collector finds other services only
  through their published host ports. Remapping a metrics port in `media/.env` or
  `claw/.env` without updating `otel/.env` silently breaks that scrape.
- **CouchDB is scraped with admin credentials** on its normal port rather than enabling
  CouchDB's separate `additional_port`, which serves the endpoint unauthenticated.
- **Retention:** metrics `${VICTORIAMETRICS_RETENTION}` (`.env`), traces 7 days
  (`tempo/tempo.yaml`), logs 7 days (`loki/loki.yaml`).
- **No `process` scraper** in `hostmetrics`: it needs root and emits a series per PID.
- **Only OTLP/HTTP is open** on the collector. OpenClaw's plugin speaks nothing else; add
  a gRPC listener when a client needs one.

## References

- [OpenTelemetry Collector — configuration](https://opentelemetry.io/docs/collector/configuration/)
- [hostmetrics receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/hostmetricsreceiver/README.md)
- [docker_stats receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/dockerstatsreceiver/README.md)
- [VictoriaMetrics — Prometheus remote write](https://docs.victoriametrics.com/single-server-victoriametrics/#prometheus-setup)
- [Tempo — configuration](https://grafana.com/docs/tempo/latest/configuration/)
- [Loki — OTLP ingestion](https://grafana.com/docs/loki/latest/send-data/otel/)
- [Grafana — provisioning datasources](https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources)
- [Grafana — provisioning dashboards](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards)
- [Tempo — TraceQL metrics](https://grafana.com/docs/tempo/latest/metrics-from-traces/metrics-queries/)
- [Unpackerr — web server / metrics](https://unpackerr.zip/docs/install/configuration/)
- [cloudflared — tunnel metrics](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/monitor-tunnels/metrics/)
- [CouchDB — Prometheus endpoint](https://docs.couchdb.org/en/stable/config/misc.html)
- [prometheus-qbittorrent-exporter](https://github.com/esanchezm/prometheus-qbittorrent-exporter)
- [scraparr](https://github.com/thecfu/scraparr) — env vars in its `sample.env`
- [pihole6-exporter](https://github.com/Mosher-Labs/pihole6-exporter)
- [urbackup-exporter](https://github.com/ngosang/urbackup-exporter)
