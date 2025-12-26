#!/bin/bash
#
# Kairon Database Backup Script
# Backs up PostgreSQL kairon database to Google Drive with rotation
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
NTFY_TOPIC="${NTFY_TOPIC:-kairon-backups}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
DB_NAME="${DB_NAME:-kairon}"
DB_USER="${DB_USER:-n8n_user}"
POSTGRES_CONTAINER=$(docker ps -q -f name=^postgres-db$)

# Retention settings (from env or defaults)
KEEP_HOURLY="${BACKUP_KEEP_HOURLY:-24}"    # Keep last 24 hourly backups
KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"        # Keep last 7 daily backups
KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"       # Keep last 4 weekly backups

# Timestamp formats
NOW=$(date +%Y-%m-%d_%H-%M-%S)
TODAY=$(date +%Y-%m-%d)
HOUR=$(date +%H)
DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday

# Logging
LOG_FILE="$BACKUP_DIR/backup.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Send notification
notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-}"
    
    curl -s \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        -d "$message" \
        "https://ntfy.sh/$NTFY_TOPIC" > /dev/null 2>&1 || true
}

# Notify on failure
notify_failure() {
    local error_msg="$1"
    log "ERROR: $error_msg"
    notify "Kairon Backup FAILED" "$error_msg" "urgent" "x,rotating_light"
    exit 1
}

# Create backup directory structure
mkdir -p "$BACKUP_DIR"/{hourly,daily,weekly}

log "Starting backup..."

# Step 1: Create database dump
DUMP_FILE="$BACKUP_DIR/kairon_${NOW}.dump"
log "Creating database dump..."

if [ -z "$POSTGRES_CONTAINER" ]; then
    notify_failure "PostgreSQL container not found"
fi

if ! docker exec "$POSTGRES_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$DUMP_FILE" 2>/dev/null; then
    rm -f "$DUMP_FILE"
    notify_failure "pg_dump failed"
fi

DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
log "Dump created: $DUMP_FILE ($DUMP_SIZE)"

# Step 2: Copy to rotation directories
HOURLY_FILE="$BACKUP_DIR/hourly/kairon_${NOW}.dump"
cp "$DUMP_FILE" "$HOURLY_FILE"

# Daily backup (keep one per day, at first backup of the day)
DAILY_MARKER="$BACKUP_DIR/daily/.marker_$TODAY"
if [ ! -f "$DAILY_MARKER" ]; then
    cp "$DUMP_FILE" "$BACKUP_DIR/daily/kairon_${TODAY}.dump"
    touch "$DAILY_MARKER"
    log "Daily backup created"
fi

# Weekly backup (on Sundays)
if [ "$DAY_OF_WEEK" -eq 7 ]; then
    WEEK=$(date +%Y-W%V)
    WEEKLY_FILE="$BACKUP_DIR/weekly/kairon_${WEEK}.dump"
    if [ ! -f "$WEEKLY_FILE" ]; then
        cp "$DUMP_FILE" "$WEEKLY_FILE"
        log "Weekly backup created"
    fi
fi

# Clean up temp dump
rm -f "$DUMP_FILE"

# Step 3: Rotate old backups locally
log "Rotating old backups..."

# Rotate hourly (keep last N)
find "$BACKUP_DIR/hourly" -name "*.dump" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +$((KEEP_HOURLY + 1)) | cut -d' ' -f2- | xargs -r rm -f || true

# Rotate daily (keep last N) and their markers
find "$BACKUP_DIR/daily" -name "*.dump" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +$((KEEP_DAILY + 1)) | cut -d' ' -f2- | xargs -r rm -f || true
find "$BACKUP_DIR/daily/" -name ".marker_*" -mtime +$KEEP_DAILY -delete 2>/dev/null || true

# Rotate weekly (keep last N)
find "$BACKUP_DIR/weekly" -name "*.dump" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +$((KEEP_WEEKLY + 1)) | cut -d' ' -f2- | xargs -r rm -f || true

# Step 4: Sync to Google Drive
log "Syncing to Google Drive..."

RCLONE_OUTPUT=$(rclone sync "$BACKUP_DIR" "$RCLONE_REMOTE_NAME:$RCLONE_REMOTE_PATH" \
    --exclude "backup.log" \
    --exclude "backup.sh" \
    --exclude ".marker_*" \
    2>&1) || {
    echo "$RCLONE_OUTPUT" >> "$LOG_FILE"
    notify_failure "rclone sync to Google Drive failed: $RCLONE_OUTPUT"
}
echo "$RCLONE_OUTPUT" >> "$LOG_FILE"

# Step 5: Verify remote backup exists
REMOTE_COUNT=$(rclone ls "$RCLONE_REMOTE_NAME:$RCLONE_REMOTE_PATH/hourly" 2>/dev/null | wc -l || echo "0")
if [ "$REMOTE_COUNT" -eq 0 ]; then
    notify_failure "No backups found on Google Drive after sync"
fi

# Calculate totals
LOCAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
HOURLY_COUNT=$(find "$BACKUP_DIR/hourly" -name "*.dump" -type f 2>/dev/null | wc -l)
DAILY_COUNT=$(find "$BACKUP_DIR/daily" -name "*.dump" -type f 2>/dev/null | wc -l)
WEEKLY_COUNT=$(find "$BACKUP_DIR/weekly" -name "*.dump" -type f 2>/dev/null | wc -l)

log "Backup complete! Local: $LOCAL_SIZE, Hourly: $HOURLY_COUNT, Daily: $DAILY_COUNT, Weekly: $WEEKLY_COUNT"

# Optional: Send success notification (uncomment if you want success notifications too)
# notify "Kairon Backup OK" "Size: $DUMP_SIZE | H:$HOURLY_COUNT D:$DAILY_COUNT W:$WEEKLY_COUNT" "low" "white_check_mark"

exit 0
