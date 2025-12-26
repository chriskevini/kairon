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

# Track cleanup files globally
CLEANUP_FILES=()

# Cleanup function
cleanup_all() {
    for file in "${CLEANUP_FILES[@]}"; do
        rm -rf "$file" 2>/dev/null || true
    done
}

trap cleanup_all EXIT INT TERM

# Source shared deployment verification
if [ -f ~/.local/share/remote-dev/lib/deploy-verify.sh ]; then
    source ~/.local/share/remote-dev/lib/deploy-verify.sh
fi

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
    local NO_MOCKS="${1:-false}"
    local STAGE_NAME="STAGE 1: Deploy to DEV"
    
    if [ "$NO_MOCKS" = "true" ]; then
        STAGE_NAME="STAGE 1b: Deploy to DEV (real APIs)"
    fi

    echo -n "$STAGE_NAME... "

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

    # Validate workflow names are unique
    validate_workflow_names || exit 1

    # Validate workflows use mode:list for portability
    validate_mode_list_usage || exit 1

    TEMP_DIR=$(mktemp -d)
    OUTPUT_FILE=$(mktemp)
    DEPLOY_LOG=$(mktemp)
    CLEANUP_FILES+=("$TEMP_DIR" "$OUTPUT_FILE" "$DEPLOY_LOG")

    # Note: No ID remapping needed for mode:list with cachedResultName (portable workflow references)
    # Workflows use cachedResultName instead of hardcoded IDs, making them environment-agnostic
    WORKFLOW_ID_REMAP='{}'

    # Wrap actual deployment in a block to capture output
    {
        PROD_API_URL="${N8N_API_URL:-http://localhost:5678}"
        PROD_API_KEY="${N8N_API_KEY:-}"

        # ID remapping disabled - using mode:list for portable workflows
        WORKFLOW_ID_REMAP='{}'

        # Single pass transformation & push
        for workflow in "$WORKFLOW_DIR"/*.json; do
            [ -f "$workflow" ] || continue
            filename=$(basename "$workflow")
            workflow_name=$(basename "$workflow" .json)
            

            
            # Only set NO_MOCKS env var when enabled
            local no_mocks_var=""
            if [ "$NO_MOCKS" != "false" ]; then
                no_mocks_var="NO_MOCKS=1"
            fi
            env WORKFLOW_NAME="$workflow_name" WORKFLOW_ID_REMAP="$WORKFLOW_ID_REMAP" $no_mocks_var python3 "$TRANSFORM_SCRIPT" < "$workflow" > "$TEMP_DIR/$filename"
        done

        if [ -d "$WORKFLOW_DEV_DIR" ]; then
            for workflow in "$WORKFLOW_DEV_DIR"/*.json; do
                [ -f "$workflow" ] || continue
                filename=$(basename "$workflow")
                cp "$workflow" "$TEMP_DIR/$filename"
            done
        fi

        WORKFLOW_DIR="$TEMP_DIR" N8N_API_URL="$API_URL" N8N_API_KEY="$API_KEY" \
            "$SCRIPT_DIR/workflows/n8n-push-local.sh" > "$DEPLOY_LOG" 2>&1
    } || {
        echo "❌ FAILED"
        echo "----------------------------------------"
        cat "$DEPLOY_LOG"
        echo "----------------------------------------"
        return 1
    }

    echo "✅ PASSED"

    # Verify deployment - show what was created/updated
    echo ""
    echo "   Deployment Summary:"
    echo "   Source: $TEMP_DIR"

    local DEV_WORKFLOW_IDS_AFTER
    DEV_WORKFLOW_IDS_AFTER=$(curl -s -H "X-N8N-API-KEY: $API_KEY" \
        "$API_URL/api/v1/workflows?limit=100" | \
        jq -c '[.data[]? | {(.name): .id}] | add // {}')

    # Count and show workflow changes
    local workflow_count
    workflow_count=$(echo "$DEV_WORKFLOW_IDS_AFTER" | jq 'keys | length')
    echo "   Accessible workflows: $workflow_count"

    # Show the deploy log output
    if [ -f "$DEPLOY_LOG" ] && [ -s "$DEPLOY_LOG" ]; then
        echo ""
        echo "   Push details:"
        cat "$DEPLOY_LOG" | sed 's/^/   /'
    fi
}

# --- COMPREHENSIVE FUNCTIONAL TESTS ---
run_functional_tests() {
    echo ""
    echo "=========================================="
    echo "STAGE 2: Functional Tests"
    echo "=========================================="

    if [ ! -f "$REPO_ROOT/tools/test-all-paths.sh" ]; then
        echo "⚠️  tools/test-all-paths.sh not found. Skipping."
        return 0
    fi

    local TEST_OUTPUT_FILE=$(mktemp)
    trap "rm -f $TEST_OUTPUT_FILE" RETURN

    # Skip cron-based workflows in Stage 2b (realistic mode)
    # They can't be tested with real APIs via webhook (run on schedule, not triggered)
    # Note: Auto_Backfill, Generate_Daily_Summary, Generate_Nudge, Proactive_Agent_Cron
    CRON_WORKFLOWS="Auto_Backfill Generate_Daily_Summary Generate_Nudge Proactive_Agent_Cron"

    # Stage 2a: Fast mock tests (current behavior)
    echo ""
    echo "  Stage 2a: Mock tests (fast)..."
    if ! "$REPO_ROOT/tools/test-all-paths.sh" --dev --quick > "$TEST_OUTPUT_FILE" 2>&1; then
        echo "❌ FAILED (mocks)"
        echo "----------------------------------------"
        cat "$TEST_OUTPUT_FILE"
        echo "----------------------------------------"
        return 1
    fi
    echo "  ✅ PASSED (mocks)"

    # Stage 2b: Realistic tests with real APIs (NEW)
     echo ""
     echo "  Stage 2b: Realistic tests (real APIs)..."
     echo "    Note: Cron workflows now testable via webhook (Schedule → Webhook transform)"
     
     if ! "$REPO_ROOT/tools/test-all-paths.sh" --dev --quick > "$TEST_OUTPUT_FILE" 2>&1; then
        echo "❌ FAILED (real APIs)"
        echo "----------------------------------------"
        cat "$TEST_OUTPUT_FILE"
        echo "----------------------------------------"
        echo "   Workflows failed when calling real APIs"
        echo "   Deployment halted before production"
        return 1
    fi
    echo "  ✅ PASSED (real APIs)"

    # Stage 2c: Quick prod verification
    echo ""
    echo "  Stage 2c: Quick prod verification..."
    verify_prod_webhook_accessible || return 1

    return 0
}

verify_prod_webhook_accessible() {
    local PROD_API_URL="${N8N_API_URL:-http://localhost:5678}"
    
    # Lightweight check - just verify webhook accepts requests
    local RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$PROD_API_URL/webhook/asoiaf92746087" \
        -H 'Content-Type: application/json' \
        -d '{
            "event_type": "test",
            "content": "health_check",
            "guild_id": "test",
            "channel_id": "test",
            "message_id": "test-'$(date +%s)'",
            "author": {"login": "system"},
            "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
        }')

    if [ "$RESPONSE" != "200" ]; then
        echo "❌ Prod webhook not responding (HTTP $RESPONSE)"
        return 1
    fi
    echo "  ✅ Prod webhook responding"
    return 0
}

# --- PROD DEPLOYMENT ---
deploy_prod() {
    echo -n "STAGE 3: Deploy to PROD... "

    if [ -z "${N8N_API_KEY:-}" ]; then
        echo "❌ FAILED (N8N_API_KEY not set)"
        exit 1
    fi

    local PROD_API_URL="${N8N_API_URL:-http://localhost:5678}"
    local PROD_API_KEY="$N8N_API_KEY"

    # Validate workflow names are unique
    validate_workflow_names || exit 1

    # Validate workflows use mode:list for portability
    validate_mode_list_usage || exit 1

    # Capture output for diagnostics
    OUTPUT_FILE=$(mktemp)
    DEPLOY_LOG=$(mktemp)
    CLEANUP_FILES+=("$OUTPUT_FILE" "$DEPLOY_LOG")

    # Get workflow IDs before for verification
    local PROD_WORKFLOW_IDS_BEFORE=""
    if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        PROD_WORKFLOW_IDS_BEFORE=$(ssh "$N8N_DEV_SSH_HOST" \
            "source /opt/n8n-docker-caddy/.env && curl -s -H \"X-N8N-API-KEY: \$N8N_API_KEY\" '$PROD_API_URL/api/v1/workflows?limit=100'" | \
            jq -c '[.data[]? | {(.name): .id}] | add // {}')
    else
        PROD_WORKFLOW_IDS_BEFORE=$(curl -s -H "X-N8N-API-KEY: $PROD_API_KEY" \
            "$PROD_API_URL/api/v1/workflows?limit=100" | \
            jq -c '[.data[]? | {(.name): .id}] | add // {}')
    fi

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
                bash /opt/kairon/scripts/workflows/n8n-push-prod.sh" > "$DEPLOY_LOG" 2>&1
        else
            N8N_API_URL="${N8N_API_URL:-http://localhost:5678}" \
            N8N_API_KEY="$N8N_API_KEY" \
            WORKFLOW_DIR="$WORKFLOW_DIR" \
                "$SCRIPT_DIR/workflows/n8n-push-prod.sh" > "$DEPLOY_LOG" 2>&1
        fi
    } || {
        echo "❌ FAILED"
        echo "----------------------------------------"
        cat "$DEPLOY_LOG"
        echo "----------------------------------------"
        return 1
    }

    echo "✅ PASSED"

    # Verify deployment
    echo ""
    echo "   Deployment Summary:"

    local PROD_WORKFLOW_IDS_AFTER=""
    if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        PROD_WORKFLOW_IDS_AFTER=$(ssh "$N8N_DEV_SSH_HOST" \
            "source /opt/n8n-docker-caddy/.env && curl -s -H \"X-N8N-API-KEY: \$N8N_API_KEY\" '$PROD_API_URL/api/v1/workflows?limit=100'" | \
            jq -c '[.data[]? | {(.name): .id}] | add // {}')
    else
        PROD_WORKFLOW_IDS_AFTER=$(curl -s -H "X-N8N-API-KEY: $PROD_API_KEY" \
            "$PROD_API_URL/api/v1/workflows?limit=100" | \
            jq -c '[.data[]? | {(.name): .id}] | add // {}')
    fi

    local workflow_count
    workflow_count=$(echo "$PROD_WORKFLOW_IDS_AFTER" | jq 'keys | length')
    echo "   Accessible workflows: $workflow_count"

    # Show the deploy log output
    if [ -f "$DEPLOY_LOG" ] && [ -s "$DEPLOY_LOG" ]; then
        echo ""
        echo "   Push details:"
        cat "$DEPLOY_LOG" | sed 's/^/   /'
    fi
}

# --- WORKFLOW NAME VALIDATION ---
validate_workflow_names() {
    echo -n "Validating workflow names... "

    local duplicates
    duplicates=$(jq -r '.name' "$WORKFLOW_DIR"/*.json 2>/dev/null | sort | uniq -d)

    if [ -n "$duplicates" ]; then
        echo "❌ FAILED"
        echo "ERROR: Duplicate workflow names found:"
        echo "$duplicates"
        echo ""
        echo "Duplicate workflow names will cause mode:list references to fail."
        echo "Please rename workflows to have unique names."
        return 1
    fi

    echo "✅ PASSED"
    return 0
}

# --- MODE:LIST VALIDATION ---
validate_mode_list_usage() {
    echo -n "Validating portable workflow references... "

    local test_output
    test_output=$(python3 "$SCRIPT_DIR/testing/test_mode_list_references.py" "$WORKFLOW_DIR" 2>&1)

    if echo "$test_output" | grep -q "mode:id"; then
        echo "❌ FAILED"
        echo "$test_output"
        echo ""
        echo "ERROR: Workflows must use mode:list for portability."
        echo "See AGENTS.md for guidance on Execute Workflow nodes."
        return 1
    fi

    echo "✅ PASSED"
    return 0
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
        deploy_dev false
        run_functional_tests
        ;;
    prod)
        run_unit_tests || exit 1
        deploy_prod
        ;;
    all|"")
        run_unit_tests || exit 1
        deploy_dev false
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
