#!/bin/bash
# Bootstraps secrets and config for the Hubs stack.
# Idempotent: re-running is a no-op once the .env file exists.
set -euo pipefail

APP_DIR="/DATA/AppData/hubs"
COMPOSE_DIR="/DATA/AppData/casaos/apps/hubs"
ENV_FILE="$COMPOSE_DIR/.env"
PERMS_PRIV="$APP_DIR/perms.key.pem"
PERMS_PUB="$APP_DIR/perms.pub.pem"
TEMPLATE_DST="$APP_DIR/config.toml.template"
TEMPLATE_SRC_URL="https://raw.githubusercontent.com/Yundera/AppStoreLab/main/Apps/Hubs/pre-install/config.toml.template"

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Framework env vars passed through from CasaOS/Yundera. These get baked into
# .env (below) so docker compose's --env-file pass doesn't shadow them with
# empties at deploy time — that would render Caddy labels like "hubs-.nip.io"
# and break the CF Worker's IP-based routing.
APP_DOMAIN="${APP_DOMAIN:-}"
APP_PUBLIC_IP_DASH="${APP_PUBLIC_IP_DASH:-}"
APP_PUBLIC_IPV4="${APP_PUBLIC_IPV4:-}"
APP_EMAIL="${APP_EMAIL:-}"

mkdir -p "$APP_DIR" "$APP_DIR/pgdata" "$APP_DIR/retstorage" "$COMPOSE_DIR"
# Postgres image runs as uid 70 (alpine) and must own its data dir.
# Recursive + every-run so a later framework chown sweep can't relock it.
chown -R 70:70 "$APP_DIR/pgdata" 2>/dev/null || true

# Always refresh the Reticulum config template so updates ship via the AppStore.
wget -qO "$TEMPLATE_DST" "$TEMPLATE_SRC_URL"

if [ -s "$ENV_FILE" ] && [ -s "$PERMS_PRIV" ] && [ -s "$PERMS_PUB" ]; then
  echo "Hubs secrets already provisioned; skipping generation."
  exit 0
fi

echo "Generating Hubs secrets..."

openssl genrsa -out "$PERMS_PRIV" 2048 2>/dev/null
openssl rsa -in "$PERMS_PRIV" -pubout -out "$PERMS_PUB" 2>/dev/null

# Reticulum's entrypoint runs the env value through sed's replacement field, which
# translates "\n" back into newlines and breaks TOML parsing. We need "\\n" (literal
# backslash-backslash-n) so sed emits "\n" (2 chars) into the .toml — TOML then
# parses that as an escaped newline inside the basic string.
PERMS_KEY_ESCAPED=$(awk 'BEGIN{ORS="\\\\n"} {print}' "$PERMS_PRIV")

# Build a JWK for PostgREST from the RSA public key (n + e in base64url).
MODULUS_HEX=$(openssl rsa -in "$PERMS_PRIV" -pubout -modulus -noout 2>/dev/null | sed 's/^Modulus=//')
PGRST_JWT_SECRET=$(python3 - "$MODULUS_HEX" <<'PY'
import base64, sys
n_hex = sys.argv[1].lower()
n_b = bytes.fromhex(n_hex)
e_b = bytes.fromhex("010001")
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
print('{"alg":"RS256","kty":"RSA","n":"%s","e":"%s"}' % (b64u(n_b), b64u(e_b)))
PY
)

rand() { openssl rand -hex "$1"; }

NODE_COOKIE=$(rand 32)
GUARDIAN_KEY=$(rand 48)
PHX_KEY=$(rand 48)
DASHBOARD_ACCESS_KEY=$(rand 24)
POSTGREST_PASSWORD=$(rand 24)

DB_USER="postgres"
DB_PASS=$(rand 24)
DB_NAME="ret_production"

cat > "$ENV_FILE" <<EOF
# Framework passthrough — must be present here because compose's --env-file
# pass shadows shell env vars; without these the Caddy labels resolve as
# "hubs-.nip.io" and CF Worker requests fall through to the catch-all.
APP_DOMAIN=$APP_DOMAIN
APP_PUBLIC_IP_DASH=$APP_PUBLIC_IP_DASH
APP_PUBLIC_IPV4=$APP_PUBLIC_IPV4
APP_EMAIL=$APP_EMAIL
PUID=$PUID
PGID=$PGID

POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASS
POSTGRES_DB=$DB_NAME
PGRST_DB_URI=postgres://$DB_USER:$DB_PASS@db:5432/$DB_NAME
PGRST_JWT_SECRET=$PGRST_JWT_SECRET
turkeyCfg_DB_USER=$DB_USER
turkeyCfg_DB_PASS=$DB_PASS
turkeyCfg_DB_NAME=$DB_NAME
turkeyCfg_NODE_COOKIE=$NODE_COOKIE
turkeyCfg_GUARDIAN_KEY=$GUARDIAN_KEY
turkeyCfg_PHX_KEY=$PHX_KEY
turkeyCfg_DASHBOARD_ACCESS_KEY=$DASHBOARD_ACCESS_KEY
turkeyCfg_POSTGREST_PASSWORD=$POSTGREST_PASSWORD
turkeyCfg_PERMS_KEY=$PERMS_KEY_ESCAPED
EOF

chmod 600 "$ENV_FILE" "$PERMS_PRIV"
chown "$PUID:$PGID" "$ENV_FILE" "$PERMS_PRIV" "$PERMS_PUB" "$TEMPLATE_DST" || true
chown -R "$PUID:$PGID" "$APP_DIR/retstorage" || true

echo "Hubs secrets written to $ENV_FILE"
