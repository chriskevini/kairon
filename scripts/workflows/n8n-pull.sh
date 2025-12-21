#!/bin/bash
# n8n-export.sh - Export n8n workflows from remote server to local files
#
# Usage: 
#   ./scripts/workflows/n8n-export.sh                    # Export all matching workflows
#   ./scripts/workflows/n8n-export.sh --all              # Export ALL workflows from server
#   ./scripts/workflows/n8n-export.sh --dry-run          # Show what would be exported
#   ./scripts/workflows/n8n-export.sh Route_Discord_Event # Export specific workflow by name
#
# By default, only exports workflows that already exist locally (safe update).
# Use --all to export everything from the server.
#
# Prerequisites:
#   - SSH access configured (e.g., ~/.ssh/config with Host alias)
#   - .env file with: REMOTE_HOST, N8N_API_KEY, N8N_API_URL (optional)

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
EXPORT_ALL=false
SPECIFIC_WORKFLOW=""

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        --all)
            EXPORT_ALL=true
            ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--all] [workflow_name]"
            echo ""
            echo "Options:"
            echo "  --dry-run    Show what would be exported without making changes"
            echo "  --all        Export ALL workflows from server (not just existing ones)"
            echo "  name         Export specific workflow by name"
            echo ""
            echo "By default, only exports workflows that already exist in n8n-workflows/"
            exit 0
            ;;
        -*)
            echo "Unknown option: $arg"
            exit 1
            ;;
        *)
            SPECIFIC_WORKFLOW="$arg"
            ;;
    esac
done

# --- 5. MAIN EXECUTION ---
echo "Exporting workflows from $REMOTE_HOST"
echo "   API: $N8N_API_URL"
[ "$DRY_RUN" = true ] && echo "   Mode: DRY-RUN (no changes will be made)"
echo ""

# Fetch all workflows from remote
echo "Fetching remote workflows..."
REMOTE_WORKFLOWS=$(ssh "$REMOTE_HOST" "curl -s -H 'X-N8N-API-KEY: $N8N_API_KEY' '$N8N_API_URL/api/v1/workflows?limit=100'" </dev/null)

if [ -z "$REMOTE_WORKFLOWS" ] || [ "$(echo "$REMOTE_WORKFLOWS" | jq -r '.data')" = "null" ]; then
    echo "Error: Failed to fetch remote workflows. Check API key and connectivity."
    exit 1
fi

WORKFLOW_COUNT=$(echo "$REMOTE_WORKFLOWS" | jq -r '.data | length')
echo "   Found $WORKFLOW_COUNT workflows on remote"

# Build list of local workflow names (for filtering)
declare -A LOCAL_WORKFLOWS
for json_file in "$WORKFLOW_DIR"/*.json; do
    [ -f "$json_file" ] || continue
    name=$(jq -r '.name' "$json_file" 2>/dev/null)
    if [ -n "$name" ] && [ "$name" != "null" ]; then
        LOCAL_WORKFLOWS["$name"]=1
    fi
done

echo "   Found ${#LOCAL_WORKFLOWS[@]} workflows locally"
echo ""

# Build list of workflows to export
declare -a EXPORT_IDS
declare -A WORKFLOW_NAMES  # id -> name
declare -A WORKFLOW_FILES  # id -> filename

while IFS= read -r line; do
    id=$(echo "$line" | jq -r '.id')
    name=$(echo "$line" | jq -r '.name')
    
    # Filter logic
    if [ -n "$SPECIFIC_WORKFLOW" ]; then
        if [ "$name" != "$SPECIFIC_WORKFLOW" ]; then
            continue
        fi
    elif [ "$EXPORT_ALL" != true ]; then
        if [ -z "${LOCAL_WORKFLOWS[$name]:-}" ]; then
            continue
        fi
    fi
    
    filename=$(echo "$name" | tr ' ' '_' | tr -cd '[:alnum:]_-').json
    
    EXPORT_IDS+=("$id")
    WORKFLOW_NAMES["$id"]="$name"
    WORKFLOW_FILES["$id"]="$filename"
done < <(echo "$REMOTE_WORKFLOWS" | jq -c '.data[]')

if [ ${#EXPORT_IDS[@]} -eq 0 ]; then
    echo "No workflows to export."
    exit 0
fi

echo "Workflows to export: ${#EXPORT_IDS[@]}"
echo ""

# Dry-run mode
if [ "$DRY_RUN" = true ]; then
    echo "Processing..."
    for id in "${EXPORT_IDS[@]}"; do
        name="${WORKFLOW_NAMES[$id]}"
        filename="${WORKFLOW_FILES[$id]}"
        filepath="$WORKFLOW_DIR/$filename"
        
        if [ -f "$filepath" ]; then
            echo "   [DRY-RUN] Would UPDATE: $name -> $filename"
        else
            echo "   [DRY-RUN] Would CREATE: $name -> $filename"
        fi
    done
    echo ""
    echo "Export complete! (dry-run)"
    exit 0
fi

# --- ACTUAL EXPORT (batched in single SSH call) ---

# Create temp directory on remote
REMOTE_TMP="/tmp/n8n_export_$$"

# Build remote script that fetches all workflows and saves them
REMOTE_SCRIPT="#!/bin/bash
mkdir -p $REMOTE_TMP
"

for id in "${EXPORT_IDS[@]}"; do
    filename="${WORKFLOW_FILES[$id]}"
    REMOTE_SCRIPT+="
curl -s -H 'X-N8N-API-KEY: $N8N_API_KEY' '$N8N_API_URL/api/v1/workflows/$id' | jq '{
    name: .name,
    nodes: .nodes,
    connections: .connections,
    settings: .settings,
    staticData: .staticData,
    meta: .meta,
    active: false
}' > '$REMOTE_TMP/$filename'
echo 'Exported: $filename' >&2
"
done

echo "Exporting on remote server..."
LOCAL_TMP=$(mktemp -d)
trap "rm -rf $LOCAL_TMP" EXIT

# Export, download, and cleanup in single SSH session via tar
# The && ensures cleanup only happens if export succeeds
ssh "$REMOTE_HOST" "
    set -e
    $REMOTE_SCRIPT
    # Check if any JSON files were created
    if ls $REMOTE_TMP/*.json >/dev/null 2>&1; then
        cd $REMOTE_TMP && tar czf - *.json
    else
        echo 'No files exported' >&2
        exit 1
    fi
    rm -rf $REMOTE_TMP
" </dev/null | (cd "$LOCAL_TMP" && tar xzf -)

echo ""
echo "Downloading to local..."
# Move files to workflow directory
for id in "${EXPORT_IDS[@]}"; do
    name="${WORKFLOW_NAMES[$id]}"
    filename="${WORKFLOW_FILES[$id]}"
    
    if [ -f "$LOCAL_TMP/$filename" ]; then
        mv "$LOCAL_TMP/$filename" "$WORKFLOW_DIR/$filename"
        echo "   Saved: $name -> $filename"
    fi
done

# Run sanitization
echo ""
echo "Running sanitization..."
"$SCRIPT_DIR/sanitize_workflows.sh"

echo ""
echo "Export complete! ${#EXPORT_IDS[@]} workflows exported."
