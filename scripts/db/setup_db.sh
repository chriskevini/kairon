#!/bin/bash
# Setup script for Kairon database in Docker container
# Run this on your server where postgres-db container is running

set -euo pipefail  # Exit on error, undefined vars, pipe failures

echo "Kairon Database Setup"
echo "========================"

# Configuration
CONTAINER_NAME="postgres-db"
DB_NAME="kairon"
DB_USER="${POSTGRES_USER:-postgres}"
EXISTING_DB="${POSTGRES_DB:-postgres}"  # Connect to existing DB first

echo ""
echo "Container: $CONTAINER_NAME"
echo "Database: $DB_NAME"
echo "User: $DB_USER"
echo ""

# Check if container exists and is running
echo "Checking container status..."
if ! docker ps --filter "name=$CONTAINER_NAME" --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "ERROR: Container '$CONTAINER_NAME' is not running"
    echo "   Run: docker ps -a | grep postgres"
    exit 1
fi
echo "OK: Container is running"

# Create database
echo ""
echo "Creating database '$DB_NAME'..."
if docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$EXISTING_DB" -tc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
    echo "WARNING: Database '$DB_NAME' already exists"
    read -p "Drop and recreate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$EXISTING_DB" -c "DROP DATABASE $DB_NAME;"
        docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$EXISTING_DB" -c "CREATE DATABASE $DB_NAME;"
        echo "OK: Database recreated"
    else
        echo "SKIP: Database creation skipped"
    fi
else
    docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$EXISTING_DB" -c "CREATE DATABASE $DB_NAME;"
    echo "OK: Database created"
fi

# Run schema
echo ""
echo "Running schema..."
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" < db/schema.sql
echo "OK: Schema applied"

# Run seeds
echo ""
echo "Running seed data..."
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" < db/seeds/001_initial_data.sql
echo "OK: Seed data loaded"

# Verify setup
echo ""
echo "Verifying setup..."
echo ""

echo "Config table:"
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT key, value FROM config;"

echo ""
echo "Tables created:"
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"

echo ""
echo "OK: Setup complete!"
echo ""
echo "Connection info for n8n:"
echo "   Host: localhost (or container IP)"
echo "   Port: 5432 (check docker port mapping)"
echo "   Database: $DB_NAME"
echo "   User: $DB_USER"
echo ""
echo "To get connection string:"
echo "  docker port $CONTAINER_NAME 5432"
