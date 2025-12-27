#!/bin/bash
# Regression Testing with Prod DB Snapshot
#
# Tests modified workflows against production-like data to prevent regressions
#
# Usage:
#   bash scripts/testing/regression_test.sh [options]
#
# Options:
#   --all                    Test all workflows (not just modified)
#   --workflow <name>        Test specific workflow only
#   --no-db-snapshot         Skip prod DB snapshot (use existing dev data)
#   --keep-db                Don't restore dev DB after tests
#   --verbose                Show detailed output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
TEST_ALL=false
SPECIFIC_WORKFLOW=""
SKIP_DB_SNAPSHOT=false
KEEP_DB=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            TEST_ALL=true
            shift
            ;;
        --workflow)
            SPECIFIC_WORKFLOW="$2"
            shift 2
            ;;
        --no-db-snapshot)
            SKIP_DB_SNAPSHOT=true
            shift
            ;;
        --keep-db)
            KEEP_DB=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --all                    Test all workflows"
            echo "  --workflow <name>        Test specific workflow"
            echo "  --no-db-snapshot         Skip prod DB snapshot"
            echo "  --keep-db                Don't restore dev DB"
            echo "  --verbose                Show detailed output"
            echo "  --help                   Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# Testing-specific environment configuration
TESTING_DB_USER="${DB_USER:-n8n_user}"
TESTING_DB_NAME="${DB_NAME:-kairon}"
TESTING_DB_CONTAINER="${CONTAINER_DB:-postgres-dev-local}"
TESTING_WEBHOOK_PATH="${WEBHOOK_PATH:-asoiaf3947}"

# Timing and limit constants
readonly WORKFLOW_EXECUTION_TIMEOUT_SECONDS=15
readonly EXECUTION_HISTORY_LIMIT=20
readonly PROJECTION_LOOKUP_WINDOW_SECONDS=10

# Validate environment variables
validate_env() {
    local errors=0
    
    if ! [[ "$TESTING_DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Invalid DB_NAME format: $TESTING_DB_NAME (must be alphanumeric + underscore)"
        errors=$((errors + 1))
    fi
    
    if ! [[ "$TESTING_DB_USER" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Invalid DB_USER format: $TESTING_DB_USER (must be alphanumeric + underscore)"
        errors=$((errors + 1))
    fi
    
    if [ $errors -gt 0 ]; then
        exit 1
    fi
}

validate_env

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Logging
log_test() { echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}  ✓${NC} $1"; ((PASSED_TESTS++)); }
log_fail() { echo -e "${RED}  ✗${NC} $1"; ((FAILED_TESTS++)); }
log_info() { [ "$VERBOSE" = true ] && echo -e "${YELLOW}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Cleanup trap
cleanup() {
    if [ "$KEEP_DB" = false ] && [ -n "${DEV_DB_BACKUP:-}" ] && [ -f "$DEV_DB_BACKUP" ]; then
        echo ""
        echo "Restoring dev database..."
        docker exec -i "$TESTING_DB_CONTAINER" psql -U "$TESTING_DB_USER" -d "$TESTING_DB_NAME" < "$DEV_DB_BACKUP" > /dev/null 2>&1
        rm -f "$DEV_DB_BACKUP" "${PROD_DUMP:-}" 2>/dev/null || true
        echo -e "${GREEN}✓ Dev DB restored${NC}"
    fi
}

trap cleanup EXIT INT TERM

# ============================================================================
# STEP 1: Identify Modified Workflows
# ============================================================================

get_modified_workflows() {
    if [ -n "$SPECIFIC_WORKFLOW" ]; then
        echo "$SPECIFIC_WORKFLOW"
        return
    fi

    if [ "$TEST_ALL" = true ]; then
        # List all workflows that have test payloads
        for payload_file in "$REPO_ROOT/n8n-workflows/tests/regression"/*.json; do
            [ -f "$payload_file" ] || continue
            basename "$payload_file" .json
        done
        return
    fi

    # Get workflows modified in this branch
    local base_branch
    if git rev-parse --abbrev-ref HEAD@{u} &>/dev/null; then
        base_branch=$(git rev-parse --abbrev-ref HEAD@{u})
    else
        # Fallback for detached HEAD (CI/CD environments)
        base_branch="origin/main"
    fi

    git diff --name-only "$base_branch" \
        | grep "^n8n-workflows/[^/]*\.json$" \
        | grep -v "^n8n-workflows/tests/" \
        | sed 's|^n8n-workflows/||' \
        | sed 's|\.json$||'
}

# ============================================================================
# STEP 2: DB Snapshot
# ============================================================================

setup_test_db() {
    echo ""
    echo "=========================================="
    echo "Setting up test database"
    echo "=========================================="

    if [ "$SKIP_DB_SNAPSHOT" = true ]; then
        echo -e "${YELLOW}Skipping DB snapshot (using existing dev data)${NC}"
        return
    fi

    # Check if prod DB is accessible
    local PROD_DB_ACCESSIBLE=false

    if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        # Remote prod
        if ssh "$N8N_DEV_SSH_HOST" "docker ps -q -f name=postgres-db" | grep -q .; then
            PROD_DB_ACCESSIBLE=true
        fi
    else
        # Local prod
        if docker ps -q -f name=postgres-db | grep -q .; then
            PROD_DB_ACCESSIBLE=true
        fi
    fi

    if [ "$PROD_DB_ACCESSIBLE" = false ]; then
        echo -e "${YELLOW}Warning: Prod DB not accessible, using existing dev data${NC}"
        return
    fi

    # Backup current dev DB state
    DEV_DB_BACKUP="/tmp/dev_db_backup_$$.sql"
    echo "Backing up dev database..."
    docker exec "$TESTING_DB_CONTAINER" pg_dump -U "$TESTING_DB_USER" -d "$TESTING_DB_NAME" > "$DEV_DB_BACKUP"

    # Dump prod DB
    PROD_DUMP="/tmp/prod_snapshot_$$.dump"
    echo "Copying prod database..."

    if [ -n "${N8N_DEV_SSH_HOST:-}" ]; then
        ssh "$N8N_DEV_SSH_HOST" \
            "docker exec postgres-db pg_dump -U n8n_user -d kairon -Fc" > "$PROD_DUMP"
    else
        docker exec postgres-db pg_dump -U n8n_user -d kairon -Fc > "$PROD_DUMP"
    fi

    # Restore to dev
    echo "Restoring prod DB to dev..."
    docker exec -i "$TESTING_DB_CONTAINER" pg_restore -U "$TESTING_DB_USER" -d "$TESTING_DB_NAME" --clean --if-exists --no-owner --no-acl < "$PROD_DUMP" > /dev/null 2>&1

    echo -e "${GREEN}✓ Prod DB restored to dev${NC}"
}

# ============================================================================
# STEP 3: Test Execution
# ============================================================================

run_regression_tests() {
    local workflows=("$@")

    if [ ${#workflows[@]} -eq 0 ]; then
        echo ""
        echo -e "${YELLOW}No workflows to test${NC}"
        return 0
    fi

    echo ""
    echo "=========================================="
    echo "Testing workflows: ${workflows[*]}"
    echo "=========================================="

    for workflow in "${workflows[@]}"; do
        test_workflow "$workflow"
    done
}

test_workflow() {
    local workflow="$1"
    local payload_file="$REPO_ROOT/n8n-workflows/tests/regression/${workflow}.json"

    if [ ! -f "$payload_file" ]; then
        echo -e "${YELLOW}⚠ No test payloads found for $workflow, skipping${NC}"
        return 0
    fi

    echo ""
    log_test "Testing workflow: $workflow"
    log_info "Payload file: $payload_file"

    local test_count=$(jq '. | length' "$payload_file")

    for ((i=0; i<test_count; i++)); do
        ((TOTAL_TESTS++))
        run_test_case "$workflow" "$i" "$payload_file"
    done
}

run_test_case() {
    local workflow="$1"
    local test_index="$2"
    local payload_file="$3"

    local test_name=$(jq -r ".[$test_index].test_name // \"test_$test_index\"" "$payload_file")
    local webhook_data=$(jq -c ".[$test_index].webhook_data" "$payload_file")
    local expected_db_changes=$(jq -c ".[$test_index].expected_db_changes // {}" "$payload_file")

    log_info "Test case: $test_name"

    # Get baseline DB state
    local baseline_events=$(docker exec "$TESTING_DB_CONTAINER" psql -U "$TESTING_DB_USER" -d "$TESTING_DB_NAME" -t -c \
        "SELECT COUNT(*) FROM events;" 2>/dev/null | tr -d '[:space:]' || echo "0")
    local baseline_projections=$(docker exec "$TESTING_DB_CONTAINER" psql -U "$TESTING_DB_USER" -d "$TESTING_DB_NAME" -t -c \
        "SELECT COUNT(*) FROM projections;" 2>/dev/null | tr -d '[:space:]' || echo "0")

    log_info "Baseline: $baseline_events events, $baseline_projections projections"

    # Send webhook
    local test_timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
    local webhook_url="${N8N_DEV_API_URL:-http://localhost:5679}/webhook/$TESTING_WEBHOOK_PATH"

    local response=$(curl -s -X POST "$webhook_url" \
        -H 'Content-Type: application/json' \
        -d "$webhook_data")

    log_info "Webhook response: $response"

    # Check if webhook returned error (e.g., 404)
    if echo "$response" | jq -e '(.code // 200) >= 400' 2>/dev/null; then
        log_fail "$test_name: Webhook failed - $response"
        log_info "Expected webhook path: $TESTING_WEBHOOK_PATH (from WEBHOOK_PATH env var, dev default: asoiaf3947)"
        log_info "Actual webhook URL: $webhook_url"
        log_info "Check that Route_Event workflow is active and uses this webhook path"
        return 1
    fi

    # Wait for execution with polling
    local max_wait=$WORKFLOW_EXECUTION_TIMEOUT_SECONDS
    local wait_count=0
    local exec_data=""

    log_info "Waiting for workflow execution..."
    while [ $wait_count -lt $max_wait ]; do
        sleep 1
        exec_data=$(get_execution "$test_timestamp" "$workflow")
        if [ -n "$exec_data" ] && [ "$exec_data" != "null" ]; then
            log_info "Execution found after ${wait_count}s"
            break
        fi
        ((wait_count++))
    done

    if [ $wait_count -ge $max_wait ]; then
        log_fail "$test_name: Execution timeout (${max_wait}s) - workflow may be slow or failed"
        log_info "Timestamp: $test_timestamp"
        log_info "Workflow: $workflow"
        return 1
    fi

    if [ -z "$exec_data" ] || [ "$exec_data" = "null" ]; then
        log_fail "$test_name: No execution found"
        log_info "Timestamp: $test_timestamp"
        log_info "Workflow: $workflow"
        return 1
    fi

    local exec_id=$(echo "$exec_data" | jq -r '.id // empty')
    local exec_status=$(echo "$exec_data" | jq -r '.status // "unknown"')

    log_info "Execution ID: $exec_id"
    log_info "Status: $exec_status"

    # Check execution status
    if [ "$exec_status" != "success" ]; then
        log_fail "$test_name: Execution failed (status: $exec_status)"

        # Extract error details
        local error_msg=$(echo "$exec_data" | jq -r '.data.resultData.error.message // "Unknown error"')
        local error_node=$(echo "$exec_data" | jq -r '.data.resultData.lastNodeExecuted // "Unknown"')

        log_info "Error node: $error_node"
        log_info "Error message: $error_msg"
        log_info "View in n8n: http://localhost:5679/execution/$exec_id"

        return 1
    fi

    # Check DB changes
    local new_events=$(docker exec "$TESTING_DB_CONTAINER" psql -U "$TESTING_DB_USER" -d "$TESTING_DB_NAME" -t -c \
        "SELECT COUNT(*) FROM events;" 2>/dev/null | tr -d '[:space:]' || echo "0")
    local new_projections=$(docker exec "$TESTING_DB_CONTAINER" psql -U "$TESTING_DB_USER" -d "$TESTING_DB_NAME" -t -c \
        "SELECT COUNT(*) FROM projections;" 2>/dev/null | tr -d '[:space:]' || echo "0")

    local events_created=$((new_events - baseline_events))
    local projections_created=$((new_projections - baseline_projections))

    local expected_events=$(echo "$expected_db_changes" | jq -r '.events_created // 0')
    local expected_projections=$(echo "$expected_db_changes" | jq -r '.projections_created // 0')

    log_info "DB changes: $events_created events, $projections_created projections"
    log_info "Expected: $expected_events events, $expected_projections projections"

    local db_ok=true

    if [ "$events_created" -ne "$expected_events" ]; then
        log_fail "$test_name: Expected $expected_events events, got $events_created"
        db_ok=false
    fi

    if [ "$projections_created" -ne "$expected_projections" ]; then
        log_fail "$test_name: Expected $expected_projections projections, got $projections_created"
        db_ok=false
    fi

    # Check projection types if specified
    local expected_types=$(echo "$expected_db_changes" | jq -r '.projection_types // []')
    if [ "$expected_types" != "[]" ]; then
        local actual_json=$(docker exec "$TESTING_DB_CONTAINER" psql -U "$TESTING_DB_USER" -d "$TESTING_DB_NAME" -t -A -c \
            "SELECT json_agg(DISTINCT projection_type ORDER BY projection_type)
             FROM projections
             WHERE created_at > NOW() - INTERVAL '${PROJECTION_LOOKUP_WINDOW_SECONDS} seconds';" 2>/dev/null | jq -c '. // []')

        log_info "Projection types: $(echo "$actual_json" | jq -r '. | join(", ")')"

        # Convert expected to array and compare
        local expected_json=$(echo "$expected_types" | jq -c '. | sort')

        if [ "$expected_json" != "$actual_json" ]; then
            log_fail "$test_name: Expected projection types $expected_json, got $actual_json"
            db_ok=false
        fi
    fi

    if [ "$db_ok" = true ]; then
        log_pass "$test_name (exec: $exec_id)"
    fi

    return $([ "$db_ok" = true ] && echo 0 || echo 1)
}

get_execution() {
    local since_timestamp="$1"
    local workflow_name="$2"

    # Try to get executions via API
    local api_url="${N8N_DEV_API_URL:-http://localhost:5679}"
    local cookie_file="/tmp/n8n-dev-session.txt"

    local executions="[]"
    local use_cookie=false

    # Check authentication
    if [ -f "$cookie_file" ]; then
        local test_auth=$(curl -s -b "$cookie_file" "$api_url/rest/workflows?take=1" | jq -e '.data' 2>/dev/null)
        if [ -n "$test_auth" ]; then
            use_cookie=true
        fi
    fi

    # Get recent executions
    if [ "$use_cookie" = true ]; then
        executions=$(curl -s -b "$cookie_file" \
            "$api_url/rest/executions?limit=$EXECUTION_HISTORY_LIMIT" | jq '.data.results // []')
    elif [ -n "${N8N_DEV_API_KEY:-}" ]; then
        executions=$(curl -s -H "X-N8N-API-KEY: $N8N_DEV_API_KEY" \
            "$api_url/api/v1/executions?limit=$EXECUTION_HISTORY_LIMIT" | jq '.data // []')
    else
        return
    fi

    # Find execution matching workflow and timestamp
    echo "$executions" | jq --arg ts "$since_timestamp" --arg wf "$workflow_name" \
        '[.[] | select(.startedAt >= $ts and (.workflowData.name // .workflowName // "" | contains($wf)))] | sort_by(.startedAt) | reverse | .[0] // empty'
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo ""
    echo "=========================================="
    echo "Regression Testing Framework"
    echo "=========================================="

    # Setup
    setup_test_db

    # Get workflows to test
    local workflows=($(get_modified_workflows))

    if [ ${#workflows[@]} -eq 0 ]; then
        echo ""
        echo -e "${YELLOW}No workflows modified, skipping regression tests${NC}"
        return 0
    fi

    echo "Workflows to test: ${workflows[*]}"
    echo ""

    # Run tests
    run_regression_tests "${workflows[@]}"

    # Summary
    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo -e "Total:  $TOTAL_TESTS"
    echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
    echo -e "${RED}Failed: $FAILED_TESTS${NC}"
    echo ""

    if [ $FAILED_TESTS -gt 0 ]; then
        echo -e "${RED}❌ REGRESSION TESTS FAILED${NC}"
        echo ""
        echo "Failed tests detected issues with modified workflows."
        echo "Please fix issues before deploying to production."
        return 1
    fi

    echo -e "${GREEN}✅ All regression tests passed${NC}"
    return 0
}

main "$@"
