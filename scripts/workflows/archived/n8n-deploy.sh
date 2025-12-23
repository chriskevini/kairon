#!/bin/bash
# n8n-deploy.sh - Deploy workflows to dev, test, then prod
#
# Usage:
#   ./scripts/workflows/n8n-deploy.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-$REPO_ROOT/n8n-workflows}"

# Environment configuration
N8N_DEV_URL="${N8N_DEV_URL:-http://localhost:5679}"
N8N_PROD_URL="${N8N_PROD_URL:-http://localhost:5678}"
N8N_DEV_API_KEY="${N8N_DEV_API_KEY:-}"
N8N_PROD_API_KEY="${N8N_PROD_API_KEY:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# Check prerequisites
if [ -z "$N8N_DEV_API_KEY" ]; then
    log_error "N8N_DEV_API_KEY not set"
    exit 1
fi

if [ -z "$N8N_PROD_API_KEY" ]; then
    log_error "N8N_PROD_API_KEY not set"
    exit 1
fi

# Deploy to a specific environment
deploy_to_env() {
    local env_name="$1"
    local api_url="$2"
    local api_key="$3"
    
    echo ""
    echo "=========================================="
    echo "DEPLOYING TO ${env_name^^}"
    echo "=========================================="
    echo ""
    log_info "Target: $api_url"
    log_info "Source: $WORKFLOW_DIR"
    echo ""
    
    # Pass 1: Deploy workflows
    log_info "Pass 1: Deploying workflows..."
    
    REMOTE_WORKFLOWS=$(curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=100" | jq -r '.data')
    
    if [ -z "$REMOTE_WORKFLOWS" ] || [ "$REMOTE_WORKFLOWS" = "null" ]; then
        log_error "Failed to fetch workflows from $api_url"
        return 1
    fi
    
    declare -A WORKFLOW_IDS=()
    if [ "$REMOTE_WORKFLOWS" != "[]" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            id=$(echo "$line" | jq -r '.id')
            name=$(echo "$line" | jq -r '.name')
            [ "$id" != "null" ] && [ "$name" != "null" ] && WORKFLOW_IDS["$name"]="$id"
        done < <(echo "$REMOTE_WORKFLOWS" | jq -c '.[]')
    fi
    
    log_info "Found ${#WORKFLOW_IDS[@]} existing workflows"
    
    CREATED=0
    UPDATED=0
    FAILED=0
    
    for json_file in "$WORKFLOW_DIR"/*.json; do
        [ -f "$json_file" ] || continue
        
        name=$(jq -r '.name' "$json_file")
        if [ -z "$name" ] || [ "$name" = "null" ]; then
            log_warn "Skipping $(basename "$json_file"): missing 'name' field"
            continue
        fi
        
        cleaned=$(jq '{name: .name, nodes: .nodes, connections: .connections, settings: (.settings // {})}' "$json_file")
        existing_id="${WORKFLOW_IDS[$name]:-}"
        
        if [ -n "$existing_id" ]; then
            result=$(echo "$cleaned" | curl -s -X PUT \
                -H "X-N8N-API-KEY: $api_key" \
                -H "Content-Type: application/json" \
                "$api_url/api/v1/workflows/$existing_id" \
                -d @-)
            
            if echo "$result" | jq -e '.id' > /dev/null 2>&1; then
                UPDATED=$((UPDATED + 1))
            else
                log_error "Failed to update: $name"
                FAILED=$((FAILED + 1))
            fi
        else
            result=$(echo "$cleaned" | curl -s -X POST \
                -H "X-N8N-API-KEY: $api_key" \
                -H "Content-Type: application/json" \
                "$api_url/api/v1/workflows" \
                -d @-)
            
            new_id=$(echo "$result" | jq -r '.id // empty')
            if [ -n "$new_id" ]; then
                CREATED=$((CREATED + 1))
                WORKFLOW_IDS["$name"]="$new_id"
            else
                log_error "Failed to create: $name"
                FAILED=$((FAILED + 1))
            fi
        fi
    done
    
    log_success "Pass 1: $CREATED created, $UPDATED updated, $FAILED failed"
    [ $FAILED -gt 0 ] && return 1
    
    # Pass 2: Fix workflow ID references
    log_info "Pass 2: Fixing workflow ID references..."
    
    CURRENT_WORKFLOWS=$(curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=100" | jq -r '.data')
    WORKFLOW_NAME_TO_ID=$(echo "$CURRENT_WORKFLOWS" | jq -r 'map({(.name): .id}) | add')
    
    FIXED=0
    for workflow_name in $(echo "$WORKFLOW_NAME_TO_ID" | jq -r 'keys[]'); do
        workflow_id=$(echo "$WORKFLOW_NAME_TO_ID" | jq -r ".[\"$workflow_name\"]")
        workflow_json=$(curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows/$workflow_id")
        
        if ! echo "$workflow_json" | jq -e '.nodes[] | select(.type == "n8n-nodes-base.executeWorkflow")' > /dev/null 2>&1; then
            continue
        fi
        
        updated_json=$(echo "$workflow_json" | jq --argjson map "$WORKFLOW_NAME_TO_ID" '
            .nodes |= map(
                if .type == "n8n-nodes-base.executeWorkflow" then
                    if .parameters.workflowId.cachedResultName and $map[.parameters.workflowId.cachedResultName] then
                        .parameters.workflowId.value = $map[.parameters.workflowId.cachedResultName] |
                        .parameters.workflowId.cachedResultUrl = ("/workflow/" + $map[.parameters.workflowId.cachedResultName])
                    else
                        .
                    end
                else
                    .
                end
            )
        ')
        
        update_payload=$(echo "$updated_json" | jq '{name, nodes, connections, settings}')
        result=$(echo "$update_payload" | curl -s -X PUT \
            -H "X-N8N-API-KEY: $api_key" \
            -H "Content-Type: application/json" \
            "$api_url/api/v1/workflows/$workflow_id" \
            -d @-)
        
        if echo "$result" | jq -e '.id' > /dev/null 2>&1; then
            FIXED=$((FIXED + 1))
        fi
    done
    
    log_success "Pass 2: $FIXED workflows fixed"
    
    # Pass 3: Fix credential references (only for local dev with DB access)
    if [ "$env_name" = "dev" ] && command -v docker &> /dev/null; then
        log_info "Pass 3: Fixing credential references..."
        
        CREDENTIAL_MAP=$(docker exec postgres-db psql -U n8n_user -d n8n_chat_memory -t -A -c \
            "SELECT json_object_agg(name, id) FROM credentials_entity;" 2>/dev/null || echo '{}')
        
        if [ "$CREDENTIAL_MAP" != "{}" ] && [ -n "$CREDENTIAL_MAP" ]; then
            CRED_FIXED=0
            for workflow_name in $(echo "$WORKFLOW_NAME_TO_ID" | jq -r 'keys[]'); do
                workflow_id=$(echo "$WORKFLOW_NAME_TO_ID" | jq -r ".[\"$workflow_name\"]")
                workflow_json=$(curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows/$workflow_id")
                
                if ! echo "$workflow_json" | jq -e '.nodes[] | select(.credentials)' > /dev/null 2>&1; then
                    continue
                fi
                
                updated_json=$(echo "$workflow_json" | jq --argjson credmap "$CREDENTIAL_MAP" '
                    .nodes |= map(
                        if .credentials then
                            .credentials |= with_entries(
                                .value |= (
                                    if .name and $credmap[.name] then
                                        .id = $credmap[.name]
                                    else
                                        .
                                    end
                                )
                            )
                        else
                            .
                        end
                    )
                ')
                
                update_payload=$(echo "$updated_json" | jq '{name, nodes, connections, settings}')
                result=$(echo "$update_payload" | curl -s -X PUT \
                    -H "X-N8N-API-KEY: $api_key" \
                    -H "Content-Type: application/json" \
                    "$api_url/api/v1/workflows/$workflow_id" \
                    -d @-)
                
                if echo "$result" | jq -e '.id' > /dev/null 2>&1; then
                    CRED_FIXED=$((CRED_FIXED + 1))
                fi
            done
            log_success "Pass 3: $CRED_FIXED credential references fixed"
        else
            log_warn "Pass 3: Skipped (no DB access)"
        fi
    fi
    
    echo ""
    log_success "Deployment to ${env_name^^} complete!"
    return 0
}

# Run smoke tests
run_smoke_tests() {
    local env_name="$1"
    local api_url="$2"
    local api_key="$3"
    
    echo ""
    echo "=========================================="
    echo "SMOKE TESTS - ${env_name^^}"
    echo "=========================================="
    echo ""
    
    # Test 1: Health check
    log_info "Test 1: Health check..."
    if curl -sf "$api_url/healthz" > /dev/null; then
        log_success "Health check passed"
    else
        log_error "Health check failed"
        return 1
    fi
    
    # Test 2: Verify all workflows deployed
    log_info "Test 2: Verifying workflows..."
    EXPECTED_COUNT=$(find "$WORKFLOW_DIR" -name "*.json" | wc -l)
    ACTUAL_COUNT=$(curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=100" | jq -r '.data | length')
    
    if [ "$ACTUAL_COUNT" -ge "$EXPECTED_COUNT" ]; then
        log_success "Found $ACTUAL_COUNT workflows (expected $EXPECTED_COUNT)"
    else
        log_error "Only found $ACTUAL_COUNT workflows (expected $EXPECTED_COUNT)"
        return 1
    fi
    
    # Test 3: Verify critical workflows exist
    log_info "Test 3: Verifying critical workflows..."
    CRITICAL_WORKFLOWS=("Route_Event" "Query_DB" "Handle_Error")
    for wf in "${CRITICAL_WORKFLOWS[@]}"; do
        if curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=100" | jq -e ".data[] | select(.name == \"$wf\")" > /dev/null; then
            log_success "$wf exists"
        else
            log_error "$wf not found"
            return 1
        fi
    done
    
    # Test 4: Check for workflow reference errors
    log_info "Test 4: Checking workflow references..."
    WORKFLOWS_JSON=$(curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=100" | jq -r '.data')
    WORKFLOW_NAMES=$(echo "$WORKFLOWS_JSON" | jq -r '.[].name')
    
    ERROR_COUNT=0
    for wf_id in $(echo "$WORKFLOWS_JSON" | jq -r '.[].id'); do
        wf_json=$(curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows/$wf_id")
        
        # Check for PLACEHOLDER IDs
        if echo "$wf_json" | jq -e '.nodes[] | select(.parameters.workflowId.value == "PLACEHOLDER_WILL_BE_FIXED_BY_DEPLOY")' > /dev/null 2>&1; then
            wf_name=$(echo "$wf_json" | jq -r '.name')
            log_error "$wf_name has unfixed placeholder IDs"
            ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
    done
    
    if [ $ERROR_COUNT -eq 0 ]; then
        log_success "No workflow reference errors found"
    else
        log_error "Found $ERROR_COUNT workflows with errors"
        return 1
    fi
    
    echo ""
    log_success "All smoke tests passed for ${env_name^^}!"
    return 0
}

# Main deployment flow
main() {
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║   N8N Workflow Deployment Pipeline     ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    
    # Step 1: Deploy to DEV
    if ! deploy_to_env "dev" "$N8N_DEV_URL" "$N8N_DEV_API_KEY"; then
        log_error "DEV deployment failed"
        exit 1
    fi
    
    # Step 2: Run DEV smoke tests
    if ! run_smoke_tests "dev" "$N8N_DEV_URL" "$N8N_DEV_API_KEY"; then
        log_error "DEV smoke tests failed"
        exit 1
    fi
    
    # Step 3: Prompt for PROD deployment
    echo ""
    echo "=========================================="
    log_success "DEV deployment and tests passed!"
    echo "=========================================="
    echo ""
    read -p "Deploy to PRODUCTION? (yes/no): " -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_warn "Production deployment cancelled"
        exit 0
    fi
    
    # Step 4: Deploy to PROD
    if ! deploy_to_env "prod" "$N8N_PROD_URL" "$N8N_PROD_API_KEY"; then
        log_error "PROD deployment failed"
        exit 1
    fi
    
    # Step 5: Run PROD smoke tests
    if ! run_smoke_tests "prod" "$N8N_PROD_URL" "$N8N_PROD_API_KEY"; then
        log_error "PROD smoke tests failed"
        log_warn "Consider rolling back PROD"
        exit 1
    fi
    
    # Success!
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║   DEPLOYMENT SUCCESSFUL! 🎉            ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    log_success "DEV: $N8N_DEV_URL"
    log_success "PROD: $N8N_PROD_URL"
    echo ""
}

main "$@"
