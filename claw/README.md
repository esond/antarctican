# claw stack

Personal AI assistant: OpenClaw as the agent gateway (Discord channel, Anthropic API for
models), using its builtin memory with a local embedding model for semantic recall and,
optionally, its own Fastmail mailbox over Fastmail's hosted MCP endpoint. Deployed from
`docker-compose.claw.yml` via the Docker Compose Manager plugin.

## Services

| Service | Image | Purpose | UI port |
|---|---|---|---|
| `openclaw` | ghcr.io/openclaw/openclaw | Agent gateway + dashboard | `${OPENCLAW_HOST_PORT}` |
| `cloudflared` | cloudflare/cloudflared | Publishes the dashboard at a public hostname via Cloudflare Tunnel | — |
| `claw-browser` | ghcr.io/browserless/chromium | Headless Chromium for the agent's browser tool (CDP) | — |
| `ollama` | ollama/ollama | Local embedding model for OpenClaw's memory search (pulls it on start) | — |

OpenClaw runs as its upstream fixed user (`node`, UID 1000) — it doesn't honor
`PUID`/`PGID`, same situation as Seerr. Ollama likewise uses its upstream user.

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
5. Run OpenClaw onboarding **before first start** — a fresh install has no config, the
   container crash-loops until one exists, and a restarting container can't be exec'd.
   Run the wizard as a one-off container with all three mounts (omitting the workspace
   mount seeds the agent files into `config/workspace` instead of the share):

   ```sh
   docker run -it --rm \
     -v /mnt/user/appdata/openclaw/config:/home/node/.openclaw \
     -v /mnt/user/appdata/openclaw/auth-secret:/home/node/.config/openclaw \
     -v /mnt/user/claw:/home/node/.openclaw/workspace \
     ghcr.io/openclaw/openclaw:latest onboard
   ```

6. Start the stack from the Compose Manager plugin. On first start `ollama` pulls its
   embedding model (~640MB) and only reports healthy once it's present.
7. Enable the plugins this stack needs. The image ships ~70 stock plugins with
   nearly all of them disabled — `openclaw plugins list` shows the ratio. Two matter
   here. The **anthropic** provider plugin supplies the live model catalog; without it
   the gateway knows only the models baked into core, so anything newer than those
   won't resolve — name one in `agents.defaults.models` and the request dies with a
   `FailoverError` whose wording blames the account or the model instead.
   **discord** is installed by onboarding but without explicit trust, so the bot won't
   start until it's enabled:

   ```sh
   docker exec openclaw openclaw config set plugins.entries.anthropic.enabled true
   docker exec openclaw openclaw config set plugins.entries.discord.enabled true
   docker restart openclaw
   ```

   The gateway logs which plugins actually loaded on startup (`http server listening
   (N plugins: ...)`) — that line, not the config write, is the confirmation. Don't
   hand-register models under `models.providers.anthropic.models[]` to route around a
   thin catalog; with the plugin enabled the catalog comes from upstream and stays
   current on its own.

   In the Discord developer portal, the bot needs the **Message Content** and
   **Server Members** privileged intents. Its presence shows offline by design — DM
   it anyway; the first DM returns a pairing code, approved with
   `docker exec openclaw openclaw pairing approve discord <code>`.
8. Point memory search at the local embedding model. The builtin memory engine defaults
   to OpenAI embeddings, and without an embedding provider it falls back to keyword-only
   (BM25) search. One validated write, so it can't half-apply:

   ```sh
   docker exec openclaw openclaw config set plugins.entries.ollama.enabled true
   echo '{ agents: { defaults: { memorySearch: { enabled: true, provider: "ollama", model: "qwen3-embedding:0.6b", remote: { baseUrl: "http://ollama:11434", apiKey: "ollama-local" } } } } }' \
     | docker exec -i openclaw openclaw config patch --stdin
   docker restart openclaw
   docker exec openclaw openclaw memory index --force
   docker exec openclaw openclaw memory status
   ```

   The **ollama** provider plugin is what registers the embedding provider, and it
   ships disabled like the ones in step 7. Config alone looks like it worked — every
   write is accepted — and the only sign is one line at gateway startup:

   ```
   memorySearch.provider="ollama" is configured, but no loaded plugin registered a
   memory embedding provider that can serve "ollama". Semantic memory recall will
   fall back to keyword/FTS-only search.
   ```

   The path is `agents.defaults.memorySearch`, **not** the `memory.search` that
   docs.openclaw.ai documents — that key doesn't exist on 2026.7.1 and the patch is
   rejected. `openclaw config schema` is the authoritative source when they disagree.
   Use the native Ollama URL, not the `/v1` OpenAI-compatible one. `apiKey` is a
   placeholder Ollama ignores.

   The `memory index --force` is required, not optional: changing embedding provider or
   model invalidates the vector index identity, and OpenClaw pauses vector search rather
   than silently re-embedding. Without it the config is correct and recall still returns
   nothing. `memory status` should report a non-zero `Indexed:` and a `Vector dims:` line.

   `sources` defaults to `["memory"]`, which covers `MEMORY.md` and `memory/` but **not**
   `USER.md` — that file is injected into context every session rather than retrieved. Add
   it to `extraPaths` if it should be searchable too.

   `qwen3-embedding:0.6b` is the best quality-per-MB option that runs on CPU here;
   `embeddinggemma` is an equivalent alternative and `nomic-embed-text` a lighter one.
   Changing model later means re-embedding every note, so pick before the memory grows.
9. Enable the browser tool, attached to the `claw-browser` sidecar over CDP.
   Five gates, all required — the docs mention only the first (substitute the
   `BROWSERLESS_TOKEN` value from `.env`):

   ```sh
   docker exec openclaw openclaw config set browser.enabled true
   docker exec openclaw openclaw config set browser.profiles.browserless '{"cdpUrl":"ws://claw-browser:3000?token=<BROWSERLESS_TOKEN>","attachOnly":true,"color":"#f97316"}'
   docker exec openclaw openclaw config set plugins.entries.browser.enabled true
   docker exec openclaw openclaw config set tools.alsoAllow '["browser"]'
   docker exec openclaw openclaw config set browser.defaultProfile browserless
   docker restart openclaw
   ```

   - `attachOnly: true` — without it OpenClaw treats the profile as a
     locally-managed browser and tries to launch Chromium inside its own
     container, which fails (no browser binary there; that's the sidecar's job).
   - `color` (any CSS color) is required by the config schema even though the
     docs don't list it — the profile write is rejected without it.
   - The browser plugin ships disabled, same as Discord in step 7. If
     `plugins.allow` is set (Hardening below), `browser` must be on it too.
   - The onboarding tool profile (`tools.profile: "coding"`) excludes the UI
     tool group, so the plugin can be enabled and healthy while the agent still
     has no browser tool. `tools.alsoAllow` grants just the browser tools
     without widening the whole profile to `full`.
   - Defining the profile does not make the tool *use* it. The browser service
     registers the built-in managed profiles alongside yours (it logs
     `Browser control service ready (profiles=4)` for a config that names one),
     and an unset `browser.defaultProfile` resolves to the managed `openclaw`
     profile. A tool call that doesn't name a profile then tries to launch
     Chromium locally and fails with `No supported browser found` — the
     sidecar is never contacted. Naming `browserless` in the prompt works and
     hides the problem, so test without naming it.

   Verify from the sidecar, not from the agent's answer: `docker logs
   claw-browser` should show a `ChromiumCDPWebSocketRoute` session opening from
   the openclaw container. A managed-launch failure produces no browserless
   activity at all.
10. 1Password. The `onepassword` plugin that docs.openclaw.ai describes does not
    exist in 2026.7.1 — `plugins.allow` rejects the id as `plugin not found` — so
    the plugin/credentials-file steps there don't apply. What this image has is
    the `op` CLI (bind-mounted in step 3) authenticated by a service-account
    token from the environment, driven by the bundled 1password skill or the
    agent's exec tool.

    Create a **service account** at
    [1password.com](https://developer.1password.com/docs/service-accounts/) scoped
    **read-only to the agent's dedicated vault** (see Security notes — never
    grant it personal vaults), put its `ops_...` token in `.env` as
    `OP_SERVICE_ACCOUNT_TOKEN`, and update the stack. Sanity check:

    ```sh
    docker exec openclaw op --version    # the bind-mounted CLI
    docker exec openclaw op vault list   # should list exactly the agent vault
    ```

### Hardening

Once the dashboard is publicly reachable, apply these (the onboarding wizard leaves
insecure auth on, and `gateway.bind lan` makes the origin/rate-limit settings matter):

```sh
docker exec openclaw openclaw config set gateway.controlUi.allowInsecureAuth false
docker exec openclaw openclaw config set plugins.allow '["anthropic","discord","ollama","browser","memory-core"]'
docker exec openclaw openclaw config set plugins.bundledDiscovery allowlist
docker exec openclaw openclaw config set gateway.controlUi.allowedOrigins '["https://claw.example.com"]'
docker exec openclaw openclaw config set gateway.auth.rateLimit '{"maxAttempts":10,"windowMs":60000,"lockoutMs":300000}'
docker restart openclaw
docker exec openclaw openclaw security audit
```

`plugins.allow` is exhaustive, not additive: a plugin missing from it stays unloaded
however it is configured elsewhere, so every plugin enabled in the steps above has to
appear here. The list is also validated — an id the image doesn't ship is rejected as
`plugin not found`, which makes it a cheap way to check a name.

`memory-core` is on the list even though no step above enables it: it ships enabled and
backs the memory search from step 8. On 2026.7.1 the allowlist gates **bundled** plugins
too, so leaving it off drops memory search — the same silent degradation as an unenabled
`ollama`, one layer up. `plugins.bundledDiscovery` is what selects that behavior, and it
must be set explicitly: on a config that predates the key, `openclaw doctor` offers to
write `"compat"`, which restores the legacy carve-out where bundled plugins load whether
or not they're listed. Take `"allowlist"` instead — `compat` reintroduces exactly the
implicit loading this section exists to prevent. Order matters when applying it to a
running gateway: widen the list first, then set the mode, or the restart in between drops
`memory-core`.


The audit should come back with zero criticals. A warn about the unpinned
`@openclaw/discord` npm spec is accepted — it matters at plugin-update time, not at
rest; pin to an exact version if updates should be deliberate.

### Gotchas

- First dashboard login from any new browser is two steps: paste the gateway token
  (`openclaw config get gateway.auth.token`) into Control UI settings, then approve
  the device pairing request it triggers with
  `docker exec openclaw openclaw devices approve <requestId>` (the requestId is shown
  on the login screen). Both stick per browser. Leave `deviceAutoApprove` off — the
  one-time approval is what stops a stolen token from silently attaching a new device.
- The empty `config/workspace` directory inside the OpenClaw appdata is the mountpoint
  for the nested workspace bind. Deleting it on the host disconnects the live mount
  (the container sees ENOENT on its workspace); recreate the directory and
  `docker restart openclaw` to recover.
- `openclaw models list` dies with `Cannot read properties of undefined (reading
  'input')` once the `anthropic` provider plugin is enabled (2026.7.1). The stack
  trace lands in `applyAnthropicSonnet5Cost` while normalizing configured rows, and it
  fires whatever is in `agents.defaults.models` — including a list of nothing but
  current models. The gateway resolves models by another path and is unaffected: the
  agent keeps answering, and the dashboard still reports the model in use. Don't
  rearrange `agents.defaults.models` or hand-register `models.providers.anthropic`
  trying to clear it.
- `openclaw doctor` always reports two Browser warnings here — no Chromium executable,
  and no `DISPLAY` with `browser.headless` false — and names `browserless` as an
  "OpenClaw-managed" profile despite its `attachOnly`. They read identically whether the
  browser tool is working or completely broken, so treat them as constant, not as a
  monitor: their presence isn't a fault and their absence isn't health. Don't set
  `browser.headless` or `browser.executablePath` to silence them; both describe a local
  launch this stack never performs. The check that does discriminate is a
  `ChromiumCDPWebSocketRoute` session in `docker logs claw-browser` after a prompt that
  doesn't name the profile.
- `openclaw memory status --deep` can report `Unknown memory embedding provider: ollama`
  even while `memory_search` works fine at runtime
  ([openclaw#66077](https://github.com/openclaw/openclaw/issues/66077)) — it's a
  diagnostic-path bug, not a broken config. Trust an actual recall test over it.
- A `WorkspaceVanishedError` at message time means the workspace content no longer
  matches the attestation in `config/workspace-attestations/` — usually an empty or
  wrong mount. Fix the workspace rather than deleting attestations.

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
   `http://openclaw:18789` (Cloudflare creates the CNAME automatically). OpenClaw
   binds loopback inside its container by default, which `cloudflared` can't reach
   (502 from the tunnel); set it to bind all container interfaces:

   ```sh
   docker exec openclaw openclaw config set gateway.bind lan
   docker restart openclaw
   ```

   Exposure is still only what compose publishes — the LAN port and the tunnel.
3. In Zero Trust → Access → Applications, add an application for that hostname with a
   policy allowing only your email (one-time PIN or an identity provider).

Result: the dashboard answers at a real public URL, but Cloudflare demands your identity
before any request reaches the container, no host ports are open, and OpenClaw's own
gateway token auth remains as a second layer.

## Fastmail (agent email)

The agent gets its own mailbox and reaches it through Fastmail's official MCP server at
`https://api.fastmail.com/mcp` — a hosted endpoint, so this adds no container, no port,
and no change to `docker-compose.claw.yml`. The whole integration is one `openclaw mcp add`
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

```sh
docker exec openclaw openclaw mcp add fastmail \
  --url https://api.fastmail.com/mcp \
  --transport streamable-http \
  --header "Authorization=Bearer <fastmail-mcp-token>" \
  --include 'list_folders,search_email,read_email,read_thread,draft_email,archive_email,list_identities'
docker exec openclaw openclaw mcp probe fastmail
```

Note `--header` takes `KEY=VALUE`, not the `KEY: VALUE` shape the HTTP header itself uses
(the docs render it the latter way; the CLI rejects it). It splits on the first `=` and
does not trim the value, so put no space after the `=` — spaces and `=` padding inside the
token are fine.

`mcp add` probes before saving, so a bad token surfaces here rather than mid-task. If the
bearer header is rejected outright, fall back to `--auth oauth` in place of `--header` and
complete the consent flow from a browser.

`probe` is what lists tool names; `mcp tools <name>` only *sets* an include/exclude filter
and errors without one. Once the names are known, apply the filter with
`openclaw mcp tools fastmail --include '<name>,<name>'`.

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

The token appears in your shell history and in the Compose Manager's command box. Treat it
like the gateway token: mint it for this purpose only, and rotate it if it leaks.

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
with the gateway token, and `ANTHROPIC_API_KEY` and `DISCORD_BOT_TOKEN` from the container
environment. The Fastmail token is not uniquely exposed; it joins a set that is already
there.

So treat it as exfiltratable, per the rule in [Security notes](#security-notes), and let
the blast radius be the answer rather than the storage. A stolen Fastmail token is read and
write on a purpose-made mailbox that holds only what you forwarded, has no contacts or
calendar worth taking, and **cannot send**. That is the payoff for steps 1 and 3 — on a
token minted from your own account, the same theft would be your whole mail history,
address book, and calendar.

Two things worth doing:

- Run `docker exec openclaw openclaw mcp doctor`. It flags literal sensitive header values,
  and it is right to. The documented alternative is OAuth, which keeps credentials in
  OpenClaw's own store instead of a static header — try `--auth oauth` plus
  `openclaw mcp login`, and keep the bearer header only if the flow needs a browser
  redirect the container cannot complete.
- Keep the agent's shell surface as small as it can be; `openclaw security audit` from
  [Hardening](#hardening) reports what is enabled. Every tool that can read arbitrary paths
  is a path to the config file.

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
`codex.defaultToolsApprovalMode`, which applies only to Codex app-server threads — not the
Anthropic runtime this stack uses. The plugin `before_tool_call` hook does support
`requireApproval` with `/approve` in chat, but its docs never mention MCP, MCP tools are
built without hook wrapping, and the one documented MCP path into plugin approvals is
gated on a Codex-specific marker. So there is no verified way to make an MCP send tool
stop and ask a human here.

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
  them in a dedicated 1Password vault so rotation is one place.
- The 1Password service account is the enforcement edge of that rule: scope it read-only
  to the agent vault and nothing else. Whatever it can read, a prompt injection can read —
  there is no human-approval gate on this runtime.
- `claw-browser` sits on the LAN, so the browser tool can reach internal HTTP UIs (Unraid,
  the router) as rendered pages. That's within the trust already granted — the
  agent has network access regardless — but it's the reason the sidecar publishes no port
  and CDP is token-gated.
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
- [OpenClaw docs — browser tool](https://docs.openclaw.ai/tools/browser)
- [OpenClaw docs — 1Password plugin](https://docs.openclaw.ai/gateway/1password)
- [OpenClaw docs — MCP CLI](https://docs.openclaw.ai/cli/mcp)
- [Browserless docs](https://docs.browserless.io/)
- [Fastmail — an MCP server for Fastmail](https://www.fastmail.com/blog/an-mcp-server-for-fastmail/)
- [Fastmail — API tokens](https://www.fastmail.help/hc/en-us/articles/5254602856719-API-tokens)
- [Fastmail — connecting AI tools via the MCP server](https://www.fastmail.help/hc/en-us/articles/15869557281295-Connecting-AI-tools-via-Fastmail-s-MCP-server)
- [Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
