#!/bin/bash
# n8n-sync.sh - Sync n8n workflows from local files to remote server via API
#
# Usage: 
#   ./scripts/workflows/n8n-sync.sh              # Sync all workflows
#   ./scripts/workflows/n8n-sync.sh --dry-run    # Show what would be synced
#
# Prerequisites:
#   - SSH access configured (e.g., ~/.ssh/config with Host alias)
#   - .env file with: REMOTE_HOST, N8N_API_KEY, N8N_API_URL (optional, defaults to http://localhost:5678)

set -euo pipefail

# Source SSH connection reuse setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../ssh-setup.sh" 2>/dev/null || true

# --- 1. RESOLVE DIRECTORIES ---
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"

# --- 2. LOAD .ENV FILE ---
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | grep -v '^$' | xargs)
else
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

# --- 3. VALIDATE REQUIRED VARIABLES ---
if [ -z "$REMOTE_HOST" ]; then
    echo "Error: REMOTE_HOST not set in .env"
    exit 1
fi
if [ -z "$N8N_API_KEY" ]; then
    echo "Error: N8N_API_KEY not set in .env"
    exit 1
fi

N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"

# --- 4. PARSE ARGUMENTS ---
DRY_RUN=false
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
    esac
done

# --- 5. MAIN EXECUTION ---
echo "Syncing workflows to $REMOTE_HOST"
echo "   API: $N8N_API_URL"
[ "$DRY_RUN" = true ] && echo "   Mode: DRY-RUN (no changes will be made)"
echo ""

# Fetch existing workflows from remote (single SSH call)
echo "Fetching remote workflows..."
REMOTE_WORKFLOWS=$(ssh "$REMOTE_HOST" "curl -s -H 'X-N8N-API-KEY: $N8N_API_KEY' '$N8N_API_URL/api/v1/workflows?limit=100'" </dev/null | jq -r '.data')

if [ -z "$REMOTE_WORKFLOWS" ] || [ "$REMOTE_WORKFLOWS" = "null" ]; then
    echo "Error: Failed to fetch remote workflows. Check API key and connectivity."
    exit 1
fi

# Build lookup map: name -> id
declare -A WORKFLOW_IDS
while IFS= read -r line; do
    id=$(echo "$line" | jq -r '.id')
    name=$(echo "$line" | jq -r '.name')
    WORKFLOW_IDS["$name"]="$id"
done < <(echo "$REMOTE_WORKFLOWS" | jq -c '.[]')

echo "   Found ${#WORKFLOW_IDS[@]} workflows on remote"
echo ""

# Dry-run mode: just show what would happen
if [ "$DRY_RUN" = true ]; then
    echo "Processing local workflows..."
    CREATED=0
    UPDATED=0
    
    for json_file in "$WORKFLOW_DIR"/*.json; do
        [ -f "$json_file" ] || continue
        
        name=$(jq -r '.name' "$json_file")
        if [ -z "$name" ] || [ "$name" = "null" ]; then
            echo "   Warning: Skipping $(basename "$json_file"): missing 'name' field"
            continue
        fi
        
        existing_id="${WORKFLOW_IDS[$name]:-}"
        
        if [ -n "$existing_id" ]; then
            echo "   [DRY-RUN] Would UPDATE: $name (id: $existing_id)"
            UPDATED=$((UPDATED + 1))
        else
            echo "   [DRY-RUN] Would CREATE: $name"
            CREATED=$((CREATED + 1))
        fi
    done
    
    echo ""
    echo "Dry-run summary: $CREATED would be created, $UPDATED would be updated"
    exit 0
fi

# --- ACTUAL SYNC ---

# Prepare local temp directory with cleaned workflow files
LOCAL_TMP=$(mktemp -d)
trap "rm -rf $LOCAL_TMP" EXIT

echo "Preparing workflows..."
for json_file in "$WORKFLOW_DIR"/*.json; do
    [ -f "$json_file" ] || continue
    
    name=$(jq -r '.name' "$json_file")
    if [ -z "$name" ] || [ "$name" = "null" ]; then
        echo "   Warning: Skipping $(basename "$json_file"): missing 'name' field"
        continue
    fi
    
    # Clean the workflow JSON - only include fields the API accepts
    jq '{
        name: .name,
        nodes: .nodes,
        connections: .connections,
        settings: (.settings // {})
    }' "$json_file" > "$LOCAL_TMP/$(basename "$json_file")"
    
    echo "   Prepared: $name"
done

# Copy all files to remote in one scp call (creates dir automatically)
REMOTE_TMP="/tmp/n8n_sync_$$"
echo ""
echo "Uploading to remote..."
# Check if there are any JSON files to upload
FILE_COUNT=$(ls "$LOCAL_TMP"/*.json 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -gt 0 ]; then
    # Create directory and upload in single SSH session via tar
    # Note: Do NOT use </dev/null here - it would override the piped tar input
    (cd "$LOCAL_TMP" && tar czf - *.json) | ssh "$REMOTE_HOST" "mkdir -p $REMOTE_TMP && cd $REMOTE_TMP && tar xzf -"
    echo "   Uploaded $FILE_COUNT files"
else
    echo "   No files to upload"
    exit 0
fi

# Process all workflows on remote (single SSH call with all curl commands)
echo ""
echo "Syncing workflows..."

# Build the remote script
REMOTE_SCRIPT="#!/bin/bash
cd $REMOTE_TMP
CREATED=0
UPDATED=0
FAILED=0

"

for json_file in "$WORKFLOW_DIR"/*.json; do
    [ -f "$json_file" ] || continue
    
    name=$(jq -r '.name' "$json_file")
    if [ -z "$name" ] || [ "$name" = "null" ]; then
        continue
    fi
    
    existing_id="${WORKFLOW_IDS[$name]:-}"
    filename=$(basename "$json_file")
    
    if [ -n "$existing_id" ]; then
        # Update existing
        REMOTE_SCRIPT+="
result=\$(curl -s -X PUT -H 'X-N8N-API-KEY: $N8N_API_KEY' -H 'Content-Type: application/json' '$N8N_API_URL/api/v1/workflows/$existing_id' -d @'$filename')
if echo \"\$result\" | jq -e '.id' >/dev/null 2>&1; then
    echo '   Updated: $name (id: $existing_id)'
    UPDATED=\$((UPDATED + 1))
else
    echo '   Failed to update: $name'
    echo \"     Error: \$(echo \"\$result\" | jq -r '.message // .')\"
    FAILED=\$((FAILED + 1))
fi
"
    else
        # Create new
        REMOTE_SCRIPT+="
result=\$(curl -s -X POST -H 'X-N8N-API-KEY: $N8N_API_KEY' -H 'Content-Type: application/json' '$N8N_API_URL/api/v1/workflows' -d @'$filename')
new_id=\$(echo \"\$result\" | jq -r '.id // empty')
if [ -n \"\$new_id\" ]; then
    echo '   Created: $name (id: '\$new_id')'
    CREATED=\$((CREATED + 1))
else
    echo '   Failed to create: $name'
    echo \"     Error: \$(echo \"\$result\" | jq -r '.message // .')\"
    FAILED=\$((FAILED + 1))
fi
"
    fi
done

REMOTE_SCRIPT+="
echo ''
echo \"Sync complete: \$CREATED created, \$UPDATED updated, \$FAILED failed\"

# Cleanup
rm -rf $REMOTE_TMP
"

# Execute the remote script (single SSH call)
ssh "$REMOTE_HOST" "$REMOTE_SCRIPT" </dev/null
