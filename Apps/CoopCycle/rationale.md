# CoopCycle — rationale

## What exception is requested

1. **The app image is built by us** (`ghcr.io/worph/coopcycle-image`), not pulled from
   upstream.
2. **A public site with open sign-up** (`auth-default`, `auth-gate`): the storefront and
   customer registration are reachable without a login.
3. **A third-party key before addresses can be entered** (`zero-config`): address
   search needs an API key from a geocoding provider.
4. **Containers that start as root** (`permissions`): `coopcycle-web`, `coopcycle-worker`,
   `coopcycle-db`, `coopcycle-tile38`, `coopcycle-typesense` and `coopcycle-osrm`.

## Why it is necessary

1. Upstream publishes no production image. `coopcycle/php` contains PHP code without
   `vendor/` or the compiled front-end, and upstream's compose bind-mounts the source
   tree and runs a webpack dev server. The image here is built from the upstream release
   tag (`v6.19.0`): `composer install --no-dev`, `encore production`, and nginx with
   php-fpm in one container. On every start its entrypoint applies database migrations,
   creates missing S3 buckets and search collections (`coopcycle:setup`), and seeds the
   four settings the app marks mandatory, each only when it is absent.
2. CoopCycle is a delivery marketplace: customers browse shops, register and order
   without anyone creating their account. Everything that is not the storefront (admin,
   dispatch, shop and courier back-offices, the API) needs a login. The admin account
   is generated (`credentials`) and its sign-in is also protected by a 6-digit code
   e-mailed to the server account's address (upstream's two-factor login, always on
   for administrators).
3. The address field in the browser autocompletes through Geocode Earth, LocationIQ
   or Google, and every adapter needs a key; with none it returns 401 and no address
   can be selected, so no shop, restaurant or delivery can be created. No keyless
   adapter exists in the app. LocationIQ and Geocode Earth have free tiers, and the
   tips walk through entering the key in App settings → Env.
4. - `coopcycle-web` / `coopcycle-worker`: the entrypoint links the data folder into
     the app tree and gives it to `www-data`, then php-fpm workers, console commands
     and the queue worker all run as `www-data` (`su-exec`). nginx's master process
     stays root to bind port 80, the usual nginx model.
   - `coopcycle-db`: the postgres entrypoint chowns PGDATA and drops to `postgres`.
   - `coopcycle-tile38`, `coopcycle-typesense`, `coopcycle-osrm`: the upstream images run
     as root.

   Each of these mounts only its own folder under `/DATA/AppData/coopcycle/`, and none
   has added capabilities, host networking or a user folder.

## Mitigations

- The image adds nothing to upstream's code: same PHP extension set as upstream's
  `docker/php/Dockerfile` (no xdebug, no dev dependencies), source cloned from the
  release tag.
- Customer accounts are the app's own low-privilege role (`ROLE_USER`); shop, courier,
  dispatcher and admin roles are only granted by an admin.
- Realtime (`/centrifugo/`) accepts only connections that carry a token signed by the
  app; the origin check (`CENTRIFUGO_ALLOWED_ORIGINS: "*"`) adds nothing on top of that.
- Only the router is on the shared network, plus the web app and worker, which send
  mail through the server's `smtp` service. The database, Redis, S3, search, routing
  and realtime services are on the app's own network.

## Alternatives considered

- **Upstream's development compose**: it needs the source tree on disk, a node build at
  every start and `make` targets run by hand.
- **The `coopcycle/php` image plus a separate asset volume**: still no `vendor/`, and
  composer would run at every container start.
- **AppShield in front of the whole site**: customers could not reach the storefront,
  which is the point of the app.

## Data protection

Everything is under `/DATA/AppData/coopcycle/`:

| Folder | Holds |
| --- | --- |
| `pgdata/` | the database: users, shops, orders, deliveries, settings |
| `app/` | the API token signing key (`jwt/`), app-written images, thumbnail cache, logs |
| `s3/` | uploaded images and exports (RustFS) |
| `redis/` | sessions, cache and the message queue |
| `typesense/` | the search index (rebuilt from the database if lost) |
| `tile38/` | live courier positions |
| `osrm/` | the downloaded map and the routing graph built from it |

Verified on a test server: users, settings and the signing key survive taking the
whole stack down and up again, and a restart over existing data only applies pending
migrations.
