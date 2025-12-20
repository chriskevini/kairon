#!/bin/bash
# Sanitize n8n workflow exports by removing pinData and sensitive IDs

set -e

# Find repo root (works when called from any directory)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"
BACKUP_DIR="$REPO_ROOT/backup/n8n-workflows"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

for file in "$WORKFLOW_DIR"/*.json; do
  filename=$(basename "$file")
  echo "Sanitizing $filename..."
  
  # Create backup in central folder
  cp "$file" "$BACKUP_DIR/$filename"
  
  # Remove pinData section (test execution data with real IDs)
  jq 'del(.pinData)' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  
  echo "  ✓ Removed pinData"
done

echo ""
echo "✅ Sanitization complete!"
echo "Backups saved in backup folder"
