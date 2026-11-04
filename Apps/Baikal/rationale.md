# Baïkal — Rationale

## What exception is requested

No AppShield in front of the app (`auth-default` is met by the app's own logins instead).

## Why it is necessary

Baïkal's job is to be reached by CalDAV / CardDAV clients: DAVx⁵ on Android, the
iOS and macOS calendar and contacts, Thunderbird, and webmail calendar plugins (e.g. Roundcube's Kolab
plugins). Every one of them authenticates with HTTP Basic auth on each request and
cannot follow an OIDC login, so an SSO gate in front of `/dav.php` would lock them
all out.

## Mitigations

- Both entry points have a login that Maison generates (`secrets`, `password:24`)
  and shows under Credentials — nothing is open as shipped:
  - `/dav.php`: the calendar account `me` (`BAIKAL_USER_PASSWORD`), Basic auth;
  - `/admin/`: Baïkal's admin console, `admin` (`BAIKAL_ADMIN_PASSWORD`).
- The install wizard never shows: the `init` step writes a configured instance, so
  there is no window in which the first visitor could claim the server.
- Both passwords can be changed from Maison's Security tab; the `init` step re-syncs
  them on every up.
- Only HTTPS routes; no host port is published.

## Alternatives considered

- AppShield with an open path for `/dav.php`: AppShield's machine path is OAuth 2.1
  (`OAUTH_RESOURCE`), which DAV clients do not speak either.
- Protecting only `/admin/` with AppShield: needs a path split in front of Baïkal
  (an in-app router) for a page already behind a generated password. Possible later.

## Data protection

Calendars and contacts are in `data/db/db.sqlite`, inside the app folder, so they are
part of Maison's backup of the app.
