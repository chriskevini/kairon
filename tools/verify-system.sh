#!/bin/bash
# System verification and health check

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_TOOL="$SCRIPT_DIR/kairon-ops.sh"
REPORT_DIR="$SCRIPT_DIR/../state-reports"
mkdir -p "$REPORT_DIR"

TIMESTAMP=$(date -u +%Y%m%d-%H%M)
REPORT_FILE="$REPORT_DIR/$TIMESTAMP.json"

{
echo "{"
echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
echo "  \"status\": \"checking\","

# Docker containers
echo "  \"containers\": ["
$OPS_TOOL status | grep -A 10 "Docker Containers" | tail -n +2 | head -n -1 | while read line; do
    if [[ ! -z "$line" ]]; then
        echo "    \"$line\","
    fi
done | sed '$ s/,$//'
echo "  ],"

# Database metrics
echo "  \"database\": {"
$OPS_TOOL db-query "
    SELECT json_build_object(
        'events_24h', (SELECT COUNT(*) FROM events WHERE received_at > NOW() - INTERVAL '24 hours'),
        'traces_24h', (SELECT COUNT(*) FROM traces WHERE created_at > NOW() - INTERVAL '24 hours'),
        'projections_24h', (SELECT COUNT(*) FROM projections WHERE created_at > NOW() - INTERVAL '24 hours'),
        'last_event', (SELECT MAX(received_at) FROM events),
        'last_trace', (SELECT MAX(created_at) FROM traces),
        'last_projection', (SELECT MAX(created_at) FROM projections)
    );" | grep '{' | head -1
echo "  },"

# Workflows
echo "  \"workflows\": ["
$OPS_TOOL n8n-list 2>/dev/null | while read line; do
    echo "    \"$line\","
done | sed '$ s/,$//'
echo "  ]"

echo "}"
} | tee "$REPORT_FILE"

echo "Report saved to $REPORT_FILE"
