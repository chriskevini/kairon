#!/bin/bash
# run-migration.sh - Run a database migration on remote server with automatic backup
#
# Usage: 
#   ./scripts/db/run-migration.sh <migration_file>
#   ./scripts/db/run-migration.sh db/migrations/006_events_traces_projections.sql
#   ./scripts/db/run-migration.sh 006  # Shorthand - finds matching file
#
# Prerequisites:
#   - SSH access configured
#   - .env file in repo root

set -e

# Source SSH connection reuse setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../ssh-setup.sh" 2>/dev/null || true

# --- 1. RESOLVE DIRECTORIES ---
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# --- 2. LOAD .ENV FILE ---
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | grep -v '^$' | xargs)
else
    echo "❌ Error: .env file not found at $ENV_FILE"
    exit 1
fi

# --- 3. VALIDATE REQUIRED VARIABLES ---
for var in REMOTE_HOST CONTAINER_DB DB_USER DB_NAME REMOTE_BACKUP_DIR; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: $var not set in .env"
        exit 1
    fi
done

# --- 4. RESOLVE MIGRATION FILE ---
if [ -z "$1" ]; then
    echo "Usage: $0 <migration_file_or_number>"
    echo ""
    echo "Available migrations:"
    ls -1 "$REPO_ROOT/db/migrations/"*.sql 2>/dev/null | xargs -n1 basename
    exit 1
fi

MIGRATION_ARG="$1"

# If it's just a number, find the matching file
if [[ "$MIGRATION_ARG" =~ ^[0-9]+$ ]]; then
    MIGRATION_FILE=$(ls "$REPO_ROOT/db/migrations/"*"$MIGRATION_ARG"*.sql 2>/dev/null | head -1)
    if [ -z "$MIGRATION_FILE" ]; then
        echo "❌ No migration file found matching number: $MIGRATION_ARG"
        exit 1
    fi
elif [ -f "$REPO_ROOT/$MIGRATION_ARG" ]; then
    MIGRATION_FILE="$REPO_ROOT/$MIGRATION_ARG"
elif [ -f "$MIGRATION_ARG" ]; then
    MIGRATION_FILE="$MIGRATION_ARG"
else
    echo "❌ Migration file not found: $MIGRATION_ARG"
    exit 1
fi

MIGRATION_NAME=$(basename "$MIGRATION_FILE")

# --- 5. CONFIRMATION ---
echo "=================================================================="
echo "Database Migration"
echo "=================================================================="
echo ""
echo "Migration: $MIGRATION_NAME"
echo "Server:    $REMOTE_HOST"
echo "Database:  $DB_NAME"
echo "Container: $CONTAINER_DB"
echo ""
read -p "Run this migration? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- 6. EXECUTION ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="backup_before_${MIGRATION_NAME%.sql}_$TIMESTAMP.sql"

echo ""
echo "Step 1+2: Creating backup and running migration (single SSH session)..."

# Combine backup and migration in single SSH call to avoid rate limiting
cat "$MIGRATION_FILE" | ssh "$REMOTE_HOST" "
    mkdir -p $REMOTE_BACKUP_DIR && \
    docker exec $CONTAINER_DB pg_dump -U $DB_USER $DB_NAME > $REMOTE_BACKUP_DIR/$BACKUP_FILE && \
    echo '✅ Backup created: $REMOTE_BACKUP_DIR/$BACKUP_FILE' && \
    echo '⏳ Running migration...' && \
    docker exec -i $CONTAINER_DB psql -U $DB_USER -d $DB_NAME
"

echo ""
echo "✅ Migration complete: $MIGRATION_NAME"
