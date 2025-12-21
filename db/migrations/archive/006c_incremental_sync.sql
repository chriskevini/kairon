-- ============================================================================
-- INCREMENTAL SYNC: Catch up new events from old schema to new schema
-- ============================================================================
-- This migration can be run multiple times (idempotent) to catch up any
-- events that were added to the old schema after the initial data migration.
--
-- Use this before cutover to ensure no events are lost.
-- ============================================================================

BEGIN;

-- ============================================================================
-- STEP 1: Sync new events from raw_events → events
-- ============================================================================

INSERT INTO events (id, received_at, event_type, source, payload, idempotency_key)
SELECT 
  id,
  received_at,
  CASE 
    WHEN source_type = 'discord' THEN 'discord_message'
    WHEN source_type = 'cron' THEN 'cron_trigger'
    ELSE 'system_event'
  END as event_type,
  COALESCE(source_type, 'unknown') as source,
  jsonb_build_object(
    'content', raw_text,
    'clean_text', clean_text,
    'tag', tag,
    'discord_guild_id', discord_guild_id,
    'discord_channel_id', discord_channel_id,
    'discord_message_id', discord_message_id,
    'message_url', message_url,
    'author_login', author_login,
    'thread_id', thread_id
  ) || COALESCE(metadata, '{}'::jsonb) as payload,
  COALESCE(discord_message_id, id::text) as idempotency_key
FROM raw_events
WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.id = raw_events.id)
ON CONFLICT (event_type, idempotency_key) DO NOTHING;

\echo 'Step 1 complete: Synced new events'

-- ============================================================================
-- STEP 2: Create traces for new events with projections
-- ============================================================================

-- 2a. Activity extractions
INSERT INTO traces (event_id, parent_trace_id, step_name, step_order, created_at, data)
SELECT 
  e.id as event_id,
  NULL as parent_trace_id,
  'activity_extraction' as step_name,
  1 as step_order,
  e.received_at as created_at,
  jsonb_build_object(
    'result', jsonb_build_object(
      'projection_type', 'activity',
      'category', a.category::text,
      'confidence', a.confidence,
      'source', 'incremental_sync'
    ),
    'note', 'Trace created during incremental sync'
  ) as data
FROM events e
JOIN raw_events re ON e.id = re.id
JOIN activity_log a ON a.raw_event_id = re.id
WHERE NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id);

\echo 'Step 2a complete: Created traces for new activities'

-- 2b. Note extractions
INSERT INTO traces (event_id, parent_trace_id, step_name, step_order, created_at, data)
SELECT 
  e.id as event_id,
  NULL as parent_trace_id,
  'note_extraction' as step_name,
  1 as step_order,
  e.received_at as created_at,
  jsonb_build_object(
    'result', jsonb_build_object(
      'projection_type', 'note',
      'category', n.category::text,
      'source', 'incremental_sync'
    ),
    'note', 'Trace created during incremental sync'
  ) as data
FROM events e
JOIN raw_events re ON e.id = re.id
JOIN notes n ON n.raw_event_id = re.id
WHERE NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id);

\echo 'Step 2b complete: Created traces for new notes'

-- 2c. Thread extractions
INSERT INTO traces (event_id, parent_trace_id, step_name, step_order, created_at, data)
SELECT DISTINCT ON (e.id)
  e.id as event_id,
  NULL as parent_trace_id,
  'thread_extraction' as step_name,
  1 as step_order,
  e.received_at as created_at,
  jsonb_build_object(
    'result', jsonb_build_object(
      'projection_type', 'thread_extraction',
      'extraction_count', (SELECT COUNT(*) FROM thread_extractions WHERE conversation_id = c.id),
      'source', 'incremental_sync'
    ),
    'note', 'Trace created during incremental sync'
  ) as data
FROM events e
JOIN conversations c ON c.created_from_raw_event_id = e.id
JOIN thread_extractions te ON te.conversation_id = c.id
WHERE NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id);

\echo 'Step 2c complete: Created traces for new thread extractions'

-- ============================================================================
-- STEP 3: Sync new projections
-- ============================================================================

-- 3a. Activities
INSERT INTO projections (id, trace_id, event_id, trace_chain, projection_type, data, status, created_at, confirmed_at)
SELECT 
  a.id,
  t.id as trace_id,
  a.raw_event_id as event_id,
  ARRAY[t.id] as trace_chain,
  'activity' as projection_type,
  jsonb_build_object(
    'timestamp', a.timestamp,
    'category', a.category::text,
    'description', a.description,
    'thread_id', a.thread_id,
    'confidence', a.confidence
  ) || COALESCE(a.metadata, '{}'::jsonb) as data,
  'auto_confirmed' as status,
  a.timestamp as created_at,
  a.timestamp as confirmed_at
FROM activity_log a
JOIN traces t ON t.event_id = a.raw_event_id AND t.step_name = 'activity_extraction'
WHERE NOT EXISTS (SELECT 1 FROM projections p WHERE p.id = a.id);

\echo 'Step 3a complete: Synced new activities'

-- 3b. Notes
INSERT INTO projections (id, trace_id, event_id, trace_chain, projection_type, data, status, created_at, confirmed_at)
SELECT 
  n.id,
  t.id as trace_id,
  n.raw_event_id as event_id,
  ARRAY[t.id] as trace_chain,
  'note' as projection_type,
  jsonb_build_object(
    'timestamp', n.timestamp,
    'category', n.category::text,
    'text', n.text,
    'thread_id', n.thread_id
  ) || COALESCE(n.metadata, '{}'::jsonb) as data,
  'auto_confirmed' as status,
  n.timestamp as created_at,
  n.timestamp as confirmed_at
FROM notes n
JOIN traces t ON t.event_id = n.raw_event_id AND t.step_name = 'note_extraction'
WHERE NOT EXISTS (SELECT 1 FROM projections p WHERE p.id = n.id);

\echo 'Step 3b complete: Synced new notes'

-- 3c. Thread extractions
INSERT INTO projections (id, trace_id, event_id, trace_chain, projection_type, data, status, created_at, voided_at, voided_reason)
SELECT 
  te.id,
  tr.id as trace_id,
  c.created_from_raw_event_id as event_id,
  ARRAY[tr.id] as trace_chain,
  'thread_extraction' as projection_type,
  jsonb_build_object(
    'conversation_id', te.conversation_id,
    'item_type', te.item_type,
    'text', te.text,
    'display_order', te.display_order,
    'summary_message_id', te.summary_message_id
  ) as data,
  CASE 
    WHEN te.saved_as IS NULL THEN 'pending'
    WHEN te.saved_as = 'voided' THEN 'voided'
    ELSE 'confirmed'
  END as status,
  te.created_at,
  CASE WHEN te.saved_as = 'voided' THEN NOW() ELSE NULL END as voided_at,
  CASE WHEN te.saved_as = 'voided' THEN 'user_rejected' ELSE NULL END as voided_reason
FROM thread_extractions te
JOIN conversations c ON te.conversation_id = c.id
JOIN traces tr ON tr.event_id = c.created_from_raw_event_id AND tr.step_name = 'thread_extraction'
WHERE NOT EXISTS (SELECT 1 FROM projections p WHERE p.id = te.id);

\echo 'Step 3c complete: Synced new thread extractions'

-- ============================================================================
-- STEP 4: Report sync results
-- ============================================================================

DO $$
DECLARE
  events_synced INT;
  traces_synced INT;
  projections_synced INT;
BEGIN
  SELECT COUNT(*) INTO events_synced 
  FROM events e 
  WHERE EXISTS (SELECT 1 FROM raw_events re WHERE re.id = e.id);
  
  SELECT COUNT(*) INTO traces_synced FROM traces;
  SELECT COUNT(*) INTO projections_synced FROM projections;
  
  RAISE NOTICE '';
  RAISE NOTICE '=== INCREMENTAL SYNC COMPLETE ===';
  RAISE NOTICE 'Total events: % (should match raw_events count)', events_synced;
  RAISE NOTICE 'Total traces: %', traces_synced;
  RAISE NOTICE 'Total projections: %', projections_synced;
  RAISE NOTICE '';
  RAISE NOTICE 'Old vs New comparison:';
  RAISE NOTICE '  raw_events: % | events: %', 
    (SELECT COUNT(*) FROM raw_events), 
    (SELECT COUNT(*) FROM events);
  RAISE NOTICE '  activity_log: % | activities: %',
    (SELECT COUNT(*) FROM activity_log),
    (SELECT COUNT(*) FROM projections WHERE projection_type = 'activity');
  RAISE NOTICE '  notes: % | notes: %',
    (SELECT COUNT(*) FROM notes),
    (SELECT COUNT(*) FROM projections WHERE projection_type = 'note');
  RAISE NOTICE '';
END $$;

COMMIT;

\echo ''
\echo '✅ Incremental sync complete!'
\echo 'Systems are now in sync. Ready for workflow cutover.'
