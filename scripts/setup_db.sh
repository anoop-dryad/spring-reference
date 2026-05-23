#!/bin/bash
# =============================================================================
# setup_db.sh — Runs postgres_setup.sql using credentials from .envrc
# =============================================================================
# USAGE:
#   chmod +x setup_db.sh
#   ./setup_db.sh
#
# REQUIRES:
#   - direnv installed and .envrc loaded (direnv allow)
#   - OR manually export variables before running:
#       export DB_NAME=myapp
#       export DB_SCHEMA=app_auth
#       export DB_FLYWAY_USER=flyway_user
#       export DB_FLYWAY_PASSWORD=secret
#       export DB_APP_USER=app_user
#       export DB_APP_PASSWORD=secret
#       export PGHOST=localhost      # optional, defaults to localhost
#       export PGPORT=5432           # optional, defaults to 5432
# =============================================================================

set -euo pipefail

# ── Validate required env vars are set ────────────────────────────────────────
REQUIRED_VARS=(
  DB_NAME
  DB_SCHEMA
  DB_FLYWAY_USER
  DB_FLYWAY_PASSWORD
  DB_APP_USER
  DB_APP_PASSWORD
)

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ ERROR: Required environment variable '$var' is not set."
    echo "   Make sure your .envrc is loaded (run: direnv allow)"
    exit 1
  fi
done

# ── Optional overrides with defaults ──────────────────────────────────────────
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"

echo "🚀 Setting up PostgreSQL database..."
echo "   Host     : $PGHOST:$PGPORT"
echo "   Database : $DB_NAME"
echo "   Schema   : $DB_SCHEMA"
echo "   Flyway   : $DB_FLYWAY_USER"
echo "   App user : $DB_APP_USER"
echo ""

# ── Run the SQL script ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PGPASSWORD="${PGPASSWORD:-}" psql \
  -h "$PGHOST" \
  -p "$PGPORT" \
  -U "$PGUSER" \
  -v db_name="$DB_NAME" \
  -v schema_name="$DB_SCHEMA" \
  -v flyway_user="$DB_FLYWAY_USER" \
  -v "flyway_password=$DB_FLYWAY_PASSWORD" \
  -v app_user="$DB_APP_USER" \
  -v "app_password=$DB_APP_PASSWORD" \
  -f "$SCRIPT_DIR/postgres_setup.sql"

echo ""
echo "✅ Database setup complete."
