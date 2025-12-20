#!/bin/bash
# Quick script to find postgres user in container

echo "🔍 Finding Postgres user in container..."

CONTAINER_NAME="postgres-db"

# Try different common usernames
for user in postgres admin root user; do
    echo -n "Testing user '$user'... "
    if docker exec "$CONTAINER_NAME" psql -U "$user" -c '\q' 2>/dev/null; then
        echo "✅ FOUND!"
        echo ""
        echo "Your postgres user is: $user"
        echo ""
        echo "Run setup with:"
        echo "  POSTGRES_USER=$user ./setup_db.sh"
        exit 0
    else
        echo "❌"
    fi
done

echo ""
echo "❌ Could not find postgres user"
echo ""
echo "Try these commands to investigate:"
echo ""
echo "# Check container environment variables:"
echo "docker inspect postgres-db | grep -A 10 Env"
echo ""
echo "# Check postgres process:"
echo "docker exec postgres-db ps aux | grep postgres"
echo ""
echo "# Try to connect without user:"
echo "docker exec -it postgres-db psql"
