#!/bin/bash
# Setup script for Kairon database in Docker container
# Run this on your server where postgres-db container is running

set -e  # Exit on error

echo "🚀 Kairon Database Setup"
echo "========================"

# Configuration
CONTAINER_NAME="postgres-db"
DB_NAME="kairon"
DB_USER="${POSTGRES_USER:-postgres}"

echo ""
echo "Container: $CONTAINER_NAME"
echo "Database: $DB_NAME"
echo "User: $DB_USER"
echo ""

# Check if container exists and is running
echo "📋 Checking container status..."
if ! docker ps --filter "name=$CONTAINER_NAME" --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "❌ Container '$CONTAINER_NAME' is not running"
    echo "   Run: docker ps -a | grep postgres"
    exit 1
fi
echo "✅ Container is running"

# Create database
echo ""
echo "📦 Creating database '$DB_NAME'..."
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -tc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 && {
    echo "⚠️  Database '$DB_NAME' already exists"
    read -p "Drop and recreate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -c "DROP DATABASE $DB_NAME;"
        docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -c "CREATE DATABASE $DB_NAME;"
        echo "✅ Database recreated"
    else
        echo "⏭️  Skipping database creation"
    fi
} || {
    docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -c "CREATE DATABASE $DB_NAME;"
    echo "✅ Database created"
}

# Run migration
echo ""
echo "🔧 Running schema migration..."
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" < db/migrations/001_initial_schema.sql
echo "✅ Schema migration complete"

# Run seeds
echo ""
echo "🌱 Running seed data..."
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" < db/seeds/001_initial_data.sql
echo "✅ Seed data loaded"

# Set user state (you need to customize this)
echo ""
read -p "Enter your Discord username: " DISCORD_USER
if [ -n "$DISCORD_USER" ]; then
    docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" <<EOF
INSERT INTO user_state (user_login, sleeping, last_observation_at) 
VALUES ('$DISCORD_USER', false, NULL)
ON CONFLICT (user_login) DO NOTHING;
EOF
    echo "✅ User state initialized for '$DISCORD_USER'"
fi

# Verify setup
echo ""
echo "🔍 Verifying setup..."
echo ""

echo "Activity Categories:"
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT name, is_sleep_category FROM activity_categories ORDER BY sort_order;"

echo ""
echo "Note Categories:"
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT name FROM note_categories ORDER BY sort_order;"

echo ""
echo "User State:"
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT * FROM user_state;"

echo ""
echo "✅ Setup complete!"
echo ""
echo "📝 Connection info for n8n:"
echo "   Host: localhost (or container IP)"
echo "   Port: 5432 (check docker port mapping)"
echo "   Database: $DB_NAME"
echo "   User: $DB_USER"
echo ""
echo "To get connection string:"
echo "  docker port $CONTAINER_NAME 5432"
