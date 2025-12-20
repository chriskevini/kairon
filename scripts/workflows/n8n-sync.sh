#!/bin/bash
# n8n-sync.sh - Sync n8n workflows from GitHub to remote server
#
# Usage: 
#   ./scripts/workflows/n8n-sync.sh                    # Sync from main branch
#   ./scripts/workflows/n8n-sync.sh <branch>           # Sync from specific branch
#   ./scripts/workflows/n8n-sync.sh flat-data-shape-refactor
#
# Prerequisites:
#   - SSH access configured (e.g., ~/.ssh/config with Host alias)
#   - .env file in repo root with REMOTE_HOST, GITHUB_REPO, CONTAINER_N8N

set -e

# --- 1. RESOLVE DIRECTORIES ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# --- 2. LOAD .ENV FILE ---
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | grep -v '^$' | xargs)
else
    echo "❌ Error: .env file not found at $ENV_FILE"
    exit 1
fi

# --- 3. VALIDATE REQUIRED VARIABLES ---
if [ -z "$REMOTE_HOST" ]; then
    echo "❌ Error: REMOTE_HOST not set in .env"
    exit 1
fi
if [ -z "$GITHUB_REPO" ]; then
    echo "❌ Error: GITHUB_REPO not set in .env"
    exit 1
fi
if [ -z "$CONTAINER_N8N" ]; then
    echo "❌ Error: CONTAINER_N8N not set in .env"
    exit 1
fi

# --- 4. PARSE BRANCH ARGUMENT ---
BRANCH="${1:-main}"

# --- 5. EXECUTION ---
echo "🚀 Syncing workflows from branch: $BRANCH"
echo "   Repository: $GITHUB_REPO"
echo "   Server: $REMOTE_HOST"
echo ""

ssh -t "$REMOTE_HOST" << EOF
  set -e
  
  TEMP_DIR="/tmp/n8n_sync_\$(date +%s)"
  IMPORT_PATH="/home/node/import"

  # 1. Clone repo on remote host (specific branch)
  echo "📥 Cloning repository (branch: $BRANCH)..."
  git clone --depth 1 --branch "$BRANCH" "$GITHUB_REPO" "\$TEMP_DIR"

  # 2. Prepare import directory in container
  echo "📦 Preparing container: $CONTAINER_N8N"
  docker exec -u root "$CONTAINER_N8N" rm -rf "\$IMPORT_PATH" 2>/dev/null || true
  docker exec -u root "$CONTAINER_N8N" mkdir -p "\$IMPORT_PATH"
  docker exec -u root "$CONTAINER_N8N" chown node:node "\$IMPORT_PATH"
  
  # 3. Copy only the workflow files (not the whole repo)
  echo "📋 Copying workflow files..."
  docker cp "\$TEMP_DIR/n8n-workflows/." "$CONTAINER_N8N":"\$IMPORT_PATH/"
  
  # 4. Import workflows
  echo "⚡ Importing workflows..."
  docker exec -u node "$CONTAINER_N8N" n8n import:workflow --separate --input="\$IMPORT_PATH/"

  # 5. Cleanup
  echo "🧹 Cleaning up..."
  rm -rf "\$TEMP_DIR"
  docker exec -u root "$CONTAINER_N8N" rm -rf "\$IMPORT_PATH"

  # 6. Restart n8n to refresh
  echo "♻️ Restarting $CONTAINER_N8N..."
  docker restart "$CONTAINER_N8N"
EOF

echo ""
echo "✅ Sync complete! (branch: $BRANCH)"
