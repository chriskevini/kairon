#!/bin/bash
# Kairon Operations - Unified remote operations tool
# Uses rdev under the hood for robust SSH connection management

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

success() {
    echo -e "${GREEN}✓${NC} $*"
}

error() {
    echo -e "${RED}✗${NC} $*" >&2
}

warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

# Check if we're in the right directory
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    error "Not in kairon project root (no .env found)"
    error "Current dir: $PROJECT_ROOT"
    exit 1
fi

# Change to project root for rdev to work
cd "$PROJECT_ROOT"

# Verify rdev is available
if ! command -v rdev &>/dev/null; then
    error "rdev not found in PATH"
    error "Install rdev first (should be at ~/.local/bin/rdev)"
    exit 1
fi

# ============================================================================
# FUNCTION: status - Complete system status
# ============================================================================
cmd_status() {
    info "Checking system status..."
    echo ""
    
    echo "=== Docker Containers ==="
    rdev exec 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -10'
    echo ""
    
    echo "=== Discord Relay ==="
    rdev exec 'systemctl status kairon-relay.service --no-pager | head -15'
    echo ""
    
    echo "=== Database Health (Last 24 Hours) ==="
    rdev db "
        SELECT 
            'Events' as metric, 
            COUNT(*)::text as count,
            TO_CHAR(MAX(received_at), 'YYYY-MM-DD HH24:MI:SS UTC') as latest
        FROM events WHERE received_at > NOW() - INTERVAL '24 hours'
        UNION ALL
        SELECT 
            'Traces',
            COUNT(*)::text,
            TO_CHAR(MAX(created_at), 'YYYY-MM-DD HH24:MI:SS UTC')
        FROM traces WHERE created_at > NOW() - INTERVAL '24 hours'
        UNION ALL
        SELECT 
            'Projections',
            COUNT(*)::text,
            TO_CHAR(MAX(created_at), 'YYYY-MM-DD HH24:MI:SS UTC')
        FROM projections WHERE created_at > NOW() - INTERVAL '24 hours';
    "
    echo ""
    
    echo "=== Data Pipeline Health ==="
    rdev db "
        WITH metrics AS (
            SELECT
                (SELECT COUNT(*) FROM events WHERE received_at > NOW() - INTERVAL '1 hour') as events_1h,
                (SELECT COUNT(*) FROM traces WHERE created_at > NOW() - INTERVAL '1 hour') as traces_1h,
                (SELECT COUNT(*) FROM events e WHERE received_at > NOW() - INTERVAL '1 hour' 
                    AND NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id)) as events_without_traces
        )
        SELECT * FROM metrics;
    " 2>/dev/null || warning "Could not check data pipeline (this is OK if n8n is down)"
    
    success "Status check complete"
}

# ============================================================================
# FUNCTION: n8n-list - List all workflows
# ============================================================================
cmd_n8n_list() {
    info "Fetching workflows from n8n..."
    
    # Get API key from server
    API_KEY=$(rdev exec 'grep "^N8N_API_KEY=" ~/kairon/.env | cut -d= -f2')
    
    if [ -z "$API_KEY" ]; then
        error "Could not get N8N_API_KEY from server"
        exit 1
    fi
    
    # Fetch workflows
    rdev exec "curl -s -H 'X-N8N-API-KEY: $API_KEY' 'http://localhost:5678/api/v1/workflows'" | \
        jq -r '.data[]? | "\(.name)|\(.id)|\(.active)"' | \
        column -t -s'|' -N "NAME,ID,ACTIVE" || {
        error "Failed to fetch workflows from n8n API"
        exit 1
    }
}

# ============================================================================
# FUNCTION: n8n-get - Get workflow JSON by ID
# ============================================================================
cmd_n8n_get() {
    local workflow_id="$1"
    
    if [ -z "$workflow_id" ]; then
        error "Workflow ID required"
        echo "Usage: $0 n8n-get <workflow-id>"
        exit 1
    fi
    
    info "Fetching workflow $workflow_id..."
    
    API_KEY=$(rdev exec 'grep "^N8N_API_KEY=" ~/kairon/.env | cut -d= -f2')
    
    if [ -z "$API_KEY" ]; then
        error "Could not get N8N_API_KEY from server"
        exit 1
    fi
    
    rdev exec "curl -s -H 'X-N8N-API-KEY: $API_KEY' 'http://localhost:5678/api/v1/workflows/$workflow_id'"
}

# ============================================================================
# FUNCTION: backup - Backup all workflows and database
# ============================================================================
cmd_backup() {
    local backup_dir="$PROJECT_ROOT/backups/$(date +%Y%m%d-%H%M)"
    mkdir -p "$backup_dir/workflows" "$backup_dir/state"
    
    info "Creating backup in $backup_dir"
    
    # Get API key
    API_KEY=$(rdev exec 'grep "^N8N_API_KEY=" ~/kairon/.env | cut -d= -f2')
    
    if [ -z "$API_KEY" ]; then
        error "Could not get N8N_API_KEY from server"
        exit 1
    fi
    
    # Get workflow list
    info "Fetching workflow list..."
    local workflow_data
    workflow_data=$(rdev exec "curl -s -H 'X-N8N-API-KEY: $API_KEY' 'http://localhost:5678/api/v1/workflows'")
    
    echo "$workflow_data" > "$backup_dir/state/workflows.json"
    
    # Extract each workflow
    local workflow_count=0
    echo "$workflow_data" | jq -r '.data[]? | "\(.id)|\(.name)"' | while IFS='|' read -r id name; do
        info "Backing up: $name"
        rdev exec "curl -s -H 'X-N8N-API-KEY: $API_KEY' 'http://localhost:5678/api/v1/workflows/$id'" | \
            jq '.' > "$backup_dir/workflows/${name}.json"
        workflow_count=$((workflow_count + 1))
    done
    
    # Backup database
    info "Backing up database..."
    rdev db --backup > /dev/null 2>&1 || {
        # Fallback if rdev db --backup doesn't work
        rdev exec "docker exec postgres-db pg_dump -U n8n_user kairon" > "$backup_dir/kairon.sql"
    }
    
    # Save system state
    info "Saving system state..."
    cmd_status > "$backup_dir/state/system-status.txt" 2>&1
    
    success "Backup complete: $backup_dir"
    echo ""
    echo "Contents:"
    ls -lh "$backup_dir/workflows" | tail -n +2 | wc -l | xargs echo "  Workflows:"
    du -sh "$backup_dir" | awk '{print "  Total size: " $1}'
}

# ============================================================================
# FUNCTION: db-query - Run SQL query
# ============================================================================
cmd_db_query() {
    local query="$1"
    
    if [ -z "$query" ]; then
        error "SQL query required"
        echo "Usage: $0 db-query \"SELECT * FROM events LIMIT 5;\""
        exit 1
    fi
    
    rdev db "$query"
}

# ============================================================================
# FUNCTION: verify - Run full system verification
# ============================================================================
cmd_verify() {
    info "Running full system verification..."
    echo ""
    
    # Use verify-system.sh if it exists
    if [ -f "$SCRIPT_DIR/verify-system.sh" ]; then
        "$SCRIPT_DIR/verify-system.sh"
    else
        # Fallback to status
        cmd_status
    fi
}

# ============================================================================
# FUNCTION: test-api - Test n8n API connectivity
# ============================================================================
cmd_test_api() {
    info "Testing n8n API connectivity..."
    
    API_KEY=$(rdev exec 'grep "^N8N_API_KEY=" ~/kairon/.env | cut -d= -f2')
    
    if [ -z "$API_KEY" ]; then
        error "Could not get N8N_API_KEY from server"
        exit 1
    fi
    
    echo ""
    echo "API Key: ${API_KEY:0:20}..."
    echo ""
    
    info "Testing GET /api/v1/workflows..."
    local response
    response=$(rdev exec "curl -s -w '\n%{http_code}' -H 'X-N8N-API-KEY: $API_KEY' 'http://localhost:5678/api/v1/workflows'")
    
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | head -n -1)
    
    echo "HTTP Status: $http_code"
    
    if [ "$http_code" = "200" ]; then
        local count=$(echo "$body" | jq -r '.data | length')
        success "API working! Found $count workflows"
    else
        error "API returned $http_code"
        echo "Response: $body"
        exit 1
    fi
}

# ============================================================================
# MAIN
# ============================================================================
show_help() {
    cat <<EOF
Kairon Operations Tool - Unified operations using rdev

Usage:
  $0 <command> [args]

Commands:
  status              Show complete system status
  db-query <SQL>      Run SQL query on kairon database
  n8n-list            List all workflows with IDs
  n8n-get <ID>        Get workflow JSON by ID
  backup              Backup all workflows and database
  verify              Run full system verification
  test-api            Test n8n API connectivity
  help                Show this help

Examples:
  $0 status
  $0 db-query "SELECT COUNT(*) FROM events;"
  $0 n8n-list
  $0 backup

Note: This tool uses 'rdev' for all remote operations.
Make sure rdev is installed and .env is configured.
EOF
}

main() {
    local cmd="${1:-}"
    shift 2>/dev/null || true
    
    case "$cmd" in
        status)
            cmd_status "$@"
            ;;
        db-query)
            cmd_db_query "$@"
            ;;
        n8n-list)
            cmd_n8n_list "$@"
            ;;
        n8n-get)
            cmd_n8n_get "$@"
            ;;
        backup)
            cmd_backup "$@"
            ;;
        verify)
            cmd_verify "$@"
            ;;
        test-api)
            cmd_test_api "$@"
            ;;
        help|--help|-h|"")
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo "Run '$0 help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
