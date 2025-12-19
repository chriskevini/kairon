#!/bin/bash
set -e

# ============================================================================
# Data Migration Script: Phase 3 - Migrate Data to New Schema
# ============================================================================
# This script migrates existing data from old tables to the new
# events/traces/projections schema.
#
# What it does:
# 1. Creates backup before migration
# 2. Runs data migration SQL (006b_migrate_data.sql)
# 3. Verifies record counts
# 4. Displays summary
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATION_FILE="$SCRIPT_DIR/db/migrations/006b_migrate_data.sql"
BACKUP_DIR="/home/deployer/kairon/db/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/backup_before_data_migration_$TIMESTAMP.sql"

echo "============================================"
echo "Data Migration: Phase 3"
echo "============================================"
echo ""

# Check if migration file exists
if [ ! -f "$MIGRATION_FILE" ]; then
    echo "❌ Migration file not found: $MIGRATION_FILE"
    exit 1
fi

# Create backup directory if it doesn't exist
ssh DigitalOcean "mkdir -p $BACKUP_DIR"

echo "📦 Creating backup before data migration..."
ssh DigitalOcean "docker exec -i postgres-db pg_dump -U n8n_user -d kairon > $BACKUP_FILE"
echo "✅ Backup created: $BACKUP_FILE"
echo ""

# Display current counts
echo "📊 Current state (before migration):"
ssh DigitalOcean "docker exec -i postgres-db psql -U n8n_user -d kairon << 'EOF'
SELECT 'OLD TABLES' as category, '' as table_name, NULL as count
UNION ALL
SELECT '', 'raw_events', COUNT(*)::int FROM raw_events
UNION ALL
SELECT '', 'routing_decisions', COUNT(*)::int FROM routing_decisions
UNION ALL
SELECT '', 'activity_log', COUNT(*)::int FROM activity_log
UNION ALL
SELECT '', 'notes', COUNT(*)::int FROM notes
UNION ALL
SELECT '', 'thread_extractions', COUNT(*)::int FROM thread_extractions
UNION ALL
SELECT '', '', NULL
UNION ALL
SELECT 'NEW TABLES', '', NULL
UNION ALL
SELECT '', 'events', COUNT(*)::int FROM events
UNION ALL
SELECT '', 'traces', COUNT(*)::int FROM traces
UNION ALL
SELECT '', 'projections', COUNT(*)::int FROM projections;
EOF"
echo ""

# Ask for confirmation
read -p "Proceed with data migration? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "❌ Migration cancelled"
    exit 1
fi

# Run migration
echo "🚀 Running data migration..."
echo ""
cat "$MIGRATION_FILE" | ssh DigitalOcean "docker exec -i postgres-db psql -U n8n_user -d kairon"

# Display final counts
echo ""
echo "============================================"
echo "Migration Complete!"
echo "============================================"
echo ""
echo "📊 Final state:"
ssh DigitalOcean "docker exec -i postgres-db psql -U n8n_user -d kairon << 'EOF'
SELECT 'events' as table_name, COUNT(*) FROM events
UNION ALL
SELECT 'traces', COUNT(*) FROM traces
UNION ALL
SELECT 'projections', COUNT(*) FROM projections
UNION ALL
SELECT '  - activities', COUNT(*) FROM projections WHERE projection_type = 'activity'
UNION ALL
SELECT '  - notes', COUNT(*) FROM projections WHERE projection_type = 'note'
UNION ALL
SELECT '  - thread_extractions', COUNT(*) FROM projections WHERE projection_type = 'thread_extraction';
EOF"
echo ""

echo "✅ Data migration complete!"
echo ""
echo "📋 Next steps:"
echo "  1. Verify data integrity with sample queries"
echo "  2. Update n8n workflows to use new schema (Phase 4)"
echo "  3. Run parallel for 1 week (Phase 5)"
echo "  4. Drop old tables when ready (Phase 6)"
echo ""
echo "🔄 To rollback if needed:"
echo "  cat $BACKUP_FILE | docker exec -i postgres-db psql -U n8n_user -d kairon"
