#!/bin/bash
# Database health monitoring

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_TOOL="$SCRIPT_DIR/kairon-ops.sh"

echo "=== Kairon Database Health Check ==="
echo "Time: $(date)"
echo ""

# Critical metrics
echo "--- Event Processing Pipeline ---"
$OPS_TOOL db-query "
    WITH metrics AS (
        SELECT
            (SELECT COUNT(*) FROM events WHERE received_at > NOW() - INTERVAL '1 hour') as events_1h,
            (SELECT COUNT(*) FROM traces WHERE created_at > NOW() - INTERVAL '1 hour') as traces_1h,
            (SELECT COUNT(*) FROM projections WHERE created_at > NOW() - INTERVAL '1 hour') as projections_1h,
            (SELECT COUNT(*) FROM events WHERE received_at > NOW() - INTERVAL '24 hours') as events_24h,
            (SELECT COUNT(*) FROM traces WHERE created_at > NOW() - INTERVAL '24 hours') as traces_24h,
            (SELECT COUNT(*) FROM projections WHERE created_at > NOW() - INTERVAL '24 hours') as projections_24h
    )
    SELECT 
        'Last Hour:' as period,
        events_1h as events,
        traces_1h as traces,
        projections_1h as projections,
        (events_1h - traces_1h) as events_without_traces
    FROM metrics
    UNION ALL
    SELECT
        'Last 24 Hours:',
        events_24h,
        traces_24h,
        projections_24h,
        (events_24h - traces_24h)
    FROM metrics;
"

echo ""
echo "--- Recent Activity ---"
$OPS_TOOL db-query "
    SELECT
        'Last Event:' as type,
        TO_CHAR(MAX(received_at), 'YYYY-MM-DD HH24:MI:SS UTC') as timestamp,
        EXTRACT(EPOCH FROM (NOW() - MAX(received_at)))::int || 's ago' as age
    FROM events
    UNION ALL
    SELECT
        'Last Trace:',
        TO_CHAR(MAX(created_at), 'YYYY-MM-DD HH24:MI:SS UTC'),
        EXTRACT(EPOCH FROM (NOW() - MAX(created_at)))::int || 's ago'
    FROM traces
    UNION ALL
    SELECT
        'Last Projection:',
        TO_CHAR(MAX(created_at), 'YYYY-MM-DD HH24:MI:SS UTC'),
        EXTRACT(EPOCH FROM (NOW() - MAX(created_at)))::int || 's ago'
    FROM projections;
"

echo ""
echo "--- Health Status ---"
# Note: we use grep -o '[0-9]*' to extract the count from the psql output
events_without_traces=$($OPS_TOOL db-query "SELECT COUNT(*) FROM events e WHERE received_at > NOW() - INTERVAL '1 hour' AND NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id);" | grep -v "count" | grep -v "-" | grep -o '[0-9]*' | head -1)

if [ -z "$events_without_traces" ]; then
    events_without_traces=0
fi

if [ "$events_without_traces" -lt 5 ]; then
    echo "✅ HEALTHY - Event-to-trace pipeline working"
else
    echo "❌ DEGRADED - $events_without_traces events without traces in last hour"
fi
