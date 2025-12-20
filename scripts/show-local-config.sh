#!/bin/bash
# Show local development configuration (SSH access, docker containers, etc.)
# This file exists because AI agents cannot read .env files directly.
#
# Usage: ./scripts/show-local-config.sh

set -e

ENV_LOCAL=".env.local"

if [ ! -f "$ENV_LOCAL" ]; then
    echo "No .env.local file found."
    echo ""
    echo "Create one with your local development setup:"
    echo "  - SSH connection strings"
    echo "  - Docker container names"
    echo "  - Local port mappings"
    echo "  - Any environment-specific notes"
    exit 0
fi

cat "$ENV_LOCAL"
