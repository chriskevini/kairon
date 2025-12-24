#!/bin/bash
# Comprehensive testing script for Kairon system
# Tests all command paths and message extraction paths

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default webhook URL
WEBHOOK="${KAIRON_WEBHOOK_URL:-https://n8n.chrisirineo.com/webhook/asoiaf92746087}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

log_test() { echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}  ✓${NC} $1"; ((PASSED_TESTS++)); }
log_fail() { echo -e "${RED}  ✗${NC} $1"; ((FAILED_TESTS++)); }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

send_test() {
    local message="$1"
    local test_name="$2"
    local test_id="test-$(date +%s)-$$-$TOTAL_TESTS"
    
    ((TOTAL_TESTS++))
    log_test "$test_name"
    
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    response=$(curl -s -w "\n%{http_code}" --max-time 10 -X POST "$WEBHOOK" \
        -H "Content-Type: application/json" \
        -d '{"event_type":"message","guild_id":"test-guild","channel_id":"test-channel","message_id":"'"$test_id"'","author":{"login":"test-user","id":"test-user-id","display_name":"Test User"},"content":"'"$message"'","clean_text":"'"$message"'","timestamp":"'"$timestamp"'"}')
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" = "200" ]; then
        log_pass "HTTP 200"
        echo "$test_id" >> /tmp/kairon_test_ids.txt
        return 0
    else
        log_fail "HTTP $http_code - Body: $body"
        return 1
    fi
}

# Parse arguments
QUICK_MODE=false
VERIFY_DB=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --quick) QUICK_MODE=true ;;
        --verify-db) VERIFY_DB=true ;;
        --webhook) WEBHOOK="$2"; shift ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --quick       Run quick test suite (fewer tests)"
            echo "  --verify-db   Verify database after tests"
            echo "  --webhook URL Use custom webhook URL"
            echo "  --help        Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

> /tmp/kairon_test_ids.txt

echo ""
echo "=========================================="
echo "  Kairon System - Comprehensive Tests"
echo "=========================================="
echo "Webhook: $WEBHOOK"
echo "Mode: $([ "$QUICK_MODE" = true ] && echo "Quick" || echo "Full")"
echo ""

echo ""
log_info "=== Testing Command Paths ==="
echo ""

send_test "::ping" "Command: ping"
sleep 1

send_test "::help" "Command: help"
sleep 1

send_test "::stats" "Command: stats"
sleep 1

send_test "::recent" "Command: recent (no args)"
sleep 1

send_test "::recent activities 5" "Command: recent activities"
sleep 1

send_test "::recent notes 3" "Command: recent notes"
sleep 1

send_test "::recent todos" "Command: recent todos"
sleep 1

if [ "$QUICK_MODE" = false ]; then
    send_test "::recent activities 10" "Command: recent (limit 10)"
    sleep 1
fi

echo ""
log_info "=== Testing Message Extraction ==="
echo ""

send_test "!! I spent 3 hours testing the recovery system" "Tagged activity"
sleep 2

send_test "-- The system has multiple workflows needing investigation" "Tagged note"
sleep 2

send_test "[] Need to verify all postgres nodes use values" "Tagged todo"
sleep 2

send_test "Working on fixing production issues. Need to check logs." "Untagged message"
sleep 2

if [ "$QUICK_MODE" = false ]; then
    send_test "Today I debugged n8n workflows. Found queryReplacement issues. Need to update docs." "Complex message"
    sleep 2
fi

echo ""
log_info "=== Testing Edge Cases ==="
echo ""

send_test "::recent activities" "Edge: recent without limit"
sleep 1

send_test "testing" "Edge: short message"
sleep 2

echo ""
echo "=========================================="
echo "  Test Results"
echo "=========================================="
echo "Total: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    EXIT_CODE=1
fi

if [ "$VERIFY_DB" = true ] && [ -f "$SCRIPT_DIR/kairon-ops.sh" ]; then
    echo ""
    log_info "=== Database Verification ==="
    log_info "Waiting 10s for processing..."
    sleep 10
    
    test_count=$("$SCRIPT_DIR/kairon-ops.sh" db-query \
        "SELECT COUNT(*) FROM events WHERE idempotency_key LIKE 'test-%' AND received_at > NOW() - INTERVAL '5 minutes';" \
        | grep -o '[0-9]*' | head -1)
    
    log_info "Test events in DB: $test_count / $TOTAL_TESTS"
fi

echo ""
log_info "Test IDs: /tmp/kairon_test_ids.txt"
echo ""

exit $EXIT_CODE
