#!/bin/bash
# deploy.sh - Deploy workflows to dev and prod with testing
#
# Usage:
#   ./scripts/deploy.sh           # Full pipeline: dev → test → prod
#   ./scripts/deploy.sh dev       # Deploy to dev only + run smoke tests
#   ./scripts/deploy.sh prod      # Deploy to prod only (no tests)
#
# Prerequisites:
#   - Dev: docker-compose.dev.yml running on server
#   - N8N_DEV_API_KEY and N8N_API_KEY set in .env
#   - SSH access to remote server (N8N_DEV_SSH_HOST in .env)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi
if [ -f /opt/n8n-docker-caddy/.env ]; then
    set -a
    source /opt/n8n-docker-caddy/.env
    set +a
fi

TARGET="${1:-all}"  # Default to full pipeline
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"
WORKFLOW_DEV_DIR="$REPO_ROOT/n8n-workflows-dev"
TRANSFORM_SCRIPT="$SCRIPT_DIR/transform_for_dev.py"

# --- SSH TUNNEL SETUP ---
setup_ssh_tunnel() {
    if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        if ! curl -s --connect-timeout 1 http://localhost:5679/ > /dev/null 2>&1; then
            echo "Opening SSH tunnel to $N8N_DEV_SSH_HOST..."
            ssh -f -N -L 5679:localhost:5679 -L 5678:localhost:5678 "$N8N_DEV_SSH_HOST" 2>/dev/null || {
                echo "Error: Failed to open SSH tunnel to $N8N_DEV_SSH_HOST"
                exit 1
            }
            sleep 1
        fi
    fi
}

# --- DEV DEPLOYMENT ---
deploy_dev() {
    echo "========================================"
    echo "STAGE 1: Deploy to DEV"
    echo "========================================"
    echo ""
    
    if [ -z "${N8N_DEV_API_KEY:-}" ]; then
        echo "Error: N8N_DEV_API_KEY not set"
        exit 1
    fi
    
    local API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
    local API_KEY="$N8N_DEV_API_KEY"
    local PROD_API_URL="${N8N_API_URL:-http://localhost:5678}"
    local PROD_API_KEY="${N8N_API_KEY:-}"
    
    # Check if dev stack is running
    if ! curl -s -o /dev/null -w "" "$API_URL/" 2>/dev/null; then
        echo "Error: Dev n8n not responding at $API_URL"
        echo "Start it with: cd /opt/n8n-docker-caddy && docker compose -f docker-compose.dev.yml up -d"
        exit 1
    fi
    
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    
    # --- PASS 1: Initial transform and push ---
    echo "Pass 1: Initial deployment..."
    echo ""
    echo "Transforming workflows for dev environment..."
    for workflow in "$WORKFLOW_DIR"/*.json; do
        [ -f "$workflow" ] || continue
        filename=$(basename "$workflow")
        python3 "$TRANSFORM_SCRIPT" < "$workflow" > "$TEMP_DIR/$filename"
        echo "   Transformed: $filename"
    done
    
    # Copy dev-only workflows
    if [ -d "$WORKFLOW_DEV_DIR" ]; then
        for workflow in "$WORKFLOW_DEV_DIR"/*.json; do
            [ -f "$workflow" ] || continue
            filename=$(basename "$workflow")
            cp "$workflow" "$TEMP_DIR/$filename"
            echo "   Copied (dev-only): $filename"
        done
    fi
    
    echo ""
    echo "Pushing to dev n8n (pass 1)..."
    WORKFLOW_DIR="$TEMP_DIR" N8N_API_URL="$API_URL" N8N_API_KEY="$API_KEY" \
        "$SCRIPT_DIR/workflows/n8n-push-local.sh"
    
    # --- PASS 2: Fetch IDs and re-push with correct workflow references ---
    echo ""
    echo "Pass 2: Remapping workflow IDs..."
    
    DEV_WORKFLOW_IDS=$(curl -s -H "X-N8N-API-KEY: $API_KEY" \
        "$API_URL/api/v1/workflows?limit=100" | \
        jq -c '[.data[] | {(.name): .id}] | add // {}')
    
    echo "   Found dev workflow IDs: $(echo "$DEV_WORKFLOW_IDS" | jq 'keys | length') workflows"
    
    if [ -n "$PROD_API_KEY" ] && [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        PROD_WORKFLOW_IDS=$(ssh "$N8N_DEV_SSH_HOST" \
            "curl -s -H 'X-N8N-API-KEY: $PROD_API_KEY' '$PROD_API_URL/api/v1/workflows?limit=100'" | \
            jq -c '[.data[] | {(.name): .id}] | add // {}')
        
        echo "   Found prod workflow IDs: $(echo "$PROD_WORKFLOW_IDS" | jq 'keys | length') workflows"
        
        WORKFLOW_ID_REMAP=$(echo "$PROD_WORKFLOW_IDS" "$DEV_WORKFLOW_IDS" | \
            jq -sc '.[0] as $prod | .[1] as $dev | 
                [$prod | to_entries[] | {(.value): $dev[.key]}] | 
                add // {}')
        
        echo "   Built ID remap: $(echo "$WORKFLOW_ID_REMAP" | jq 'keys | length') mappings"
    else
        WORKFLOW_ID_REMAP='{}'
    fi
    
    rm -f "$TEMP_DIR"/*.json
    
    for workflow in "$WORKFLOW_DIR"/*.json; do
        [ -f "$workflow" ] || continue
        filename=$(basename "$workflow")
        WORKFLOW_ID_REMAP="$WORKFLOW_ID_REMAP" python3 "$TRANSFORM_SCRIPT" < "$workflow" > "$TEMP_DIR/$filename"
    done
    
    if [ -d "$WORKFLOW_DEV_DIR" ]; then
        for workflow in "$WORKFLOW_DEV_DIR"/*.json; do
            [ -f "$workflow" ] || continue
            filename=$(basename "$workflow")
            cp "$workflow" "$TEMP_DIR/$filename"
        done
    fi
    
    echo ""
    echo "Pushing to dev n8n (pass 2 - with correct workflow IDs)..."
    WORKFLOW_DIR="$TEMP_DIR" N8N_API_URL="$API_URL" N8N_API_KEY="$API_KEY" \
        "$SCRIPT_DIR/workflows/n8n-push-local.sh"
    
    echo ""
    echo "DEV deployment complete"
}

# --- SMOKE TESTS ---
run_smoke_tests() {
    echo ""
    echo "========================================"
    echo "STAGE 2: Smoke Tests"
    echo "========================================"
    echo ""
    
    local API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
    local API_KEY="$N8N_DEV_API_KEY"
    
    SMOKE_TEST_ID=$(curl -s -H "X-N8N-API-KEY: $API_KEY" \
        "$API_URL/api/v1/workflows" | \
        jq -r '.data[] | select(.name == "Smoke_Test") | .id')
    
    if [ -z "$SMOKE_TEST_ID" ] || [ "$SMOKE_TEST_ID" == "null" ]; then
        echo "Warning: Smoke_Test workflow not found in dev n8n"
        echo "Skipping smoke tests"
        return 0
    fi
    
    # Activate the workflow
    curl -s -X POST \
        -H "X-N8N-API-KEY: $API_KEY" \
        "$API_URL/api/v1/workflows/$SMOKE_TEST_ID/activate" > /dev/null
    
    echo "Invoking smoke test webhook..."
    RESULT=$(curl -s -X POST \
        --max-time 60 \
        -H "Content-Type: application/json" \
        "$API_URL/webhook/smoke-test" \
        -d '{}')
    
    if [ -z "$RESULT" ]; then
        echo "FAILED: No response from smoke test"
        return 1
    fi
    
    if ! echo "$RESULT" | jq -e '.' > /dev/null 2>&1; then
        echo "FAILED: Invalid JSON response"
        echo "$RESULT"
        return 1
    fi
    
    if echo "$RESULT" | jq -e '.success == true' > /dev/null 2>&1; then
        echo ""
        echo "SMOKE TESTS PASSED"
        echo "$RESULT" | jq -r '"  Run: \(.run_id)"'
        echo "$RESULT" | jq -r '"  Tests: \(.summary.passed)/\(.summary.total) passed"'
        echo ""
        echo "$RESULT" | jq -r '.tests[] | "  \(if .passed then "✓" else "✗" end) \(.name): \(.details)"'
        return 0
    else
        echo ""
        echo "SMOKE TESTS FAILED"
        echo "$RESULT" | jq -r '.tests[] | "  \(if .passed then "✓" else "✗" end) \(.name): \(.details)"' 2>/dev/null || echo "$RESULT"
        return 1
    fi
}

# --- PROD DEPLOYMENT ---
deploy_prod() {
    echo ""
    echo "========================================"
    echo "STAGE 3: Deploy to PROD"
    echo "========================================"
    echo ""
    
    if [ -z "${N8N_API_KEY:-}" ]; then
        echo "Error: N8N_API_KEY not set"
        exit 1
    fi
    
    # Use rdev which handles SSH-based API access
    if ! command -v rdev &> /dev/null; then
        echo "Error: rdev not found. Install from ~/.local/bin/rdev"
        exit 1
    fi
    
    echo "Pushing workflows to prod n8n via rdev..."
    rdev n8n push
    
    echo ""
    echo "PROD deployment complete"
}

# --- MAIN ---
setup_ssh_tunnel

case "$TARGET" in
    dev)
        deploy_dev
        run_smoke_tests
        ;;
    prod)
        deploy_prod
        ;;
    all|"")
        deploy_dev
        if run_smoke_tests; then
            deploy_prod
        else
            echo ""
            echo "========================================"
            echo "PROD DEPLOYMENT SKIPPED - Tests failed"
            echo "========================================"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 [dev|prod|all]"
        echo "  dev  - Deploy to dev + run smoke tests"
        echo "  prod - Deploy to prod only"
        echo "  all  - Full pipeline: dev → test → prod (default)"
        exit 1
        ;;
esac

echo ""
echo "========================================"
echo "DEPLOYMENT COMPLETE"
echo "========================================"
