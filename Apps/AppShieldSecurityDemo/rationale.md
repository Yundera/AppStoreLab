# AppShield Security Demo — Rationale

## What this app demonstrates

A reference deployment that protects an HTTP backend (`traefik/whoami`) with
[AppShield](https://github.com/Yundera/AppShield), exercising **all** of its
authentication paths so developers can see the full security model in one place:

- **Humans → SSO** via OIDC (`OIDC_REGISTRAR_URL`) → Dex → CasaOS. Zero secrets to
  configure; the gate self-registers with `auth-registrar` on first login.
- **Machines → shared hash** (`AUTH_HASH`, CasaOS-provided): presentable as `?hash=`,
  `Authorization: Bearer`, or HTTP Basic (`-u any:<hash>`).
- **Machines → real CasaOS identity** (`CREDENTIAL_VALIDATE_URL`): `-u <user>:<pass>`
  or a CasaOS bearer token, verified against CasaOS via the bridge's validator.

`whoami` echoes the request it received, so after authenticating by any path you see
exactly which headers reached the backend — visible proof the gate + proxy chain work.

## Why it's in AppStoreLab

Reference for app developers who want **both** a browser SSO experience and a
non-interactive API path on the same app, without threading OIDC secrets through
compose. Copy the compose, swap `whoami` for your backend, done.

## The human-vs-machine model

Humans pick **one** interactive method — here, SSO (the alternative is a static
username/password web login; the two are mutually exclusive). Machine auth is an
**addition** that composes with it: a request carrying a valid `?hash=`/Basic/Bearer
credential is served directly; anything else falls through to the human SSO redirect.

## Deployment prerequisites

Requires a PCS on the **Dex** auth stack (current `template-root`):
- `dex` + `auth-registrar` (OIDC) on the `pcs` network
- `casaos-oidc-bridge` with its **internal** `/validate` listener (port `8090`) — needed
  only for the CasaOS-credential machine path

```bash
docker ps --filter name=dex --filter name=auth-registrar --filter name=casaos-oidc-bridge
```

On an older Authelia-era PCS the CasaOS-credential path is unavailable and first login
fails with `ENOTFOUND auth-registrar` / `casaos-oidc-bridge` in the gate logs.

## Security note — the validator is internal-only

The CasaOS-credential path sends credentials to `http://casaos-oidc-bridge:8090/validate`.
That listener is bound to the bridge's internal port and carries **no Caddy label**, so it
is reachable only on the `pcs` network — never from the internet (a public credential
validator would be a CasaOS password-bruteforce oracle). The app needs no shared secret to
talk to it.

## Container-naming constraint

The `container_name: appshield-demo` on the gate is load-bearing:

- Mesh-router routes `appshield-demo-<user>.${APP_DOMAIN}` → container named `appshield-demo`.
- `auth-registrar` derives the OIDC `client_id` from the caller's container name via PTR on
  the `pcs` network, and only authorizes redirect URIs whose host first-label matches it.

So the **gate** must own the app's subdomain name (`appshield-demo`) and the **backend**
gets a different name (`appshield-demo-whoami`). If you fork this app, keep `name:`, the
gate service name, its `container_name`, and `store_app_id` all matching (lowercase alnum + `-`).

## Required assets

Before publishing, drop in:

| File | Size | Description |
|------|------|-------------|
| `icon.png` | 192x192 px | App icon (transparent background) |
| `screenshot-1.png` | 1280x720 px | The whoami output after a successful login |
