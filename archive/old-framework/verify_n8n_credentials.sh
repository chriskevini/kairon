#!/bin/bash
#
# Verify n8n Postgres Credentials
# Run this before/after postgres container changes to ensure n8n can connect
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "n8n Postgres Credential Verification"
echo "=========================================="
echo ""

# Check postgres container is running
echo -n "1. Checking postgres-db container... "
if docker ps --format '{{.Names}}' | grep -q '^postgres-db$'; then
    echo -e "${GREEN}RUNNING${NC}"
else
    echo -e "${RED}NOT FOUND${NC}"
    echo "   Run: docker ps -a | grep postgres"
    exit 1
fi

# Check n8n container is running
echo -n "2. Checking n8n container... "
N8N_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E 'n8n' | head -1)
if [ -n "$N8N_CONTAINER" ]; then
    echo -e "${GREEN}RUNNING${NC} ($N8N_CONTAINER)"
else
    echo -e "${YELLOW}NOT FOUND${NC} (may be running elsewhere)"
fi

# List current postgres credentials in n8n
echo ""
echo "3. Postgres credentials in n8n database:"
echo "   ----------------------------------------"
docker exec -i postgres-db psql -U n8n_user -d n8n_chat_memory -c \
    "SELECT id, name, \"createdAt\"::date FROM credentials_entity WHERE type='postgres' ORDER BY \"createdAt\" DESC;" \
    2>/dev/null || echo "   Could not query n8n credentials"

# Check which credential IDs are used in workflows
echo ""
echo "4. Credential usage in workflows:"
echo "   ----------------------------------------"
docker exec -i postgres-db psql -U n8n_user -d n8n_chat_memory -c "
SELECT 
    c.id as credential_id,
    c.name as credential_name,
    COUNT(DISTINCT w.id) as workflow_count
FROM credentials_entity c
LEFT JOIN workflow_entity w ON w.nodes::text LIKE '%' || c.id || '%'
WHERE c.type = 'postgres'
GROUP BY c.id, c.name
ORDER BY workflow_count DESC;
" 2>/dev/null || echo "   Could not query credential usage"

# Test kairon database connectivity
echo ""
echo -n "5. Testing kairon database connectivity... "
if docker exec -i postgres-db psql -U n8n_user -d kairon -c "SELECT 1;" > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
    echo "   Cannot connect to kairon database"
    exit 1
fi

# Check kairon has data
echo -n "6. Checking kairon database has data... "
EVENT_COUNT=$(docker exec -i postgres-db psql -U n8n_user -d kairon -t -c "SELECT COUNT(*) FROM events;" 2>/dev/null | tr -d ' ')
if [ -n "$EVENT_COUNT" ] && [ "$EVENT_COUNT" -gt 0 ]; then
    echo -e "${GREEN}OK${NC} ($EVENT_COUNT events)"
else
    echo -e "${YELLOW}WARNING${NC} (no events found)"
fi

# Test network connectivity from n8n to postgres
echo ""
echo -n "7. Testing network alias 'postgres'... "
if [ -n "$N8N_CONTAINER" ]; then
    if docker exec "$N8N_CONTAINER" sh -c 'nc -z postgres 5432' 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        echo "   n8n cannot reach 'postgres' hostname"
        echo "   Check --network-alias postgres on postgres-db container"
    fi
else
    echo -e "${YELLOW}SKIPPED${NC} (n8n container not found)"
fi

echo ""
echo "=========================================="
echo "Verification complete"
echo "=========================================="
echo ""
echo "If credentials are broken, see:"
echo "  - docs/remote-server-setup.md (credential settings)"
echo "  - postmortem-2025-12-22-postgres-migration.md (recovery steps)"
