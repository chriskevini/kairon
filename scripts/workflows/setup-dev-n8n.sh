#!/bin/bash
# setup-dev-n8n.sh - Create a dev n8n instance on port 5679
#
# Usage:
#   ./scripts/workflows/setup-dev-n8n.sh

set -eo pipefail

echo "Setting up DEV n8n instance on port 5679..."
echo ""

# Check if dev instance already exists
if docker ps -a | grep -q "n8n-dev"; then
    echo "Dev n8n instance already exists"
    echo "To restart: docker start n8n-dev"
    echo "To remove: docker rm -f n8n-dev"
    exit 0
fi

# Create dev n8n container
docker run -d \
    --name n8n-dev \
    --network n8n-docker-caddy_default \
    -p 5679:5678 \
    -e N8N_HOST="localhost" \
    -e N8N_PORT=5678 \
    -e N8N_PROTOCOL=http \
    -e WEBHOOK_URL="http://localhost:5679/" \
    -e GENERIC_TIMEZONE="America/Los_Angeles" \
    -e N8N_LOG_LEVEL=debug \
    -e DB_TYPE=postgresdb \
    -e DB_POSTGRESDB_HOST=postgres-db \
    -e DB_POSTGRESDB_PORT=5432 \
    -e DB_POSTGRESDB_DATABASE=n8n_dev \
    -e DB_POSTGRESDB_USER=n8n_user \
    -e DB_POSTGRESDB_PASSWORD=password \
    -v n8n_dev_data:/home/node/.n8n \
    docker.n8n.io/n8nio/n8n

echo ""
echo "Creating dev database..."
docker exec postgres-db psql -U n8n_user -c "CREATE DATABASE n8n_dev;" 2>/dev/null || echo "Database n8n_dev already exists"

echo ""
echo "Waiting for n8n-dev to start..."
sleep 10

if curl -sf http://localhost:5679/healthz > /dev/null; then
    echo ""
    echo "✓ DEV n8n is running!"
    echo ""
    echo "Dev URL: http://localhost:5679"
    echo ""
    echo "Next steps:"
    echo "1. Open http://localhost:5679 in your browser"
    echo "2. Create your admin account"
    echo "3. Create credentials (exact names):"
    echo "   - Discord Bot account"
    echo "   - OpenRouter account"
    echo "   - GitHub account"
    echo "   - Postgres account (use DB: kairon)"
    echo "4. Generate an API key (Settings → API)"
    echo "5. Set N8N_DEV_API_KEY in your environment"
    echo ""
else
    echo "✗ Failed to start n8n-dev"
    echo "Check logs: docker logs n8n-dev"
    exit 1
fi
