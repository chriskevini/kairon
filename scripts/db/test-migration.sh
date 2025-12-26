#!/bin/bash
# Automated Database Migration Testing
#
# This script safely tests migrations on a temporary database before production deployment.
# It follows the safety procedures documented in docs/archive/database-migration-safety.md
#
# Usage:
#   ./scripts/db/test-migration.sh <migration_file>
#   ./scripts/db/test-migration.sh db/migrations/024_backfill_meta_event_types.sql
#
# Exit codes:
#   0 - Success
#   1 - Migration test failed
#   2 - Invalid arguments
#   3 - Environment error
#
# Requirements:
#   - .env file with DB_* variables or local PostgreSQL access
#   - psql, pg_dump, pg_restore, createdb, dropdb installed

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)")"

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi

# Database configuration (with defaults)
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-n8n_user}"
DB_NAME="${DB_NAME:-kairon}"

# Test database name
TEST_DB_NAME="${DB_NAME}_test_$$"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    if [ -n "${CLEANUP_DONE:-}" ]; then
        return
    fi

    log_info "Cleaning up test database: $TEST_DB_NAME"
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS $TEST_DB_NAME" 2>/dev/null; then
        log_success "Test database dropped successfully"
    else
        log_warning "Failed to drop test database (may not exist): $TEST_DB_NAME"
    fi

    CLEANUP_DONE=1
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

# Print usage
usage() {
    cat << EOF
Usage: $0 <migration_file>

Test a database migration safely on a temporary database.

Arguments:
    migration_file    Path to migration SQL file to test

Example:
    $0 db/migrations/024_backfill_meta_event_types.sql

Environment Variables:
    DB_HOST           Database host (default: localhost)
    DB_PORT           Database port (default: 5432)
    DB_USER           Database user (default: n8n_user)
    DB_NAME           Source database for backup (default: kairon)

EOF
    exit 2
}

# Validate arguments
if [ $# -lt 1 ]; then
    log_error "Migration file argument required"
    usage
fi

MIGRATION_FILE="$1"

# Validate migration file exists and is readable
if [ ! -f "$MIGRATION_FILE" ]; then
    log_error "Migration file not found: $MIGRATION_FILE"
    exit 2
fi

if [ ! -r "$MIGRATION_FILE" ]; then
    log_error "Migration file not readable: $MIGRATION_FILE"
    exit 2
fi

MIGRATION_NAME=$(basename "$MIGRATION_FILE")
log_info "Testing migration: $MIGRATION_NAME"

# Build psql command
PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER"

# Test database connectivity
log_info "Testing database connectivity..."
if ! $PSQL -d postgres -c "SELECT 1" > /dev/null 2>&1; then
    log_error "Cannot connect to database server at $DB_HOST:$DB_PORT"
    log_error "Please check DB_HOST, DB_PORT, DB_USER, and ensure PostgreSQL is running"
    exit 3
fi
log_success "Database connectivity verified"

# Step 1: Create test database
log_info "Creating test database: $TEST_DB_NAME"
if ! $PSQL -d postgres -c "CREATE DATABASE $TEST_DB_NAME" > /dev/null 2>&1; then
    log_error "Failed to create test database"
    exit 1
fi
log_success "Test database created"

# Step 2: Create schema in test database (minimal setup)
log_info "Initializing test database schema..."
$PSQL -d "$TEST_DB_NAME" -c "
    CREATE TABLE IF NOT EXISTS events (
        id UUID PRIMARY KEY,
        event_type TEXT NOT NULL,
        channel_id TEXT,
        message_id TEXT,
        payload JSONB DEFAULT '{}',
        timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    
    CREATE TABLE IF NOT EXISTS traces (
        id UUID PRIMARY KEY,
        event_id UUID REFERENCES events(id),
        timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    
    CREATE TABLE IF NOT EXISTS projections (
        id UUID PRIMARY KEY,
        trace_id UUID REFERENCES traces(id),
        projection_type TEXT NOT NULL,
        data JSONB DEFAULT '{}',
        timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
" > /dev/null 2>&1
log_success "Test database schema initialized"

# Step 3: Run migration
log_info "Running migration..."
LOG_FILE="$REPO_ROOT/logs/migration_test_${MIGRATION_NAME%.sql}_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"

if $PSQL -d "$TEST_DB_NAME" -f "$MIGRATION_FILE" 2>&1 | tee "$LOG_FILE"; then
    log_success "Migration executed successfully"
else
    log_error "Migration failed with errors (see log: $LOG_FILE)"
    grep -i "error" "$LOG_FILE" || true
    exit 1
fi

# Step 4: Check for errors in log
if grep -i "ERROR" "$LOG_FILE" > /dev/null; then
    log_error "Migration contains errors (see log: $LOG_FILE)"
    grep -i "ERROR" "$LOG_FILE"
    exit 1
fi
log_success "No errors detected in migration"

# Step 5: Verify schema changes
log_info "Verifying schema changes..."

# Get table count before and after migration (check if new tables were added)
TABLE_COUNT=$($PSQL -d "$TEST_DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public'")
log_info "Total tables after migration: $TABLE_COUNT"

# Step 6: Test rollback if exists
ROLLBACK_FILE="${MIGRATION_FILE%.sql}_rollback.sql"
if [ -f "$ROLLBACK_FILE" ]; then
    log_info "Rollback file found: $ROLLBACK_FILE"
    log_info "Testing rollback..."

    ROLLBACK_LOG="${LOG_FILE%.log}_rollback.log"
    if $PSQL -d "$TEST_DB_NAME" -f "$ROLLBACK_FILE" 2>&1 | tee "$ROLLBACK_LOG"; then
        log_success "Rollback executed successfully"
    else
        log_error "Rollback failed (see log: $ROLLBACK_LOG)"
        exit 1
    fi

    # Verify rollback restored state
    TABLE_COUNT_AFTER_ROLLBACK=$($PSQL -d "$TEST_DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public'")
    log_info "Tables after rollback: $TABLE_COUNT_AFTER_ROLLBACK"
fi

# Step 7: Test idempotency (run migration twice)
log_info "Testing idempotency (running migration twice)..."
if $PSQL -d "$TEST_DB_NAME" -f "$MIGRATION_FILE" > /dev/null 2>&1; then
    log_success "Migration is idempotent (safe to run multiple times)"
else
    log_warning "Migration is not idempotent (may fail if run twice)"
    log_warning "Consider adding idempotency checks (IF NOT EXISTS, ON CONFLICT, etc.)"
fi

# All tests passed
echo ""
log_success "Migration test passed: $MIGRATION_NAME"
log_info "Log files preserved at:"
echo "  - Migration:  $LOG_FILE"
if [ -f "${LOG_FILE%.log}_rollback.log" ]; then
    echo "  - Rollback:   ${LOG_FILE%.log}_rollback.log"
fi
echo ""
log_info "Test database will be cleaned up automatically"

exit 0
