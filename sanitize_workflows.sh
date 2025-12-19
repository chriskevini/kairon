#!/bin/bash
# Sanitize n8n workflow exports by removing pinData and sensitive IDs

# Create backup directory if it doesn't exist
mkdir -p ./backup/n8n-workflows

for file in n8n-workflows/*.json; do
  echo "Sanitizing $file..."
  
  # Create backup in central folder
  cp "$file" "./backup/$file"
  
  # Remove pinData section (test execution data with real IDs)
  jq 'del(.pinData)' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  
  echo "  ✓ Removed pinData"
done

echo ""
echo "✅ Sanitization complete!"
echo "Backups saved in backup folder"
