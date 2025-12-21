#!/bin/bash
# Sanitize n8n workflow exports by removing pinData (test execution data)

set -e

# Find repo root (works when called from any directory)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"

for file in "$WORKFLOW_DIR"/*.json; do
  filename=$(basename "$file")
  
  # Remove pinData section (test execution data with real IDs)
  if jq -e '.pinData' "$file" > /dev/null 2>&1; then
    echo "Sanitizing $filename..."
    jq 'del(.pinData)' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    echo "  ✓ Removed pinData"
  fi
done

echo "✅ Sanitization complete!"
