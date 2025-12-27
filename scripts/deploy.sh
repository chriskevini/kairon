#!/bin/bash
set -euo pipefail

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
#   ./scripts/deploy.sh local     # Set up local dev + deploy + test
#   ./scripts/deploy.sh dev       # Deploy to dev only + run smoke tests
#   ./scripts/deploy.sh prod      # Deploy to prod only (no tests)
#
# Prerequisites:
#   - Local: docker-compose.dev.yml (./scripts/deploy.sh local handles setup)
#   - Dev: docker-compose.dev.yml running on server
#   - Prod: N8N_API_KEY set in .env
#   - Remote: SSH access to remote server (N8N_DEV_SSH_HOST in .env)

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

# --- LOCAL DEV ENVIRONMENT SETUP ---
setup_local_dev() {
    echo ""
    echo "=========================================="
    echo "Setting up local development environment"
    echo "=========================================="
    
    # 1. Check if containers are running
    echo -n "Checking Docker containers... "
    if docker ps | grep -q "n8n-dev-local"; then
        echo "✅ Already running"
    else
        echo "Starting..."
        docker-compose -f "$REPO_ROOT/docker-compose.dev.yml" up -d
        echo "Waiting for services to be ready..."
        
        # Wait for PostgreSQL to be ready
        local max_wait=30
        local wait_count=0
        while [ $wait_count -lt $max_wait ]; do
            if docker exec postgres-dev-local pg_isready -U postgres > /dev/null 2>&1; then
                break
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        if [ $wait_count -ge $max_wait ]; then
            echo "❌ PostgreSQL failed to start"
            exit 1
        fi
        
        # Wait a bit more for n8n
        sleep 5
        echo "✅ Containers started"
    fi
    
    # 2. Check database initialization
    echo -n "Checking database schema... "
    local DB_USER="${DB_USER:-postgres}"
    local DB_NAME="${DB_NAME:-kairon_dev}"
    
    if docker exec postgres-dev-local psql -U "$DB_USER" -d "$DB_NAME" -c "\dt events" 2>/dev/null | grep -q events; then
        echo "✅ Already initialized"
    else
        echo "Initializing..."
        local SCHEMA_OUTPUT=$(mktemp)
        CLEANUP_FILES+=("$SCHEMA_OUTPUT")
        
        if ! docker exec -i postgres-dev-local psql -U "$DB_USER" -d "$DB_NAME" < "$REPO_ROOT/db/schema.sql" > "$SCHEMA_OUTPUT" 2>&1; then
            echo "❌ Schema loading failed"
            echo "----------------------------------------"
            cat "$SCHEMA_OUTPUT"
            echo "----------------------------------------"
            exit 1
        fi
        
        # Check for ROLLBACK in output (indicates transaction failure)
        if grep -q "ROLLBACK" "$SCHEMA_OUTPUT"; then
            echo "❌ Schema loading failed (transaction rolled back)"
            echo "----------------------------------------"
            cat "$SCHEMA_OUTPUT"
            echo "----------------------------------------"
            exit 1
        fi
        
        echo "✅ Schema loaded"
    fi
    
    # 3. Check n8n owner setup and create API key
    echo -n "Checking n8n owner account... "
    local N8N_URL="http://localhost:5679"
    local max_wait=30
    local wait_count=0
    
    # Wait for n8n to be ready
    while [ $wait_count -lt $max_wait ]; do
        if curl -s -o /dev/null -w "" "$N8N_URL/rest/settings" 2>/dev/null; then
            break
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    if [ $wait_count -ge $max_wait ]; then
        echo "❌ n8n failed to start"
        exit 1
    fi
    
    # Check if owner exists
    local settings=$(curl -s "$N8N_URL/rest/settings")
    local show_setup=$(echo "$settings" | jq -r '.data.userManagement.showSetupOnFirstLoad')
    
    local N8N_OWNER_EMAIL="${N8N_DEV_USER:-admin}@example.com"
    local N8N_OWNER_PASSWORD="${N8N_DEV_PASSWORD:-Admin123!}"
    
    if [ "$show_setup" = "true" ]; then
        echo "Creating..."
        
        local setup_result=$(curl -s -X POST "$N8N_URL/rest/owner/setup" \
            -H "Content-Type: application/json" \
            -d "{
                \"email\": \"$N8N_OWNER_EMAIL\",
                \"firstName\": \"Admin\",
                \"lastName\": \"User\",
                \"password\": \"$N8N_OWNER_PASSWORD\"
            }")
        
        if ! echo "$setup_result" | jq -e '.data.id' > /dev/null 2>&1; then
            echo "❌ Failed to create owner account"
            echo "$setup_result" | jq
            exit 1
        fi
        echo "✅ Owner account created"
    else
        echo "✅ Already initialized"
    fi
    
    # Create or retrieve API key for deployments
    echo -n "Checking n8n API key... "
    
    # Login to get session cookie
    local cookie_file="/tmp/n8n-dev-session-$$.txt"
    
    curl -s -c "$cookie_file" -X POST "$N8N_URL/rest/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"emailOrLdapLoginId\": \"$N8N_OWNER_EMAIL\",
            \"password\": \"$N8N_OWNER_PASSWORD\"
        }" > /dev/null
    
    # Export the cookie file path to be used by deployment scripts
    export N8N_DEV_COOKIE_FILE="$cookie_file"
    echo "✅ Authentication configured"
    echo "   Email: $N8N_OWNER_EMAIL"
    echo "   Cookie: $cookie_file"
    echo "   Using session-based authentication"
    
    # 4. Set up n8n credentials for workflows (Postgres, Discord, etc.)
    echo -n "Checking n8n node credentials... "
    setup_n8n_credentials
    echo "✅ Credentials configured"
    
    echo ""
}

# --- N8N NODE CREDENTIAL SETUP ---
# Creates credentials needed for workflows to connect to services (DB, Discord, etc.)
# Uses the same IDs as production so workflows work without modification
setup_n8n_credentials() {
    local DB_USER="${DB_USER:-postgres}"
    local DB_PASSWORD="${DB_PASSWORD:-postgres}"
    local DB_NAME="${DB_NAME:-kairon_dev}"
    local DB_HOST="postgres-dev-local"  # Docker network hostname
    
    # Credential ID that workflows reference (safe to be in version control)
    # This is just an ID reference - actual credentials are stored encrypted in n8n
    local POSTGRES_CRED_ID="${N8N_POSTGRES_CREDENTIAL_ID:-GIpVtzgs3wiCmQBQ}"
    
    # Create credential JSON file
    local CRED_FILE=$(mktemp)
    CLEANUP_FILES+=("$CRED_FILE")
    
    cat > "$CRED_FILE" << EOF
[
  {
    "id": "$POSTGRES_CRED_ID",
    "name": "Postgres account",
    "type": "postgres",
    "data": {
      "host": "$DB_HOST",
      "port": 5432,
      "database": "$DB_NAME",
      "user": "$DB_USER",
      "password": "$DB_PASSWORD",
      "ssl": "disable"
    }
  }
]
EOF
    
    # Copy credential file to container and import
    docker cp "$CRED_FILE" n8n-dev-local:/tmp/credentials.json
    
    # Check if credential already exists with correct ID
    local existing_creds
    existing_creds=$(docker exec n8n-dev-local n8n export:credentials --all 2>&1 | grep -v "Invalid value\|Permissions\|Error tracking" || echo "[]")
    
    if echo "$existing_creds" | jq -e ".[] | select(.id == \"$POSTGRES_CRED_ID\")" > /dev/null 2>&1; then
        # Credential exists - update it by deleting and reimporting
        # (n8n import doesn't update existing credentials)
        docker exec n8n-dev-local sh -c "sqlite3 /home/node/.n8n/database.sqlite \"DELETE FROM credentials_entity WHERE id = '$POSTGRES_CRED_ID';\"" 2>/dev/null || true
    fi
    
    # Import credential
    docker exec n8n-dev-local n8n import:credentials --input=/tmp/credentials.json 2>&1 | grep -v "Invalid value\|Permissions\|Error tracking" || true
    
    # Cleanup temp file in container
    docker exec n8n-dev-local rm -f /tmp/credentials.json 2>/dev/null || true
}

# --- DEV DEPLOYMENT ---
deploy_dev() {
    local NO_MOCKS="${1:-false}"
    local STAGE_NAME="STAGE 1: Deploy to DEV"
    
    if [ "$NO_MOCKS" = "true" ]; then
        STAGE_NAME="STAGE 1b: Deploy to DEV (real APIs)"
    fi

    echo -n "$STAGE_NAME... "

    local API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
    local API_KEY="${N8N_DEV_API_KEY:-}"
    
    # For localhost, cookie-based auth is set up in setup_local_dev()
    if [[ "$API_URL" == http://localhost* ]]; then
        API_KEY=""
    fi

    # Check if dev stack is running
    if ! curl -s -o /dev/null -w "" "$API_URL/" 2>/dev/null; then
        echo "❌ FAILED (Dev n8n not responding at $API_URL)"
        echo ""
        echo "Tip: Run './scripts/deploy.sh local' to set up the local environment"
        exit 1
    fi

    # Validate workflows before deployment
    echo ""
    validate_workflow_names || exit 1
    validate_mode_list_usage || exit 1
    validate_workflow_structure || exit 1

    TEMP_DIR=$(mktemp -d)
    OUTPUT_FILE=$(mktemp)
    DEPLOY_LOG=$(mktemp)
    CLEANUP_FILES+=("$TEMP_DIR" "$OUTPUT_FILE" "$DEPLOY_LOG")

    # Build workflow ID mapping: production ID -> dev ID
    # This is needed because n8n validates Execute Workflow node references exist
    # We map cachedResultName (workflow name) to existing dev workflow ID
    echo "   Building workflow ID mapping..."
    
    # Get existing dev workflow IDs and validate count
    local DEV_WORKFLOW_IDS
    local WORKFLOW_COUNT
    if [ -n "${N8N_DEV_COOKIE_FILE:-}" ] && [ -f "${N8N_DEV_COOKIE_FILE}" ]; then
        local RESPONSE=$(curl -s -b "$N8N_DEV_COOKIE_FILE" "$API_URL/rest/workflows?take=100")
        DEV_WORKFLOW_IDS=$(echo "$RESPONSE" | jq -c '[.data[]? | {(.name): .id}] | add // {}')
        WORKFLOW_COUNT=$(echo "$RESPONSE" | jq '.data | length')
    elif [ -n "${API_KEY:-}" ]; then
        local RESPONSE=$(curl -s -H "X-N8N-API-KEY: $API_KEY" "$API_URL/rest/workflows?take=100")
        DEV_WORKFLOW_IDS=$(echo "$RESPONSE" | jq -c '[.data[]? | {(.name): .id}] | add // {}')
        WORKFLOW_COUNT=$(echo "$RESPONSE" | jq '.data | length')
    else
        DEV_WORKFLOW_IDS='{}'
        WORKFLOW_COUNT=0
    fi
    
    # Warn if approaching or at the 100-workflow limit
    if [ "$WORKFLOW_COUNT" -eq 100 ]; then
        echo ""
        echo "⚠️  WARNING: Exactly 100 workflows detected!"
        echo "   The workflow ID mapping may be incomplete if more workflows exist."
        echo "   Consider implementing pagination in scripts/deploy.sh:325"
        echo ""
    elif [ "$WORKFLOW_COUNT" -gt 90 ]; then
        echo "   Note: $WORKFLOW_COUNT workflows found (approaching 100-workflow limit)"
    fi
    
    # Build mapping from production IDs to dev IDs
    # Parse source workflows to get prod ID -> workflow name mapping
    local WORKFLOW_ID_REMAP='{'
    for workflow in "$WORKFLOW_DIR"/*.json; do
        [ -f "$workflow" ] || continue
        local wf_name=$(jq -r '.name // empty' "$workflow")
        local prod_id=$(jq -r '.id // empty' "$workflow")
        
        if [ -n "$wf_name" ] && [ -n "$prod_id" ]; then
            # Get dev ID for this workflow name
            local dev_id=$(echo "$DEV_WORKFLOW_IDS" | jq -r --arg name "$wf_name" '.[$name] // empty')
            if [ -n "$dev_id" ]; then
                WORKFLOW_ID_REMAP+="\"$prod_id\":\"$dev_id\","
            fi
        fi
        
        # Also check Execute Workflow nodes for their referenced workflow IDs
        # These reference prod IDs via cachedResultName
        while IFS= read -r ref_line; do
            [ -z "$ref_line" ] && continue
            local ref_name=$(echo "$ref_line" | jq -r '.cachedResultName // empty')
            local ref_prod_id=$(echo "$ref_line" | jq -r '.value // empty')
            if [ -n "$ref_name" ] && [ -n "$ref_prod_id" ]; then
                local ref_dev_id=$(echo "$DEV_WORKFLOW_IDS" | jq -r --arg name "$ref_name" '.[$name] // empty')
                if [ -n "$ref_dev_id" ]; then
                    WORKFLOW_ID_REMAP+="\"$ref_prod_id\":\"$ref_dev_id\","
                fi
            fi
        done < <(jq -c '.nodes[]?.parameters.workflowId | select(.__rl == true)' "$workflow" 2>/dev/null)
    done
    # Remove trailing comma and close brace
    WORKFLOW_ID_REMAP="${WORKFLOW_ID_REMAP%,}}"
    
    echo "   ID mapping: $WORKFLOW_ID_REMAP"

    # Wrap actual deployment in a block to capture output
    {
        # Single pass transformation & push
        for workflow in "$WORKFLOW_DIR"/*.json; do
            [ -f "$workflow" ] || continue
            filename=$(basename "$workflow")
            workflow_name=$(basename "$workflow" .json)
            

            
            # Set NO_MOCKS env var when enabled
            if [ "$NO_MOCKS" != "false" ]; then
                export NO_MOCKS=1
            fi
            env WORKFLOW_NAME="$workflow_name" WORKFLOW_ID_REMAP="$WORKFLOW_ID_REMAP" python3 "$TRANSFORM_SCRIPT" < "$workflow" > "$TEMP_DIR/$filename"
        done

        if [ -d "$WORKFLOW_DEV_DIR" ]; then
            for workflow in "$WORKFLOW_DEV_DIR"/*.json; do
                [ -f "$workflow" ] || continue
                filename=$(basename "$workflow")
                cp "$workflow" "$TEMP_DIR/$filename"
            done
        fi

        WORKFLOW_DIR="$TEMP_DIR" N8N_API_URL="$API_URL" N8N_API_KEY="$API_KEY" \
            N8N_DEV_COOKIE_FILE="$N8N_DEV_COOKIE_FILE" \
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

    # Show the deploy log output
    if [ -f "$DEPLOY_LOG" ] && [ -s "$DEPLOY_LOG" ]; then
        echo ""
        echo "   Push details:"
        cat "$DEPLOY_LOG" | sed 's/^/   /'
    fi
    
    # Note: Workflow ID verification removed for local dev (basic auth makes it complex)
    # Stage 2 tests will catch any deployment issues
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
    echo "  Stage 2d: Python unit tests..."
    if ! pytest "$REPO_ROOT/n8n-workflows/tests/" -v > /dev/null 2>&1; then
        echo "❌ FAILED (pytest)"
        pytest "$REPO_ROOT/n8n-workflows/tests/" -v
        return 1
    fi
    echo "  ✅ PASSED (pytest)"
    
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
    local CHECK_CMD="curl -s -f -H \"X-N8N-API-KEY: $N8N_API_KEY\" \"$PROD_API_URL/api/v1/workflows?limit=1\""
    if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        if ! ssh "$N8N_DEV_SSH_HOST" "source /opt/n8n-docker-caddy/.env && $CHECK_CMD" > /dev/null 2>&1; then
            echo "❌ Rollback failed: n8n API not responding on $N8N_DEV_SSH_HOST at $PROD_API_URL"
            return 1
        fi
    else
        if ! eval "$CHECK_CMD" > /dev/null 2>&1; then
            echo "❌ Rollback failed: n8n API not responding at $PROD_API_URL"
            return 1
        fi
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

# --- WORKFLOW STRUCTURE VALIDATION ---
validate_workflow_structure() {
    echo -n "Validating workflow structure... "
    
    local validation_output
    validation_output=$(bash "$SCRIPT_DIR/workflows/validate_workflows.sh" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo "❌ FAILED"
        echo "$validation_output"
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
    local)
        # Local development setup and deployment
        setup_local_dev
        run_unit_tests || exit 1
        deploy_dev false
        run_functional_tests
        ;;
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
        echo "Usage: $0 [local|dev|prod|all]"
        echo "  local - Set up local dev environment + deploy + test"
        echo "  dev   - Deploy to dev + run smoke tests"
        echo "  prod  - Deploy to prod only"
        echo "  all   - Full pipeline: dev → test → prod (default)"
        exit 1
        ;;
esac

echo ""
echo "========================================"
echo "DEPLOYMENT COMPLETE"
echo "========================================"
