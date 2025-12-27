#!/bin/bash
set -euo pipefail

# n8n-push-local.sh - Push workflows to a local n8n instance via API
#
# Usage:
#   WORKFLOW_DIR=/path/to/workflows N8N_API_URL=http://localhost:5679 N8N_API_KEY=xxx ./n8n-push-local.sh
#
# This is a simplified version for local dev deployment (no SSH)

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

# Check if we hit the 100-workflow limit
WORKFLOW_COUNT=$(echo "$REMOTE_WORKFLOWS" | jq 'length')
if [ "$WORKFLOW_COUNT" -eq 100 ]; then
    echo ""
    echo "⚠️  WARNING: Exactly 100 workflows fetched!"
    echo "   There may be more workflows that weren't retrieved."
    echo "   Consider implementing pagination in n8n-push-local.sh:46"
    echo ""
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
    # Don't include 'active' here - we handle activation separately to avoid validation issues
    cleaned=$(jq '{
        name: .name,
        nodes: .nodes,
        connections: .connections,
        settings: {}
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
            
            # Activate if needed - failures are non-fatal (some workflows can't be activated in dev)
            if [ "$(jq -r '.active' "$json_file")" = "true" ]; then
                activation_result=$(curl_auth -X PATCH \
                    -H "Content-Type: application/json" \
                    -d '{"active": true}' \
                    "$N8N_API_URL/rest/workflows/$existing_id" 2>&1)
                if echo "$activation_result" | jq -e '.code' > /dev/null 2>&1; then
                    echo "     Warning: Could not activate (non-fatal)"
                fi
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
            
            # Activate if needed - failures are non-fatal (some workflows can't be activated in dev)
            if [ "$(jq -r '.active' "$json_file")" = "true" ]; then
                activation_result=$(curl_auth -X PATCH \
                    -H "Content-Type: application/json" \
                    -d '{"active": true}' \
                    "$N8N_API_URL/rest/workflows/$new_id" 2>&1)
                if echo "$activation_result" | jq -e '.code' > /dev/null 2>&1; then
                    echo "     Warning: Could not activate (non-fatal)"
                fi
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

# Second pass: Update Execute Workflow node references to use local IDs
# This is needed because mode:list still uses the cached value field
# Run this regardless of created/updated - workflow refs may need updating anytime
if [ $((CREATED + UPDATED)) -gt 0 ]; then
    echo ""
    echo "Updating workflow references..."
    
    # Refresh workflow ID mapping
    declare -A WORKFLOW_IDS=()
    RESPONSE=$(curl_auth "$N8N_API_URL/rest/workflows?take=100")
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        id=$(echo "$line" | jq -r '.id')
        name=$(echo "$line" | jq -r '.name')
        [ "$id" = "null" ] || [ "$name" = "null" ] && continue
        WORKFLOW_IDS["$name"]="$id"
    done < <(echo "$RESPONSE" | jq -c '.data[]')
    
    # Build JSON mapping for jq
    ID_MAP_JSON="{"
    for name in "${!WORKFLOW_IDS[@]}"; do
        ID_MAP_JSON+="\"$name\":\"${WORKFLOW_IDS[$name]}\","
    done
    ID_MAP_JSON="${ID_MAP_JSON%,}}"
    
    REFS_UPDATED=0
    for name in "${!WORKFLOW_IDS[@]}"; do
        id="${WORKFLOW_IDS[$name]}"
        
        # Get current workflow
        workflow_data=$(curl_auth "$N8N_API_URL/rest/workflows/$id")
        
        # Check if any Execute Workflow nodes need updating
        needs_update=$(echo "$workflow_data" | jq -r --argjson idmap "$ID_MAP_JSON" '
            .data.nodes[] | 
            select(.type == "n8n-nodes-base.executeWorkflow") |
            select(.parameters.workflowId.__rl == true) |
            select(.parameters.workflowId.cachedResultName != null) |
            select($idmap[.parameters.workflowId.cachedResultName] != null) |
            select(.parameters.workflowId.value != $idmap[.parameters.workflowId.cachedResultName]) |
            .name
        ' 2>/dev/null | head -1)
        
        if [ -n "$needs_update" ]; then
            # Update the workflow with corrected IDs
            updated_nodes=$(echo "$workflow_data" | jq --argjson idmap "$ID_MAP_JSON" '
                .data.nodes | map(
                    if .type == "n8n-nodes-base.executeWorkflow" and 
                       .parameters.workflowId.__rl == true and
                       .parameters.workflowId.cachedResultName != null and
                       $idmap[.parameters.workflowId.cachedResultName] != null
                    then
                        .parameters.workflowId.value = $idmap[.parameters.workflowId.cachedResultName] |
                        .parameters.workflowId.cachedResultUrl = "/workflow/" + $idmap[.parameters.workflowId.cachedResultName]
                    else
                        .
                    end
                )
            ')
            
            # Update workflow
            result=$(curl_auth -X PATCH \
                -H "Content-Type: application/json" \
                "$N8N_API_URL/rest/workflows/$id" \
                -d "{\"nodes\": $updated_nodes}")
            
            if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
                echo "   Updated refs: $name"
                REFS_UPDATED=$((REFS_UPDATED + 1))
            fi
        fi
    done
    
    if [ $REFS_UPDATED -gt 0 ]; then
        echo "   $REFS_UPDATED workflow(s) had references updated"
    fi
fi

[ $FAILED -gt 0 ] && exit 1
exit 0
