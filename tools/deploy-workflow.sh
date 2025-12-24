#!/bin/bash
# Safe workflow deployment tool for Kairon

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPS_TOOL="$SCRIPT_DIR/kairon-ops.sh"
VALIDATOR="$SCRIPT_DIR/validate-workflow.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
    echo "Usage: $0 <workflow_file.json> [--id <ID>] [--force]"
    echo "       $0 --rollback <workflow_name>"
    exit 1
}

if [ "$1" == "--help" ] || [ -z "$1" ]; then usage; fi
if [ "$1" == "--rollback" ]; then
    workflow_name="$2"
    if [ -z "$workflow_name" ]; then error "Specify workflow name to rollback"; fi
    
    latest_backup=$(ls -t "$PROJECT_ROOT/backups"/*/workflows/"$workflow_name".json 2>/dev/null | head -1)
    if [ -z "$latest_backup" ]; then error "No backup found for $workflow_name"; fi
    
    log "Rolling back $workflow_name using $latest_backup"
    $0 "$latest_backup" --force
    exit 0
fi

WORKFLOW_FILE="$1"
WORKFLOW_ID=""
FORCE=false

# Parse arguments
shift
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --id) WORKFLOW_ID="$2"; shift ;;
        --force) FORCE=true ;;
        *) usage ;;
    esac
    shift
done

if [ -z "$WORKFLOW_FILE" ]; then usage; fi
if [ ! -f "$WORKFLOW_FILE" ]; then error "File not found: $WORKFLOW_FILE"; fi

# 1. Validate
log "Validating $WORKFLOW_FILE..."
$VALIDATOR "$WORKFLOW_FILE" || error "Validation failed"

# 2. Identify Workflow ID if not provided
if [ -z "$WORKFLOW_ID" ]; then
    log "Searching for workflow ID..."
    NAME=$(jq -r '.name' "$WORKFLOW_FILE")
    WORKFLOW_ID=$($OPS_TOOL n8n-list | grep "^$NAME -" | awk -F'ID: ' '{print $2}' | awk '{print $1}')
    if [ -z "$WORKFLOW_ID" ]; then
        error "Could not find ID for workflow '$NAME'. Please specify with --id"
    fi
    log "Found ID: $WORKFLOW_ID"
fi

# 3. Create backup
log "Creating backup of current production version..."
TIMESTAMP=$(date +%Y%m%d-%H%M)
BACKUP_DIR="$PROJECT_ROOT/backups/deploy-$TIMESTAMP"
mkdir -p "$BACKUP_DIR/workflows"
$OPS_TOOL n8n-get "$WORKFLOW_ID" > "$BACKUP_DIR/workflows/$(jq -r '.name' "$WORKFLOW_FILE").json" || warn "Backup failed, continuing anyway..."

# 4. Sanitize
log "Sanitizing workflow JSON..."
TEMP_FILE=$(mktemp)
# Keep only essential fields for deployment
jq '{name, nodes, connections, settings, staticData}' "$WORKFLOW_FILE" > "$TEMP_FILE"

# 5. Confirm
if [ "$FORCE" = false ]; then
    read -p "Deploying to ID $WORKFLOW_ID. Are you sure? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error "Deployment cancelled"
    fi
fi

# 6. Deploy
log "Uploading workflow..."
# Since kairon-ops.sh doesn't have n8n-deploy yet, we'll use a temp script on the server
# Or we can just use curl directly via ssh if we have the API key
API_KEY=$($OPS_TOOL db-query "SELECT 1" > /dev/null && ssh DigitalOcean 'grep "^N8N_API_KEY=" ~/kairon/.env | cut -d= -f2')

if [ -z "$API_KEY" ]; then
    error "Could not retrieve n8n API key from server"
fi

# Upload via curl
# n8n API expects the workflow object directly
RESPONSE=$(curl -s -X PUT -H "X-N8N-API-KEY: $API_KEY" -H "Content-Type: application/json" \
    --data @"$TEMP_FILE" "https://n8n.chrisirineo.com/api/v1/workflows/$WORKFLOW_ID")

if echo "$RESPONSE" | jq -e '.data.id' >/dev/null 2>&1; then
    log "Deployment successful!"
else
    error "Deployment failed: $RESPONSE"
fi

rm "$TEMP_FILE"
