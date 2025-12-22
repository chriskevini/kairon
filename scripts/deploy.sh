#!/bin/bash
# deploy.sh - Deploy workflows to dev or prod with testing
#
# Usage:
#   ./scripts/deploy.sh dev    # Transform + deploy to dev + run smoke tests
#   ./scripts/deploy.sh prod   # Deploy to prod as-is (not yet implemented)
#
# Prerequisites:
#   - Dev: docker-compose.dev.yml running on server
#   - N8N_DEV_API_KEY set in .env
#   - N8N_DEV_SSH_HOST set in .env (if running from a different machine)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables from repo .env first, then server .env
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

TARGET="${1:-dev}"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"
WORKFLOW_DEV_DIR="$REPO_ROOT/n8n-workflows-dev"
TRANSFORM_SCRIPT="$SCRIPT_DIR/transform_for_dev.py"

# --- CONFIGURATION ---
if [ "$TARGET" == "prod" ]; then
    echo "Prod deployment not yet implemented in this script"
    echo "Use the existing manual process for now"
    exit 1
else
    if [ -z "${N8N_DEV_API_KEY:-}" ]; then
        echo "Error: N8N_DEV_API_KEY not set"
        echo "Add it to .env or export it"
        exit 1
    fi
    
    # Set up SSH tunnels if N8N_DEV_SSH_HOST is configured
    if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        # Dev tunnel (5679)
        if ! curl -s --connect-timeout 1 http://localhost:5679/ > /dev/null 2>&1; then
            echo "Opening SSH tunnel to $N8N_DEV_SSH_HOST..."
            ssh -f -N -L 5679:localhost:5679 -L 5678:localhost:5678 "$N8N_DEV_SSH_HOST" 2>/dev/null || {
                echo "Error: Failed to open SSH tunnel to $N8N_DEV_SSH_HOST"
                echo "Make sure you can SSH to this host without a password prompt"
                exit 1
            }
            # Give tunnel a moment to establish
            sleep 1
        fi
    fi
    
    API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
    API_KEY="$N8N_DEV_API_KEY"
    PROD_API_URL="${N8N_API_URL:-http://localhost:5678}"
    PROD_API_KEY="${N8N_API_KEY:-}"
    echo "Deploying to DEV ($API_URL)"
fi

echo "   Workflow source: $WORKFLOW_DIR"
echo ""

# --- DEV DEPLOYMENT ---
if [ "$TARGET" == "dev" ]; then
    # Check if dev stack is running
    if ! curl -s -o /dev/null -w "" "$API_URL/" 2>/dev/null; then
        echo "Error: Dev n8n not responding at $API_URL"
        echo "Start it with: cd /opt/n8n-docker-caddy && docker compose -f docker-compose.dev.yml up -d"
        exit 1
    fi
    
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    
    # --- PASS 1: Initial transform and push (creates workflows, gets IDs) ---
    echo "Pass 1: Initial deployment..."
    echo ""
    
    # Transform workflows for dev (mock external calls, convert webhooks)
    # First pass: no ID remapping yet
    echo "Transforming workflows for dev environment..."
    for workflow in "$WORKFLOW_DIR"/*.json; do
        [ -f "$workflow" ] || continue
        filename=$(basename "$workflow")
        python3 "$TRANSFORM_SCRIPT" < "$workflow" > "$TEMP_DIR/$filename"
        echo "   Transformed: $filename"
    done
    
    # Copy dev-only workflows (no transformation needed, they're already dev-specific)
    if [ -d "$WORKFLOW_DEV_DIR" ]; then
        for workflow in "$WORKFLOW_DEV_DIR"/*.json; do
            [ -f "$workflow" ] || continue
            filename=$(basename "$workflow")
            cp "$workflow" "$TEMP_DIR/$filename"
            echo "   Copied (dev-only): $filename"
        done
    fi
    
    # Push transformed workflows to dev (creates any missing workflows)
    echo ""
    echo "Pushing to dev n8n (pass 1)..."
    WORKFLOW_DIR="$TEMP_DIR" N8N_API_URL="$API_URL" N8N_API_KEY="$API_KEY" \
        "$SCRIPT_DIR/workflows/n8n-push-local.sh"
    
    # --- PASS 2: Fetch IDs and re-push with correct workflow references ---
    echo ""
    echo "Pass 2: Remapping workflow IDs..."
    
    # Fetch workflow name -> ID mapping from dev n8n
    DEV_WORKFLOW_IDS=$(curl -s -H "X-N8N-API-KEY: $API_KEY" \
        "$API_URL/api/v1/workflows?limit=100" | \
        jq -c '[.data[] | {(.name): .id}] | add // {}')
    
    echo "   Found dev workflow IDs: $(echo "$DEV_WORKFLOW_IDS" | jq 'keys | length') workflows"
    
    # Fetch workflow name -> ID mapping from prod n8n (via remote SSH to avoid tunnel auth issues)
    if [ -n "$PROD_API_KEY" ] && [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        PROD_WORKFLOW_IDS=$(ssh "$N8N_DEV_SSH_HOST" \
            "curl -s -H 'X-N8N-API-KEY: $PROD_API_KEY' '$PROD_API_URL/api/v1/workflows?limit=100'" | \
            jq -c '[.data[] | {(.name): .id}] | add // {}')
        
        echo "   Found prod workflow IDs: $(echo "$PROD_WORKFLOW_IDS" | jq 'keys | length') workflows"
        
        # Build prod ID -> dev ID mapping by matching names
        # { "prodId1": "devId1", "prodId2": "devId2", ... }
        WORKFLOW_ID_REMAP=$(echo "$PROD_WORKFLOW_IDS" "$DEV_WORKFLOW_IDS" | \
            jq -sc '.[0] as $prod | .[1] as $dev | 
                [$prod | to_entries[] | {(.value): $dev[.key]}] | 
                add // {}')
        
        echo "   Built ID remap: $(echo "$WORKFLOW_ID_REMAP" | jq 'keys | length') mappings"
    else
        echo "   Warning: N8N_API_KEY not set, skipping workflow ID remapping"
        WORKFLOW_ID_REMAP='{}'
    fi
    
    # Re-transform with ID remapping
    rm -f "$TEMP_DIR"/*.json
    
    for workflow in "$WORKFLOW_DIR"/*.json; do
        [ -f "$workflow" ] || continue
        filename=$(basename "$workflow")
        WORKFLOW_ID_REMAP="$WORKFLOW_ID_REMAP" python3 "$TRANSFORM_SCRIPT" < "$workflow" > "$TEMP_DIR/$filename"
    done
    
    # Copy dev-only workflows again
    if [ -d "$WORKFLOW_DEV_DIR" ]; then
        for workflow in "$WORKFLOW_DEV_DIR"/*.json; do
            [ -f "$workflow" ] || continue
            filename=$(basename "$workflow")
            cp "$workflow" "$TEMP_DIR/$filename"
        done
    fi
    
    # Push again with correct IDs
    echo ""
    echo "Pushing to dev n8n (pass 2 - with correct workflow IDs)..."
    WORKFLOW_DIR="$TEMP_DIR" N8N_API_URL="$API_URL" N8N_API_KEY="$API_KEY" \
        "$SCRIPT_DIR/workflows/n8n-push-local.sh"
    
    # Run smoke tests
    echo ""
    echo "Running smoke tests..."
    
    # Find Smoke_Test workflow ID
    SMOKE_TEST_ID=$(curl -s -H "X-N8N-API-KEY: $API_KEY" \
        "$API_URL/api/v1/workflows" | \
        jq -r '.data[] | select(.name == "Smoke_Test") | .id')
    
    if [ -z "$SMOKE_TEST_ID" ] || [ "$SMOKE_TEST_ID" == "null" ]; then
        echo "Warning: Smoke_Test workflow not found in dev n8n"
        echo "Create it manually in the dev n8n UI, then re-run deploy"
        echo ""
        echo "Deployment complete (smoke tests skipped)"
        exit 0
    fi
    
    # Activate the workflow (required for webhook to work)
    ACTIVATE_RESULT=$(curl -s -X POST \
        -H "X-N8N-API-KEY: $API_KEY" \
        "$API_URL/api/v1/workflows/$SMOKE_TEST_ID/activate")
    
    if ! echo "$ACTIVATE_RESULT" | jq -e '.active == true' > /dev/null 2>&1; then
        echo "Warning: Could not activate Smoke_Test workflow"
        echo "$ACTIVATE_RESULT" | jq '.' 2>/dev/null || echo "$ACTIVATE_RESULT"
        echo ""
        echo "Deployment complete (smoke tests skipped)"
        exit 0
    fi
    
    # Execute smoke test via webhook with timeout
    echo "   Invoking smoke test webhook..."
    RESULT=$(curl -s -X POST \
        --max-time 60 \
        -H "Content-Type: application/json" \
        "$API_URL/webhook/smoke-test" \
        -d '{}')
    
    # Check if curl succeeded
    if [ -z "$RESULT" ]; then
        echo "FAILED: No response from smoke test (timeout or connection error)"
        exit 1
    fi
    
    # Check if response is valid JSON
    if ! echo "$RESULT" | jq -e '.' > /dev/null 2>&1; then
        echo "FAILED: Smoke test returned invalid JSON"
        echo "Raw response: $RESULT"
        exit 1
    fi
    
    # Check result
    if echo "$RESULT" | jq -e '.success == true' > /dev/null 2>&1; then
        echo ""
        echo "========================================"
        echo "SMOKE TESTS PASSED"
        echo "========================================"
        echo "$RESULT" | jq -r '"Run: \(.run_id)"' || echo "Run: unknown"
        echo "$RESULT" | jq -r '"Tests: \(.summary.passed)/\(.summary.total) passed"' || echo "Tests: unknown"
        echo ""
        echo "Test Results:"
        echo "$RESULT" | jq -r '.tests[] | "  \(if .passed then "✓" else "✗" end) \(.name): \(.details)"' || {
            echo "  (could not parse individual test results)"
        }
    else
        echo ""
        echo "========================================"
        echo "SMOKE TESTS FAILED"
        echo "========================================"
        
        # Try to parse structured response
        if echo "$RESULT" | jq -e '.tests' > /dev/null 2>&1; then
            echo "$RESULT" | jq -r '"Run: \(.run_id // "unknown")"' || echo "Run: unknown"
            echo "$RESULT" | jq -r '"Tests: \(.summary.passed // 0)/\(.summary.total // 0) passed"' || echo "Tests: unknown"
            echo ""
            echo "Test Results:"
            echo "$RESULT" | jq -r '.tests[] | "  \(if .passed then "✓" else "✗" end) \(.name): \(.details)"' || {
                echo "  (could not parse individual test results)"
            }
        else
            # Raw output if not structured
            echo "Raw response:"
            echo "$RESULT" | jq '.' 2>/dev/null || echo "$RESULT"
        fi
        exit 1
    fi
fi

echo ""
echo "========================================"
echo "DEPLOYMENT COMPLETE: $TARGET"
echo "========================================"
