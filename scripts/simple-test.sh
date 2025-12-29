#!/bin/bash
# Simple regression testing for n8n workflows
#
# This replaces the complex regression test framework with a straightforward approach:
# - Test workflows via their webhook endpoints
# - Verify database changes
# - No complex mocking or transformation
#
# Usage:
#   ./scripts/simple-test.sh [workflow_name] [--cleanup]
#
# Examples:
#   ./scripts/simple-test.sh                    # Test all workflows with test payloads
#   ./scripts/simple-test.sh Route_Message      # Test specific workflow
#   ./scripts/simple-test.sh --cleanup            # Clean up test data only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$REPO_ROOT/n8n-workflows/tests/payloads"

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# Configuration
SPECIFIC_WORKFLOW="${1:-}"
CLEANUP="${2:-false}"
N8N_API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
N8N_API_KEY="${N8N_DEV_API_KEY:-}"
DB_CONTAINER="${DB_CONTAINER:-postgres-dev-local}"
DB_USER="${DB_USER:-n8n_user}"
DB_NAME="${DB_NAME:-kairon}"
DB_NAME_DEV="${DB_NAME_DEV:-kairon_dev}"

# Colors
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

# Clean up test data
cleanup_test_data() {
    log_info "Cleaning up test data..."
    
    local db_name="${DB_NAME_DEV:-$DB_NAME}"
    
    # Delete test events (those with test message IDs)
    local deleted_events
    deleted_events=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$db_name" -t -c "
        DELETE FROM events 
        WHERE payload->>'message_id' LIKE 'test-%' 
        OR payload->>'message_id' LIKE 'dev-%';
        RETURNING COUNT(*);
    " 2>/dev/null | tr -d '[:space:]' || echo "0")
    
    # Delete orphaned projections
    local deleted_projections
    deleted_projections=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$db_name" -t -c "
        DELETE FROM projections 
        WHERE event_id NOT IN (SELECT id FROM events)
        RETURNING COUNT(*);
    " 2>/dev/null | tr -d '[:space:]' || echo "0")
    
    log_success "Deleted $deleted_events test events"
    log_success "Deleted $deleted_projections orphaned projections"
}

# Execute a test payload
run_test() {
    local test_file="$1"
    local test_name
    test_name=$(basename "$test_file" .json)
    
    log_info "Testing: $test_name"
    
    if [ ! -f "$test_file" ]; then
        log_error "Test file not found: $test_file"
        return 1
    fi
    
    # Parse test payload
    local webhook_data
    local expected_events
    local expected_projections
    
    local db_name="${DB_NAME_DEV:-$DB_NAME}"
    
    webhook_data=$(jq -c '.webhook_data' "$test_file")
    expected_events=$(jq -r '.expected_db_changes.events_created // 0' "$test_file")
    expected_projections=$(jq -r '.expected_db_changes.projections_created // 0' "$test_file")
    
    # Get event count before test
    local events_before
    events_before=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$db_name" -t -c "SELECT COUNT(*) FROM events;" 2>/dev/null | tr -d '[:space:]' || echo "0")
    
    # Get projection count before test
    local projections_before
    projections_before=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$db_name" -t -c "SELECT COUNT(*) FROM projections;" 2>/dev/null | tr -d '[:space:]' || echo "0")
    
    # Send webhook
    local webhook_path="${WEBHOOK_PATH:-kairon-dev-test}"
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$N8N_API_URL/webhook/$webhook_path" \
        -H "Content-Type: application/json" \
        -d "$webhook_data")
    
    if [ "$response" != "200" ]; then
        log_error "Webhook failed (HTTP $response)"
        return 1
    fi
    
    # Wait for workflow execution
    sleep 3
    
    # Check event count after test
    local events_after
    events_after=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$db_name" -t -c "SELECT COUNT(*) FROM events;" 2>/dev/null | tr -d '[:space:]' || echo "0")
    
    # Check projection count after test
    local projections_after
    projections_after=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$db_name" -t -c "SELECT COUNT(*) FROM projections;" 2>/dev/null | tr -d '[:space:]' || echo "0")
    
    # Verify results
    local events_created=$((events_after - events_before))
    local projections_created=$((projections_after - projections_before))
    
    local passed=true
    
    if [ "$events_created" -ne "$expected_events" ]; then
        log_error "Expected $expected_events events, got $events_created"
        passed=false
    fi
    
    if [ "$projections_created" -ne "$expected_projections" ]; then
        log_error "Expected $expected_projections projections, got $projections_created"
        passed=false
    fi
    
    if [ "$passed" = true ]; then
        log_success "Test passed: $test_name"
        return 0
    else
        return 1
    fi
}

# Main execution
main() {
    # Handle cleanup-only mode
    if [ "$1" = "--cleanup" ]; then
        cleanup_test_data
        exit 0
    fi
    
    echo "=========================================="
    echo "Simple n8n Workflow Testing"
    echo "=========================================="
    echo ""
    
    # Check if test directory exists
    if [ ! -d "$TEST_DIR" ]; then
        log_info "No test payloads found at $TEST_DIR"
        log_info "Create test payloads to enable regression testing"
        log_info "Use --cleanup flag to remove existing test data"
        exit 0
    fi
    
    # Find test files
    local test_files=()
    if [ -n "$SPECIFIC_WORKFLOW" ]; then
        # Test specific workflow
        if [ -f "$TEST_DIR/${SPECIFIC_WORKFLOW}.json" ]; then
            test_files=("$TEST_DIR/${SPECIFIC_WORKFLOW}.json")
        else
            log_error "No test payload found for $SPECIFIC_WORKFLOW"
            exit 1
        fi
    else
        # Test all workflows
        while IFS= read -r -d '' file; do
            test_files+=("$file")
        done < <(find "$TEST_DIR" -name "*.json" -print0)
    fi
    
    if [ ${#test_files[@]} -eq 0 ]; then
        log_info "No test files found"
        exit 0
    fi
    
    # Run tests
    local passed=0
    local failed=0
    
    for test_file in "${test_files[@]}"; do
        if run_test "$test_file"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
        echo ""
    done
    
    # Summary
    echo "=========================================="
    if [ $failed -eq 0 ]; then
        log_success "All tests passed ($passed/$((passed + failed)))"
    else
        log_error "Some tests failed ($failed/$((passed + failed)))"
    fi
    
    # Clean up test data if enabled
    if [ "$CLEANUP" = "true" ]; then
        echo ""
        cleanup_test_data
    fi
    
    # Exit with proper code
    if [ $failed -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

main
