#!/bin/bash
# Script to safely run database migration 006 on production
# Creates Event-Trace-Projection schema with automatic backup

set -e  # Exit on error

echo "=================================================================="
echo "Migration 006: Create Event-Trace-Projection Schema (Phase 1)"
echo "=================================================================="
echo ""
echo "This migration creates new tables alongside existing schema:"
echo "  - events (replaces raw_events)"
echo "  - traces (replaces routing_decisions + multi-step support)"
echo "  - projections (replaces activity_log, notes, todos, thread_extractions)"
echo "  - embeddings (RAG support, unpopulated)"
echo ""
echo "⚠️  OLD TABLES ARE NOT TOUCHED - Parallel running strategy"
echo "⚠️  Data migration happens in Phase 3 (separate script)"
echo ""

# Configuration
DB_CONTAINER="postgres-db"
DB_USER="n8n_user"
DB_NAME="kairon"
BACKUP_DIR="/home/deployer/kairon/db/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/backup_before_migration_006_$TIMESTAMP.sql"

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
echo "Step 3: Running migration 006..."
docker exec -i $DB_CONTAINER psql -U $DB_USER -d $DB_NAME < db/migrations/006_events_traces_projections.sql

if [ $? -eq 0 ]; then
    echo "✅ Migration completed successfully"
    echo ""
    echo "📊 New tables created:"
    echo "  - events (immutable event log)"
    echo "  - traces (LLM reasoning chains)"
    echo "  - projections (structured outputs, JSONB-first)"
    echo "  - embeddings (vector embeddings for RAG)"
    echo ""
    echo "📊 Compatibility views created:"
    echo "  - activity_log_v2, notes_v2, todos_v2, thread_extractions_v2"
    echo ""
    echo "Backup saved at: $BACKUP_FILE"
    echo ""
    echo "⏭️  Next steps:"
    echo "  1. Verify tables: docker exec -it $DB_CONTAINER psql -U $DB_USER -d $DB_NAME -c '\\dt'"
    echo "  2. Run data migration (Phase 3): ./run_migration_006_data.sh"
    echo "  3. Update n8n workflows to write to new schema"
    echo "  4. Parallel run for 1 week"
    echo "  5. Drop old tables (migration 007)"
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
