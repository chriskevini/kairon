-- OPTIONAL: Clean up test/debug raw events
-- ⚠️ WARNING: This permanently deletes data. Use carefully!

-- STEP 1: Preview what will be deleted (run this first!)
SELECT 
  id,
  received_at,
  clean_text,
  tag,
  CASE 
    WHEN EXISTS (SELECT 1 FROM activity_log WHERE raw_event_id = raw_events.id) THEN 'has_activity'
    WHEN EXISTS (SELECT 1 FROM notes WHERE raw_event_id = raw_events.id) THEN 'has_note'
    ELSE 'orphaned'
  END AS status
FROM raw_events
WHERE 
  clean_text ILIKE '%debug%' 
  OR clean_text ILIKE '%test%'
  OR clean_text ILIKE '%SQL%'
ORDER BY received_at DESC;

-- STEP 2: Delete test messages (ONLY run after reviewing above!)
/*
DELETE FROM raw_events
WHERE 
  clean_text ILIKE '%debug%' 
  OR clean_text ILIKE '%test%'
  OR clean_text ILIKE '%SQL%';
*/

-- STEP 3: More aggressive - delete ALL orphaned raw events (not processed)
/*
DELETE FROM raw_events
WHERE id NOT IN (
  SELECT raw_event_id FROM activity_log
  UNION
  SELECT raw_event_id FROM notes
);
*/
