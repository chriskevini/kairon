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

    # Stage 2d: Run Python tag parsing tests
    echo ""
    echo "  Stage 2d: Python tag parsing tests..."
    if ! pytest "$REPO_ROOT/n8n-workflows/tests/test_tag_parsing.py" > /dev/null 2>&1; then
        echo "❌ FAILED (tag parsing)"
        return 1
    fi
    echo "  ✅ PASSED (tag parsing)"
    
    # Stage 1b: Redeploy with real APIs (between test stages)
    echo ""
    echo "  Redeploying workflows for realistic API testing..."
    if ! deploy_dev true; then
        echo "❌ FAILED (redeployment)"
        echo "----------------------------------------"
        cat "$DEPLOY_LOG"
        echo "----------------------------------------"
        return 1
    fi
    echo "  ✅ Redeployment PASSED"
    
    # Stage 2b: Realistic tests with real APIs (NEW)
     echo ""
     echo "  Stage 2b: Realistic tests (real APIs)..."
     echo "    Note: Cron workflows now testable via webhook (Schedule → Webhook transform)"
     
     if ! "$REPO_ROOT/tools/test-all-paths.sh" --dev --quick --no-mocks > "$TEST_OUTPUT_FILE" 2>&1; then
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
    # echo ""
    # echo "  Stage 2c: Quick prod verification..."
    # verify_prod_webhook_accessible || return 1

    return 0
}

verify_prod_webhook_accessible() {
    local PROD_API_URL="${N8N_API_URL:-http://localhost:5678}"
    local SMOKE_TEST_CONTENT="smoke_test_$(date +%s)"
    
    echo "    1. Sending test webhook to Route_Event..."
    local RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$PROD_API_URL/webhook/asoiaf92746087" \
        -H 'Content-Type: application/json' \
        -d "{
            \"event_type\": \"message\",
            \"content\": \"$SMOKE_TEST_CONTENT\",
            \"guild_id\": \"test\",
            \"channel_id\": \"test\",
            \"message_id\": \"smoke-$(date +%s)\",
            \"author\": {\"login\": \"smoke_test\"},
            \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
        }")

    if [ "$RESPONSE" != "200" ]; then
        echo "❌ SMOKE TEST FAILED: Prod webhook not responding (HTTP $RESPONSE)"
        return 1
    fi
    echo "    ✅ Webhook accepted"

    echo "    2. Verifying execution success in n8n..."
    local MAX_RETRIES=5
    local RETRY_COUNT=0
    local EXEC_STATUS=""
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        sleep 2
        local EXEC_DATA=$(curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" \
            "$PROD_API_URL/api/v1/executions?limit=5")
        
        EXEC_STATUS=$(echo "$EXEC_DATA" | jq -r --arg content "$SMOKE_TEST_CONTENT" '
            .data[] | 
            select(.workflowData.name == "Route_Message") | 
            .status
        ' | head -1)
        
        if [ "$EXEC_STATUS" = "success" ]; then
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done

    if [ "$EXEC_STATUS" != "success" ]; then
        echo "❌ SMOKE TEST FAILED: Route_Message execution status: ${EXEC_STATUS:-unknown} (after $MAX_RETRIES retries)"
        return 1
    fi
    echo "    ✅ Execution status: $EXEC_STATUS"

    echo "    3. Verifying event created in database..."
    local EVENT_COUNT
    if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        EVENT_COUNT=$(ssh "$N8N_DEV_SSH_HOST" "docker exec -i ${CONTAINER_DB:-postgres-db} psql -U ${DB_USER:-n8n_user} -d ${DB_NAME:-kairon} -t -c \"SELECT COUNT(*) FROM events WHERE payload->>'content' = '$SMOKE_TEST_CONTENT'\"" | tr -d '[:space:]')
    else
        EVENT_COUNT=$(docker exec -i ${CONTAINER_DB:-postgres-db} psql -U ${DB_USER:-n8n_user} -d ${DB_NAME:-kairon} -t -c "SELECT COUNT(*) FROM events WHERE payload->>'content' = '$SMOKE_TEST_CONTENT'" | tr -d '[:space:]')
    fi

    if [ "$EVENT_COUNT" -lt 1 ]; then
        echo "❌ SMOKE TEST FAILED: Event not found in database"
        return 1
    fi
    echo "    ✅ Event found in database"

    # Cleanup test event
    if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        ssh "$N8N_DEV_SSH_HOST" "docker exec -i ${CONTAINER_DB:-postgres-db} psql -U ${DB_USER:-n8n_user} -d ${DB_NAME:-kairon} -c \"DELETE FROM events WHERE payload->>'content' = '$SMOKE_TEST_CONTENT'\"" > /dev/null
    else
        docker exec -i ${CONTAINER_DB:-postgres-db} psql -U ${DB_USER:-n8n_user} -d ${DB_NAME:-kairon} -c "DELETE FROM events WHERE payload->>'content' = '$SMOKE_TEST_CONTENT'" > /dev/null
    fi

    return 0
}

# --- ROLLBACK ---
rollback_prod() {
    local backup_dir="${1:-${LATEST_DEPLOY_BACKUP:-}}"
    
    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        echo "❌ Rollback failed: No valid backup directory provided or found."
        return 1
    fi

    echo ""
    echo "=========================================="
    echo "ROLLBACK: Restoring from $(basename "$backup_dir")"
    echo "=========================================="
    
    # Pre-flight checks
    if [ -z "${N8N_API_KEY:-}" ]; then
        echo "❌ Rollback failed: N8N_API_KEY not set"
        return 1
    fi

    local PROD_API_URL="${N8N_API_URL:-http://localhost:5678}"
    
    # Check if n8n is responding
    if ! curl -s -f -H "X-N8N-API-KEY: $N8N_API_KEY" "$PROD_API_URL/api/v1/workflows?limit=1" > /dev/null 2>&1; then
        echo "❌ Rollback failed: n8n API not responding at $PROD_API_URL"
        return 1
    fi

    # Database parameters
    local CONTAINER="${CONTAINER_DB:-postgres-db}"
    local DB_USER="${DB_USER:-n8n_user}"
    local DB_NAME="${DB_NAME:-kairon}"
    
    # 1. Restore Database
    if [ -f "$backup_dir/kairon.sql" ]; then
        echo "   Restoring database..."
        if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
            # Remote restore with unique temp file
            local REMOTE_TEMP="/tmp/rollback_$$_$(date +%s).sql"
            if ! scp -q "$backup_dir/kairon.sql" "$N8N_DEV_SSH_HOST:$REMOTE_TEMP"; then
                echo "   ❌ Failed to upload SQL backup"
                return 1
            fi
            
            if ! ssh "$N8N_DEV_SSH_HOST" "docker exec -i $CONTAINER psql -U $DB_USER -d $DB_NAME < $REMOTE_TEMP" > /dev/null 2>&1; then
                echo "   ❌ Database restore failed"
                ssh "$N8N_DEV_SSH_HOST" "rm -f $REMOTE_TEMP" 2>/dev/null || true
                return 1
            fi
            ssh "$N8N_DEV_SSH_HOST" "rm -f $REMOTE_TEMP" 2>/dev/null || true
        else
            # Local restore
            if ! docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" < "$backup_dir/kairon.sql" > /dev/null 2>&1; then
                echo "   ❌ Database restore failed"
                return 1
            fi
        fi
        echo "   ✅ Database restored"
    fi

    # 2. Restore Workflows
    if [ -d "$backup_dir/workflows" ]; then
        echo "   Restoring workflows..."
        
        # Create temporary directory for processed workflows
        local TEMP_WORKFLOW_DIR=$(mktemp -d)
        CLEANUP_FILES+=("$TEMP_WORKFLOW_DIR")
        
        # Strip metadata from backup workflows for n8n-push-prod.sh
        for json_file in "$backup_dir/workflows"/*.json; do
            [ -f "$json_file" ] || continue
            # Keep only name, nodes, connections, settings
            jq '{name, nodes, connections, settings}' "$json_file" > "$TEMP_WORKFLOW_DIR/$(basename "$json_file")"
        done
        
        if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
            # Remote restore via n8n-push-prod.sh
            rsync -az --delete "$TEMP_WORKFLOW_DIR/" "$N8N_DEV_SSH_HOST:/tmp/rollback_workflows/"
            
            if ! ssh "$N8N_DEV_SSH_HOST" "cd /opt/kairon && \
                export \$(grep -E '^(N8N_API_KEY|N8N_API_URL)=' /opt/n8n-docker-caddy/.env) && \
                WORKFLOW_DIR='/tmp/rollback_workflows' \
                bash /opt/kairon/scripts/workflows/n8n-push-prod.sh" > /dev/null 2>&1; then
                echo "   ❌ Workflow restore failed"
                return 1
            fi
            ssh "$N8N_DEV_SSH_HOST" "rm -rf /tmp/rollback_workflows" 2>/dev/null || true
        else
            # Local restore via n8n-push-prod.sh
            if ! N8N_API_URL="${N8N_API_URL:-http://localhost:5678}" \
                N8N_API_KEY="$N8N_API_KEY" \
                WORKFLOW_DIR="$TEMP_WORKFLOW_DIR" \
                "$SCRIPT_DIR/workflows/n8n-push-prod.sh" > /dev/null 2>&1; then
                echo "   ❌ Workflow restore failed"
                return 1
            fi
        fi
        echo "   ✅ Workflows restored"
    fi

    echo ""
    echo "✅ ROLLBACK COMPLETE"
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

    # Create backup before deployment
    echo ""
    echo "   Creating pre-deployment backup..."
    local BACKUP_ID="deploy-$(date +%Y%m%d-%H%M%S)"
    local BACKUP_DIR="$REPO_ROOT/backups/$BACKUP_ID"
    
    if [ -f "$REPO_ROOT/tools/kairon-ops.sh" ]; then
        # Create a specific directory for this deployment backup
        mkdir -p "$BACKUP_DIR"
        
        # We need to temporarily override the backup directory logic in kairon-ops.sh
        # or just let it create its own and we record which one it was.
        # kairon-ops.sh backup creates a directory like backups/YYYYMMDD-HHMM
        
        if ! "$REPO_ROOT/tools/kairon-ops.sh" backup > /tmp/backup_output.log 2>&1; then
            echo "   ⚠️  Backup failed! Please check system status."
            cat /tmp/backup_output.log | sed 's/^/      /'
            read -p "      Continue deployment without backup? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "      Deployment aborted."
                exit 1
            fi
        else
            local LATEST_BACKUP=$(ls -td "$REPO_ROOT/backups"/*/ | head -1)
            echo "   ✅ Backup created: $(basename "$LATEST_BACKUP")"
            export LATEST_DEPLOY_BACKUP="$LATEST_BACKUP"
        fi
    fi

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
        
        if [ -n "${LATEST_DEPLOY_BACKUP:-}" ]; then
            echo "   Deployment failed. Rolling back automatically..."
            rollback_prod "$LATEST_DEPLOY_BACKUP"
        fi
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

    # Run deep smoke tests after production deployment
    echo ""
    echo "   Running post-deployment deep smoke tests..."
    if ! verify_prod_webhook_accessible; then
        if [ -n "${LATEST_DEPLOY_BACKUP:-}" ]; then
            echo "   Smoke tests failed. Rolling back automatically..."
            rollback_prod "$LATEST_DEPLOY_BACKUP"
        fi
        return 1
    fi
    echo "   ✅ Smoke tests passed"
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
        echo "⚠️  Direct production deployment is deprecated. Running full pipeline..."
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
