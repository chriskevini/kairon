-- Check database health and core table stats

-- 1. Core table counts
SELECT 'Total events' AS metric, COUNT(*) AS count FROM events
UNION ALL
SELECT 'Total traces', COUNT(*) FROM traces
UNION ALL
SELECT 'Total projections', COUNT(*) FROM projections
UNION ALL
SELECT 'Total config keys', COUNT(*) FROM config;

-- 2. Projections by type
SELECT 
    projection_type,
    status,
    COUNT(*) as count
FROM projections
GROUP BY projection_type, status
ORDER BY projection_type, status;

-- 3. Check for events without traces (potential processing failures)
-- Exclude system events that might not produce traces
SELECT 'Events without traces' AS metric, COUNT(*) AS count
FROM events e
LEFT JOIN traces t ON e.id = t.event_id
WHERE t.id IS NULL
  AND e.event_type = 'discord_message';

-- 3b. Recent orphaned events (no trace)
SELECT 
    e.received_at,
    e.payload->>'tag' as tag,
    LEFT(e.payload->>'clean_text', 50) as content,
    e.payload->>'message_url' as url
FROM events e
LEFT JOIN traces t ON e.id = t.event_id
WHERE t.id IS NULL
  AND e.event_type = 'discord_message'
ORDER BY e.received_at DESC
LIMIT 5;

-- 4. Sample of recent events and their traces/projections
SELECT 
    e.received_at,
    e.event_type,
    e.payload->>'tag' as tag,
    LEFT(COALESCE(e.payload->>'clean_text', e.payload->>'trigger_type'), 50) as content,
    COUNT(DISTINCT t.id) as traces,
    COUNT(DISTINCT p.id) as projections
FROM events e
LEFT JOIN traces t ON e.id = t.event_id
LEFT JOIN projections p ON e.id = p.event_id
GROUP BY e.id
ORDER BY e.received_at DESC
LIMIT 10;
