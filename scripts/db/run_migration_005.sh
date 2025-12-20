#!/bin/bash
# Script to safely run database migration 005 on production
# Creates unsaved_extractions view with automatic backup

set -e  # Exit on error

echo "=================================================="
echo "Migration 005: Create unsaved_extractions view"
echo "=================================================="
echo ""

# Configuration
DB_CONTAINER="postgres-db"
DB_USER="n8n_user"
DB_NAME="kairon"
BACKUP_DIR="/home/deployer/kairon/db/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/backup_before_migration_005_$TIMESTAMP.sql"

# Ensure backup directory exists
echo "Step 1: Creating backup directory..."
mkdir -p "$BACKUP_DIR"

# Create backup
echo "Step 2: Creating database backup..."
echo "Backup location: $BACKUP_FILE"
docker exec $DB_CONTAINER pg_dump -U $DB_USER $DB_NAME > "$BACKUP_FILE"

if [ -f "$BACKUP_FILE" ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "✅ Backup created successfully ($BACKUP_SIZE)"
else
    echo "❌ Backup failed! Aborting migration."
    exit 1
fi

# Run migration
echo ""
echo "Step 3: Running migration 005..."
docker exec -i $DB_CONTAINER psql -U $DB_USER -d $DB_NAME < db/migrations/005_create_unsaved_extractions_view.sql

if [ $? -eq 0 ]; then
    echo "✅ Migration completed successfully"
    echo ""
    echo "Backup saved at: $BACKUP_FILE"
    echo ""
    echo "To rollback if needed:"
    echo "  cat $BACKUP_FILE | docker exec -i $DB_CONTAINER psql -U $DB_USER -d $DB_NAME"
else
    echo "❌ Migration failed!"
    echo ""
    echo "To restore from backup:"
    echo "  cat $BACKUP_FILE | docker exec -i $DB_CONTAINER psql -U $DB_USER -d $DB_NAME"
    exit 1
fi
