#!/bin/bash
# Database Migration Runner with Version Tracking
#
# This script manages database migrations with automatic version tracking.
# It only runs migrations that haven't been applied yet, preventing double-application.
#
# Usage:
#   ./scripts/db/migrate.sh                    # Run all pending migrations
#   ./scripts/db/migrate.sh status             # Show migration status
#   ./scripts/db/migrate.sh --dry-run         # Show what would be run
#   ./scripts/db/migrate.sh --version 025      # Run specific migration
#   ./scripts/db/migrate.sh --rollback          # Rollback last migration
#
# Requirements:
#   - .env file with DB_* variables or local PostgreSQL access
#   - psql installed
#
# Exit codes:
#   0 - Success
#   1 - Migration failed
#   2 - Invalid arguments
#   3 - Environment error

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

MIGRATIONS_DIR="$REPO_ROOT/db/migrations"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Flags
DRY_RUN=false
STATUS_ONLY=false
ROLLBACK=false
SPECIFIC_VERSION=""
VERIFY_CHECKSUMS=false

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

log_migration() {
    echo -e "${CYAN}[MIGRATION]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS] [COMMAND]

Database migration runner with automatic version tracking.

Commands:
    (default)       Run all pending migrations
    status          Show migration status (applied vs pending)
    --dry-run       Show pending migrations without executing
    --version N     Run specific migration (e.g., --version 025)
    --rollback      Rollback last migration
    --verify        Verify checksums of all applied migrations

Options:
    -h, --help      Show this help message

Environment Variables:
    DB_HOST         Database host (default: localhost)
    DB_PORT         Database port (default: 5432)
    DB_USER         Database user (default: n8n_user)
    DB_NAME         Database name (default: kairon)

Examples:
    $0 status                    # Show migration status
    $0 --dry-run                # Show pending migrations
    $0                          # Run pending migrations
    $0 --version 025            # Run specific migration
    $0 --rollback               # Rollback last migration
    $0 --verify                 # Verify all applied migration checksums

EOF
    exit 2
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        status)
            STATUS_ONLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --version)
            SPECIFIC_VERSION="$2"
            shift 2
            ;;
        --rollback)
            ROLLBACK=true
            shift
            ;;
    --verify)
            VERIFY_CHECKSUMS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Build psql command
PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"

# Test database connectivity
log_info "Testing database connectivity..."
if ! $PSQL -c "SELECT 1" > /dev/null 2>&1; then
    log_error "Cannot connect to database at $DB_HOST:$DB_PORT"
    log_error "Please check DB_HOST, DB_PORT, DB_USER, and ensure PostgreSQL is running"
    exit 3
fi
log_success "Database connectivity verified"

# Check if schema_migrations table exists
SCHEMA_MIGRATIONS_EXISTS=$($PSQL -t -c "
    SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'schema_migrations'
    );
" | tr -d ' ')

if [ "$SCHEMA_MIGRATIONS_EXISTS" != "t" ]; then
    log_warning "schema_migrations table does not exist"
    log_info "Please run migration 025_schema_migrations.sql first"
    exit 1
fi

# Get list of migration files
MIGRATION_FILES=($(find "$MIGRATIONS_DIR" -name "*.sql" -type f | sort))

if [ ${#MIGRATION_FILES[@]} -eq 0 ]; then
    log_info "No migration files found in $MIGRATIONS_DIR"
    exit 0
fi

# Get applied migrations
APPLIED_VERSIONS=$($PSQL -t -c "SELECT version FROM schema_migrations ORDER BY version;" | tr '\n' '|' | sed 's/|$//')

# Function to check if migration is applied
is_applied() {
    local version="$1"
    if [[ ":$APPLIED_VERSIONS:" == *":$version:"* ]]; then
        return 0
    else
        return 1
    fi
}

# Function to calculate checksum
calculate_checksum() {
    local file="$1"
    sha256sum "$file" | awk '{print $1}'
}

# Function to extract description from migration file
extract_description() {
    local file="$1"
    grep -i "^-- Migration:" "$file" | sed 's/^-- Migration: *//' | head -1
}

# Show migration status
if [ "$STATUS_ONLY" = true ]; then
    echo ""
    echo "=========================================="
    echo "Migration Status"
    echo "=========================================="
    echo ""
    echo "Applied Migrations:"
    echo "-------------------"
    if [ -z "$APPLIED_VERSIONS" ]; then
        echo "  (none)"
    else
        for version in ${APPLIED_VERSIONS//|/ }; do
            printf "  ${GREEN}✓${NC} $version\n"
        done
    fi
    echo ""
    echo "Pending Migrations:"
    echo "-------------------"
    PENDING_COUNT=0
    for migration_file in "${MIGRATION_FILES[@]}"; do
        version=$(basename "$migration_file" .sql)
        if ! is_applied "$version"; then
            PENDING_COUNT=$((PENDING_COUNT + 1))
            description=$(extract_description "$migration_file")
            printf "  ${YELLOW}○${NC} $version - $description\n"
        fi
    done
    if [ $PENDING_COUNT -eq 0 ]; then
        printf "  ${GREEN}All migrations up to date!${NC}\n"
    fi
    echo ""
    echo "=========================================="
    exit 0
fi

# Run specific migration
if [ -n "$SPECIFIC_VERSION" ]; then
    MIGRATION_FILE="$MIGRATIONS_DIR/${SPECIFIC_VERSION}.sql"

    if [ ! -f "$MIGRATION_FILE" ]; then
        log_error "Migration file not found: $MIGRATION_FILE"
        exit 2
    fi

    if is_applied "$SPECIFIC_VERSION"; then
        log_warning "Migration $SPECIFIC_VERSION is already applied"
        log_info "Use --force to re-apply (not recommended)"
        exit 0
    fi

    description=$(extract_description "$MIGRATION_FILE")
    checksum=$(calculate_checksum "$MIGRATION_FILE")

    log_migration "Running migration: $SPECIFIC_VERSION"
    log_info "Description: $description"
    log_info "Checksum: $checksum"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would apply: $SPECIFIC_VERSION"
        exit 0
    fi

    LOG_FILE="$REPO_ROOT/logs/migration_${SPECIFIC_VERSION}_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$(dirname "$LOG_FILE")"

    if $PSQL -f "$MIGRATION_FILE" 2>&1 | tee "$LOG_FILE"; then
        # Record migration
        $PSQL -c "
            INSERT INTO schema_migrations (version, description, checksum)
            VALUES ('$SPECIFIC_VERSION', '$description', '$checksum');
        " > /dev/null

        log_success "Migration $SPECIFIC_VERSION applied successfully"
        log_info "Log: $LOG_FILE"
    else
        log_error "Migration $SPECIFIC_VERSION failed"
        log_info "See log: $LOG_FILE"
        exit 1
    fi

    exit 0
fi

# Run all pending migrations
echo ""
echo "=========================================="
echo "Running Pending Migrations"
echo "=========================================="
echo ""

MIGRATIONS_RUN=0
for migration_file in "${MIGRATION_FILES[@]}"; do
    version=$(basename "$migration_file" .sql)
    description=$(extract_description "$migration_file")
    checksum=$(calculate_checksum "$migration_file")

    if is_applied "$version"; then
        log_info "Skipping: $version (already applied)"
        continue
    fi

    MIGRATIONS_RUN=$((MIGRATIONS_RUN + 1))

    if [ "$DRY_RUN" = true ]; then
        log_migration "[DRY-RUN] Would apply: $version - $description"
        continue
    fi

    log_migration "Running migration: $version"
    log_info "Description: $description"
    log_info "Checksum: $checksum"

    LOG_FILE="$REPO_ROOT/logs/migration_${version}_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$(dirname "$LOG_FILE")"

    if $PSQL -f "$migration_file" 2>&1 | tee "$LOG_FILE"; then
        # Record migration
        $PSQL -c "
            INSERT INTO schema_migrations (version, description, checksum)
            VALUES ('$version', '$description', '$checksum');
        " > /dev/null

        log_success "Migration $version applied successfully"
    else
        log_error "Migration $version failed"
        log_info "See log: $LOG_FILE"
        exit 1
    fi

    echo ""
done

if [ $MIGRATIONS_RUN -eq 0 ]; then
    log_success "All migrations up to date!"
else
    echo ""
    echo "=========================================="
    log_success "Completed: $MIGRATIONS_RUN migration(s) applied"
    echo "=========================================="
fi

# Verify checksums if requested
if [ "$VERIFY_CHECKSUMS" = true ]; then
    echo ""
    echo "=========================================="
    echo "Verifying Migration Checksums"
    echo "=========================================="
    echo ""

    VERIFICATION_FAILED=false
    VERIFIED_COUNT=0

    # Get all applied migrations with their checksums
    $PSQL -c "
        SELECT version, checksum
        FROM schema_migrations
        ORDER BY version;
    " | while IFS='|' read -r version stored_checksum; do
        # Skip header
        if [ "$version" = "version" ]; then
            continue
        fi

        MIGRATION_FILE="$MIGRATIONS_DIR/${version}.sql"

        if [ ! -f "$MIGRATION_FILE" ]; then
            log_error "Migration file not found: $version.sql"
            VERIFICATION_FAILED=true
            continue
        fi

        CURRENT_CHECKSUM=$(calculate_checksum "$MIGRATION_FILE")

        if [ "$CURRENT_CHECKSUM" = "$stored_checksum" ]; then
            log_success "✓ $version - Checksum verified"
            VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
        else
            log_error "✗ $version - Checksum mismatch!"
            log_info "  Stored:   $stored_checksum"
            log_info "  Current:  $CURRENT_CHECKSUM"
            log_warning "  Migration file has been modified since application"
            VERIFICATION_FAILED=true
        fi
    done

    echo ""
    if [ "$VERIFICATION_FAILED" = true ]; then
        log_error "Checksum verification failed"
        log_error "One or more migration files have been modified"
        exit 1
    else
        log_success "All $VERIFIED_COUNT migration(s) verified"
    fi
fi

exit 0
