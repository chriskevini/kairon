#!/bin/bash
# Show local development configuration (SSH access, docker containers, etc.)
# This file exists because AI agents cannot read .env files directly.
#
# Usage: ./scripts/show-local-config.sh

set -e

# Find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================="
echo "Environment Configuration (.env)"
echo "=========================================="
if [ -f "$REPO_ROOT/.env" ]; then
    cat "$REPO_ROOT/.env"
else
    echo "(no .env file found)"
fi

echo ""
echo "=========================================="
echo "Local Notes (.env.local)"
echo "=========================================="
if [ -f "$REPO_ROOT/.env.local" ]; then
    cat "$REPO_ROOT/.env.local"
else
    echo "(no .env.local file found)"
fi
