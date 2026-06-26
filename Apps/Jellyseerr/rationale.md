# Jellyseerr — Rationale

## What deviation / exception is being requested
Jellyseerr runs as `user: 0:0` (root). Authentication is not enabled via nginx-hash-lock 
or OIDC. Jellyseerr runs as a single container without a proxy sidecar, with auth handled 
by its own onboarding wizard.

## Why it is necessary
- **Root container**: Jellyseerr requires write access to `/app/config` on startup to 
  create its logs directory. The mounted volume is created as root by the host system and 
  cannot be changed via pre-install-cmd reliably across all server configurations.
- **Authentication**: Jellyseerr has its own built-in authentication system that requires 
  the user to create an admin account on first launch by signing in with their Jellyfin 
  credentials. This is an explicitly-listed valid exception in CONTRIBUTING.md's Security 
  checklist (app handles authentication configuration on first launch via an onboarding 
  process).

## Security mitigations in place
- Jellyseerr's onboarding wizard requires Jellyfin credentials to create an admin account 
  on first launch — cannot be bypassed
- No privileged mode
- Memory limit set (256M)
- App data maps to `/DATA/AppData/jellyseerr/config/` only — no user directory access
- Root is required only for config directory write access, not for any system-level operations

## Alternatives considered and rejected
- OIDC/hash-lock authentication — Jellyseerr's native Jellyfin SSO authentication is more 
  appropriate; adding an external auth layer creates a confusing double-login experience 
  and breaks Jellyfin user permission syncing
- Running a proxy sidecar — unnecessary since Jellyseerr has no need to bind to port 80 
  and runs fine on port 5055 behind Caddy
- Running as PUID:PGID — the mounted volume is created as root by the host before the 
  container starts, causing permission denied errors on startup across different server 
  configurations
- pre-install-cmd to fix permissions — not reliable across all Yundera server 
  configurations

## Data protection
- All config and data persists in `/DATA/AppData/jellyseerr/config/`
- No user media directories are accessed or mounted
- All data survives uninstall/reinstall
