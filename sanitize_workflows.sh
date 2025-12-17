#!/bin/bash
# Sanitize n8n workflow exports by removing pinData and sensitive IDs

for file in n8n-workflows/*.json; do
  echo "Sanitizing $file..."
  
  # Create backup
  cp "$file" "$file.backup"
  
  # Remove pinData section (test execution data with real IDs)
  jq 'del(.pinData)' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  
  echo "  ✓ Removed pinData"
done

echo ""
echo "✅ Sanitization complete!"
echo "Backups saved as *.backup"
echo ""
echo "⚠️  Manual steps required:"
echo "1. In n8n UI, update webhook paths to use: {{ \$env.WEBHOOK_PATH }}"
echo "2. Update Discord channel IDs to use environment variables"
echo "3. Re-export workflows after making these changes"
