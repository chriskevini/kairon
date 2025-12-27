#!/bin/bash
# n8n-push-local.sh - Push workflows to a local n8n instance via API
#
# Usage:
#   WORKFLOW_DIR=/path/to/workflows N8N_API_URL=http://localhost:5679 N8N_API_KEY=xxx ./n8n-push-local.sh
#
# This is a simplified version for local dev deployment (no SSH)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Allow override of workflow directory (for transformed workflows)
WORKFLOW_DIR="${WORKFLOW_DIR:-$REPO_ROOT/n8n-workflows}"
N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"

# Support basic auth for local development
N8N_BASIC_AUTH_USER="${N8N_BASIC_AUTH_USER:-}"
N8N_BASIC_AUTH_PASSWORD="${N8N_BASIC_AUTH_PASSWORD:-}"
N8N_DEV_COOKIE_FILE="${N8N_DEV_COOKIE_FILE:-}"

# Helper function to make authenticated curl requests
curl_auth() {
    if [ -n "$N8N_API_KEY" ]; then
        curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" "$@"
    elif [ -n "$N8N_DEV_COOKIE_FILE" ] && [ -f "$N8N_DEV_COOKIE_FILE" ]; then
        curl -s -b "$N8N_DEV_COOKIE_FILE" "$@"
    elif [ -n "$N8N_BASIC_AUTH_USER" ] && [ -n "$N8N_BASIC_AUTH_PASSWORD" ]; then
        curl -s -u "$N8N_BASIC_AUTH_USER:$N8N_BASIC_AUTH_PASSWORD" "$@"
    else
        curl -s "$@"
    fi
}

# Initialize associative array
declare -A WORKFLOW_IDS=()

echo "Pushing workflows to $N8N_API_URL"
echo "   Source: $WORKFLOW_DIR"
echo ""

# Fetch existing workflows
echo "Fetching existing workflows..."
RESPONSE=$(curl_auth "$N8N_API_URL/rest/workflows?take=100")
REMOTE_WORKFLOWS=$(echo "$RESPONSE" | jq -r '.data? // []')

if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "null" ]; then
    echo "Error: Failed to fetch workflows. Check API key and connectivity."
    exit 1
fi

# Build lookup map: name -> id
if [ "$REMOTE_WORKFLOWS" != "[]" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        id=$(echo "$line" | jq -r '.id')
        name=$(echo "$line" | jq -r '.name')
        [ "$id" = "null" ] || [ "$name" = "null" ] && continue
        
        # In dev, we trust the name->id mapping without verification to speed things up
        WORKFLOW_IDS["$name"]="$id"
    done < <(echo "$REMOTE_WORKFLOWS" | jq -c '.[]')
fi

echo "   Found ${#WORKFLOW_IDS[@]} accessible workflows"
echo ""

# Process each workflow file
CREATED=0
UPDATED=0
FAILED=0

for json_file in "$WORKFLOW_DIR"/*.json; do
    [ -f "$json_file" ] || continue
    
    name=$(jq -r '.name' "$json_file")
    if [ -z "$name" ] || [ "$name" = "null" ]; then
        echo "   Warning: Skipping $(basename "$json_file"): missing 'name' field"
        continue
    fi
    
    # Clean workflow JSON - only include fields the API accepts
    cleaned=$(jq '{
        name: .name,
        nodes: .nodes,
        connections: .connections,
        settings: {},
        active: (.active // false)
    }' "$json_file")
    
    existing_id="${WORKFLOW_IDS[$name]:-}"
    
    if [ -n "$existing_id" ]; then
        # Update existing workflow
        result=$(echo "$cleaned" | curl_auth -X PATCH \
            -H "Content-Type: application/json" \
            "$N8N_API_URL/rest/workflows/$existing_id" \
            -d @-)
        
        if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
            echo "   Updated: $name (id: $existing_id)"
            UPDATED=$((UPDATED + 1))
            
            # Activate if needed
            if [ "$(jq -r '.active' "$json_file")" = "true" ]; then
                curl_auth -X POST \
                    "$N8N_API_URL/rest/workflows/$existing_id/activate" > /dev/null
            fi
        else
            echo "   Failed to update: $name"
            echo "     Error: $(echo "$result" | jq -r '.message // .')"
            FAILED=$((FAILED + 1))
        fi
    else
        # Create new workflow
        result=$(echo "$cleaned" | curl_auth -X POST \
            -H "Content-Type: application/json" \
            "$N8N_API_URL/rest/workflows" \
            -d @-)
        
        new_id=$(echo "$result" | jq -r '.data.id // empty')
        if [ -n "$new_id" ]; then
            echo "   Created: $name (id: $new_id)"
            CREATED=$((CREATED + 1))
            
            # Activate if needed
            if [ "$(jq -r '.active' "$json_file")" = "true" ]; then
                curl_auth -X POST \
                    "$N8N_API_URL/rest/workflows/$new_id/activate" > /dev/null
            fi
        else
            echo "   Failed to create: $name"
            echo "     Error: $(echo "$result" | jq -r '.message // .')"
            FAILED=$((FAILED + 1))
        fi
    fi
done

echo ""
echo "Push complete: $CREATED created, $UPDATED updated, $FAILED failed"

[ $FAILED -gt 0 ] && exit 1
exit 0
