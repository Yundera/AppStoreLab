# Jellyseerr — Rationale

## What deviation / exception is being requested
Authentication is not enabled via nginx-hash-lock or OIDC. Jellyseerr runs as a 
single container without a proxy sidecar, with auth handled by its own onboarding wizard.

## Why it is necessary
Jellyseerr has its own built-in authentication system that requires the user to create 
an admin account on first launch by signing in with their Jellyfin credentials. This is 
an explicitly-listed valid exception in CONTRIBUTING.md's Security checklist (app handles 
authentication configuration on first launch via an onboarding process).

## Security mitigations in place
- Jellyseerr's onboarding wizard requires Jellyfin credentials to create an admin account 
  on first launch — cannot be bypassed
- No privileged mode
- Memory limit set (256M)
- App data maps to `/DATA/AppData/jellyseerr/config/` only — no user directory access
- No root container — runs as default container user

## Alternatives considered and rejected
- OIDC/hash-lock authentication — Jellyseerr's native Jellyfin SSO authentication is more 
  appropriate; adding an external auth layer creates a confusing double-login experience 
  and breaks Jellyfin user permission syncing
- Running a proxy sidecar — unnecessary since Jellyseerr has no need to bind to port 80 
  and runs fine on port 5055 behind Caddy

## Data protection
- All config and data persists in `/DATA/AppData/jellyseerr/config/`
- No user media directories are accessed or mounted
- All data survives uninstall/reinstall
