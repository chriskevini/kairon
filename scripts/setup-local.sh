#!/bin/bash
set -euo pipefail

# setup-local.sh - One-command local environment setup
#
# Usage: ./scripts/setup-local.sh
#
# This script:
# 1. Starts all containers (n8n, postgres, discord-relay, embedding-service)
# 2. Initializes database schema
# 3. Sets up n8n owner account
# 4. Deploys workflows

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cleanup function
cleanup() {
    if [ -n "${COOKIE_FILE:-}" ] && [ -f "$COOKIE_FILE" ]; then
        rm -f "$COOKIE_FILE" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo "=========================================="
echo "KAIRON LOCAL SETUP"
echo "=========================================="
echo ""

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# Check .env
if [ ! -f "$REPO_ROOT/.env" ]; then
    log_warn ".env file not found. Copying from .env.example..."
    cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
    log_info "Created .env file"
    echo ""
    echo "IMPORTANT: Update .env with your credentials:"
    echo "  - DISCORD_BOT_TOKEN (for Discord bot)"
    echo "  - OPENROUTER_API_KEY (for LLM)"
    echo "  - Optional: N8N_DEV_USER, N8N_DEV_PASSWORD"
    echo ""
    read -p "Press Enter after updating .env, or Ctrl+C to exit..."
    source "$REPO_ROOT/.env"
fi

# Build and start containers
echo "Building and starting containers..."
if ! docker-compose build; then
    echo "ERROR: Failed to build containers"
    exit 1
fi

if ! docker-compose up -d; then
    echo "ERROR: Failed to start containers"
    exit 1
fi

log_info "Containers started"
echo ""

# Wait for postgres
echo "Waiting for PostgreSQL to be ready..."
max_wait=30
wait_count=0

while [ $wait_count -lt $max_wait ]; do
    if docker exec postgres-local pg_isready -U ${DB_USER:-postgres} > /dev/null 2>&1; then
        break
    fi
    sleep 1
    wait_count=$((wait_count + 1))
done

if [ $wait_count -ge $max_wait ]; then
    echo "ERROR: PostgreSQL failed to start"
    exit 1
fi

log_info "PostgreSQL is ready"
echo ""

# Initialize database
echo "Checking database schema..."
if docker exec postgres-local psql -U ${DB_USER:-postgres} -d ${DB_NAME:-kairon} -c "\dt events" 2>/dev/null | grep -q events; then
    log_info "Database already initialized"
else
    echo "Initializing database schema..."
    if ! docker exec -i postgres-local psql -U ${DB_USER:-postgres} -d ${DB_NAME:-kairon} < "$REPO_ROOT/db/schema.sql"; then
        echo "ERROR: Failed to initialize database"
        exit 1
    fi
    log_info "Database schema loaded"
fi
echo ""

# Wait for n8n
echo "Waiting for n8n to be ready..."
wait_count=0
max_wait=60

while [ $wait_count -lt $max_wait ]; do
    if curl -s -o /dev/null -w "" http://localhost:5679/ > /dev/null 2>&1; then
        break
    fi
    sleep 2
    wait_count=$((wait_count + 2))
done

if [ $wait_count -ge $max_wait ]; then
    echo "ERROR: n8n failed to start"
    docker-compose logs n8n | tail -50
    exit 1
fi

log_info "n8n is ready"
echo ""

# Set up n8n owner account
echo "Setting up n8n owner account..."
COOKIE_FILE="/tmp/n8n-setup-cookie-$$"
settings=$(curl -s http://localhost:5679/rest/settings)
show_setup=$(echo "$settings" | jq -r '.data.userManagement.showSetupOnFirstLoad // "true"')

if [ "$show_setup" = "true" ]; then
    N8N_USER="${N8N_DEV_USER:-admin}"
    N8N_PASSWORD="${N8N_DEV_PASSWORD:-Admin123!}"
    N8N_EMAIL="${N8N_USER}@example.com"
    
    echo "Creating owner account..."
    setup_result=$(curl -s -c "$COOKIE_FILE" -X POST http://localhost:5679/rest/owner/setup \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$N8N_EMAIL\",\"firstName\":\"Admin\",\"lastName\":\"User\",\"password\":\"$N8N_PASSWORD\"}")
    
    if ! echo "$setup_result" | jq -e '.data.id' > /dev/null 2>&1; then
        echo "ERROR: Failed to create owner account"
        echo "$setup_result" | jq .
        exit 1
    fi
    log_info "Owner account created: $N8N_EMAIL"
else
    log_info "Owner account already exists"
    # Login to get session cookie
    N8N_USER="${N8N_DEV_USER:-admin}"
    N8N_PASSWORD="${N8N_DEV_PASSWORD:-Admin123!}"
    N8N_EMAIL="${N8N_USER}@example.com"
    curl -s -c "$COOKIE_FILE" -X POST http://localhost:5679/rest/login \
        -H "Content-Type: application/json" \
        -d "{\"emailOrLdapLoginId\":\"$N8N_EMAIL\",\"password\":\"$N8N_PASSWORD\"}" > /dev/null
fi
echo ""

# Deploy workflows
echo "Deploying workflows..."
cd "$REPO_ROOT"
if ! ./scripts/deploy.sh local; then
    echo "ERROR: Failed to deploy workflows"
    exit 1
fi
cd - > /dev/null

echo ""
echo "=========================================="
echo "SETUP COMPLETE"
echo "=========================================="
echo ""
echo "Access services:"
echo "  n8n UI:        http://localhost:5679"
echo "  Embedding API: http://localhost:8000"
echo ""
echo "View logs:"
echo "  docker-compose logs -f [service-name]"
echo ""
echo "Services: n8n, postgres, discord-relay, embedding-service"
echo ""
echo "To use with Discord:"
echo "  1. Set up webhook tunnel (ngrok/cloudflared)"
echo "  2. Update N8N_WEBHOOK_URL in .env"
echo "  3. Restart discord-relay: docker-compose restart discord-relay"
echo ""
