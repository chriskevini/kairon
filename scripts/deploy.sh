#!/bin/bash
set -euo pipefail

# deploy.sh - Deploy workflows to local or production n8n instance
#
# Usage:
#   ./scripts/deploy.sh           # Deploy to localhost
#   ./scripts/deploy.sh prod      # Deploy to production (remote server)
#
# Prerequisites:
#   - Local: docker-compose.yml with n8n running on port 5679
#   - Prod: N8N_API_KEY set in .env, SSH access to remote server

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

TARGET="${1:-local}"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"
DRY_RUN="${2:-false}"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# --- VALIDATION FUNCTIONS ---

validate_workflow_names() {
    echo "Validating workflow names..."
    local duplicates
    duplicates=$(jq -r '.name' "$WORKFLOW_DIR"/*.json 2>/dev/null | sort | uniq -d)
    
    if [ -n "$duplicates" ]; then
        log_error "Duplicate workflow names found:"
        echo "$duplicates" | sed 's/^/  /'
        return 1
    fi
    
    log_info "Workflow names are unique"
    return 0
}

validate_mode_list_usage() {
    echo "Validating portable workflow references..."
    local test_output
    test_output=$(python3 "$SCRIPT_DIR/testing/test_mode_list_references.py" "$WORKFLOW_DIR" 2>&1)
    
    if echo "$test_output" | grep -q "mode:id"; then
        log_error "Workflows must use mode:list for portability"
        echo "$test_output"
        return 1
    fi
    
    log_info "Workflow references use mode:list"
    return 0
}

validate_workflow_structure() {
    echo "Validating workflow structure..."
    local validation_output
    validation_output=$(bash "$SCRIPT_DIR/workflows/validate_workflows.sh" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "Workflow structure validation failed"
        echo "$validation_output" | sed 's/^/  /'
        return 1
    fi
    
    log_info "Workflow structure is valid"
    return 0
}

validate_workflow_integrity() {
    echo "Validating workflow integrity..."
    local validation_output
    validation_output=$(python3 "$SCRIPT_DIR/validation/workflow_integrity.py" --quiet 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 1 ]; then
        log_error "Workflow integrity issues found"
        python3 "$SCRIPT_DIR/validation/workflow_integrity.py" | sed 's/^/  /'
        return 1
    elif [ $exit_code -eq 2 ]; then
        log_warn "Warnings found (deployment allowed)"
    else
        log_info "Workflow integrity is valid"
    fi
    
    return 0
}

run_unit_tests() {
    echo "Running unit tests..."
    local test_output
    test_output=$(python3 "$SCRIPT_DIR/workflows/unit_test_framework.py" --all 2>&1) || {
        log_error "Unit tests failed"
        echo "$test_output" | sed 's/^/  /'
        return 1
    }
    
    log_info "Unit tests passed"
    return 0
}

# --- DEPLOYMENT FUNCTIONS ---

deploy_to_local() {
    echo ""
    echo "=========================================="
    echo "Deploying to LOCALHOST"
    echo "=========================================="
    echo ""
    
    local API_URL="http://localhost:5679"
    
    # Check n8n is running
    if ! curl -s -o /dev/null -w "" "$API_URL/" 2>/dev/null; then
        log_error "n8n not responding at $API_URL"
        echo ""
        echo "Start n8n with:"
        echo "  docker-compose up -d"
        echo ""
        echo "Wait for n8n to be ready, then retry."
        return 1
    fi
    
    # Set up authentication
    local COOKIE_FILE="/tmp/n8n-local-cookie-$$"
    local N8N_USER="${N8N_DEV_USER:-admin}"
    local N8N_PASSWORD="${N8N_DEV_PASSWORD:-Admin123!}"
    local N8N_EMAIL="${N8N_USER}@example.com"
    
    echo "Setting up authentication..."
    local login_response
    login_response=$(curl -s -c "$COOKIE_FILE" -X POST "$API_URL/rest/login" \
        -H "Content-Type: application/json" \
        -d "{\"emailOrLdapLoginId\":\"$N8N_EMAIL\",\"password\":\"$N8N_PASSWORD\"}")
    
    if ! echo "$login_response" | jq -e '.data' > /dev/null 2>&1; then
        log_error "Login failed - check credentials in .env"
        return 1
    fi
    
    log_info "Authenticated to n8n"
    
    # Deploy workflows
    echo ""
    echo "Pushing workflows..."
    
    if ! WORKFLOW_DIR="$WORKFLOW_DIR" \
        N8N_API_URL="$API_URL" \
        N8N_DEV_COOKIE_FILE="$COOKIE_FILE" \
        "$SCRIPT_DIR/workflows/n8n-push-local.sh"; then
        rm -f "$COOKIE_FILE"
        return 1
    fi
    
    rm -f "$COOKIE_FILE"
    
    log_info "Workflows deployed to localhost"
    echo ""
    echo "Access n8n UI at: http://localhost:5679"
    
    return 0
}

deploy_to_prod() {
    echo ""
    echo "=========================================="
    echo "Deploying to PRODUCTION"
    echo "=========================================="
    echo ""
    
    # Check prerequisites
    if [ -z "${N8N_API_KEY:-}" ]; then
        log_error "N8N_API_KEY not set in .env"
        return 1
    fi
    
    local remote_host="${N8N_DEV_SSH_HOST:-${REMOTE_HOST:-}}"
    if [ -z "$remote_host" ]; then
        log_error "No remote host configured. Set N8N_DEV_SSH_HOST or REMOTE_HOST in .env"
        return 1
    fi
    
    local PROD_API_URL="${N8N_API_URL:-http://localhost:5678}"
    local REMOTE_PATH="${REMOTE_KAIRON_PATH:-/root/kairon}"
    
    echo "Target: $remote_host"
    echo "API URL: $PROD_API_URL"
    echo ""
    
    # Create backup
    if [ -f "$REPO_ROOT/tools/kairon-ops.sh" ]; then
        echo "Creating backup..."
        if ! "$REPO_ROOT/tools/kairon-ops.sh" backup > /tmp/backup.log 2>&1; then
            log_warn "Backup failed - check /tmp/backup.log"
            read -p "Continue anyway? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return 1
            fi
        else
            log_info "Backup created"
        fi
    fi
    
    # Sync workflows to remote
    echo "Syncing workflows to remote..."
    if ! rsync -az --delete \
        --exclude '.git' \
        "$REPO_ROOT/n8n-workflows/" \
        "$remote_host:$REMOTE_PATH/n8n-workflows/"; then
        log_error "Failed to sync workflows"
        return 1
    fi
    
    log_info "Workflows synced"
    
    # Deploy on remote
    echo ""
    echo "Deploying on remote server..."
    if ! ssh "$remote_host" "cd $REMOTE_PATH && \
        set -a && source $REMOTE_PATH/.env && set +a && \
        WORKFLOW_DIR='$REMOTE_PATH/n8n-workflows' \
        bash $REMOTE_PATH/scripts/workflows/n8n-push-prod.sh"; then
        log_error "Remote deployment failed"
        return 1
    fi
    
    log_info "Workflows deployed to production"
    
    # Smoke test
    echo ""
    echo "Running smoke tests..."
    if ! curl -s -X POST "$PROD_API_URL/webhook/${WEBHOOK_PATH:-asoiaf92746087}" \
        -H 'Content-Type: application/json' \
        -d '{"event_type":"message","content":"smoke_test","guild_id":"test","channel_id":"test","message_id":"test","author":{"login":"test"}}' \
        > /dev/null; then
        log_warn "Smoke test failed (webhook not responding)"
    else
        log_info "Smoke test passed"
    fi
    
    return 0
}

# --- MAIN ---

main() {
    echo ""
    echo "=========================================="
    echo "KAIRON DEPLOYMENT"
    echo "=========================================="
    echo ""
    echo "Target: $TARGET"
    echo "Workflow directory: $WORKFLOW_DIR"
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "Mode: DRY RUN (validation only, no deployment)"
    fi
    echo ""
    
    # Validate first
    echo "Validating..."
    echo ""
    validate_workflow_names || exit 1
    validate_mode_list_usage || exit 1
    validate_workflow_structure || exit 1
    validate_workflow_integrity || exit 1
    run_unit_tests || exit 1
    
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo "=========================================="
        echo "VALIDATION COMPLETE (dry run)"
        echo "=========================================="
        echo ""
        exit 0
    fi
    
    echo ""
    
    # Deploy
    case "$TARGET" in
        local)
            deploy_to_local || exit 1
            ;;
        prod)
            deploy_to_prod || exit 1
            ;;
        *)
            echo "Usage: $0 [local|prod] [--dry-run]"
            echo ""
            echo "Commands:"
            echo "  local   - Deploy to localhost (default)"
            echo "  prod    - Deploy to production server"
            echo ""
            echo "Options:"
            echo "  --dry-run - Validate without deploying"
            echo ""
            echo "Configuration:"
            echo "  Local:  docker-compose up -d"
            echo "  Prod:   Set N8N_API_KEY, N8N_DEV_SSH_HOST in .env"
            exit 1
            ;;
    esac
    
    echo ""
    echo "=========================================="
    echo "DEPLOYMENT COMPLETE"
    echo "=========================================="
    echo ""
}

main
