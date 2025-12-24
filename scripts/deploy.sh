#!/bin/bash
# deploy.sh - Deploy workflows to dev and prod with testing
#
# This is the MAIN ENTRY POINT for n8n workflow deployment.
# Use this for CI/CD and manual deployments.
#
# Architecture:
#   - This script orchestrates the deployment pipeline
#   - For dev: 2-pass deployment with transform_for_dev.py
#   - For prod: delegates to n8n-push-prod.sh (3-pass deployment with ID fixing)
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
    echo -n "STAGE 1: Deploy to DEV... "
    
    if [ -z "${N8N_DEV_API_KEY:-}" ]; then
        echo "❌ FAILED (N8N_DEV_API_KEY not set)"
        exit 1
    fi
    
    local API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
    local API_KEY="$N8N_DEV_API_KEY"
    
    # Check if dev stack is running
    if ! curl -s -o /dev/null -w "" "$API_URL/" 2>/dev/null; then
        echo "❌ FAILED (Dev n8n not responding at $API_URL)"
        exit 1
    fi
    
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    
    # Capture output for diagnostics
    local OUTPUT_FILE=$(mktemp)
    trap "rm -rf $TEMP_DIR $OUTPUT_FILE" EXIT
    
    # Wrap actual deployment in a block to capture output
    {
        # Get IDs upfront for ID remapping
        DEV_WORKFLOW_IDS=$(curl -s -H "X-N8N-API-KEY: $API_KEY" \
            "$API_URL/api/v1/workflows?limit=100" | \
            jq -c '[.data[]? | {(.name): .id}] | add // {}')
        
        PROD_API_URL="${N8N_API_URL:-http://localhost:5678}"
        PROD_API_KEY="${N8N_API_KEY:-}"
        
        if [ -n "$PROD_API_KEY" ] && [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
            PROD_WORKFLOW_IDS=$(ssh "$N8N_DEV_SSH_HOST" \
                "source /opt/n8n-docker-caddy/.env && curl -s -H \"X-N8N-API-KEY: \$N8N_API_KEY\" '$PROD_API_URL/api/v1/workflows?limit=100'" | \
                jq -c '[.data[]? | {(.name): .id}] | add // {}')
            
            WORKFLOW_ID_REMAP=$(echo "$PROD_WORKFLOW_IDS" "$DEV_WORKFLOW_IDS" | \
                jq -sc '.[0] as $prod | .[1] as $dev | 
                    [$prod | to_entries[] | {(.value): $dev[.key]}] | 
                    add // {}')
        else
            WORKFLOW_ID_REMAP='{}'
        fi

        # Single pass transformation & push
        for workflow in "$WORKFLOW_DIR"/*.json; do
            [ -f "$workflow" ] || continue
            filename=$(basename "$workflow")
            workflow_name=$(basename "$workflow" .json)
            WORKFLOW_NAME="$workflow_name" WORKFLOW_ID_REMAP="$WORKFLOW_ID_REMAP" python3 "$TRANSFORM_SCRIPT" < "$workflow" > "$TEMP_DIR/$filename"
        done
        
        if [ -d "$WORKFLOW_DEV_DIR" ]; then
            for workflow in "$WORKFLOW_DEV_DIR"/*.json; do
                [ -f "$workflow" ] || continue
                filename=$(basename "$workflow")
                cp "$workflow" "$TEMP_DIR/$filename"
            done
        fi
        
        WORKFLOW_DIR="$TEMP_DIR" N8N_API_URL="$API_URL" N8N_API_KEY="$API_KEY" \
            "$SCRIPT_DIR/workflows/n8n-push-local.sh" > "$OUTPUT_FILE" 2>&1
    } || {
        echo "❌ FAILED"
        echo "----------------------------------------"
        cat "$OUTPUT_FILE"
        echo "----------------------------------------"
        return 1
    }
    
    echo "✅ PASSED"
}

# --- COMPREHENSIVE FUNCTIONAL TESTS ---
run_functional_tests() {
    echo -n "STAGE 2: Functional Tests... "

    if [ ! -f "$REPO_ROOT/tools/test-all-paths.sh" ]; then
        echo "⚠️  tools/test-all-paths.sh not found. Skipping."
        return 0
    fi

    # Capture output for diagnostics
    local TEST_OUTPUT_FILE=$(mktemp)
    trap "rm -f $TEST_OUTPUT_FILE" RETURN

    # Run the comprehensive end-to-end test script against the dev environment
    # Tests all 40+ execution paths with database verification
    if "$REPO_ROOT/tools/test-all-paths.sh" --dev --quick --verify-db > "$TEST_OUTPUT_FILE" 2>&1; then
        echo "✅ PASSED"
        return 0
    else
        echo "❌ FAILED"
        echo "----------------------------------------"
        cat "$TEST_OUTPUT_FILE"
        echo "----------------------------------------"
        return 1
    fi
}

# --- PROD DEPLOYMENT ---
deploy_prod() {
    echo -n "STAGE 3: Deploy to PROD... "
    
    if [ -z "${N8N_API_KEY:-}" ]; then
        echo "❌ FAILED (N8N_API_KEY not set)"
        exit 1
    fi
    
    # Capture output for diagnostics
    local OUTPUT_FILE=$(mktemp)
    trap "rm -f $OUTPUT_FILE" EXIT
    
    {
        # Determine if we're on the remote server or local machine
        if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
            # Sync files quietly
            rsync -az --delete \
                --exclude '.git' \
                "$REPO_ROOT/n8n-workflows/" \
                "$N8N_DEV_SSH_HOST:/opt/kairon/n8n-workflows/"
            
            rsync -az \
                "$SCRIPT_DIR/workflows/n8n-push-prod.sh" \
                "$N8N_DEV_SSH_HOST:/opt/kairon/scripts/workflows/"
            
            ssh "$N8N_DEV_SSH_HOST" "cd /opt/kairon && \
                export \$(grep -E '^(N8N_API_KEY|N8N_API_URL)=' /opt/n8n-docker-caddy/.env) && \
                WORKFLOW_DIR='/opt/kairon/n8n-workflows' \
                bash /opt/kairon/scripts/workflows/n8n-push-prod.sh" > "$OUTPUT_FILE" 2>&1
        else
            N8N_API_URL="${N8N_API_URL:-http://localhost:5678}" \
            N8N_API_KEY="$N8N_API_KEY" \
            WORKFLOW_DIR="$WORKFLOW_DIR" \
                "$SCRIPT_DIR/workflows/n8n-push-prod.sh" > "$OUTPUT_FILE" 2>&1
        fi
    } || {
        echo "❌ FAILED"
        echo "----------------------------------------"
        cat "$OUTPUT_FILE"
        echo "----------------------------------------"
        return 1
    }
    
    echo "✅ PASSED"
}

# --- UNIT TESTS ---
run_unit_tests() {
    echo -n "STAGE 0: Unit Tests... "

    # Run only fast structural tests - functional testing done by smoke tests
    local structural_output

    structural_output=$(python3 "$SCRIPT_DIR/workflows/unit_test_framework.py" --all 2>&1) || {
        echo "❌ FAILED"
        echo "----------------------------------------"
        echo "$structural_output"
        echo "----------------------------------------"
        return 1
    }

    echo "✅ PASSED"
}

# --- MAIN ---
setup_ssh_tunnel

case "$TARGET" in
    dev)
        run_unit_tests || exit 1
        deploy_dev
        run_functional_tests
        ;;
    prod)
        run_unit_tests || exit 1
        deploy_prod
        ;;
    all|"")
        run_unit_tests || exit 1
        deploy_dev
        if run_functional_tests; then
            deploy_prod
        else
            echo ""
            echo "========================================"
            echo "PROD DEPLOYMENT SKIPPED - Functional tests failed"
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
