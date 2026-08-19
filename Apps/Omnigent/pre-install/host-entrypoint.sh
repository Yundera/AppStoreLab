#!/usr/bin/env bash
#
# Omnigent host bootstrap (Yundera AppStoreLab).
#
# The official omnigent-host image ships the agent toolchain but its default
# command is `sleep infinity` — it is built to be driven from outside. This
# script turns it into a self-registering host container:
#
#   1. wait for the coordinator to answer /health
#   2. sign in non-interactively (the CLI's own `login` only prompts on a TTY)
#   3. give the host a stable display name
#   4. run `omnigent host` in the foreground — that command IS the daemon
#
# Without this container Omnigent has nowhere to execute anything: the server
# image carries no git/node/tmux, and agents only ever run on a registered host.
set -euo pipefail

SERVER="${OMNIGENT_SERVER_URL:-http://omnigent:8000}"
USERNAME="${OMNIGENT_ADMIN_USERNAME:-admin}"
PASSWORD="${OMNIGENT_ADMIN_PASSWORD:-}"
WORKDIR="${OMNIGENT_HOST_WORKDIR:-/workspace}"
HOST_NAME="${OMNIGENT_HOST_DISPLAY_NAME:-$(hostname)}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[omnigent-host] waiting for $SERVER/health ..."
for i in $(seq 1 150); do
  if curl -fsS --max-time 3 "$SERVER/health" >/dev/null 2>&1; then
    echo "[omnigent-host] coordinator is up"
    break
  fi
  if [ "$i" = 150 ]; then
    echo "[omnigent-host] FATAL: $SERVER never became healthy" >&2
    exit 1
  fi
  sleep 2
done

# With OMNIGENT_AUTH_ENABLED=0 the server treats every request as the single
# "local" user, so no token is needed and we skip straight to connecting.
if [ -n "$PASSWORD" ]; then
  echo "[omnigent-host] signing in to $SERVER as $USERNAME"
  OMNIGENT_SERVER_URL="$SERVER" \
  OMNIGENT_ADMIN_USERNAME="$USERNAME" \
  OMNIGENT_ADMIN_PASSWORD="$PASSWORD" \
  python3 - <<'PY_LOGIN'
import json, os, pathlib, stat, sys, time, urllib.error, urllib.request

server = os.environ["OMNIGENT_SERVER_URL"].rstrip("/")
body = json.dumps({
    "username": os.environ["OMNIGENT_ADMIN_USERNAME"],
    "password": os.environ["OMNIGENT_ADMIN_PASSWORD"],
}).encode()

# The admin row is created during the server's first-boot bootstrap, which can
# land after /health starts answering — retry 401s rather than racing it.
payload = None
for attempt in range(30):
    try:
        request = urllib.request.Request(
            f"{server}/auth/login", data=body,
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.load(response)
        break
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            print(f"[omnigent-host] admin not ready yet ({attempt + 1}/30)", flush=True)
            time.sleep(2)
            continue
        sys.exit(f"[omnigent-host] FATAL: login failed {exc.code}")
    except urllib.error.URLError:
        time.sleep(2)

if payload is None:
    sys.exit("[omnigent-host] FATAL: could not sign in (admin never appeared)")

state = pathlib.Path.home() / ".omnigent"
state.mkdir(parents=True, exist_ok=True)
tokens_path = state / "auth_tokens.json"
tokens = {}
if tokens_path.exists():
    try:
        tokens = json.loads(tokens_path.read_text())
    except (json.JSONDecodeError, OSError):
        tokens = {}
tokens[server] = {
    "token": payload["token"],
    "user_id": payload["user"]["id"],
    "expires_at": time.time() + payload.get("expires_in", 8 * 3600),
}
tokens_path.write_text(json.dumps(tokens, indent=2))
tokens_path.chmod(stat.S_IRUSR | stat.S_IWUSR)
print(f"[omnigent-host] logged in as {payload['user']['id']}", flush=True)
PY_LOGIN
else
  echo "[omnigent-host] no admin password set — assuming auth-disabled server"
fi

# --global so this lands in ~/.omnigent/config.yaml (persisted) rather than a
# project-level .omnigent/config.yaml inside the working directory.
omnigent config set --global "server=$SERVER" >/dev/null 2>&1 \
  || omnigent config set "server=$SERVER" >/dev/null 2>&1 \
  || true

# Pin the display name. omnigent completes a partial host section rather than
# discarding it — a config naming the host but omitting host_id keeps that name
# and only the id is generated (see omnigent/host/identity.py). So seeding the
# name here survives, and the id stays stable across restarts because the whole
# config directory is a persistent volume.
#
# Deliberately NOT done with OMNIGENT_HOST_NAME: that variable is reserved for
# server-managed sandbox launches and must be paired with OMNIGENT_HOST_ID, or
# the CLI exits with "must be set together".
OMNIGENT_CONFIG_PATH="$HOME/.omnigent/config.yaml" \
OMNIGENT_WANTED_NAME="$HOST_NAME" \
python3 - <<'PY_NAME'
import os, pathlib, yaml

path = pathlib.Path(os.environ["OMNIGENT_CONFIG_PATH"])
wanted = os.environ["OMNIGENT_WANTED_NAME"]

config = {}
if path.exists():
    try:
        config = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError:
        config = {}
if not isinstance(config, dict):
    config = {}

host_section = config.get("host")
if not isinstance(host_section, dict):
    host_section = {}

if host_section.get("name") != wanted:
    host_section["name"] = wanted
    config["host"] = host_section
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(config, default_flow_style=False, sort_keys=True))
    print(f"[omnigent-host] host name set to {wanted}", flush=True)
PY_NAME

echo "[omnigent-host] connecting as '$HOST_NAME' (workdir=$WORKDIR)"
exec omnigent host --server "$SERVER" --non-interactive
