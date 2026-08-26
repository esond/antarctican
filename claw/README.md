# claw stack

Personal AI assistant: OpenClaw as the agent gateway (Discord channel, Anthropic API for
models) with Memorizer as its long-term memory over MCP. Deployed from
`docker-compose.claw.yml` via the Docker Compose Manager plugin.

## Services

| Service | Image | Purpose | UI port |
|---|---|---|---|
| `openclaw` | ghcr.io/openclaw/openclaw | Agent gateway + dashboard | `${OPENCLAW_HOST_PORT}` |
| `cloudflared` | cloudflare/cloudflared | Publishes the dashboard at a public hostname via Cloudflare Tunnel | — |
| `memorizer` | petabridge/memorizer | Vector-search agent memory (MCP server) | `${MEMORIZER_HOST_PORT}` |
| `memorizer-postgres` | pgvector/pgvector | Memory storage | — |
| `memorizer-ollama` | ollama/ollama | Local embedding + chunking models for Memorizer | — |
| `memorizer-ollama-init` | curlimages/curl | One-shot model pull on stack start | — |

OpenClaw runs as its upstream fixed user (`node`, UID 1000) — it doesn't honor
`PUID`/`PGID`, same situation as Seerr. Postgres and Ollama likewise use their upstream
users.

## Deploying

1. Create the agent workspace share in Unraid (default name `claw`, matching
   `CLAW_WORKSPACE`). Don't SMB-export it; if you must, export read-only. Anything
   writable on this share becomes agent-readable input.
2. Copy `.env.example` to `.env` and fill it in. The Anthropic key should be a dedicated
   key with a monthly spend cap set at
   [console.anthropic.com](https://console.anthropic.com); the Discord token comes from a
   bot application created at the
   [Discord developer portal](https://discord.com/developers/applications).
3. Pre-create and chown the bind-mount dirs (the images run as non-root and can't create
   them):

   ```sh
   mkdir -p /mnt/user/appdata/openclaw/config /mnt/user/appdata/openclaw/auth-secret
   chown -R 1000:1000 /mnt/user/appdata/openclaw /mnt/user/claw
   ```

4. Set up the Cloudflare Tunnel (below) and put its token in `.env`, or comment out the
   `cloudflared` service to stay LAN-only for now.
5. Start the stack from the Compose Manager plugin. First start pulls the two small
   Ollama models (~100MB); `memorizer` waits for that to finish before coming up.
6. Run OpenClaw onboarding to wire up Anthropic + Discord and generate the gateway auth
   config:

   ```sh
   docker exec -it openclaw openclaw onboard
   ```

7. Register Memorizer as an MCP server in OpenClaw's config
   (`/mnt/user/appdata/openclaw/config/openclaw.json`), pointing at the
   container-internal address:

   ```json
   "mcp": {
     "servers": {
       "memorizer": { "url": "http://memorizer:8080/mcp" }
     }
   }
   ```

   Then add a line to the agent's system prompt telling it to use the memory tools
   (`store`, `searchMemories`, `get`) — Memorizer's README has a recommended snippet.

## Public dashboard access

The dashboard is **not** exposed through SWAG or a port-forward, deliberately. OpenClaw's
history includes mass scans finding six figures of openly reachable instances and a string
of CVEs; an agent gateway with credentials to your life is the last thing that should sit
naked on 443.

Instead, `cloudflared` makes an outbound-only connection to Cloudflare and serves the
dashboard at `claw.antarctican.tv`, with a Cloudflare Access policy in front (the
`antarctican.tv` zone is hosted on Cloudflare's free plan; registration stays at
DNSimple):

1. In [Zero Trust](https://one.dash.cloudflare.com/) → Networks → Tunnels, create a tunnel,
   pick **Docker** as the connector, and copy the token into
   `CLOUDFLARED_TUNNEL_TOKEN`.
2. Add a public hostname `claw.antarctican.tv` to the tunnel with service
   `http://openclaw:18789` (Cloudflare creates the CNAME automatically).
3. In Zero Trust → Access → Applications, add an application for that hostname with a
   policy allowing only your email (one-time PIN or an identity provider).

Result: the dashboard answers at a real public URL, but Cloudflare demands your identity
before any request reaches the container, no host ports are open, and OpenClaw's own
gateway token auth remains as a second layer. The Memorizer UI has no authentication —
leave it LAN-only, never add it to the tunnel.

## Security notes

- The agent workspace is its own share; no other shares are mounted into any container
  here, and nothing in this stack touches the Docker socket. Keep it that way — if the
  agent ever needs Docker control, use the `docker-socket-proxy` pattern from `media/`.
- Treat every credential the agent can use as exfiltratable via prompt injection: give it
  per-service accounts created for it (its own API keys, never personal logins), and keep
  them in a dedicated 1Password vault so rotation is one place.
- Skills from ClawHub are third-party code with a documented malware problem. Read a
  skill before installing it; prefer MCP servers for integrations.

## References

- [OpenClaw docs — Docker install](https://docs.openclaw.ai/install/docker)
- [OpenClaw docs — gateway configuration](https://docs.openclaw.ai/gateway/configuration)
- [petabridge/memorizer](https://github.com/petabridge/memorizer)
- [Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
