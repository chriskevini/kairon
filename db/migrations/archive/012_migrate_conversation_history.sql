-- Migration 012: Migrate conversation_messages to projections & standardize timestamps
-- 
-- This migration:
-- 1. Adds 'timestamp' field to all events payload (from received_at) for consistency
-- 2. Migrates assistant messages from conversation_messages → projections (thread_response)
-- 3. Backfills threads.started_from_event_id where possible
--
-- After this migration:
-- - All events have payload->>'timestamp'
-- - All projections have data->>'timestamp'  
-- - conversation_messages can be dropped (in future migration after verification)

-- ============================================================================
-- 1. STANDARDIZE TIMESTAMPS IN EVENTS
-- ============================================================================
-- Add timestamp field to all events payload for consistency with projections

UPDATE events
SET payload = payload || jsonb_build_object('timestamp', received_at)
WHERE NOT (payload ? 'timestamp');

-- ============================================================================
-- 2. CREATE INITIAL EVENTS FOR OLD THREADS
-- ============================================================================
-- For threads without started_from_event_id, create an event from threads.topic
-- This captures the initial message that started the thread

INSERT INTO events (event_type, source, payload, idempotency_key, received_at, metadata)
SELECT 
  'discord_message' as event_type,
  'migration_012' as source,
  jsonb_build_object(
    'clean_text', t.topic,
    'channel_id', t.thread_id,
    'timestamp', COALESCE(
      (SELECT MIN(cm.timestamp) FROM conversation_messages cm WHERE cm.thread_id = t.id),
      t.created_at
    )
  ) as payload,
  'migration_012_thread_start_' || t.id::text as idempotency_key,
  COALESCE(
    (SELECT MIN(cm.timestamp) FROM conversation_messages cm WHERE cm.thread_id = t.id),
    t.created_at
  ) as received_at,
  jsonb_build_object('migration', '012', 'is_thread_starter', true) as metadata
FROM threads t
WHERE t.started_from_event_id IS NULL
  AND t.topic IS NOT NULL
ON CONFLICT (event_type, idempotency_key) DO NOTHING;

-- ============================================================================
-- 3. BACKFILL started_from_event_id FOR OLD THREADS
-- ============================================================================

UPDATE threads t
SET started_from_event_id = (
  SELECT e.id 
  FROM events e 
  WHERE e.idempotency_key = 'migration_012_thread_start_' || t.id::text
  LIMIT 1
)
WHERE t.started_from_event_id IS NULL;

-- ============================================================================
-- 4. MIGRATE ASSISTANT MESSAGES TO PROJECTIONS
-- ============================================================================
-- Create placeholder traces first (projections require a trace_id)

INSERT INTO traces (event_id, step_name, step_order, data, trace_chain)
SELECT 
  t.started_from_event_id as event_id,
  'migration_012_thread_response' as step_name,
  1 as step_order,
  jsonb_build_object(
    'migration', '012',
    'original_cm_id', cm.id::text
  ) as data,
  ARRAY[]::uuid[] as trace_chain
FROM conversation_messages cm
JOIN threads t ON cm.thread_id = t.id
WHERE cm.role = 'assistant'
  AND t.started_from_event_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM traces tr 
    WHERE tr.data->>'original_cm_id' = cm.id::text
  );

-- Now create the projections for assistant messages
INSERT INTO projections (event_id, trace_id, trace_chain, projection_type, status, data, created_at)
SELECT 
  t.started_from_event_id as event_id,
  (SELECT tr.id FROM traces tr WHERE tr.data->>'original_cm_id' = cm.id::text LIMIT 1) as trace_id,
  ARRAY[]::uuid[] as trace_chain,
  'thread_response' as projection_type,
  'auto_confirmed' as status,
  jsonb_build_object(
    'thread_id', t.thread_id,
    'response_text', cm.text,
    'role', 'assistant',
    'timestamp', cm.timestamp
  ) as data,
  cm.timestamp as created_at
FROM conversation_messages cm
JOIN threads t ON cm.thread_id = t.id
WHERE cm.role = 'assistant'
  AND t.started_from_event_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM projections p 
    WHERE p.data->>'thread_id' = t.thread_id
      AND p.projection_type = 'thread_response'
      AND (p.data->>'timestamp')::timestamptz = cm.timestamp
  );

-- ============================================================================
-- 5. VERIFY (run these manually)
-- ============================================================================
-- SELECT 'events_with_timestamp' as check, COUNT(*) FROM events WHERE payload ? 'timestamp';
-- SELECT 'events_without_timestamp' as check, COUNT(*) FROM events WHERE NOT (payload ? 'timestamp');
-- SELECT 'threads_with_start_event' as check, COUNT(*) FROM threads WHERE started_from_event_id IS NOT NULL;
-- SELECT 'threads_without_start_event' as check, COUNT(*) FROM threads WHERE started_from_event_id IS NULL;
-- SELECT 'migrated_assistant_msgs' as check, COUNT(*) FROM projections WHERE projection_type = 'thread_response';
-- SELECT 'old_assistant_msgs' as check, COUNT(*) FROM conversation_messages WHERE role = 'assistant';
