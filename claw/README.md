# claw stack

Personal AI assistant: OpenClaw as the agent gateway (Discord channel; OpenAI models
through a ChatGPT subscription login, Anthropic API key as fallback), using its builtin
memory with a local embedding model for semantic recall and, optionally, its own Fastmail
mailbox over Fastmail's hosted MCP endpoint. Deployed from `docker-compose.claw.yml` via
the Docker Compose Manager plugin.

## Services

| Service | Image | Purpose | UI port |
|---|---|---|---|
| `openclaw` | ghcr.io/openclaw/openclaw (`-browser` variant) | Agent gateway + dashboard, with the agent's headless Chromium baked in | `${OPENCLAW_HOST_PORT}` |
| `cloudflared` | cloudflare/cloudflared | Publishes the dashboard at a public hostname via Cloudflare Tunnel | — |
| `ollama` | ollama/ollama | Local embedding model for OpenClaw's memory search (pulls it on start) | — |

OpenClaw runs as its upstream fixed user (`node`, UID 1000) — it doesn't honor
`PUID`/`PGID`, same situation as Seerr. Ollama likewise uses its upstream user.

## Who owns what

- **Compose** owns the network (`claw-net`, cloudflared's pinned address), the bind
  mounts, the host port, and the environment. Infrastructure secrets (gateway token,
  Discord, 1Password, tunnel) live in `.env`; model-provider credentials do not — they
  go in through the dashboard and sit in OpenClaw's auth store.
- **The OpenClaw dashboard** owns everything else — models, plugins, channels, memory,
  browser, gateway hardening, MCP servers. Its Config tab renders a form from the live
  config schema (with a raw JSON editor as the escape hatch), validates every write, and
  hot-reloads most changes. Settings written this way are what `openclaw doctor`
  migrates on upgrade, which is the point of keeping them there.
- **The CLI** is for the handful of things the dashboard can't do: the one-off
  onboarding, `memory index --force`, and diagnostics. Don't script config with
  `openclaw config set` — each call is an unvalidated write the next upgrade has to
  understand.

## Deploying

1. Create the agent workspace share in Unraid (default name `claw`, matching
   `CLAW_WORKSPACE`). Don't SMB-export it; if you must, export read-only. Anything
   writable on this share becomes agent-readable input.
2. Copy `.env.example` to `.env` and fill it in. `OPENCLAW_GATEWAY_TOKEN` is the dashboard
   login token (`openssl rand -hex 32`); the Discord token comes from a bot application
   created at the [Discord developer portal](https://discord.com/developers/applications).
   There are no model-provider keys in `.env` — the ChatGPT subscription login and the
   Anthropic API key are both added on the dashboard's Models page.
3. Pre-create and chown the bind-mount dirs (the images run as non-root and can't create
   them):

   ```sh
   mkdir -p /mnt/user/appdata/openclaw/config /mnt/user/appdata/openclaw/auth-secret
   chown -R 1000:1000 /mnt/user/appdata/openclaw /mnt/user/claw
   ```

   Also fetch the 1Password CLI binary the compose file bind-mounts into the
   container — **before first start**; if the file is missing at `up` time,
   Docker creates a directory in its place and the mount breaks:

   ```sh
   mkdir -p /mnt/user/appdata/openclaw/bin
   curl -fsSL https://cache.agilebits.com/dist/1P/op2/pkg/v2.39.0/op_linux_amd64_v2.39.0.zip -o /tmp/op.zip
   unzip -o /tmp/op.zip -d /mnt/user/appdata/openclaw/bin op
   rm /tmp/op.zip
   chmod 755 /mnt/user/appdata/openclaw/bin/op
   ```

   (`op` is a static binary, so a bind mount works across image updates; bump
   the version in the URL to upgrade it.)

4. Set up the Cloudflare Tunnel (below) and put its token in `.env`, or comment out the
   `cloudflared` service to stay LAN-only for now.
5. Run onboarding **before first start** — the gateway refuses to start until
   `gateway.mode=local` exists in `openclaw.json`, and a restarting container can't be
   exec'd. Run the wizard as a one-off container with all three mounts (omitting the
   workspace mount seeds the agent files into `config/workspace` instead of the share)
   and the stack's `.env`, so the wizard can see the gateway token it is asked to
   reference:

   ```sh
   docker run -it --rm \
     --env-file /boot/config/plugins/compose.manager/projects/claw/.env \
     -v /mnt/user/appdata/openclaw/config:/home/node/.openclaw \
     -v /mnt/user/appdata/openclaw/auth-secret:/home/node/.config/openclaw \
     -v /mnt/user/claw:/home/node/.openclaw/workspace \
     ghcr.io/openclaw/openclaw:latest-browser \
     openclaw onboard --tui --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN --skip-daemon --skip-health
   ```

   (`--env-file` path is wherever the Compose Manager plugin keeps this stack's `.env`.)
   In the wizard: local mode, bind **lan** (the container's loopback is unreachable from
   the host port and from cloudflared), token auth. For the model provider pick
   **OpenAI Codex (device)** — `openai-codex-device` — which prints a code to enter at
   the URL it shows; no browser callback is needed inside the container. Skip the
   optional steps (skills, hooks, channels, bootstrap); those are done in the dashboard.

   The `openclaw` before the subcommand is required, not a typo. The image entrypoint is
   `tini -s --` with a default command of `node openclaw.mjs gateway`, so a bare
   subcommand replaces the whole command rather than appending to it and dies with
   `[FATAL tini (7)] exec onboard failed: No such file or directory`. Every one-off
   `docker run` against this image needs the same shape.

6. Start the stack from the Compose Manager plugin. On first start `ollama` pulls its
   embedding model (~640MB) and only reports healthy once it's present.
7. Open `http://<unraid-ip>:${OPENCLAW_HOST_PORT}`, paste `OPENCLAW_GATEWAY_TOKEN` into
   the settings panel, and approve the device-pairing request it triggers (the login
   screen shows the request; **Settings → Devices** lists it, or
   `docker exec openclaw openclaw devices approve <requestId>`). Both stick per browser.
   Leave `deviceAutoApprove` off — the one-time approval is what stops a stolen token from
   silently attaching a new device.
8. Configure everything else in the dashboard — next section.

## Configuring in the dashboard

Everything here is done at the dashboard; where a setting has no dedicated page it is
edited in the **Config** tab, which shows the same keys as the JSON file. Keys are given
so you can find them in the form or the raw editor. Do the sections in order — plugins
gate models, models gate everything downstream.

### Plugins

**Settings → Plugins → Installed.** The image ships ~70 stock plugins with nearly all of
them disabled, and a disabled provider plugin is invisible from the outside: the gateway
knows only the models baked into core, so anything newer won't resolve, and a request for
one dies with a `FailoverError` whose wording blames the account or the model. Enable:

| Plugin | Why |
|---|---|
| `openai` | Live OpenAI model catalog. Ships **disabled** even though docs.openclaw.ai says otherwise. |
| `codex` | The harness that runs OpenAI models through the Codex app-server. Subscription (OAuth) auth only works through it — see [Codex harness](#codex-harness). |
| `anthropic` | Live Anthropic catalog for the fallback model. |
| `discord` | Installed by onboarding without explicit trust; the bot won't start until enabled. |
| `ollama` | Registers the embedding provider for memory search. |
| `browser` | The agent's browser tool. |

`memory-core` ships enabled and backs memory search; leave it. The gateway logs which
plugins actually loaded on startup (`http server listening (N plugins: ...)`) — that line
is the confirmation, not the toggle. A separate allowlist, `plugins.allow`, is set later
under [Gateway and public access](#gateway-and-public-access); once it exists it gates
every plugin here, enabled or not.

### Models and auth

**Settings → Models** lists providers with their auth state, and **Add account** offers
the same sign-in methods as the CLI: for OpenAI, API key, browser sign-in, or
**device code**. If onboarding already completed the ChatGPT login the account shows
here; otherwise add it with device code. OpenClaw stores the resulting profile under the
canonical provider id `openai` in its own auth store (`state/openclaw.sqlite` and the
agent's `openclaw-agent.sqlite` on the config mount) and refreshes it itself. Add
Anthropic the same way with **API key** — a dedicated key with a monthly spend cap set at
[console.anthropic.com](https://console.anthropic.com). It lands in the same auth store.

There are deliberately no provider keys in the environment. A key there would compete
with the stored profile — for OpenAI that means API-key billing alongside the
subscription — and keys in the auth store are one place to see, replace and remove them.

Then the **Defaults** card — primary model, first fallback, utility model, thinking
level, populated from the configured catalog. Pick the primary from what the OpenAI
account actually exposes: `openai/gpt-5.6-sol` is the documented subscription route;
Terra and Luna refs appear only if the native Codex catalog exposes them (`/codex
models` in chat lists it). Set `anthropic/claude-sonnet-5` as first fallback. Failover
is about quota, not capability — rate-limit responses roll to the next model in the
chain, other failures fail immediately without retry. Whether failover crosses from the
Codex harness to the embedded runtime that serves Anthropic has not been verified on this
host; test it before relying on it.

Model refs are provider-prefixed (`openai/*`, `anthropic/*`) — a bare model name doesn't
resolve. In the Config tab, `agents.defaults.models` is an **allowlist** as well as a
per-model settings map: a model absent from it is missing from the picker and rejected
at runtime even with the provider enabled and valid auth. Onboarding seeds a handful.
Rather than naming models one by one, add the wildcard entries `"openai/*": {}` and
`"anthropic/*": {}` so every model the enabled providers discover is allowed; entries
can also carry `alias` and `params`.

`agents.defaults.model` (singular) holds `{ primary, fallbacks }`; the Defaults card
writes it. `utility` is a separate slot that does not follow `primary`.

### Memory search

Config tab, `agents.defaults.memorySearch`:

```json5
{ enabled: true, provider: "ollama", model: "qwen3-embedding:0.6b",
  remote: { baseUrl: "http://ollama:11434", apiKey: "ollama-local" } }
```

The builtin engine defaults to OpenAI embeddings and, with no embedding provider, silently
falls back to keyword-only (BM25) search. Use the native Ollama URL, not the `/v1` one;
`apiKey` is a placeholder Ollama ignores. The path is `agents.defaults.memorySearch`,
**not** the `memory.search` that docs.openclaw.ai documents — the form only offers the
real one, which is one reason to edit here rather than by CLI.

Config alone can look right while recall returns nothing. Two checks:

```sh
docker logs openclaw 2>&1 | grep -i "memory embedding provider"   # should print nothing
docker exec openclaw openclaw memory status                        # non-zero Indexed:, a Vector dims: line
```

The log line `memorySearch.provider="ollama" is configured, but no loaded plugin
registered a memory embedding provider` means the `ollama` plugin isn't enabled. A zero
`Indexed:` after changing embedding provider or model means the index identity changed
and OpenClaw paused vector search rather than re-embedding — `docker exec openclaw
openclaw memory index --force` rebuilds it. Changing model later means re-embedding
every note, so pick before the memory grows. `sources` defaults to `["memory"]`, which
covers `MEMORY.md` and `memory/` but not `USER.md` (injected every session, not
retrieved); add it to `extraPaths` if it should be searchable.

### Browser

Config tab: `browser.enabled: true`, `browser.noSandbox: true`, and `tools.alsoAllow:
["browser"]`. All three plus the plugin enable are required:

- `noSandbox` — Chromium's own sandbox creates user namespaces, which Docker's default
  seccomp profile denies (and `no-new-privileges` rules out the setuid helper). Without
  it the launch fails with `Failed to move to new namespace`.
- `tools.alsoAllow` — the onboarding tool profile (`tools.profile: "coding"`) excludes the
  UI tool group, so the plugin can be enabled and healthy while the agent still has no
  browser tool. This grants just the browser tools without widening the profile to `full`.
- Leave `browser.headless`, `browser.executablePath` and `browser.defaultProfile` unset.
  The image ships Playwright's Chromium where OpenClaw auto-detects it; with no
  `DISPLAY` the Linux fallback launches `--headless=new`; the managed `openclaw` profile
  keeps its cookies and logins under `config/browser/openclaw/user-data` on the config
  mount, so they survive restarts and image updates (delete that directory with the stack
  stopped to reset it).

Verify with a prompt that uses the browser *without* naming a profile, then `docker exec
openclaw openclaw browser --json status`: the `openclaw` profile should be the running
one with `headlessSource: linux-display-fallback`. The agent's answer alone isn't proof.

### Discord

Config tab: `channels.discord.enabled: true`. Leave `token` unset — the channel falls
back to `DISCORD_BOT_TOKEN` from the environment for the default account (a config
token would win over it). `dmPolicy` defaults to `pairing` and `groupPolicy` to
`allowlist`; keep both.

In the Discord developer portal the bot needs the **Message Content** and **Server
Members** privileged intents. Its presence shows offline by design — DM it anyway; the
first DM returns a pairing code, approved at **Settings → Channels → DM access
requests**. Pairings are stored in the state database, not the config.

### Gateway and public access

Config tab, once the tunnel is up (the wizard leaves insecure auth on, and `bind: lan`
makes origin and rate-limit settings matter):

| Key | Value |
|---|---|
| `gateway.trustedProxies` | `["172.25.0.10"]` — cloudflared's pinned address; see [Public dashboard access](#public-dashboard-access) |
| `gateway.controlUi.allowedOrigins` | `["https://claw.example.com"]` |
| `gateway.controlUi.allowInsecureAuth` | `false` |
| `gateway.auth.rateLimit` | `{ maxAttempts: 10, windowMs: 60000, lockoutMs: 300000 }` |
| `plugins.allow` | `["openai","codex","anthropic","discord","ollama","browser","memory-core"]` |

`plugins.allow` is exhaustive, not additive: a plugin missing from it stays unloaded
however it is configured elsewhere, so every plugin enabled above has to appear here,
`memory-core` included (the allowlist gates bundled plugins too, and leaving it off drops
memory search silently). The list is validated — an id the image doesn't ship is rejected
as `plugin not found`. Set it last, after every plugin is enabled and working.

Then `docker exec openclaw openclaw security audit` should come back with zero criticals.
It will warn about the unpinned `@openclaw/discord` npm spec; treat that as real (an
unpinned spec once resolved to a broken build mid-upgrade,
[openclaw#76798](https://github.com/openclaw/openclaw/issues/76798)) and pin it.

### MCP servers

**Settings → MCP** adds, enables, disables and removes servers. Anything beyond a URL —
headers, tool filters — is edited in the Config tab under `mcp.servers.<name>`. See
[Fastmail](#fastmail-agent-email) for the one server this stack uses.

## Codex harness

OpenAI models on a ChatGPT subscription do not run on OpenClaw's embedded runtime. With
the runtime policy at its default (`auto`), the official ChatGPT route selects the
**Codex** harness, which runs the turn through the `@openai/codex` app-server that the
`codex` plugin ships and manages. OpenClaw keeps the channels, sessions, model selection,
approvals and transcript; Codex owns the thread, native tools and compaction. `/status`
in chat reports `Runtime: OpenAI Codex`; `/codex status` reports connectivity, account,
rate limits, MCP servers and skills.

What still works through it: `memory_search`/`memory_get`, the browser tool, skills
(forwarded as a compact list), the workspace persona files (`SOUL.md`, `USER.md`,
`AGENTS.md`, `MEMORY.md`), and `mcp.servers` (projected into the app-server; a
per-server `codex` block scopes it to agents). Native Codex subagents do not inherit the
persona files or skills.

Two things to know:

- **The app-server binary can be missing.** The plugin resolves `@openai/codex` from
  its own package root; the Docker build prunes plugin dependency trees, and on this
  host a chat under the harness once died with `Managed Codex app-server binary was not
  found for @openai/codex`. Check before the first chat:

  ```sh
  docker exec openclaw openclaw doctor --lint --only codex/managed-app-server --json
  ```

  If it reports the binary missing, install the plugin from **Settings → Plugins →
  Discover** (or `docker exec openclaw openclaw plugins install @openclaw/codex`). A
  downloadable install stores its package state under the config mount, so it survives
  container replacement. The env-var escape hatch, `OPENCLAW_CODEX_APP_SERVER_BIN`
  pointing at a bind-mounted `codex` binary, is the same pattern as `op` and is the
  fallback if the install route doesn't take.
- **The default mode is `yolo`**: `approvalPolicy: never`, `sandbox: danger-full-access`.
  The alternative, `appServer.mode: "guardian"`, sandboxes with `bwrap`, which needs
  nested user namespaces this container denies (same reason Chromium runs `noSandbox`).
  So the container is the boundary, as it was with the embedded runtime — nothing new is
  exposed, but don't read `yolo` as a setting to tighten later.

Explicit `agents.defaults.agentRuntime: "codex"` fails hard if the harness is
unavailable; leaving it `auto` is the documented route and is what the dashboard sets.

## Gotchas

- The empty `config/workspace` directory inside the OpenClaw appdata is the mountpoint
  for the nested workspace bind. Deleting it on the host disconnects the live mount
  (the container sees ENOENT on its workspace); recreate the directory and
  `docker restart openclaw` to recover.
- Environment variables arrive when the container is *recreated*, not on a restart. After
  editing `.env`, update the stack from the Compose Manager rather than restarting.
- `openclaw models list` dies with `Cannot read properties of undefined (reading
  'input')` once the `anthropic` provider plugin is enabled (seen on 2026.7.1). The
  gateway resolves models by another path and is unaffected. Don't rearrange
  `agents.defaults.models` or hand-register `models.providers.anthropic` trying to clear
  it, and don't hand-register models under `models.providers.<provider>.models[]` at
  all — with the plugin enabled the catalog comes from upstream and stays current.
- `openclaw doctor`'s `--only`, `--skip`, `--all` and `--severity-min` are **lint-only**
  flags: combining any of them with `--fix` exits non-zero. There is no supported way to
  scope a repair. When `--fix` has to run, run it interactively (`-it`, without `--yes`)
  and use its per-finding prompts as the control surface. `doctor --fix` also discards
  *all* pending migrations if any plugin fails to load
  ([openclaw#76798](https://github.com/openclaw/openclaw/issues/76798)).
- `openclaw memory status --deep` can report `Unknown memory embedding provider: ollama`
  even while `memory_search` works fine at runtime
  ([openclaw#66077](https://github.com/openclaw/openclaw/issues/66077)) — a
  diagnostic-path bug. Trust an actual recall test over it.
- A `WorkspaceVanishedError` at message time means the workspace content no longer
  matches its attestation in the state database — usually an empty or wrong mount. Fix
  the workspace rather than deleting attestations.
- `plugins.bundledDiscovery` no longer exists as of 2026.9.2. Don't re-add it: on some
  versions an unrecognized config key blocks gateway startup outright
  ([openclaw#78236](https://github.com/openclaw/openclaw/issues/78236)). This is the
  general case for the Config tab's schema validation — a key the form doesn't offer is
  a key the running version doesn't know.
- docs.openclaw.ai has been wrong about this version several times (the memory-search
  key path, the `openai` plugin default, the `onepassword` plugin). When the docs and
  the Config tab disagree, the tab reflects the live schema and wins.

## Public dashboard access

The dashboard is **not** exposed through SWAG or a port-forward, deliberately. OpenClaw's
history includes mass scans finding six figures of openly reachable instances and a string
of CVEs; an agent gateway with credentials to your life is the last thing that should sit
naked on 443.

Instead, `cloudflared` makes an outbound-only connection to Cloudflare and serves the
dashboard at `claw.example.com`, with a Cloudflare Access policy in front (the
`example.com` zone is hosted on Cloudflare's free plan; registration stays at
DNSimple):

1. In [Zero Trust](https://one.dash.cloudflare.com/) → Networks → Tunnels, create a tunnel,
   pick **Docker** as the connector, and copy the token into
   `CLOUDFLARED_TUNNEL_TOKEN`.
2. Add a public hostname `claw.example.com` to the tunnel with service
   `http://openclaw:18789` (Cloudflare creates the CNAME automatically). The gateway
   must be bound `lan` (onboarding step above) — bound to loopback it 502s from the
   tunnel. Exposure is still only what compose publishes — the LAN port and the tunnel.
3. In Zero Trust → Access → Applications, add an application for that hostname with a
   policy allowing only your email (one-time PIN or an identity provider).
4. Tell the gateway to trust `cloudflared` as a proxy: `gateway.trustedProxies:
   ["172.25.0.10"]` in the Config tab. Since 2026.9.x the gateway attributes
   proxy-shaped traffic *before* auth runs, and rejects requests it can't attribute with
   `403 proxy_attribution_required` — the tunnel 403s while LAN access on
   `${OPENCLAW_HOST_PORT}` keeps working, which is the tell.

   That address is pinned in the compose file (`cloudflared.networks.claw-net.ipv4_address`,
   with the subnet declared under `networks.claw-net.ipam` so Docker can't reassign it).
   **The two must stay in sync** — change one without the other and the tunnel 403s again.

   Leave `gateway.allowRealIpFallback` unset. It defaults to `false`, which is fail-closed;
   enabling it makes the gateway accept `X-Real-IP` when `X-Forwarded-For` is absent, and is
   only safe if the proxy strips a client-supplied `X-Real-IP`. Never widen `trustedProxies`
   beyond that one address: anything it names can forge client IPs.

Result: the dashboard answers at a real public URL, but Cloudflare demands your identity
before any request reaches the container, no host ports are open, and OpenClaw's own
gateway token auth remains as a second layer.

## 1Password

The `onepassword` plugin that docs.openclaw.ai describes does not exist in this image
(`plugins.allow` rejects the id as `plugin not found`). What the image has is the `op`
CLI (bind-mounted in Deploying step 3) authenticated by a service-account token from the
environment, driven by the bundled 1password skill or the agent's exec tool.

Create a **service account** at
[1password.com](https://developer.1password.com/docs/service-accounts/) scoped
**read-only to the agent's dedicated vault** (see Security notes — never grant it
personal vaults), put its `ops_...` token in `.env` as `OP_SERVICE_ACCOUNT_TOKEN`, and
update the stack. Sanity check:

```sh
docker exec openclaw op --version    # the bind-mounted CLI
docker exec openclaw op vault list   # should list exactly the agent vault
```

## Fastmail (agent email)

The agent gets its own mailbox and reaches it through Fastmail's official MCP server at
`https://api.fastmail.com/mcp` — a hosted endpoint, so this adds no container, no port,
and no change to `docker-compose.claw.yml`. The whole integration is one MCP server entry
plus setup inside Fastmail.

Three decisions are baked into the setup below. Each is load-bearing, and each step
explains why before it tells you what to click.

| | Choice |
|---|---|
| Mailbox | Its own Fastmail **user**, never an alias on yours |
| Trigger | You ask in Discord — email never wakes the agent |
| Outbound | The agent **drafts**; you send |

### 1. Give the agent its own Fastmail user

An alias or Masked Email on your account will not do. An API token is scoped to the
*account* that minted it, not to the address the mail arrived at — a token created from
your account carries `mail` scope over your whole mailbox no matter which alias is
involved. That is the opposite of "never mine."

Add a second user on a Duo or Family plan (each co-subscriber keeps their own account,
inbox, and settings) and give it an address on the domain.

Pick something unguessable rather than the obvious `claw@` or `agent@`, and keep it out of
this repo — the repo is public, and the address is the one thing an attacker needs before
any of the rest of this matters. Treat it the way you would a webhook URL: not a secret in
the cryptographic sense, but nothing to publish either. It is a layer under the discard
rule in step 2, not a replacement for it.

Fastmail does not document per-user token creation, but it works: a Duo sub-account can
reach Settings → Privacy & Security → Manage API tokens under its own login and mint its
own (verified August 2026). That is what makes this arrangement worth anything — the
token the agent holds is issued by, and scoped to, an account that is not yours.

Note that an **app password** is not a substitute. Those authenticate IMAP/SMTP/CalDAV
clients and carry no MCP scopes; the MCP endpoint will not accept one as a bearer token.

### 2. Control what reaches the account at all — not what the agent reads

The MCP token's **Read data** scope is account-wide. There is no folder-scoped token, so
the agent can read every folder in its account whenever it likes, and an injection sitting
in one message can tell it to go read another. Filing rules organize; they do not confine.

So the boundary has to be *delivery*, not filing. Two rules, in order:

1. **If** From is your personal address **then** move to `Tasks`
2. **If** From is not on the allowlist **then** discard

The allowlist is your address plus any sender the agent genuinely needs — signup and
confirmation mail for accounts you create *for* it, for instance. Keep it short and add to
it deliberately.

The second rule is the one that matters. Mail that never lands cannot be read, so anyone
who learns the agent's address still cannot put text in front of it. Discard, not move to
Trash: the token reads Trash too.

A "only read mail from me" line in `TOOLS.md` is not a substitute. That is a suggestion to
the model, and overriding suggestions to the model is precisely what an injection does.

### 3. Mint a read + write token — no send scope

Fastmail's own [MCP setup guide](https://www.fastmail.help/hc/en-us/articles/15869557281295-Connecting-AI-tools-via-Fastmail-s-MCP-server)
documents OAuth 2.0 as the usual way to connect a client. That path needs a browser for
the consent screen, which a headless container does not have — so use the API token
alternative it mentions, and pass the token as a bearer header.

As the agent user, go to Settings → Privacy & Security → Manage API tokens and create a
token. In the **Type** section pick **MCP**, not JMAP — the scope list is type-specific,
and only the MCP type offers the three levels below. (JMAP tokens expose a different set:
read-only, email, email submission, contacts, masked email.)

The three MCP access levels are independent checkboxes ("you can choose more than one"),
so withholding send is a real option:

- ✅ **Read data** — search and read mail
- ✅ **Make changes** — draft replies; move, delete, and organize mail
- ❌ **Send email** — deliberately withheld; see [Outbound](#outbound-the-agent-drafts-you-send)

Each level bundles contacts and calendars in with mail; there is no mail-only scope. On a
purpose-made account those are empty, which is one more reason step 1 is a separate user
rather than an alias on yours — on your account, "read mail" would also mean your whole
address book and calendar.

### 4. Register it with OpenClaw

Add the server at **Settings → MCP** (URL `https://api.fastmail.com/mcp`, transport
streamable-http), then fill in the header and tool filter in the Config tab under
`mcp.servers.fastmail`:

```json5
{
  url: "https://api.fastmail.com/mcp",
  transport: "streamable-http",
  headers: { Authorization: "Bearer <fastmail-mcp-token>" },
  toolFilter: {
    include: ["list_folders", "search_email", "read_email", "read_thread",
              "draft_email", "archive_email", "list_identities"],
  },
}
```

Then `docker exec openclaw openclaw mcp probe fastmail` — `probe` is what lists tool
names and confirms the token is accepted. If the bearer header is rejected outright, the
fallback is `auth: "oauth"` in place of the header, completing the consent flow from a
browser. Removing a server later is `openclaw mcp unset <name>` (or the MCP page);
`remove`/`delete` don't exist and print the parent help rather than erroring.

Filter entries are raw MCP tool names, matched before OpenClaw namespaces them — so
`draft_email`, not the `fastmail__draft_email` the probe prints. Re-probe after applying a
filter and check the tool count actually dropped; a filter that matches nothing fails
silently and looks exactly like a filter that worked.

The include list matters more than it looks. Fastmail advertises 29 tools covering mail,
contacts, calendars, notes, and attachments — far more surface than reading a folder and
drafting a reply needs, and it includes `delete_email`, `delete_contact`, `delete_event`,
and `delete_note`, all of which the **Make changes** scope permits. The seven above are
what the workflow uses; everything else stays out of the model's context entirely.

Observed with a read + write token: no send-capable tool appears in the catalog at all.
Withholding the send scope removes the capability at discovery, not just at call time, so
the model is never offered a way to transmit. Whether Fastmail gates advertisement on
scope or simply has no send tool is not something this setup can distinguish — but either
way, do not read a missing tool as a substitute for the scope decision in step 3.

Under the Codex harness the server is projected into the app-server; `/codex status`
lists it. Confirm it is there after switching runtimes — the projection is a different
code path from the embedded runtime's MCP bridge.

Then add a line to the agent's `TOOLS.md` in the workspace telling it to work from the
`Tasks` folder and to leave replies in `Drafts`.

### Where the token lives

The model never sees it in normal operation. The header is attached by the gateway when it
opens the connection to Fastmail; what reaches the model is tool names, schemas, and
results. OpenClaw treats resolved MCP headers as credential material — it registers them in
a secret-redaction registry before they reach any transport, including the bare token
inside a `Bearer <token>` value, so they stay out of logs, status output, and debug
captures.

At rest is the honest part: the token is stored in OpenClaw's config under
`${APPDATA}/openclaw/config`, which is the *parent* of the agent's workspace mount. An
agent with a shell tool or file reads that reach outside the workspace can read it — along
with the gateway token, the ChatGPT OAuth profile and Anthropic key in the auth store,
and `DISCORD_BOT_TOKEN` from the container environment. The Fastmail
token is not uniquely exposed; it joins a set that is already there.

So treat it as exfiltratable, per the rule in [Security notes](#security-notes), and let
the blast radius be the answer rather than the storage. A stolen Fastmail token is read and
write on a purpose-made mailbox that holds only what you forwarded, has no contacts or
calendar worth taking, and **cannot send**. That is the payoff for steps 1 and 3 — on a
token minted from your own account, the same theft would be your whole mail history,
address book, and calendar.

Two things worth doing:

- Run `docker exec openclaw openclaw mcp doctor`. It flags literal sensitive header values,
  and it is right to. The documented alternative is OAuth, which keeps credentials in
  OpenClaw's own store instead of a static header — try `auth: "oauth"` plus
  `openclaw mcp login`, and keep the bearer header only if the flow needs a browser
  redirect the container cannot complete.
- Keep the agent's shell surface as small as it can be; `openclaw security audit` reports
  what is enabled. Every tool that can read arbitrary paths is a path to the config file.

### Using it

Forward anything you want handled to the agent's address; the rule files it into `Tasks`.
Then ask in Discord — "handle what's in Tasks." Email is a data source and an outbound
drafting surface, never a wake-up signal, so every run is one you started and can watch in
a channel you already trust.

Deliberately **not** set up: a cron or heartbeat that polls the folder. That would close
the loop — attacker-controlled text arriving and the agent acting on it with nobody in the
room. The forward-then-ask rhythm costs one Discord message and removes the whole class.

### Outbound: the agent drafts, you send

The agent composes into `Drafts` in its own account. You open Fastmail and hit send.

Note what **Make changes** covers: the agent can edit a draft after you have read it. You
are still the one transmitting, which is the property that matters, but drafting is not
inert — read a draft at send time, not just when it appears.

This is not squeamishness about a working feature — it is that the gate a send tool would
need does not exist here. OpenClaw's `mcp add --approval` flag is not it: `approve` means
*bypass* per-call approval, not require it, and the flag writes
`codex.defaultToolsApprovalMode`, which applies only to Codex app-server threads. Now that
OpenAI turns *do* run on the Codex app-server, the per-server `codex.defaultToolsApprovalMode:
"prompt"` setting is worth re-testing as an approval gate — but it covers only the Codex
runtime, not the Anthropic fallback, and the plugin `before_tool_call` hook still has no
documented MCP path. Until a gate is verified for every runtime in the chain, there is no
way to make an MCP send tool stop and ask a human here.

Given that, granting send scope means granting *unattended* send. And at the API level
"reply to a thread" and "email a stranger" are the same permission — there is no cheaper
reply-only scope — so it would be unattended cold-send, to an agent whose input is
untrusted forwarded mail. Drafting costs one click, since you are already in the loop when
the run happens.

Revisit if OpenClaw ships a runtime-agnostic tool approval gate: the change is a second
token with **Send email**, registered as its own MCP server so the gate can target it.

## Security notes

- The agent workspace is its own share; no other shares are mounted into any container
  here, and nothing in this stack touches the Docker socket. Keep it that way — if the
  agent ever needs Docker control, use the `docker-socket-proxy` pattern from `media/`.
- Treat every credential the agent can use as exfiltratable via prompt injection: give it
  per-service accounts created for it (its own API keys, never personal logins), and keep
  them in a dedicated 1Password vault so rotation is one place. The ChatGPT login is the
  one exception by design — it's the subscription being used — so it should be a ChatGPT
  account that holds nothing else.
- The 1Password service account is the enforcement edge of that rule: scope it read-only
  to the agent vault and nothing else. Whatever it can read, a prompt injection can read —
  there is no human-approval gate on this runtime.
- The Codex harness runs in `yolo` mode (`sandbox: danger-full-access`) because its
  `guardian` sandbox needs nested user namespaces the container denies. The container
  is the boundary, as it already was for the embedded runtime's exec tool.
- The browser tool runs Chromium inside the `openclaw` container, with `--no-sandbox`
  because Docker's seccomp profile denies Chromium's namespace sandbox. A renderer
  escape therefore lands in the gateway container — next to the config mount and the
  auth store holding the provider credentials. Keep `browser.ssrfPolicy` at its fail-closed
  default (it blocks navigation to private and loopback addresses, the gateway's own port
  included, unless `dangerouslyAllowPrivateNetwork` is set), and note that this Chromium
  is the version pinned by the image's Playwright release, so it only updates when the
  OpenClaw image does.
- Skills from ClawHub are third-party code with a documented malware problem. Read a
  skill before installing it; prefer MCP servers for integrations.
- Forwarded mail is untrusted input that lands directly in the agent's context — a message
  body is an attacker's chance to write instructions the agent reads as its own. The
  defenses that hold are the ones outside the prompt: a Fastmail rule that discards mail
  before it is ever delivered, and no send scope on its token. Note that the read token is
  account-wide — any folder the agent's account holds is readable, so the boundary has to
  be delivery. Rules written into `TOOLS.md` are not defenses; they are the thing the
  injection overrides.
- Prefer official first-party MCP endpoints over community servers. Every Fastmail MCP
  server on GitHub is unofficial, and handing unvetted npm code a full-mailbox token is
  the same supply-chain bet as a ClawHub skill. Fastmail's own hosted endpoint avoids it
  entirely — no code to audit, and scopes enforced on their side.

## References

- [OpenClaw docs — Docker install](https://docs.openclaw.ai/install/docker)
- [OpenClaw docs — gateway configuration](https://docs.openclaw.ai/gateway/configuration)
- [OpenClaw docs — Control UI](https://docs.openclaw.ai/web/control-ui)
- [OpenClaw docs — OpenAI provider (subscription OAuth)](https://docs.openclaw.ai/providers/openai)
- [OpenClaw docs — Codex harness](https://docs.openclaw.ai/plugins/codex-harness)
- [OpenClaw docs — onboarding reference](https://docs.openclaw.ai/reference/wizard)
- [OpenClaw docs — browser tool](https://docs.openclaw.ai/tools/browser)
- [OpenClaw docs — MCP](https://docs.openclaw.ai/tools/mcp)
- [Fastmail — an MCP server for Fastmail](https://www.fastmail.com/blog/an-mcp-server-for-fastmail/)
- [Fastmail — API tokens](https://www.fastmail.help/hc/en-us/articles/5254602856719-API-tokens)
- [Fastmail — connecting AI tools via the MCP server](https://www.fastmail.help/hc/en-us/articles/15869557281295-Connecting-AI-tools-via-Fastmail-s-MCP-server)
- [Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
