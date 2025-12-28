#!/bin/bash
set -euo pipefail

# teardown-local.sh - Clean up local Kairon environment
#
# Usage: ./scripts/teardown-local.sh
#
# This script:
# 1. Stops all containers
# 2. Removes containers and volumes
# 3. Cleans up temporary files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

echo "=========================================="
echo "TEARDOWN LOCAL ENVIRONMENT"
echo "=========================================="
echo ""

# Check if docker-compose.yml exists
if [ ! -f "$REPO_ROOT/docker-compose.yml" ]; then
    log_error "docker-compose.yml not found at $REPO_ROOT"
    exit 1
fi

cd "$REPO_ROOT"

# Stop containers
echo "Stopping containers..."
docker-compose down 2>/dev/null || true
log_info "Containers stopped"
echo ""

# Remove orphaned containers (if any)
echo "Removing orphaned containers..."
ORPHANS=$(docker ps -a --filter "name=kairon" --format "{{.Names}}")
for orphan in $ORPHANS; do
    if docker ps -a --filter "name=$orphan" --format "{{.Status}}" | grep -q "Exited"; then
        docker rm "$orphan" 2>/dev/null || true
        log_info "Removed orphan: $orphan"
    fi
done
echo ""

# Clean up session cookies
echo "Cleaning up temporary files..."
rm -f /tmp/n8n-*cookie*.txt 2>/dev/null || true
log_info "Session files cleaned"
echo ""

# Show what's left
echo "=========================================="
echo "Remaining resources:"
echo "=========================================="
docker ps -a --filter "name=kairon" --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "Volumes:"
docker volume ls | grep kairon || echo "  No kairon volumes"
echo ""
echo "To completely remove data (including database):"
echo "  docker-compose down -v"
echo ""
log_info "Teardown complete"
