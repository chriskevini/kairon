#!/bin/bash
# Safe migration runner for remote server

set -e  # Exit on error

echo "🔍 Step 1: Finding PostgreSQL container..."
POSTGRES_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i postgres | head -1)

if [ -z "$POSTGRES_CONTAINER" ]; then
    echo "❌ No PostgreSQL container found!"
    echo "Available containers:"
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    exit 1
fi

echo "✅ Found PostgreSQL container: $POSTGRES_CONTAINER"
echo ""

echo "🔍 Step 2: Checking current database state..."
docker exec -i "$POSTGRES_CONTAINER" psql -U n8n_user -d kairon <<'EOF'
-- Check if migration already applied
SELECT 
  EXISTS (SELECT 1 FROM pg_type WHERE typname = 'activity_category') AS has_enum,
  EXISTS (SELECT 1 FROM information_schema.columns 
          WHERE table_name = 'activity_log' AND column_name = 'category_id') AS has_old_column,
  EXISTS (SELECT 1 FROM information_schema.columns 
          WHERE table_name = 'activity_log' AND column_name = 'category') AS has_new_column;
EOF

echo ""
read -p "📋 Does this look correct? (old_column=true, new_column=false means NOT migrated yet) [y/N]: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Aborted by user"
    exit 1
fi

echo ""
echo "💾 Step 3: Creating backup..."
BACKUP_FILE="backups/pre_migration_002_$(date +%Y%m%d_%H%M%S).sql"
mkdir -p backups

docker exec "$POSTGRES_CONTAINER" pg_dump -U n8n_user -d kairon > "$BACKUP_FILE"

if [ -f "$BACKUP_FILE" ]; then
    echo "✅ Backup created: $BACKUP_FILE"
    echo "   Size: $(du -h "$BACKUP_FILE" | cut -f1)"
else
    echo "❌ Backup failed!"
    exit 1
fi

echo ""
read -p "🚀 Step 4: Ready to run migration 002? [y/N]: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Aborted by user"
    exit 1
fi

echo ""
echo "⚙️  Running migration 002..."
docker exec -i "$POSTGRES_CONTAINER" psql -U n8n_user -d kairon < db/migrations/002_static_categories.sql

echo ""
echo "🔍 Step 5: Verifying migration..."
docker exec -i "$POSTGRES_CONTAINER" psql -U n8n_user -d kairon <<'EOF'
-- Verify new schema
SELECT 
  'activity_category enum exists' AS check_name,
  EXISTS (SELECT 1 FROM pg_type WHERE typname = 'activity_category') AS result
UNION ALL
SELECT 
  'note_category enum exists',
  EXISTS (SELECT 1 FROM pg_type WHERE typname = 'note_category')
UNION ALL
SELECT 
  'activity_log has category column',
  EXISTS (SELECT 1 FROM information_schema.columns 
          WHERE table_name = 'activity_log' AND column_name = 'category')
UNION ALL
SELECT 
  'activity_log NO category_id column',
  NOT EXISTS (SELECT 1 FROM information_schema.columns 
              WHERE table_name = 'activity_log' AND column_name = 'category_id')
UNION ALL
SELECT 
  'notes has category column',
  EXISTS (SELECT 1 FROM information_schema.columns 
          WHERE table_name = 'notes' AND column_name = 'category')
UNION ALL
SELECT 
  'activity_categories table dropped',
  NOT EXISTS (SELECT 1 FROM information_schema.tables 
              WHERE table_name = 'activity_categories');

-- Show sample data
SELECT 'Sample activities:' AS check_name, '' AS result;
SELECT id, timestamp, category, description 
FROM activity_log 
ORDER BY timestamp DESC 
LIMIT 3;

SELECT 'Sample notes:' AS check_name, '' AS result;
SELECT id, timestamp, category, title, text 
FROM notes 
ORDER BY timestamp DESC 
LIMIT 3;
EOF

echo ""
echo "✅ Migration 002 complete!"
echo ""
echo "📋 Next steps:"
echo "   1. Test n8n workflows (they should continue working)"
echo "   2. Check Discord bot behavior"
echo "   3. If issues occur, restore backup:"
echo "      docker exec -i $POSTGRES_CONTAINER psql -U n8n_user -d kairon < $BACKUP_FILE"
echo ""
