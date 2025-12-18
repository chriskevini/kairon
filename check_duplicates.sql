-- Check for duplicates and failed processing

-- 1. Count total raw events
SELECT 'Total raw events' AS metric, COUNT(*) AS count
FROM raw_events
UNION ALL

-- 2. Count successful activities
SELECT 'Successful activities', COUNT(*)
FROM activity_log
UNION ALL

-- 3. Count successful notes
SELECT 'Successful notes', COUNT(*)
FROM notes
UNION ALL

-- 4. Find "orphaned" raw events (received but not processed)
SELECT 'Orphaned raw events (not processed)', COUNT(*)
FROM raw_events re
LEFT JOIN activity_log al ON re.id = al.raw_event_id
LEFT JOIN notes n ON re.id = n.raw_event_id
WHERE al.id IS NULL AND n.id IS NULL;

-- 5. Show recent raw events with processing status
SELECT 
  re.received_at,
  re.clean_text,
  re.tag,
  CASE 
    WHEN al.id IS NOT NULL THEN 'activity'
    WHEN n.id IS NOT NULL THEN 'note'
    ELSE 'unprocessed'
  END AS status,
  COALESCE(al.category::text, n.category::text, '-') AS category
FROM raw_events re
LEFT JOIN activity_log al ON re.id = al.raw_event_id
LEFT JOIN notes n ON re.id = n.raw_event_id
ORDER BY re.received_at DESC
LIMIT 10;
