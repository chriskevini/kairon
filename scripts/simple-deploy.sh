#!/bin/bash
# Simple deployment pipeline for n8n workflows
# 
# This replaces the complex 2,150+ line deployment system with a simple, robust approach:
# - Single codebase (no transformations)
# - Direct workflow testing
# - Straightforward deployment
#
# Usage:
#   ./scripts/simple-deploy.sh [dev|prod|all]
#
# Prerequisites:
#   - .env file with N8N_API_KEY and N8N_API_URL
#   - n8n instance running and accessible
#   - PostgreSQL database accessible

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# Configuration
TARGET="${1:-all}"
N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_info() {
    echo -e "${YELLOW}→ $1${NC}"
}

# Validate JSON syntax
validate_json() {
    log_info "Validating workflow JSON syntax..."
    
    local errors=0
    for workflow in "$WORKFLOW_DIR"/*.json; do
        [ -f "$workflow" ] || continue
        
        if ! jq empty "$workflow" 2>/dev/null; then
            log_error "Invalid JSON: $(basename "$workflow")"
            errors=$((errors + 1))
        fi
    done
    
    if [ $errors -gt 0 ]; then
        log_error "Found $errors JSON syntax errors"
        return 1
    fi
    
    log_success "JSON validation passed"
    return 0
}

# Deploy workflows to n8n
deploy_workflows() {
    local api_url="$1"
    local api_key="$2"
    
    log_info "Deploying workflows to $api_url..."
    
    # Check API key is provided
    if [ -z "$api_key" ]; then
        log_error "N8N_API_KEY not set. Set N8N_API_KEY or N8N_DEV_API_KEY in .env"
        echo ""
        echo "Example .env:"
        echo "  N8N_API_KEY=your-prod-key"
        echo "  N8N_DEV_API_KEY=your-dev-key"
        return 1
    fi
    
    # Check n8n is accessible
    if ! curl -s -f -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=1" > /dev/null 2>&1; then
        log_error "Cannot connect to n8n at $api_url"
        return 1
    fi
    
    # Get existing workflows
    local existing_workflows
    existing_workflows=$(curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=100" | jq -r '.data[] | "\(.name)|\(.id)"')
    
    # Deploy each workflow
    local deployed=0
    local updated=0
    local errors=0
    
    for workflow in "$WORKFLOW_DIR"/*.json; do
        [ -f "$workflow" ] || continue
        
        local wf_name
        wf_name=$(jq -r '.name' "$workflow")
        
        # Check if workflow exists
        local existing_id
        existing_id=$(echo "$existing_workflows" | grep "^${wf_name}|" | cut -d'|' -f2 || echo "")
        
        # Prepare workflow payload (remove id, pinData, versionId)
        local payload
        payload=$(jq 'del(.id, .pinData, .versionId)' "$workflow")
        
        if [ -n "$existing_id" ]; then
            # Update existing workflow
            if curl -s -f -X PUT \
                -H "X-N8N-API-KEY: $api_key" \
                -H "Content-Type: application/json" \
                -d "$payload" \
                "$api_url/api/v1/workflows/$existing_id" > /dev/null 2>&1; then
                updated=$((updated + 1))
                echo "  Updated: $wf_name"
            else
                log_error "Failed to update: $wf_name"
                errors=$((errors + 1))
            fi
        else
            # Create new workflow
            if curl -s -f -X POST \
                -H "X-N8N-API-KEY: $api_key" \
                -H "Content-Type: application/json" \
                -d "$payload" \
                "$api_url/api/v1/workflows" > /dev/null 2>&1; then
                deployed=$((deployed + 1))
                echo "  Created: $wf_name"
            else
                log_error "Failed to create: $wf_name"
                errors=$((errors + 1))
            fi
        fi
    done
    
    echo ""
    if [ $errors -eq 0 ]; then
        log_success "Deployment complete: $deployed created, $updated updated"
        return 0
    else
        log_error "Deployment failed: $errors errors"
        return 1
    fi
}

# Run basic tests
run_tests() {
    log_info "Running basic workflow tests..."
    
    # Test 1: Validate all workflows can be parsed
    validate_json || return 1
    
    # Test 2: Check for duplicate workflow names
    local duplicates
    duplicates=$(jq -r '.name' "$WORKFLOW_DIR"/*.json 2>/dev/null | sort | uniq -d)
    if [ -n "$duplicates" ]; then
        log_error "Duplicate workflow names found:"
        echo "$duplicates"
        return 1
    fi
    
    # Test 3: Verify environment variable syntax in workflow parameters
    # Note: Only check node parameters (not jsCode), as JS code can use $env directly
    local invalid_refs
    invalid_refs=$(jq -r '
        .nodes[] | 
        select(.parameters) | 
        .parameters | 
        to_entries[] | 
        select(.key != "jsCode") |
        select(.value | type == "string") | 
        select(.value | contains("$env.") and (contains("={{ $env.") | not)) | 
        "\(.key): \(.value)"
    ' "$WORKFLOW_DIR"/*.json 2>/dev/null || echo "")
    
    if [ -n "$invalid_refs" ]; then
        log_error "Invalid environment variable syntax in parameters (use ={{ \$env.VAR_NAME }})"
        echo "$invalid_refs" | head -5
        return 1
    fi
    
    log_success "All tests passed"
    return 0
}

# Smoke test deployed workflows
smoke_test() {
    local api_url="$1"
    local api_key="$2"
    
    log_info "Running smoke test..."
    
    # Verify workflows are accessible
    local count
    count=$(curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=1" | jq '.data | length')
    
    if [ "$count" -ge 1 ]; then
        log_success "Smoke test passed ($count workflows accessible)"
        return 0
    else
        log_error "Smoke test failed (no workflows accessible)"
        return 1
    fi
}

# Main execution
main() {
    echo "=========================================="
    echo "Simple n8n Workflow Deployment"
    echo "=========================================="
    echo ""
    
    case "$TARGET" in
        validate)
            # Validation only - no deployment
            run_tests
            ;;
            
        dev)
            # Deploy to dev environment
            export N8N_API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
            export N8N_API_KEY="${N8N_DEV_API_KEY:-$N8N_API_KEY}"
            
            run_tests || exit 1
            deploy_workflows "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            smoke_test "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            ;;
            
        prod)
            # Deploy to production
            run_tests || exit 1
            deploy_workflows "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            smoke_test "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            ;;
            
        all)
            # Deploy to both dev and prod
            # First dev
            log_info "Stage 1: Deploy to dev"
            export N8N_API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
            export N8N_API_KEY="${N8N_DEV_API_KEY:-$N8N_API_KEY}"
            
            run_tests || exit 1
            deploy_workflows "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            smoke_test "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            
            echo ""
            log_info "Stage 2: Deploy to production"
            export N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
            export N8N_API_KEY="${N8N_API_KEY}"
            
            deploy_workflows "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            smoke_test "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            ;;
            
        *)
            echo "Usage: $0 [validate|dev|prod|all]"
            echo ""
            echo "Options:"
            echo "  validate - Validate workflows only (no deployment)"
            echo "  dev      - Deploy to dev environment only"
            echo "  prod     - Deploy to production only"
            echo "  all      - Deploy to dev, then production (default)"
            exit 1
            ;;
    esac
    
    echo ""
    echo "=========================================="
    log_success "Deployment complete!"
    echo "=========================================="
}

main
