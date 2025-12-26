#!/bin/bash
#
# Kairon Database Restore Script
# Restores PostgreSQL kairon database from backup
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load environment variables from .env if it exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Configuration (with defaults)
BACKUP_DIR="${BACKUP_DIR:-/root/kairon-backups}"
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-gdrive}"
RCLONE_REMOTE_PATH="${RCLONE_REMOTE_PATH:-kairon-backups}"
DB_NAME="${DB_NAME:-kairon}"
DB_USER="${DB_USER:-n8n_user}"
POSTGRES_CONTAINER=$(docker ps -q -f name=postgres)

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -l, --list              List available backups (local and remote)"
    echo "  -f, --file <path>       Restore from specific local file"
    echo "  -r, --remote <path>     Restore from Google Drive (e.g., hourly/kairon_2025-12-22_05-31-27.dump)"
    echo "  --latest                Restore from latest local hourly backup"
    echo "  --latest-daily          Restore from latest local daily backup"
    echo "  --dry-run               Show what would be restored without actually restoring"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --list"
    echo "  $0 --latest"
    echo "  $0 --file /root/kairon-backups/hourly/kairon_2025-12-22_05-31-27.dump"
    echo "  $0 --remote hourly/kairon_2025-12-22_05-31-27.dump"
    exit 1
}

list_backups() {
    echo "=== Local Backups ==="
    echo ""
    echo "Hourly:"
    find "$BACKUP_DIR/hourly" -name "*.dump" -type f -printf '  %T+ %p (%s bytes)\n' 2>/dev/null | sort -r | head -10 || echo "  (none)"
    echo ""
    echo "Daily:"
    find "$BACKUP_DIR/daily" -name "*.dump" -type f -printf '  %T+ %p (%s bytes)\n' 2>/dev/null | sort -r || echo "  (none)"
    echo ""
    echo "Weekly:"
    find "$BACKUP_DIR/weekly" -name "*.dump" -type f -printf '  %T+ %p (%s bytes)\n' 2>/dev/null | sort -r || echo "  (none)"
    echo ""
    echo "=== Remote Backups (Google Drive) ==="
    echo ""
    rclone ls "$RCLONE_REMOTE_NAME:$RCLONE_REMOTE_PATH" 2>/dev/null | while read size path; do
        echo "  $path ($size bytes)"
    done || echo "  (unable to connect)"
}

restore_db() {
    local dump_file="$1"
    local dry_run="${2:-false}"
    
    if [ ! -f "$dump_file" ]; then
        echo "ERROR: Backup file not found: $dump_file"
        exit 1
    fi
    
    local file_size=$(du -h "$dump_file" | cut -f1)
    echo "Backup file: $dump_file ($file_size)"
    
    if [ "$dry_run" = "true" ]; then
        echo "[DRY RUN] Would restore $dump_file to database '$DB_NAME'"
        echo "[DRY RUN] This would DROP and recreate the database"
        return 0
    fi
    
    echo ""
    echo "WARNING: This will DROP and recreate the '$DB_NAME' database!"
    echo "All current data will be LOST."
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "Restore cancelled."
        exit 0
    fi
    
    echo ""
    echo "Restoring database..."
    
    # Drop existing connections
    docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d postgres -c "
        SELECT pg_terminate_backend(pg_stat_activity.pid)
        FROM pg_stat_activity
        WHERE pg_stat_activity.datname = '$DB_NAME'
        AND pid <> pg_backend_pid();" 2>/dev/null || true
    
    # Drop and recreate database
    docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME;" 
    docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
    
    # Restore from dump
    docker exec -i "$POSTGRES_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" -v < "$dump_file"
    
    echo ""
    echo "Restore complete!"
    
    # Verify
    echo ""
    echo "Verifying restore..."
    docker exec "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "
        SELECT 'events' as table_name, COUNT(*) as rows FROM events
        UNION ALL SELECT 'traces', COUNT(*) FROM traces
        UNION ALL SELECT 'projections', COUNT(*) FROM projections;"
}

# Parse arguments
if [ $# -eq 0 ]; then
    usage
fi

DRY_RUN=false
ACTION=""
TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        -l|--list)
            list_backups
            exit 0
            ;;
        -f|--file)
            ACTION="file"
            TARGET="$2"
            shift 2
            ;;
        -r|--remote)
            ACTION="remote"
            TARGET="$2"
            shift 2
            ;;
        --latest)
            ACTION="latest"
            shift
            ;;
        --latest-daily)
            ACTION="latest-daily"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

case "$ACTION" in
    file)
        restore_db "$TARGET" "$DRY_RUN"
        ;;
    remote)
        echo "Downloading from Google Drive: $TARGET"
        TEMP_FILE="/tmp/kairon_restore_$(date +%s).dump"
        rclone copy "$RCLONE_REMOTE_NAME:$RCLONE_REMOTE_PATH/$TARGET" /tmp/
        DOWNLOADED_FILE="/tmp/$(basename "$TARGET")"
        mv "$DOWNLOADED_FILE" "$TEMP_FILE"
        restore_db "$TEMP_FILE" "$DRY_RUN"
        rm -f "$TEMP_FILE"
        ;;
    latest)
        LATEST=$(find "$BACKUP_DIR/hourly" -name "*.dump" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [ -z "$LATEST" ]; then
            echo "ERROR: No hourly backups found"
            exit 1
        fi
        restore_db "$LATEST" "$DRY_RUN"
        ;;
    latest-daily)
        LATEST=$(find "$BACKUP_DIR/daily" -name "*.dump" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [ -z "$LATEST" ]; then
            echo "ERROR: No daily backups found"
            exit 1
        fi
        restore_db "$LATEST" "$DRY_RUN"
        ;;
    *)
        usage
        ;;
esac
