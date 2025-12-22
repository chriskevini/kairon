-- Understanding processing health by tag

-- Tags have different expected outcomes:
-- !! (Activity) -> Expected 1+ activity projections
-- .. (Note)     -> Expected 1+ note projections
-- ++ (Thread)   -> Expected trace and thread_response projection
-- :: (Command)  -> Expected trace, may not have projection (if ephemeral)
-- (null)        -> Multi-extraction, expected 1+ projections

SELECT 
  e.payload->>'tag' as tag,
  COUNT(*) AS total_events,
  COUNT(DISTINCT p.id) FILTER (WHERE p.projection_type = 'activity') AS with_activity,
  COUNT(DISTINCT p.id) FILTER (WHERE p.projection_type = 'note') AS with_note,
  COUNT(DISTINCT p.id) FILTER (WHERE p.projection_type = 'todo') AS with_todo,
  COUNT(DISTINCT p.id) FILTER (WHERE p.projection_type = 'thread_response') AS with_thread_resp,
  COUNT(DISTINCT t.id) AS with_trace,
  COUNT(DISTINCT e.id) FILTER (WHERE t.id IS NULL AND p.id IS NULL) AS orphaned
FROM events e
LEFT JOIN traces t ON e.id = t.event_id
LEFT JOIN projections p ON e.id = p.event_id
WHERE e.event_type = 'discord_message'
GROUP BY e.payload->>'tag'
ORDER BY tag;

-- Recent orphaned messages (no trace, no projection)
SELECT 
  e.payload->>'tag' as tag,
  LEFT(e.payload->>'clean_text', 50) as text,
  e.received_at,
  e.payload->>'message_url' as message_url
FROM events e
LEFT JOIN traces t ON e.id = t.event_id
LEFT JOIN projections p ON e.id = p.event_id
WHERE e.event_type = 'discord_message'
  AND t.id IS NULL 
  AND p.id IS NULL
ORDER BY e.received_at DESC
LIMIT 20;
