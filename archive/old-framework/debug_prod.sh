#!/bin/bash
# debug_prod.sh - Production debugging helper for Kairon
#
# Usage:
#   ./scripts/debug_prod.sh executions [limit]     - List recent executions
#   ./scripts/debug_prod.sh execution <id>         - Get execution details with error
#   ./scripts/debug_prod.sh events [limit]         - List recent events from DB
#   ./scripts/debug_prod.sh logs [lines]           - Get n8n container logs
#   ./scripts/debug_prod.sh workflow <name>        - Get workflow details
#   ./scripts/debug_prod.sh test                   - Send test webhook
#   ./scripts/debug_prod.sh ssh <command>          - Run command via SSH with retry

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment
if [ -f "$REPO_ROOT/.env" ]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

N8N_API_KEY="${N8N_API_KEY:-}"
N8N_HOST="${N8N_HOST:-n8n.chrisirineo.com}"
SSH_HOST="${REMOTE_HOST:-DigitalOcean}"
WEBHOOK_PATH="${WEBHOOK_PATH:-asoiaf92746087}"

# SSH with exponential backoff retry (start 10s, doubles each attempt)
ssh_retry() {
    local max_attempts=5
    local delay=10
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ssh -o ConnectTimeout=15 -o ServerAliveInterval=30 "$SSH_HOST" "$@" 2>/dev/null; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            echo "SSH attempt $attempt failed, retrying in ${delay}s..." >&2
            sleep $delay
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    
    echo "SSH failed after $max_attempts attempts" >&2
    return 1
}

# API call helper
api() {
    local endpoint="$1"
    curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" "https://$N8N_HOST/api/v1/$endpoint"
}

case "${1:-help}" in
    executions)
        limit="${2:-10}"
        api "executions?limit=$limit" | jq -r '.data[] | "\(.id)\t\(.status)\t\(.mode)\t\(.startedAt)"'
        ;;
    
    execution)
        id="${2:?Usage: $0 execution <id>}"
        # Get basic info from API
        echo "=== Execution $id ==="
        api "executions/$id" | jq '{id, status, mode, startedAt, stoppedAt, workflowId}'
        
        # Get detailed error from DB
        echo ""
        echo "=== Error Details ==="
        ssh_retry "docker exec postgres-db psql -U n8n_user -d n8n_chat_memory -t -c \"
            SELECT executionData::json->'resultData'->'error'->>'message' as error_message,
                   executionData::json->'resultData'->'error'->>'node' as error_node
            FROM execution_entity 
            WHERE id = '$id';
        \"" 2>/dev/null || echo "(Could not fetch from DB)"
        ;;
    
    events)
        limit="${2:-10}"
        ssh_retry "docker exec postgres-db psql -U n8n_user -d kairon -c \"
            SELECT id, event_type, received_at, payload->>'clean_text' as text
            FROM events 
            ORDER BY received_at DESC 
            LIMIT $limit;
        \""
        ;;
    
    logs)
        lines="${2:-50}"
        ssh_retry "docker logs n8n-docker-caddy-n8n-1 --tail $lines 2>&1"
        ;;
    
    workflow)
        name="${2:?Usage: $0 workflow <name>}"
        api "workflows" | jq -r ".data[] | select(.name == \"$name\") | .id" | while read id; do
            api "workflows/$id" | jq '{id, name, active, settings, node_names: [.nodes[].name]}'
        done
        ;;
    
    test)
        msg="${2:-test message $(date +%s)}"
        echo "Sending test webhook..."
        curl -s -X POST "https://$N8N_HOST/webhook/$WEBHOOK_PATH" \
            -H "Content-Type: application/json" \
            -d "{\"event_type\": \"message\", \"body\": {\"content\": \"$msg\", \"guild_id\": \"test\", \"channel_id\": \"test\", \"message_id\": \"$(date +%s)\", \"author\": {\"login\": \"debug\"}, \"timestamp\": \"$(date -Iseconds)\"}}"
        echo ""
        sleep 2
        echo "Latest execution:"
        api "executions?limit=1" | jq '.data[0] | {id, status, mode}'
        ;;
    
    ssh)
        shift
        ssh_retry "$@"
        ;;
    
    help|*)
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  executions [limit]    - List recent executions"
        echo "  execution <id>        - Get execution details with error"
        echo "  events [limit]        - List recent events from DB"
        echo "  logs [lines]          - Get n8n container logs"
        echo "  workflow <name>       - Get workflow details"
        echo "  test [message]        - Send test webhook"
        echo "  ssh <command>         - Run command via SSH with retry"
        ;;
esac
