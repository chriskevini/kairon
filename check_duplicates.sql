-- Check for duplicates and processing health

-- 1. Summary of processing success
WITH stats AS (
    SELECT 
        COUNT(*) as total_msg,
        COUNT(DISTINCT p.event_id) as with_projections
    FROM events e
    LEFT JOIN projections p ON e.id = p.event_id
    WHERE e.event_type = 'discord_message'
)
SELECT 'Total Discord Messages' AS metric, total_msg AS count FROM stats
UNION ALL
SELECT 'Messages with Projections', with_projections FROM stats
UNION ALL
SELECT 'Orphaned Messages (no projections)', total_msg - with_projections FROM stats;

-- 2. Check for duplicate idempotency keys
SELECT 
    idempotency_key, 
    event_type, 
    COUNT(*) 
FROM events 
WHERE idempotency_key IS NOT NULL 
GROUP BY idempotency_key, event_type 
HAVING COUNT(*) > 1;

-- 3. Show recent events with processing status
SELECT 
  e.received_at,
  e.payload->>'tag' as tag,
  LEFT(e.payload->>'clean_text', 50) as text,
  CASE 
    WHEN COUNT(p.id) > 0 THEN 'processed (' || COUNT(p.id) || ' projections)'
    WHEN COUNT(t.id) > 0 THEN 'trace only'
    ELSE 'unprocessed'
  END AS status
FROM events e
LEFT JOIN traces t ON e.id = t.event_id
LEFT JOIN projections p ON e.id = p.event_id
WHERE e.event_type = 'discord_message'
GROUP BY e.id
ORDER BY e.received_at DESC
LIMIT 10;
