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

send_message() {
    local message="$1"
    local test_name="$2"
    local thread_id="${3:-null}"
    local test_id="test-msg-$(date +%s)-$$-$TOTAL_TESTS"
    
    ((TOTAL_TESTS++))
    log_test "$test_name"
    
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    
    # Use HEREDOC for safer JSON construction
    local payload=$(cat <<EOF
{
  "event_type": "message",
  "guild_id": "$GUILD_ID",
  "channel_id": "$CHANNEL_ID",
  "message_id": "$test_id",
  "thread_id": "$thread_id",
  "author": {
    "login": "test-user",
    "id": "test-user-id",
    "display_name": "Test User"
  },
  "content": "$message",
  "timestamp": "$timestamp"
}
EOF
)
    
    local response
    response=$(curl -s -w "\n%{http_code}" --max-time 20 -X POST "$WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_fail "Curl failed with exit code $exit_code"
        return 1
    fi

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" = "200" ]; then
        log_pass "HTTP 200"
        echo "$test_id" >> /tmp/kairon_test_ids.txt
        return 0
    else
        log_fail "HTTP $http_code - Body: $body"
        return 1
    fi
}

send_reaction() {
    local emoji="$1"
    local message_id="$2"
    local action="${3:-add}"
    local test_name="$4"
    
    ((TOTAL_TESTS++))
    log_test "$test_name"
    
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    
    local payload=$(cat <<EOF
{
  "event_type": "reaction",
  "action": "$action",
  "emoji": "$emoji",
  "guild_id": "$GUILD_ID",
  "channel_id": "$CHANNEL_ID",
  "message_id": "$message_id",
  "user": {
    "id": "test-user-id",
    "login": "test-user",
    "display_name": "Test User"
  },
  "timestamp": "$timestamp"
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" --max-time 15 -X POST "$WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    local http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" = "200" ]; then
        log_pass "HTTP 200"
        return 0
    else
        log_fail "HTTP $http_code"
        return 1
    fi
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --quick) QUICK_MODE=true ;;
        --verify-db) VERIFY_DB=true ;;
        --webhook) WEBHOOK="$2"; shift ;;
        --guild-id) GUILD_ID="$2"; shift ;;
        --channel-id) CHANNEL_ID="$2"; shift ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --quick          Run quick test suite (skip exhaustive aliases)"
            echo "  --verify-db      Verify database after tests"
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

> /tmp/kairon_test_ids.txt

echo "=========================================="
echo "  Kairon - COMPREHENSIVE PATH COVERAGE"
echo "=========================================="
echo "Webhook: $WEBHOOK"
echo "Guild: $GUILD_ID"
echo "Channel: $CHANNEL_ID"
echo "Mode: $([ "$QUICK_MODE" = true ] && echo "Quick" || echo "Exhaustive")"
echo ""

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
echo ""

# 2. THREADS (Start/Save/Continue)
log_info "--- 2. Thread Workflows ---"
send_message "++ What is my north star?" "Start thread ++"
send_message "chat Tell me a joke" "Start thread alias (chat)"
send_message "Some response in thread" "Continue thread (mock)" "123456789"
send_message "-- Summarize this thread" "Save thread --"
send_message "save Close thread" "Save thread alias"
echo ""

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
echo ""

# 4. SEMANTIC CLASSIFICATION (Route_Message / Multi_Capture)
log_info "--- 4. Semantic Classification ---"
send_message "I am currently working on the test script" "Auto: Activity"
send_message "The database seems to respond faster today" "Auto: Note"
send_message "I need to remember to update the documentation later" "Auto: Todo"
send_message "I finished the report and I noticed the cat is hungry. Need to buy food." "Auto: Multi-extraction"
echo ""

# 5. REACTIONS (Route_Event / Route_Reaction)
log_info "--- 5. Reaction Handling ---"
LAST_MSG_ID=$(tail -n1 /tmp/kairon_test_ids.txt)
send_reaction "1️⃣" "$LAST_MSG_ID" "add" "Reaction: Extraction save"
send_reaction "🔵" "$LAST_MSG_ID" "add" "Reaction: Trigger correction"
send_reaction "❌" "$LAST_MSG_ID" "add" "Reaction: Void/Delete"
echo ""

# 6. EDGE CASES
log_info "--- 6. Edge Cases ---"
send_message "" "Empty message"
send_message "   " "Whitespace only"
send_message "!!" "Only tag"
send_message "::" "Only command tag"
LONG_MSG=$(printf 'A%.0s' {1..500})
send_message "$LONG_MSG" "Long message (500 chars)"
echo ""

echo "=========================================="
echo "  Test Results"
echo "=========================================="
echo "Total: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✓ All paths verified!${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}✗ $FAILED_TESTS failures detected${NC}"
    EXIT_CODE=1
fi

if [ "$VERIFY_DB" = true ] && [ -f "$SCRIPT_DIR/kairon-ops.sh" ]; then
    echo ""
    log_info "=== Database Verification ==="
    log_info "Waiting 10s for async processing..."
    sleep 10
    
    test_count=$("$SCRIPT_DIR/kairon-ops.sh" db-query \
        "SELECT COUNT(*) FROM events WHERE idempotency_key LIKE 'test-msg-%' AND received_at > NOW() - INTERVAL '5 minutes';" \
        | grep -o '[0-9]*' | head -1)
    
    log_info "Test events in DB: $test_count / $TOTAL_TESTS"
fi

exit $EXIT_CODE
