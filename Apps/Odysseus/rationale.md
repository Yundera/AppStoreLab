# Odysseus — packaging rationale

Notes on the choices in `docker-compose.yml` that deviate from the store defaults,
and on why the app is in AppStoreLab rather than the main AppStore.

## Container image comes from a community fork

`ghcr.io/worph/odysseus:1.0.2-dev.7c8070f`

Upstream does not currently publish a pullable image:

- `ghcr.io/odysseus-dev/odysseus` — the current org's package is **private**; every
  tag returns `unauthorized`.
- `ghcr.io/pewdiepie-archdaemon/odysseus` — the pre-rename org's package is public
  but **frozen since 2026-07-12**, with nothing indicating it is stale.

See [odysseus-dev/odysseus#5728](https://github.com/odysseus-dev/odysseus/issues/5728).
The image used here is built from unmodified upstream source with the upstream CI
workflow. It is public, anonymous-pullable, and a proper multi-arch index
(`linux/amd64` + `linux/arm64`).

The tag embeds the source commit (`7c8070f`), so it behaves as an immutable
reference even though upstream's own `1.0.2` tag is mutable and has been rebuilt
several times.

**This is the main reason the app lives in AppStoreLab.** Promote it to the main
AppStore once upstream publishes a public package (swap the `image:` line), or
mirror the image to `rg.fr-par.scw.cloud/aptero` if it needs to ship before then.

## Three containers, ~4.5 GB of memory limits

Odysseus needs both a vector store and a search backend to be functional:

| Service | Limit | Why |
|---|---|---|
| `odysseus` | 3 GB | Python app + FastEmbed (ONNX MiniLM) + a headless Chromium for the built-in browser MCP server |
| `odysseus-chromadb` | 1 GB | persistent long-term memory |
| `odysseus-searxng` | 512 MB | private metasearch backing Deep Research |

Measured idle usage on a test PCS right after first start: ~840 MB / ~45 MB /
~145 MB. The limits leave headroom for agent runs and research jobs, which spawn
the bundled Chromium.

Upstream's compose also ships an `ntfy` service for push notifications. It is
dropped here — the store already has a standalone Ntfy app, and `NTFY_BASE_URL`
is left empty so the feature simply stays off.

## ChromaDB persist path

Upstream's compose mounts `/chroma/chroma`, which was correct for Chroma 0.x.
Chroma 1.5.x reads `persist_path` from the `/config.yaml` baked into the image,
and that value is `/data`. The mount here targets `/data`; copying upstream's
path would silently give an ephemeral vector store.

## No model backend is configured

Odysseus is an interface and agent runtime, not a model. Nothing sensible can be
picked on the user's behalf:

- Pointing at the store's Ollama app is not possible out of the box — that app
  keeps `ollama-api` on its own `ollama_default` network and only `expose`s
  11434, so it is unreachable from here, and Compose has no notion of an optional
  external network.
- Baking in a cloud provider would require a key the user has not given.

So `OPENAI_API_KEY`, `OLLAMA_BASE_URL`, `RESEARCH_LLM_ENDPOINT` and
`EMBEDDING_URL` all ship empty, and `tips.before_install` tells the user this is
the first thing to set up. Embeddings still work offline via the bundled
FastEmbed model, so memory and search are functional before a chat model exists.

## Authentication and cookies

The app is published on public HTTPS hostnames, so it must not be left open:

- `AUTH_ENABLED=true`, `LOCALHOST_BYPASS=false`, `SECURE_COOKIES=true`.
- `ODYSSEUS_ADMIN_USER` + `ODYSSEUS_ADMIN_PASSWORD` seed the admin account on
  first start. Both must be set together, or `setup.py` falls back to printing a
  random password into the container log. **`ODYSSEUS_ADMIN_PASSWORD` must be at
  least 8 characters** — below that, `setup.py` errors out and creates no admin
  at all. `$APP_DEFAULT_PASSWORD` is 12 characters on a PCS.
- `ALLOWED_ORIGINS` is a comma-separated list of *exact* origins with no wildcard
  support, so all three published hostnames are listed. Omitting the `.nip.io`
  and `.sslip.io` entries breaks login on those URLs.

## `user: "0:0"` on the main service

The image has no `USER` directive on purpose: its entrypoint starts as root,
repairs ownership on the bind-mounted `/app/data` and `/app/logs`, then drops to
`PUID`/`PGID` with `gosu` before running uvicorn. Forcing a non-root `user:` here
would break that repair step. Verified on a test PCS: files under
`/DATA/AppData/odysseus/data/` end up owned by `1000:1000`.

## `init: true` on the main service

The image's entrypoint `exec`s uvicorn, so uvicorn becomes PID 1 — and uvicorn
does not reap orphaned children. Odysseus ships a built-in Playwright browser
MCP server that spawns Chromium, so every browser the agent starts is left
behind as a zombie. Observed on a test PCS: 30 `chromium` / `chrome_crashpad`
zombies accumulated within a few hours of light use.

That is not just untidy. Zombies stay in the host process table, and once enough
pile up, Docker's `containers/json` enumeration slows to the point where CasaOS's
app-grid request times out — the whole dashboard shows "Failed to load apps,
please refresh later" for *every* app on the box, not just this one.

`init: true` puts Docker's `docker-init` at PID 1 to reap them. After the change,
PID 1 is `docker-init`, uvicorn is PID 7, and the zombie count under the
container stays at 0.

## SearXNG configuration via `printf`, not a `pre-install/` asset

SearXNG needs a `settings.yml` that enables the `json` output format (Odysseus
queries it as an API) and carries a `secret_key`. The whole file is nine lines,
so `pre-install-cmd` writes it with a single `printf` and `openssl rand -hex 32`
rather than fetching an asset from jsDelivr. This keeps the app installable from
a branch before the commit reaches `main`, and avoids the heredoc syntax the
contributing guide warns against.

Upstream instead overrides the SearXNG `entrypoint:` with an inline shell script
that templates the secret at container start. That is not reproduced here — the
pre-install step does the same job without replacing the image's entrypoint.

## Testing

Deployed and validated on `holyhorse.nsl.sh` (test PCS, amd64) on 2026-07-29/30:

- All three containers start; `odysseus` reports healthy ~40 s after `up`.
- ChromaDB connects and creates its collections; FastEmbed loads the MiniLM model
  (384 dimensions); SearXNG returns JSON results to the app.
- `https://odysseus-<domain>/` redirects to `/login` and serves the UI; login with
  `admin` / `$APP_DEFAULT_PASSWORD` returns 200 and sets a `Secure; HttpOnly`
  session cookie; authenticated requests to `/` and `/api/models` return 200.
- Appears as a managed app tile in the CasaOS dashboard, with the `tips.before_install`
  block rendering correctly in the ⋮ → Tips dialog.
- `docker compose down && up` preserves `auth.json` and the database — setup logs
  `[skip] auth.json already exists` and the same credentials still work.

**Known gap:** the `caddy_2` Let's Encrypt route
(`odysseus-<ip>.sslip.io`) did not obtain a public certificate on that box.
Caddy's ACME order is cancelled by a config-reload race whenever a new app is
added, and it then pins the local-CA fallback certificate. This is not specific
to this app — `casadash-<ip>.sslip.io`, already installed on the same host, fails
identically. The gateway (`nsl.sh`) and `nip.io` routes both work.
