-- Understanding "orphaned" raw events

-- Orphans are EXPECTED for these cases:
-- 1. Commands (::) - ephemeral, no secondary table
-- 2. Failed workflow processing - debugging info
-- 3. Messages in threads (continuation) - may not create activity/note

SELECT 
  re.tag,
  COUNT(*) AS total_events,
  COUNT(al.id) AS has_activity,
  COUNT(n.id) AS has_note,
  COUNT(*) - COUNT(al.id) - COUNT(n.id) AS orphaned
FROM raw_events re
LEFT JOIN activity_log al ON re.id = al.raw_event_id
LEFT JOIN notes n ON re.id = n.raw_event_id
GROUP BY re.tag
ORDER BY re.tag;

-- Show recent orphaned events by tag
SELECT 
  re.tag,
  re.clean_text,
  re.received_at,
  re.message_url
FROM raw_events re
LEFT JOIN activity_log al ON re.id = al.raw_event_id
LEFT JOIN notes n ON re.id = n.raw_event_id
WHERE al.id IS NULL AND n.id IS NULL
ORDER BY re.received_at DESC
LIMIT 20;
