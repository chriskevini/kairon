#!/bin/bash
# Fix Execute_Command workflow to use Execute_Queries for ctx preservation
# This fixes the bug where QueryGetTimezone loses ctx, breaking QueryGetConfig

set -e

WORKFLOW_FILE="n8n-workflows/Execute_Command.json"
BACKUP_FILE="n8n-workflows/Execute_Command.json.backup"

# Backup original
cp "$WORKFLOW_FILE" "$BACKUP_FILE"
echo "✓ Backed up original to $BACKUP_FILE"

# Get Execute_Queries workflow ID
EXECUTE_QUERIES_ID="CgUAxK0i4YhrZ2Wp"

# Generate new node IDs
PREPARE_NODE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
CALL_NODE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

echo "Generated node IDs:"
echo "  PrepareConfigQueries: $PREPARE_NODE_ID"
echo "  CallExecuteQueries: $CALL_NODE_ID"

# Step 1: Remove QueryGetTimezone and QueryGetConfig nodes
echo "Removing old nodes..."
jq --arg old1 "QueryGetTimezone" --arg old2 "QueryGetConfig" '
  .nodes = [.nodes[] | select(.name != $old1 and .name != $old2)]
' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp" && mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"

# Step 2: Add PrepareConfigQueries node (read from separate file to avoid escaping issues)
echo "Adding PrepareConfigQueries node..."
cat > /tmp/prepare_config_queries_code.js << 'ENDOFCODE'
// Build queries for timezone + config value (Execute_Queries pattern)
const ctx = $json.ctx;
const key = ctx.validation.normalized_key;

return {
  json: {
    ctx: {
      ...ctx,
      db_queries: [
        {
          key: "timezone",
          sql: "SELECT value FROM config WHERE key = 'timezone'",
          params: []
        },
        {
          key: "config",
          sql: "SELECT key, value FROM config WHERE key = COALESCE($1, '')",
          params: [key]
        }
      ]
    }
  }
};
ENDOFCODE

PREPARE_CODE=$(cat /tmp/prepare_config_queries_code.js)

jq --arg node_id "$PREPARE_NODE_ID" --arg code "$PREPARE_CODE" '
  .nodes += [{
    "parameters": {
      "jsCode": $code
    },
    "type": "n8n-nodes-base.code",
    "typeVersion": 2,
    "position": [-400, 8816],
    "id": $node_id,
    "name": "PrepareConfigQueries"
  }]
' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp" && mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"

# Step 3: Add CallExecuteQueries node
echo "Adding CallExecuteQueries node..."
jq --arg node_id "$CALL_NODE_ID" --arg workflow_id "$EXECUTE_QUERIES_ID" '
  .nodes += [{
    "parameters": {
      "workflowId": {
        "__rl": true,
        "value": $workflow_id,
        "mode": "list",
        "cachedResultName": "Execute_Queries"
      }
    },
    "type": "n8n-nodes-base.executeWorkflow",
    "typeVersion": 1.3,
    "position": [-176, 8816],
    "id": $node_id,
    "name": "CallExecuteQueries"
  }]
' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp" && mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"

# Step 4: Update connections
echo "Updating connections..."
jq --arg prepare_id "$PREPARE_NODE_ID" --arg call_id "$CALL_NODE_ID" '
  # Update SwitchGetTarget connections - output 0 (config) goes to PrepareConfigQueries
  .connections.SwitchGetTarget.main[0] = [{
    "node": "PrepareConfigQueries",
    "type": "main",
    "index": 0
  }] |
  
  # Add PrepareConfigQueries connections - goes to CallExecuteQueries
  .connections.PrepareConfigQueries = {
    "main": [[{
      "node": "CallExecuteQueries",
      "type": "main",
      "index": 0
    }]]
  } |
  
  # Add CallExecuteQueries connections - goes to PrepareGetResponse
  .connections.CallExecuteQueries = {
    "main": [[{
      "node": "PrepareGetResponse",
      "type": "main",
      "index": 0
    }]]
  } |
  
  # Remove old QueryGetTimezone and QueryGetConfig connections
  del(.connections.QueryGetTimezone) |
  del(.connections.QueryGetConfig)
' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp" && mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"

# Step 5: Update PrepareGetResponse to read from ctx.db instead of node references
echo "Updating PrepareGetResponse to use ctx.db..."
cat > /tmp/prepare_get_response_code.js << 'ENDOFCODE'
// Format get command response - merge DB result into ctx
// Fetches timezone and config from ctx.db (populated by Execute_Queries)
const ctx = $json.ctx;
const result = ctx.db?.config?.row;

// Check if query returned data
if (!result || !result.key || !result.value) {
  const key = ctx.validation.normalized_key;
  return {
    json: {
        ctx: {
          ...ctx,
          response: {
            content: `❌ Config key \`${key}\` not found.\n\nUse \`::set ${key} <value>\` to set it first.\n\nAvailable keys: north_star, summary_time, timezone, verbose, next_pulse`
          }
        }
    }
  };
}

// Format the value nicely
let displayValue = result.value;

// Special formatting for timestamps
if (result.key === 'next_pulse' || result.key === 'summary_time') {
  try {
    const timestamp = new Date(result.value);
    if (!isNaN(timestamp.getTime())) {
      const now = new Date();
      const diffMs = timestamp - now;
      
      // Fetch timezone from ctx.db (populated by Execute_Queries)
      const timezone = ctx.db?.timezone?.row?.value || 'America/Los_Angeles'; // fallback
      
      // Extract friendly timezone name (e.g., "Vancouver" from "America/Vancouver")
      const tzName = timezone.includes('/') ? timezone.split('/')[1].replace(/_/g, ' ') : timezone;
      
      // Format timestamp in user's local timezone
      const options = {
        timeZone: timezone,
        year: 'numeric',
        month: 'short',
        day: 'numeric',
        hour: 'numeric',
        minute: '2-digit',
        hour12: true
      };
      const localTimeStr = timestamp.toLocaleString('en-US', options);
      
      if (result.key === 'next_pulse') {
        if (diffMs <= 0) {
          displayValue = 'Now (pulse should run soon)';
        } else {
          const diffMinutes = Math.floor(diffMs / (1000 * 60));
          const diffHours = Math.floor(diffMinutes / 60);
          const remainingMinutes = diffMinutes % 60;
          
          if (diffHours > 0) {
            displayValue = `In ${diffHours}h ${remainingMinutes}m (${localTimeStr} ${tzName})`;
          } else {
            displayValue = `In ${diffMinutes}m (${localTimeStr} ${tzName})`;
          }
        }
      } else {
        // For other timestamps, show formatted local time with timezone
        displayValue = `${localTimeStr} ${tzName}`;
      }
    }
  } catch (e) {
    // If parsing fails, use raw value
  }
}

return {
  json: {
    ctx: {
      ...ctx,
      db: { config_key: result.key, config_value: result.value },
      response: {
        content: `**${result.key}:** ${displayValue}`
      }
    }
  }
};
ENDOFCODE

RESPONSE_CODE=$(cat /tmp/prepare_get_response_code.js)

jq --arg code "$RESPONSE_CODE" '
  .nodes = [.nodes[] | 
    if .name == "PrepareGetResponse" then
      .parameters.jsCode = $code
    else
      .
    end
  ]
' "$WORKFLOW_FILE" > "$WORKFLOW_FILE.tmp" && mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"

echo "✓ Workflow updated successfully!"
echo ""
echo "Changes made:"
echo "  - Removed: QueryGetTimezone, QueryGetConfig"
echo "  - Added: PrepareConfigQueries, CallExecuteQueries"
echo "  - Updated: PrepareGetResponse to read from ctx.db"
echo "  - Fixed: ctx preservation through Execute_Queries pattern"
echo ""
echo "To restore original: mv $BACKUP_FILE $WORKFLOW_FILE"
