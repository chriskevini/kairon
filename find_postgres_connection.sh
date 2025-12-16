#!/bin/bash
# Find the correct Postgres connection for n8n

echo "🔍 Finding Postgres connection info for n8n..."
echo ""

# Check if postgres-db is running
if ! docker ps --filter "name=postgres-db" --format "{{.Names}}" | grep -q "postgres-db"; then
    echo "❌ postgres-db container is not running"
    exit 1
fi

echo "✅ postgres-db is running"
echo ""

# Get container IP
POSTGRES_IP=$(docker inspect postgres-db --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "📍 Postgres container IP: $POSTGRES_IP"

# Get network
POSTGRES_NETWORK=$(docker inspect postgres-db --format='{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}')
echo "🌐 Postgres network: $POSTGRES_NETWORK"

# Check if n8n container exists
if docker ps --filter "name=n8n" --format "{{.Names}}" | grep -q "n8n"; then
    N8N_NETWORK=$(docker inspect n8n --format='{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}')
    echo "🌐 n8n network: $N8N_NETWORK"
    
    if [ "$POSTGRES_NETWORK" = "$N8N_NETWORK" ]; then
        echo ""
        echo "✅ Both on same network!"
        echo ""
        echo "Use these settings in n8n:"
        echo "  Host: postgres-db"
        echo "  Port: 5432"
        echo "  Database: kairon"
        echo "  User: n8n_user"
        echo "  Password: password"
        echo "  SSL: disabled"
    else
        echo ""
        echo "⚠️  Containers on different networks"
        echo ""
        echo "Try these settings in n8n:"
        echo "  Host: $POSTGRES_IP"
        echo "  Port: 5432"
        echo "  Database: kairon"
        echo "  User: n8n_user"
        echo "  Password: password"
        echo "  SSL: disabled"
    fi
else
    echo "❌ n8n container not found"
    echo ""
    echo "If n8n is NOT in Docker, use:"
    echo "  Host: localhost (or 127.0.0.1)"
    echo "  Port: $(docker port postgres-db 5432 | cut -d: -f2)"
    echo "  Database: kairon"
    echo "  User: n8n_user"
    echo "  Password: password"
    echo "  SSL: disabled"
fi

echo ""
echo "📝 To test connection:"
echo "docker exec -it postgres-db psql -U n8n_user -d kairon -c 'SELECT 1;'"
