#!/bin/bash
# Sanitize n8n workflow exports by removing pinData (test execution data)

set -euo pipefail

# Find repo root (works when called from any directory)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"

for file in "$WORKFLOW_DIR"/*.json; do
  filename=$(basename "$file")
  
  # Remove pinData section (test execution data with real IDs)
  if jq -e '.pinData' "$file" > /dev/null 2>&1; then
    echo "Sanitizing $filename (pinData)..."
    jq 'del(.pinData)' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  fi

  # Remove credential IDs (forces deployment script to look them up by name)
  if jq -e '.nodes[].credentials' "$file" > /dev/null 2>&1; then
    echo "Sanitizing $filename (credential IDs)..."
    jq '.nodes |= map(if .credentials then .credentials |= with_entries(.value |= del(.id)) else . end)' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  fi
done

echo "✅ Sanitization complete!"
