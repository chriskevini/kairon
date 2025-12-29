#!/bin/bash
# monitor-prod.sh - Monitor n8n production for errors and alert
#
# This script checks for failed executions in n8n and sends alerts to Discord.
# It's intended to run as a background service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# Configuration
N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"
WEBHOOK_URL="${DISCORD_KAIRON_LOGS_WEBHOOK:-}"
CHECK_INTERVAL=300 # 5 minutes
LAST_CHECK_FILE="$REPO_ROOT/.monitor_state"

if [ -z "$N8N_API_KEY" ]; then
    echo "Error: N8N_API_KEY not set"
    exit 1
fi

if [ -z "$WEBHOOK_URL" ]; then
    echo "Warning: DISCORD_KAIRON_LOGS_WEBHOOK not set. Alerts will only be printed to stdout."
fi

echo "Starting n8n production monitor..."
echo "API URL: $N8N_API_URL"
echo "Check interval: ${CHECK_INTERVAL}s"

# Initialize last check time if not exists
if [ ! -f "$LAST_CHECK_FILE" ]; then
    # Start looking from 5 minutes ago on first run to catch immediate issues
    echo $(($(date +%s) - CHECK_INTERVAL)) > "$LAST_CHECK_FILE"
fi

while true; do
    NOW=$(date +%s)
    LAST_CHECK=$(cat "$LAST_CHECK_FILE")
    
    # Check recent failed executions
    # w: \n%{http_code} to get status code
    RESPONSE=$(curl -s -w "\n%{http_code}" \
        -H "X-N8N-API-KEY: $N8N_API_KEY" \
        "$N8N_API_URL/api/v1/executions?status=error&limit=50")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    FAILED_DATA=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" != "200" ]; then
        echo "Warning: API returned HTTP $HTTP_CODE"
        sleep "$CHECK_INTERVAL"
        continue
    fi
    
    if [ -n "$FAILED_DATA" ] && [ "$FAILED_DATA" != "null" ]; then
        # 1. Get workflow list for name mapping
        # Store in a temporary file to avoid "Argument list too long"
        WORKFLOWS_FILE=$(mktemp)
        curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_API_URL/api/v1/workflows" > "$WORKFLOWS_FILE"
        
        # 2. Filter failures that happened since last check
        NEW_FAILURES=$(echo "$FAILED_DATA" | jq -r --arg last "$LAST_CHECK" --arg url "$N8N_API_URL" --slurpfile workflows "$WORKFLOWS_FILE" '
            ($workflows[0].data | map({(.id): .name}) | add) as $names |
            .data[] | 
            select(.stoppedAt != null) |
            (.stoppedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $stopped_ts |
            select($stopped_ts > ($last | tonumber)) | 
            "• **\($names[.workflowId] // .workflowId)** (ID: \(.id))\n  [View Execution](\($url)/execution/\(.id))\n  Time: \(.stoppedAt)"
        ')
        
        rm -f "$WORKFLOWS_FILE"
        
        if [ -n "$NEW_FAILURES" ]; then
            echo -e "Failures detected:\n$NEW_FAILURES"
            
            if [ -n "$WEBHOOK_URL" ]; then
                # Properly escape for JSON using jq
                jq -n --arg content "🚨 **New n8n Production Errors Detected**

$NEW_FAILURES

[View Executions]($N8N_API_URL/executions)" \
                    '{content: $content}' | \
                curl -s -X POST "$WEBHOOK_URL" \
                    -H "Content-Type: application/json" \
                    -d @- > /dev/null
            fi
        fi
    fi
    
    # Update last check time
    echo "$NOW" > "$LAST_CHECK_FILE"
    
    sleep "$CHECK_INTERVAL"
done
