#!/bin/bash
# Kairon Operations - Unified remote operations tool
# Supports both dev and prod environments via --dev/--prod flags
# Uses rdev under the hood for robust SSH connection management

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Track SSH tunnel PID for cleanup
SSH_TUNNEL_PID=""

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

# Source shared utilities if available
if [ -f ~/.local/share/remote-dev/lib/json-helpers.sh ]; then
    source ~/.local/share/remote-dev/lib/json-helpers.sh
fi

if [ -f ~/.local/share/remote-dev/lib/credential-helper.sh ]; then
    source ~/.local/share/remote-dev/lib/credential-helper.sh
fi

# ============================================================================
# ENVIRONMENT SETUP
# ============================================================================
ENVIRONMENT="prod"  # default to prod

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --dev) ENVIRONMENT="dev"; shift ;;
        --prod) ENVIRONMENT="prod"; shift ;;
        *) break ;;
    esac
done

# Initialize credentials based on environment
init_environment() {
    case "$ENVIRONMENT" in
        dev)
            if [ -z "${N8N_DEV_API_KEY:-}" ]; then
                error "Dev environment not configured"
                error "Set N8N_DEV_API_KEY in .env file"
                error "See .env.example for required dev variables"
                exit 1
            fi
            export CRED_API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
            export CRED_API_KEY="${N8N_DEV_API_KEY:-}"
            export CRED_CONTAINER_DB="${CONTAINER_DB_DEV:-postgres-dev}"
            export CRED_DB_NAME="${DB_NAME_DEV:-kairon_dev}"
            export CRED_DB_USER="${DB_USER_DEV:-n8n_user}"
            export CRED_SSH_HOST="${N8N_DEV_SSH_HOST:-}"
            ;;
        prod)
            if [ -z "${N8N_API_KEY:-}" ]; then
                error "Production environment not configured"
                error "Set N8N_API_KEY in .env file"
                exit 1
            fi
            export CRED_API_URL="${N8N_API_URL:-http://localhost:5678}"
            export CRED_API_KEY="${N8N_API_KEY:-}"
            export CRED_CONTAINER_DB="${CONTAINER_DB:-postgres-db}"
            export CRED_DB_NAME="${DB_NAME:-kairon}"
            export CRED_DB_USER="${DB_USER:-n8n_user}"
            export CRED_SSH_HOST=""
            ;;
    esac
}

# Check if we're in the right directory
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    error "Not in kairon project root (no .env found)"
    error "Current dir: $PROJECT_ROOT"
    exit 1
fi

# Load environment variables from .env
set -a
source "$PROJECT_ROOT/.env"
set +a

# Initialize credentials AFTER loading .env
init_environment

# Cleanup function for SSH tunnel
cleanup_ssh_tunnel() {
    if [ -n "$SSH_TUNNEL_PID" ]; then
        kill "$SSH_TUNNEL_PID" 2>/dev/null || true
    fi
}

# Set up SSH tunnel for dev environment if needed
if [ "$ENVIRONMENT" = "dev" ] && [ -n "$CRED_SSH_HOST" ]; then
    if ! curl -s --connect-timeout 1 http://localhost:5679/ > /dev/null 2>&1; then
        info "Opening SSH tunnel to $CRED_SSH_HOST..."
        ssh -f -N -L 5679:localhost:5679 "$CRED_SSH_HOST" 2>/dev/null || {
            error "Failed to open SSH tunnel to $CRED_SSH_HOST"
            exit 1
        }
        
        # Find the SSH tunnel PID for cleanup
        sleep 1
        SSH_TUNNEL_PID=$(ps aux | grep "[s]sh.*5679:localhost:5679.*$CRED_SSH_HOST" | awk '{print $2}' | head -1)
        
        # Set trap for cleanup
        trap cleanup_ssh_tunnel EXIT INT TERM
    fi
fi

# Change to project root for rdev to work
cd "$PROJECT_ROOT"

# Verify rdev is available
if ! command -v rdev &>/dev/null; then
    error "rdev not found in PATH"
    error "Install rdev first (should be at ~/.local/bin/rdev)"
    exit 1
fi

# Determine if we should use local or remote execution
# For dev with SSH host: use local curl via SSH tunnel (port forwarding)
# For prod: always use rdev for remote execution
use_local() {
    [ "$ENVIRONMENT" = "dev" ]
}

get_api_key() {
    if use_local; then
        echo "$CRED_API_KEY"
    else
        rdev exec 'source ~/kairon/.env 2>/dev/null && echo "$N8N_API_KEY"' 2>/dev/null || echo "$CRED_API_KEY"
    fi
}

execute_remote() {
    if use_local; then
        bash -c "$*" 2>/dev/null || eval "$@"
    else
        rdev exec "$@"
    fi
}

execute_db() {
    if use_local; then
        docker exec -i "$CRED_CONTAINER_DB" psql -U "$CRED_DB_USER" -d "$CRED_DB_NAME" -t -c "$@" 2>/dev/null || \
            docker exec "$CRED_CONTAINER_DB" psql -U "$CRED_DB_USER" -d "$CRED_DB_NAME" -c "$@"
    else
        rdev db "$@"
    fi
}

# ============================================================================
# FUNCTION: status - Complete system status
# ============================================================================
cmd_status() {
    local env_label
    if [ "$ENVIRONMENT" = "dev" ]; then
        env_label="[DEV]"
    else
        env_label="[PROD]"
    fi
    
    info "Checking system status $env_label..."
    echo ""
    
    echo "=== Docker Containers ==="
    execute_remote 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -10'
    echo ""
    
    echo "=== Discord Relay ==="
    execute_remote 'systemctl status kairon-relay.service --no-pager | head -15' 2>/dev/null || warning "Discord relay service not found"
    echo ""
    
    echo "=== Database Health (Last 24 Hours) ==="
    execute_db "
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
    execute_db "
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
    
    local api_key
    api_key=$(get_api_key)
    
    if [ -z "$api_key" ]; then
        error "Could not get N8N_API_KEY"
        exit 1
    fi
    
    local url="$CRED_API_URL/api/v1/workflows"
    execute_remote "curl -s -H 'X-N8N-API-KEY: $api_key' '$url'" | \
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
    
    local api_key
    api_key=$(get_api_key)
    
    if [ -z "$api_key" ]; then
        error "Could not get N8N_API_KEY"
        exit 1
    fi
    
    execute_remote "curl -s -H 'X-N8N-API-KEY: $api_key' '$CRED_API_URL/api/v1/workflows/$workflow_id'"
}

# ============================================================================
# FUNCTION: backup - Backup all workflows and database
# ============================================================================
cmd_backup() {
    local backup_dir="$PROJECT_ROOT/backups/$(date +%Y%m%d-%H%M)"
    mkdir -p "$backup_dir/workflows" "$backup_dir/state"
    
    info "Creating backup in $backup_dir"
    
    local api_key
    api_key=$(get_api_key)
    
    if [ -z "$api_key" ]; then
        error "Could not get N8N_API_KEY"
        exit 1
    fi
    
    # Get workflow list
    info "Fetching workflow list..."
    local workflow_data
    workflow_data=$(execute_remote "curl -s -H 'X-N8N-API-KEY: $api_key' '$CRED_API_URL/api/v1/workflows'")
    
    echo "$workflow_data" > "$backup_dir/state/workflows.json"
    
    # Extract each workflow
    local workflow_count=0
    echo "$workflow_data" | jq -r '.data[]? | "\(.id)|\(.name)"' | while IFS='|' read -r id name; do
        local safe_name
        safe_name=$(echo "$name" | tr '/' '_' | tr ' ' '_' | sed 's/[^a-zA-Z0-9_-]/_/g' | tr -s '_')
        info "Backing up: $name"
        execute_remote "curl -s -H 'X-N8N-API-KEY: $api_key' '$CRED_API_URL/api/v1/workflows/$id'" | \
            jq '.' > "$backup_dir/workflows/${safe_name}.json"
        workflow_count=$((workflow_count + 1))
    done
    
    # Backup database
    info "Backing up database..."
    if use_local; then
        docker exec "$CRED_CONTAINER_DB" pg_dump -U "$CRED_DB_USER" "$CRED_DB_NAME" > "$backup_dir/kairon.sql" 2>/dev/null || {
            error "Failed to backup database locally"
        }
    else
        execute_db --backup > /dev/null 2>&1 || {
            execute_remote "docker exec $CRED_CONTAINER_DB pg_dump -U $CRED_DB_USER $CRED_DB_NAME" > "$backup_dir/kairon.sql"
        }
    fi
    
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
    
    execute_db "$query"
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
    
    local api_key
    api_key=$(get_api_key)
    
    if [ -z "$api_key" ]; then
        error "Could not get N8N_API_KEY"
        exit 1
    fi
    
    echo ""
    echo "API Key: ${api_key:0:20}..."
    echo ""
    echo "API URL: $CRED_API_URL"
    echo ""
    
    info "Testing GET /api/v1/workflows..."
    local response
    response=$(execute_remote "curl -s -w '\n%{http_code}' -H 'X-N8N-API-KEY: $api_key' '$CRED_API_URL/api/v1/workflows'")
    
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
  $0 [OPTIONS] <command> [args]
  $0 --dev <command> [args]
  $0 --prod <command> [args]

Options:
  --dev     Use development environment (local n8n on port 5679)
  --prod    Use production environment (default, remote server)

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
  # Production (default - connects to remote server)
  $0 status
  $0 db-query "SELECT COUNT(*) FROM events;"
  $0 n8n-list
  $0 backup

  # Development (connects to local n8n on port 5679)
  $0 --dev status
  $0 --dev db-query "SELECT COUNT(*) FROM events;"
  $0 --dev n8n-list

Environment Variables (from .env):
  N8N_DEV_API_URL, N8N_DEV_API_KEY - Dev n8n credentials
  N8N_API_URL, N8N_API_KEY         - Prod n8n credentials

Note: This tool uses 'rdev' for production operations.
For dev, commands run directly on localhost.
EOF
}

main() {
    local cmd="${1:-}"
    shift 2>/dev/null || true
    
    # Show environment context
    if [ "$ENVIRONMENT" = "dev" ]; then
        echo -e "${YELLOW}🔧 Using DEVELOPMENT environment${NC}" >&2
    fi
    
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
