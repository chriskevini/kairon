#!/bin/bash
# backup-db.sh - Daily database backup with rotation
#
# Usage:
#   ./scripts/db/backup-db.sh           # Run backup
#   ./scripts/db/backup-db.sh --list    # List existing backups
#
# Cron (runs daily at midnight):
#   0 0 * * * /path/to/kairon/scripts/db/backup-db.sh >> /var/log/kairon-backup.log 2>&1
#
# Prerequisites:
#   - SSH access configured
#   - .env file in repo root
#   - REMOTE_BACKUP_DIR set in .env

set -euo pipefail

# --- Configuration ---
RETENTION_DAYS=7

# --- Common Setup ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
kairon_init "$SCRIPT_DIR"
kairon_setup_ssh
kairon_require_vars REMOTE_HOST CONTAINER_DB DB_USER DB_NAME REMOTE_BACKUP_DIR

# --- Parse Arguments ---
if [[ "${1:-}" == "--list" ]]; then
    echo "Existing backups in $REMOTE_BACKUP_DIR:"
    ssh "$REMOTE_HOST" "ls -lh $REMOTE_BACKUP_DIR/*.sql.gz 2>/dev/null || echo '  (none)'"
    exit 0
fi

# --- Run Backup ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="kairon_${TIMESTAMP}.sql.gz"

echo "[$(date -Iseconds)] Starting backup..."

# Ensure backup directory exists
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_BACKUP_DIR"

# Run pg_dump inside container, compress, and save
ssh "$REMOTE_HOST" "docker exec $CONTAINER_DB pg_dump -U $DB_USER $DB_NAME | gzip > $REMOTE_BACKUP_DIR/$BACKUP_FILE"

# Verify backup was created and has content
BACKUP_SIZE=$(ssh "$REMOTE_HOST" "stat -c%s $REMOTE_BACKUP_DIR/$BACKUP_FILE 2>/dev/null || echo 0")
if [ "$BACKUP_SIZE" -lt 1000 ]; then
    echo "[$(date -Iseconds)] ERROR: Backup file too small ($BACKUP_SIZE bytes), likely failed"
    exit 1
fi

echo "[$(date -Iseconds)] Backup complete: $BACKUP_FILE ($(numfmt --to=iec $BACKUP_SIZE))"

# --- Rotate Old Backups ---
echo "[$(date -Iseconds)] Rotating backups older than $RETENTION_DAYS days..."
DELETED=$(ssh "$REMOTE_HOST" "find $REMOTE_BACKUP_DIR -name 'kairon_*.sql.gz' -mtime +$RETENTION_DAYS -delete -print | wc -l")
echo "[$(date -Iseconds)] Deleted $DELETED old backup(s)"

# --- Summary ---
echo "[$(date -Iseconds)] Current backups:"
ssh "$REMOTE_HOST" "ls -lh $REMOTE_BACKUP_DIR/kairon_*.sql.gz 2>/dev/null | tail -5"
