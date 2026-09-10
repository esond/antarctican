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
  target is three edits: publish the port in the other stack with a
  `${SERVICE_METRICS_HOST_PORT}` var, add the matching port var to this stack's `.env`,
  and add a `scrape_configs` job in `otel-collector/config.yaml`.

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

## Next steps

Everything wired today is native or free. The rest needs an exporter sidecar and an API
key each, so it is a separate pass. Suggested order, most signal per effort first:

1. **qBittorrent** via `esanchezm/prometheus-qbittorrent-exporter`. Exposes a `firewalled`
   gauge, i.e. the NAT-PMP stall healarr restarts on, so the stall becomes visible rather
   than just its restart.
2. **Sonarr / Radarr / Prowlarr** via `thecfu/scraparr` (actively released;
   `onedr0p/exportarr:latest` lags its main branch by a year, pin a tag if used). Queue,
   health, indexer and download-client stats.
3. **Notifiarr**: native `/metrics`, needs an "Extra Key" in its config and an
   `X-Api-Key` header on the scrape job.
4. **Tautulli** via `mm503/tautulli-exporter` for Plex playback; the Plex exporters
   themselves are unmaintained.
5. **UrBackup** via `ngosang/urbackup-exporter`, ships a Grafana dashboard.
6. **Pi-hole v6** via `Mosher-Labs/pihole6-exporter` (fork with automatic session re-auth
   for the v6 API).
7. **Unraid temperatures, array and parity state.** Not visible to `hostmetrics`; needs
   the Unraid GraphQL API and there is no ready-made exporter, so a small custom scrape.

The pattern for 1-6 is the one already in use: the exporter runs as a sidecar in the
stack that owns the service (on that stack's network, with the API key in that stack's
`.env`), publishes its metrics port as `${SERVICE_METRICS_HOST_PORT}`, and this stack gets
the matching port var in `.env.example` plus a `scrape_configs` job in
`otel-collector/config.yaml`.

Not worth it: Plex (exporters dead), Seerr (predecessor exporter untested against Seerr),
Tunarr (nothing exists), Ollama (upstream `/metrics` PR unmerged), SWAG (manual
`stub_status` surgery for connection counts only).

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

4. Redeploy the stacks that gained a metrics port (`media`, `claw`) so the new ports and
   env vars take effect, then start this stack from the Compose Manager plugin.

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

- Grafana: `http://<unraid-ip>:${GRAFANA_HOST_PORT}`, log in with the admin values from
  `.env`. Connections → Data sources should list VictoriaMetrics, Tempo and Loki, each
  passing **Test**. Explore → Tempo → Search shows OpenClaw runs once the plugin is on.

## Dashboards

Datasources and the dashboards under `grafana/provisioning/dashboards/` are provisioned
and read-only in the UI: edit the JSON here, copy it to the host, and Grafana picks the
change up within 30 seconds. To iterate in the UI first, **Save as** a copy, then export
its JSON back into the repo. Ad-hoc dashboards imported in the UI still persist in
`${APPDATA}/grafana/data`.

- **OpenClaw** (`openclaw.json`): community dashboard
  [25068](https://grafana.com/grafana/dashboards/25068-openclaw-diagnostics-otel/) with
  its datasources bound to the provisioned uids. The 22 metrics panels are upstream's;
  the five log and trace panels were written for OpenSearch and are rebuilt here on Loki
  (`{service_name="openclaw"}`, levels from Loki's `detected_level`) and on Tempo
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
