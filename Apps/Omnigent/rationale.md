# Omnigent — packaging rationale

Notes on where this app departs from the AppStoreLab defaults, and why.

## Three containers, one of which exists only to run agents

Omnigent splits into a coordinator and one or more *hosts*. The coordinator
serves the web interface and stores sessions; hosts are the machines agents
actually execute on. `ghcr.io/omnigent-ai/omnigent-server` is deliberately
minimal — no `git`, `node`, `tmux` or agent CLIs — so it cannot run anything
itself. Installing the server alone yields a working web interface with no way
to start a session.

`omnigent-host` therefore ships alongside it, from the official
`ghcr.io/omnigent-ai/omnigent-host` image, which carries the toolchain
(Python 3.12, Node 22, git, tmux, bubblewrap, `claude`, `codex`).

Credentials belong on the **host**, never the coordinator: `configured_harnesses`
is probed by the host daemon and reported upward, so a credential placed in the
server container is silently ignored. The install tip says so explicitly, because
`docker exec -it omnigent omnigent setup` looks like the obvious command and
silently does nothing useful.

## `entrypoint` overridden from `pre-install`

The host image's default command is `sleep infinity` — it is built to be driven
from outside by a sandbox provider. Turning it into a self-registering container
needs a bootstrap that waits for the coordinator, signs in, and execs
`omnigent host`. That script is fetched to `/DATA/AppData/omnigent/bootstrap/`
by `pre-install-cmd` and mounted in, which keeps the app on official images with
no build step.

Sign-in is done by POSTing `/auth/login` and writing the JWT to
`~/.omnigent/auth_tokens.json` — the same thing `omnigent login` does, except
that command only prompts on a TTY and cannot be scripted.

## `webui_port: 8000`, not 80

The server's own `HEALTHCHECK` curls `http://127.0.0.1:${PORT}/health`, and 8000
is the port upstream documents everywhere. Remapping to 80 buys a marginally
cleaner internal URL and adds a way for the healthcheck and the docs to drift
apart. The public URL is unaffected — Caddy terminates at
`https://omnigent-<user>.<domain>` either way.

## `OMNIGENT_HOST_NAME` is not used to name the host

It looks like the obvious variable, but it is reserved for server-managed
sandbox launches and must be set together with `OMNIGENT_HOST_ID`; setting it
alone makes the CLI exit with *"must be set together"*. The supported route is a
partial `host:` section in `config.yaml` — omnigent completes it by generating
only the missing `host_id` and never clobbers a name that is already there
(`omnigent/host/identity.py`). The bootstrap seeds the name that way.

## Cookie secret generated at install

`OMNIGENT_ACCOUNTS_COOKIE_SECRET` must be **valid hex** — the server refuses to
boot with `RuntimeError: must be a valid hex string` otherwise, so
`$APP_DEFAULT_PASSWORD` cannot be reused for it. `pre-install-cmd` generates one
with `openssl rand -hex 32` into the app's `.env`, the same pattern Docmost uses
for `DOCMOST_APP_SECRET`.

The first admin is seeded through `OMNIGENT_ACCOUNTS_INIT_ADMIN_*`. Without it
the server boots into a "create the first admin" web form, and the host sidecar
has no credentials to sign in with — the app would arrive half-installed.

## `TZ: Etc/UTC` hardcoded

The platform injects a malformed `$TZ` into containers. Rather than pass it
through and hope, both long-running services pin `Etc/UTC`.

## Resource limits

The host is given the largest budget (4 GB / 2 CPU): it runs the agents, and
`node`-based harnesses on a large repository are the heaviest thing in the
stack. Upstream puts the server's own working set at 512 MB–1 GB, so it gets
1.5 GB. `cpu_shares: 50` on the host keeps agent work from starving interactive
apps on a busy PCS.

## Agents only see `/workspace`

`/DATA/AppData/omnigent/workspace/` is the only user-writable path mounted into
the host. `/DATA/Documents`, `/DATA/Media` and the Docker socket are **not**
exposed, unlike the ClaudeCode app which is explicitly an administrative tool.
An agent here has full shell access inside its own container and can spend money
against the connected account; widening that blast radius should be a deliberate
choice by the user, not the default. Users who want agents working on other
directories can add mounts themselves.
