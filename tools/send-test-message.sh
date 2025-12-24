#!/bin/bash
# Send test message to n8n webhook (simulating Discord relay)

MESSAGE_TYPE="${1:-message}"  # message, reaction, etc.
CONTENT="${2:-testing system}"

WEBHOOK_URL="https://n8n.chrisirineo.com/webhook/asoiaf92746087"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
UNIQUE_ID="test-$(date +%s)-$$"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

case "$MESSAGE_TYPE" in
  message)
    PAYLOAD=$(cat <<EOF
{
  "event_type": "message",
  "guild_id": "test-guild",
  "channel_id": "test-channel",
  "message_id": "$UNIQUE_ID",
  "author": {
    "login": "test-user",
    "id": "test-user-id",
    "display_name": "Test User"
  },
  "content": "$CONTENT",
  "timestamp": "$TIMESTAMP"
}
EOF
)
    ;;
  
  ping)
    PAYLOAD=$(cat <<EOF
{
  "event_type": "message",
  "guild_id": "test-guild",
  "channel_id": "test-channel",
  "message_id": "$UNIQUE_ID",
  "author": {
    "login": "test-user",
    "id": "test-user-id",
    "display_name": "Test User"
  },
  "content": "::ping",
  "timestamp": "$TIMESTAMP"
}
EOF
)
    ;;
    
  recent)
    PAYLOAD=$(cat <<EOF
{
  "event_type": "message",
  "guild_id": "test-guild",
  "channel_id": "test-channel",
  "message_id": "$UNIQUE_ID",
  "author": {
    "login": "test-user",
    "id": "test-user-id",
    "display_name": "Test User"
  },
  "content": "::recent",
  "timestamp": "$TIMESTAMP"
}
EOF
)
    ;;
    
  activity)
    PAYLOAD=$(cat <<EOF
{
  "event_type": "message",
  "guild_id": "test-guild",
  "channel_id": "test-channel",
  "message_id": "$UNIQUE_ID",
  "author": {
    "login": "test-user",
    "id": "test-user-id",
    "display_name": "Test User"
  },
  "content": "!! I spent 2 hours coding today, made progress on the recovery system",
  "timestamp": "$TIMESTAMP"
}
EOF
)
    ;;
    
  *)
    echo "Usage: $0 <message|ping|recent|activity> [custom content]"
    exit 1
    ;;
esac

echo -e "${YELLOW}Sending test $MESSAGE_TYPE to n8n...${NC}"
echo "Message ID: $UNIQUE_ID"
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "200" ]; then
  echo -e "${GREEN}✓ Success!${NC} HTTP $HTTP_CODE"
  echo "Response: $BODY"
  echo ""
  echo "Check database for results:"
  echo "  ./tools/kairon-ops.sh db-query \"SELECT * FROM events WHERE idempotency_key LIKE '$UNIQUE_ID%' ORDER BY received_at DESC LIMIT 1;\""
else
  echo "✗ Failed! HTTP $HTTP_CODE"
  echo "Response: $BODY"
  exit 1
fi
