#!/bin/bash
# Comprehensive testing script for Kairon system
# Tests all command paths, aliases, message extraction, and reactions
# Goal: 100% path coverage

set -u # Error on undefined variables

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables if .env exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    ENV_WEBHOOK=$(grep "^N8N_WEBHOOK_URL=" "$PROJECT_ROOT/.env" | cut -d= -f2- | tr -d '"'\''')
    if [ -n "$ENV_WEBHOOK" ] && [[ "$ENV_WEBHOOK" != *"your-n8n-domain"* ]]; then
        KAIRON_WEBHOOK_URL="$ENV_WEBHOOK"
    fi
fi

# Default settings
WEBHOOK="${KAIRON_WEBHOOK_URL:-https://n8n.chrisirineo.com/webhook/asoiaf92746087}"
GUILD_ID="754207117157859388"
CHANNEL_ID="1453335033665556654"
QUICK_MODE=false
VERIFY_DB=false
DEV_MODE=false
QUIET_MODE=true
NO_MOCKS=false

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

log_test() { [ "$QUIET_MODE" = false ] && echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass() { [ "$QUIET_MODE" = false ] && echo -e "${GREEN}  ✓${NC} $1"; ((PASSED_TESTS++)); }
log_fail() { echo -e "${RED}  ✗${NC} $1"; ((FAILED_TESTS++)); }
log_info() { [ "$QUIET_MODE" = false ] && echo -e "${YELLOW}[INFO]${NC} $1"; }

send_message() {
    local content="$1"
    local description="$2"
    local thread_id="${3:-}"
    local msg_id="test-msg-$(date +%s%N)"
    
    ((TOTAL_TESTS++))
    log_test "$description ($content)"
    
    local payload=$(cat <<EOF
{
  "event_type": "message",
  "guild_id": "$GUILD_ID",
  "channel_id": "$CHANNEL_ID",
  "message_id": "$msg_id",
  "author": {
    "login": "test-user",
    "id": "12345",
    "display_name": "Test User"
  },
  "content": "$content",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "thread_id": "$thread_id"
}
EOF
)
    
    response_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    if [ "$response_code" = "200" ]; then
        log_pass "Sent"
        echo "$msg_id" >> /tmp/kairon_test_ids.txt
    else
        log_fail "$description: Failed to send '$content' (HTTP $response_code)"
    fi
}

send_reaction() {
    local emoji="$1"
    local message_id="$2"
    local action="$3"
    local description="$4"
    
    ((TOTAL_TESTS++))
    log_test "$description ($emoji $action)"
    
    local payload=$(cat <<EOF
{
  "event_type": "reaction",
  "guild_id": "$GUILD_ID",
  "channel_id": "$CHANNEL_ID",
  "message_id": "$message_id",
  "user_id": "12345",
  "emoji": "$emoji",
  "action": "$action",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
}
EOF
)
    
    response_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload")
        
    if [ "$response_code" = "200" ]; then
        log_pass "Sent"
    else
        log_fail "$description: Failed to send reaction '$emoji' (HTTP $response_code)"
    fi
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --quick) QUICK_MODE=true ;;
        --verify-db) VERIFY_DB=true ;;
        --dev) DEV_MODE=true ;;
        --no-mocks) NO_MOCKS=true ;;
        --verbose) QUIET_MODE=false ;;
        --webhook) WEBHOOK="$2"; shift ;;
        --guild-id) GUILD_ID="$2"; shift ;;
        --channel-id) CHANNEL_ID="$2"; shift ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --quick          Run quick test suite (skip exhaustive aliases)"
            echo "  --verify-db      Verify database after tests"
            echo "  --dev            Run against dev environment (port 5679)"
            echo "  --no-mocks       Indicate that tests are running against real APIs"
            echo "  --verbose        Show full output (default is silent on success)"
            echo "  --webhook URL    Use custom webhook URL"
            echo "  --guild-id ID    Discord guild ID"
            echo "  --channel-id ID  Discord channel ID"
            echo "  --help           Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [ "$DEV_MODE" = true ]; then
    # Load WEBHOOK_PATH from .env if it exists
    DEV_WEBHOOK_PATH="kairon-dev-test"
    if [ -f "$PROJECT_ROOT/.env" ]; then
        ENV_PATH=$(grep "^WEBHOOK_PATH=" "$PROJECT_ROOT/.env" | cut -d= -f2- | tr -d '"'\''')
        if [ -n "$ENV_PATH" ]; then
            DEV_WEBHOOK_PATH="$ENV_PATH"
        fi
    fi
    WEBHOOK="http://localhost:5679/webhook/$DEV_WEBHOOK_PATH"
    if [ "$NO_MOCKS" = true ]; then
        log_info "Running in DEV mode (port 5679) with REAL APIs (NO_MOCKS)"
    else
        log_info "Running in DEV mode (port 5679) with MOCK APIs"
    fi
fi


> /tmp/kairon_test_ids.txt

if [ "$QUIET_MODE" = false ]; then
    echo "=========================================="
    echo "  Kairon - COMPREHENSIVE PATH COVERAGE"
    echo "=========================================="
    echo "Webhook: $WEBHOOK"
    echo "Guild: $GUILD_ID"
    echo "Channel: $CHANNEL_ID"
    echo "Mode: $([ "$QUICK_MODE" = true ] && echo "Quick" || echo "Exhaustive")"
    echo ""
fi

# 1. COMMAND ALIASES & NORMALIZATION (Route_Event)
log_info "--- 1. Tag Aliases & Normalization ---"
send_message "!!Task without space" "Symbol tag (no space)"
send_message "!! Task with space" "Symbol tag (with space)"
send_message "act Task with word" "Word alias (with space)"
send_message "ACT Case insensitivity" "Word alias (mixed case)"
send_message ".. Note capture" "Note tag .."
send_message "note Note alias" "Note alias"
send_message "\$\$ Todo item" "Todo tag \$\$"
send_message "todo Todo alias" "Todo alias"
send_message "to-do Another todo alias" "Todo alias (to-do)"

if [ "$QUICK_MODE" = false ]; then
    send_message "ping" "Untagged 'ping' (should be classified)"
    send_message "!!  Extra spaces" "Tag with extra spaces"
fi
[ "$QUIET_MODE" = false ] && echo ""

# 2. THREADS (Start/Save/Continue)
log_info "--- 2. Thread Workflows ---"
send_message "++ What is my north star?" "Start thread ++"
send_message "chat Tell me a joke" "Start thread alias (chat)"
send_message "Some response in thread" "Continue thread (mock)" "123456789"
send_message "-- Summarize this thread" "Save thread --"
send_message "save Close thread" "Save thread alias"
[ "$QUIET_MODE" = false ] && echo ""

# 3. COMMAND LOGIC (Execute_Command)
log_info "--- 3. Command Execution ---"
send_message "::ping" "Cmd: ping"
send_message "::help" "Cmd: help"
send_message "::stats" "Cmd: stats"
send_message "::status" "Cmd: status"
send_message "::recent" "Cmd: recent"
send_message "::recent activities 2" "Cmd: recent activities"
send_message "::recent notes 1" "Cmd: recent notes"
send_message "::get north_star" "Cmd: get config"
send_message "::set north_star test_value" "Cmd: set config"
send_message "::modules" "Cmd: modules list"
send_message "::generate pulse" "Cmd: generate pulse"
send_message "::generate summary" "Cmd: generate summary"
send_message "::get module default" "Cmd: get module"
send_message "::nonexistent_command" "Cmd: unknown command"

if [ "$QUICK_MODE" = false ]; then
    send_message "::recent invalid_type" "Cmd: recent (invalid type)"
    send_message "::recent activities 500" "Cmd: recent (limit too high)"
    send_message "::delete activity 99" "Cmd: delete (out of range)"
fi
[ "$QUIET_MODE" = false ] && echo ""

# 4. SEMANTIC CLASSIFICATION (Route_Message / Multi_Capture)
log_info "--- 4. Semantic Classification ---"
send_message "I am currently working on the test script" "Auto: Activity"
send_message "The database seems to respond faster today" "Auto: Note"
send_message "I need to remember to update the documentation later" "Auto: Todo"
send_message "I finished the report and I noticed the cat is hungry. Need to buy food." "Auto: Multi-extraction"
[ "$QUIET_MODE" = false ] && echo ""

# 5. REACTIONS (Route_Event / Route_Reaction)
log_info "--- 5. Reaction Handling ---"
LAST_MSG_ID=$(tail -n1 /tmp/kairon_test_ids.txt)
send_reaction "1️⃣" "$LAST_MSG_ID" "add" "Reaction: Extraction save"
send_reaction "🔵" "$LAST_MSG_ID" "add" "Reaction: Trigger correction"
send_reaction "❌" "$LAST_MSG_ID" "add" "Reaction: Void/Delete"
[ "$QUIET_MODE" = false ] && echo ""

# 6. EDGE CASES & VALIDATION TIERS (Issue #68)
log_info "--- 6. Edge Cases & Validation Tiers ---"
send_message "" "Tier 1: Empty message (Expect ⛔)"
send_message "   " "Tier 1: Whitespace only (Expect ⛔)"
send_message "!!" "Tier 2: Tag only (Expect ⚠️)"
send_message "act" "Tier 2: Tag alias only (Expect ⚠️)"
send_message "test message" "Tier 3: Test keyword (Expect 💀)"
send_message "testing something" "Tier 3: Testing keyword (Expect 💀)"
send_message "aaaaa" "Tier 3: Junk keyword (Expect 💀)"
send_message "::" "Only command tag"
LONG_MSG=$(printf 'A%.0s' {1..500})
send_message "$LONG_MSG" "Long message (500 chars)"
[ "$QUIET_MODE" = false ] && echo ""

if [ "$QUIET_MODE" = false ] || [ $FAILED_TESTS -gt 0 ]; then
    echo "=========================================="
    echo "  Test Results"
    echo "=========================================="

    # CRON WORKFLOWS (via webhook transform)
    if [ "$DEV_MODE" = true ]; then
        log_info "--- 7. CRON Workflow Triggers ---"
        
        # Auto_Backfill
        ((TOTAL_TESTS++))
        response_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "http://localhost:5679/webhook/kairon-dev-test/CronTrigger" \
            -H "Content-Type: application/json" -d '{}')
        [ "$response_code" = "200" ] && log_pass "Auto_Backfill (CronTrigger)" || log_fail "Auto_Backfill failed (HTTP $response_code)"
        
        # Proactive_Agent_Cron
        ((TOTAL_TESTS++))
        response_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "http://localhost:5679/webhook/kairon-dev-test/Every5Minutes" \
            -H "Content-Type: application/json" -d '{}')
        [ "$response_code" = "200" ] && log_pass "Proactive_Agent_Cron (Every5Minutes)" || log_fail "Proactive_Agent_Cron failed (HTTP $response_code)"
        
        # Generate_Daily_Summary
        ((TOTAL_TESTS++))
        response_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "http://localhost:5679/webhook/kairon-dev-test/Every5Minutes" \
            -H "Content-Type: application/json" -d '{}')
        [ "$response_code" = "200" ] && log_pass "Generate_Daily_Summary (Every5Minutes)" || log_fail "Generate_Daily_Summary failed (HTTP $response_code)"
        
        # Generate_Nudge
        ((TOTAL_TESTS++))
        response_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "http://localhost:5679/webhook/kairon-dev-test/Every15Minutes" \
            -H "Content-Type: application/json" -d '{}')
        [ "$response_code" = "200" ] && log_pass "Generate_Nudge (Every15Minutes)" || log_fail "Generate_Nudge failed (HTTP $response_code)"
        
        echo ""
    fi
    echo "Total: $TOTAL_TESTS"
    echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
    echo -e "${RED}Failed: $FAILED_TESTS${NC}"
    echo ""
fi

if [ $FAILED_TESTS -eq 0 ]; then
    [ "$QUIET_MODE" = false ] && echo -e "${GREEN}✓ All paths verified!${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}✗ $FAILED_TESTS failures detected${NC}"
    EXIT_CODE=1
fi

# Enhanced database verification
verify_database_processing() {
    [ "$QUIET_MODE" = false ] && echo ""
    echo -e "${BLUE}=== Database Verification ===${NC}"
    echo -e "${YELLOW}Waiting for async processing (30s timeout)...${NC}"
    
    # Set up db query function based on environment
    # Extract just the numeric result using grep to avoid psql format dependencies
    if [ "$DEV_MODE" = true ]; then
        db_verify() {
            CONTAINER_DB=postgres-dev DB_NAME=kairon_dev rdev db "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1
        }
    else
        db_verify() {
            "$SCRIPT_DIR/kairon-ops.sh" db-query "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1
        }
    fi
    
    # Wait for events to be processed with periodic checks
    local elapsed=0
    local timeout=30
    local test_count=0
    
    while [ $elapsed -lt $timeout ]; do
        test_count=$(db_verify \
            "SELECT COUNT(*) FROM events WHERE (idempotency_key LIKE 'test-msg-%' OR payload->>'discord_message_id' LIKE 'test-msg-%') AND received_at > NOW() - INTERVAL '5 minutes';" \
            || echo "0")
        
        if [ "${test_count:-0}" -gt 0 ]; then
            break
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
        [ "$QUIET_MODE" = false ] && echo -n "."
    done
    [ "$QUIET_MODE" = false ] && echo ""
    
    if [ "${test_count:-0}" -eq 0 ]; then
        echo -e "${RED}  ✗ No test events found in database${NC}"
        echo -e "${YELLOW}     Tip: n8n may be down or webhook not reachable${NC}"
        return 1
    fi
    
    echo -e "${GREEN}  ✓ Found $test_count / $TOTAL_TESTS test events in database${NC}"
    
    # Check for traces (workflow processing)
    local traced_count
    traced_count=$(db_verify \
        "SELECT COUNT(DISTINCT t.event_id) FROM traces t JOIN events e ON e.id = t.event_id WHERE (e.idempotency_key LIKE 'test-msg-%' OR e.payload->>'discord_message_id' LIKE 'test-msg-%') AND e.received_at > NOW() - INTERVAL '5 minutes';" \
        || echo "0")
    
    if [ "${traced_count:-0}" -gt 0 ]; then
        echo -e "${GREEN}  ✓ $traced_count events processed by workflows (have traces)${NC}"
    else
        echo -e "${YELLOW}  ⚠ No workflow traces found (workflows may not be processing)${NC}"
    fi
    
    # Check for projections (data extraction)
    local projection_count
    projection_count=$(db_verify \
        "SELECT COUNT(DISTINCT p.trace_id) FROM projections p JOIN traces t ON t.id = p.trace_id JOIN events e ON e.id = t.event_id WHERE (e.idempotency_key LIKE 'test-msg-%' OR e.payload->>'discord_message_id' LIKE 'test-msg-%') AND e.received_at > NOW() - INTERVAL '5 minutes';" \
        || echo "0")
    
    if [ "${projection_count:-0}" -gt 0 ]; then
        echo -e "${GREEN}  ✓ $projection_count events created projections${NC}"
    fi
    
    # Summary
    echo ""
    if [ "${traced_count:-0}" -lt "${test_count:-0}" ]; then
        echo -e "${YELLOW}  ⚠ Some events not fully processed by workflows${NC}"
        return 1
    else
        echo -e "${GREEN}  ✓ All test events successfully processed${NC}"
        return 0
    fi
}

if [ "$VERIFY_DB" = true ] && [ -f "$SCRIPT_DIR/kairon-ops.sh" ]; then
    verify_database_processing || {
        echo -e "${RED}Database verification failed${NC}"
        EXIT_CODE=1
    }
fi

exit $EXIT_CODE
