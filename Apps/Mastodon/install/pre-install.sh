#!/bin/bash
set -e

# Check required PCS environment variables
if [ -z "$PCS_DOMAIN" ]; then
  echo "Error: PCS_DOMAIN is not set"
  exit 1
fi

if [ -z "$PCS_DEFAULT_PASSWORD" ]; then
  echo "Error: PCS_DEFAULT_PASSWORD is not set"
  exit 1
fi

if [ -z "$PCS_EMAIL" ]; then
  echo "Error: PCS_EMAIL is not set"
  exit 1
fi

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Create directories
mkdir -p /DATA/AppData/casaos/apps/mastodon
mkdir -p /DATA/AppData/mastodon/postgres /DATA/AppData/mastodon/redis /DATA/AppData/mastodon/public/system
chown -R ${PUID}:${PGID} /DATA/AppData/casaos/apps/mastodon || true
chown -R ${PUID}:${PGID} /DATA/AppData/mastodon || true

# Generate .env if it doesn't exist or is empty
if [ ! -s /DATA/AppData/casaos/apps/mastodon/.env ]; then
  echo "Generating Mastodon configuration..."

  # Generate secrets
  SECRET_KEY_BASE=$(docker run --rm ghcr.io/mastodon/mastodon:v4.4.4 bin/rails secret)
  OTP_SECRET=$(docker run --rm ghcr.io/mastodon/mastodon:v4.4.4 bin/rails secret)
  VAPID_OUTPUT=$(docker run --rm ghcr.io/mastodon/mastodon:v4.4.4 bundle exec rake mastodon:webpush:generate_vapid_key)
  VAPID_PRIVATE_KEY=$(echo "$VAPID_OUTPUT" | grep "VAPID_PRIVATE_KEY" | cut -d'=' -f2)
  VAPID_PUBLIC_KEY=$(echo "$VAPID_OUTPUT" | grep "VAPID_PUBLIC_KEY" | cut -d'=' -f2)
  ENCRYPTION_OUTPUT=$(docker run --rm ghcr.io/mastodon/mastodon:v4.4.4 bin/rails db:encryption:init)
  ENCRYPTION_DETERMINISTIC=$(echo "$ENCRYPTION_OUTPUT" | grep "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" | cut -d'=' -f2)
  ENCRYPTION_SALT=$(echo "$ENCRYPTION_OUTPUT" | grep "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" | cut -d'=' -f2)
  ENCRYPTION_PRIMARY=$(echo "$ENCRYPTION_OUTPUT" | grep "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" | cut -d'=' -f2)

  # Write .env file
  cat > /DATA/AppData/casaos/apps/mastodon/.env << EOF
LOCAL_DOMAIN=mastodon-${PCS_DOMAIN}
WEB_DOMAIN=mastodon-${PCS_DOMAIN}
SINGLE_USER_MODE=true
STREAMING_API_BASE_URL=https://mastodon-${PCS_DOMAIN}
REDIS_HOST=redis
REDIS_PORT=6379
DB_HOST=db
DB_USER=mastodon
DB_NAME=mastodon_production
DB_PASS=mastodon_default_password_change_me
DB_PORT=5432
SECRET_KEY_BASE=${SECRET_KEY_BASE}
OTP_SECRET=${OTP_SECRET}
VAPID_PRIVATE_KEY=${VAPID_PRIVATE_KEY}
VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=${ENCRYPTION_DETERMINISTIC}
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=${ENCRYPTION_SALT}
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=${ENCRYPTION_PRIMARY}
RAILS_ENV=production
RAILS_SERVE_STATIC_FILES=true
RAILS_LOG_LEVEL=warn
PAPERCLIP_ROOT_PATH=/mastodon/public/system
PREPARED_STATEMENTS=true
MAX_TOOT_CHARS=500
TRUSTED_PROXY_IP=172.16.0.0/12
RAILS_FORCE_SSL=false
EOF

  chown ${PUID}:${PGID} /DATA/AppData/casaos/apps/mastodon/.env || true

  echo "Configuration generated successfully!"
else
  echo "Configuration already exists, skipping generation."
fi

echo ""
echo "=== Initializing Database ==="

# Start database and redis containers only  
cd /DATA/AppData/casaos/apps/mastodon
export $(cat /DATA/AppData/casaos/apps/mastodon/.env | xargs)
docker compose up -d db redis

# Wait for database to be ready
echo "Waiting for database to be ready..."
RETRY_COUNT=0
MAX_RETRIES=30
until docker compose exec -T db pg_isready -U mastodon > /dev/null 2>&1; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "Error: Database failed to start after $MAX_RETRIES attempts"
        docker compose logs db
        exit 1
    fi
    echo "Database not ready, waiting... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
done
echo "Database is ready!"

# Check if database is initialized
echo "Checking database initialization..."
DB_INITIALIZED=$(docker compose exec -T db psql -U mastodon -d mastodon_production -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")

if [ "$DB_INITIALIZED" -eq "0" ]; then
    echo "Database not initialized. Running schema load..."
    if ! docker compose run --rm --env-file /DATA/AppData/casaos/apps/mastodon/.env mastodon-backend bundle exec rails db:schema:load; then
        echo "Error: Failed to load database schema"
        docker compose logs mastodon-backend
        exit 1
    fi
    echo "Database schema loaded!"
else
    echo "Database already initialized (found $DB_INITIALIZED tables), skipping schema load."
fi

# Run migrations (idempotent - only runs pending migrations)
echo "Running database migrations..."
if ! docker compose run --rm --env-file /DATA/AppData/casaos/apps/mastodon/.env mastodon-backend bundle exec rails db:migrate; then
    echo "Error: Failed to run database migrations"
    docker compose logs mastodon-backend
    exit 1
fi
echo "Migrations complete!"

# Check if admin user exists and create if needed
echo "Checking for admin user..."
ADMIN_OUTPUT=$(docker compose run --rm --env-file /DATA/AppData/casaos/apps/mastodon/.env mastodon-backend bin/tootctl accounts create admin --email $PCS_EMAIL --confirmed 2>&1 || true)

if echo "$ADMIN_OUTPUT" | grep -q "New password:" || echo "$ADMIN_OUTPUT" | grep -q "OK"; then
    echo "Admin user created or already exists. Setting up permissions and password..."
    
    # Approve the admin user (idempotent)
    docker compose run --rm --env-file /DATA/AppData/casaos/apps/mastodon/.env mastodon-backend bin/tootctl accounts modify admin --approve || true

    # Set password to PCS_DEFAULT_PASSWORD
    echo "Setting admin password..."
    if ! docker compose run --rm --env-file /DATA/AppData/casaos/apps/mastodon/.env mastodon-backend bin/rails runner "u = User.find_by(email: '$PCS_EMAIL'); if u.nil?; puts 'User not found'; exit 1; end; u.password = '$PCS_DEFAULT_PASSWORD'; u.password_confirmation = '$PCS_DEFAULT_PASSWORD'; puts 'Password updated successfully' if u.save"; then
        echo "Error: Failed to set admin password"
        exit 1
    fi

    echo ""
    echo "=== Admin User Ready! ==="
    echo "Email: $PCS_EMAIL"
    echo "Password: $PCS_DEFAULT_PASSWORD"
    echo ""
else
    echo "Failed to create admin user. Output:"
    echo "$ADMIN_OUTPUT"
    exit 1
fi

# Validate database setup
echo ""
echo "=== Validating Database Setup ==="
FINAL_TABLE_COUNT=$(docker compose exec -T db psql -U mastodon -d mastodon_production -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
ADMIN_USER_COUNT=$(docker compose run --rm --env-file /DATA/AppData/casaos/apps/mastodon/.env mastodon-backend bin/rails runner "puts User.where(email: '$PCS_EMAIL').count" 2>/dev/null || echo "0")

echo "Database tables found: $FINAL_TABLE_COUNT"
echo "Admin users found: $ADMIN_USER_COUNT"

if [ "$FINAL_TABLE_COUNT" -lt "10" ]; then
    echo "Error: Database appears to be incompletely initialized (only $FINAL_TABLE_COUNT tables)"
    exit 1
fi

if [ "$ADMIN_USER_COUNT" -eq "0" ]; then
    echo "Error: Admin user was not created properly"
    exit 1
fi

# Stop temporary containers
docker compose down

echo ""
echo "=== Pre-Install Complete! ==="
echo "✅ Database initialized with $FINAL_TABLE_COUNT tables"
echo "✅ Admin user created: $PCS_EMAIL"
echo "✅ Ready for application startup"
echo ""
