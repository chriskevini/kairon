-- ============================================================================
-- DATA MIGRATION: Old Schema → New Schema (Phase 3)
-- ============================================================================
-- Migrates existing data from raw_events, activity_log, notes, thread_extractions
-- to the new events/traces/projections schema.
--
-- IMPORTANT: This migration handles the case where routing_decisions is empty
-- by creating synthetic traces based on tag detection and category information.
-- ============================================================================

BEGIN;

-- ============================================================================
-- STEP 1: Migrate raw_events → events
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
ON CONFLICT (event_type, idempotency_key) DO NOTHING;

\echo 'Step 1 complete: raw_events → events'

-- ============================================================================
-- STEP 2: Create synthetic traces ONLY for LLM extraction operations
-- ============================================================================
-- IMPORTANT: Tags are deterministic (pattern matching), NOT traces!
-- Only create traces for actual LLM operations (intent classification, extraction)
-- 
-- Since routing_decisions is empty, we reverse-engineer which events had LLM
-- extraction by checking which events have projections (activities/notes).

-- 2a. Create traces for events that resulted in activity extraction
-- (These likely went through LLM classification or multi-extraction)
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
      'source', 'synthetic_migration'
    ),
    'note', 'Synthetic trace created during migration from legacy schema'
  ) as data
FROM events e
JOIN raw_events re ON e.id = re.id
JOIN activity_log a ON a.raw_event_id = re.id;

\echo 'Step 2a complete: Created traces for activity extractions'

-- 2b. Create traces for events that resulted in note extraction
-- (Only create if no activity trace exists - avoid duplicates)
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
      'source', 'synthetic_migration'
    ),
    'note', 'Synthetic trace created during migration from legacy schema'
  ) as data
FROM events e
JOIN raw_events re ON e.id = re.id
JOIN notes n ON n.raw_event_id = re.id
WHERE NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id);

\echo 'Step 2b complete: Created traces for note extractions'

-- 2c. Create traces for thread extractions (LLM operation on thread save)
-- ONE trace per conversation, not per extraction (multiple extractions per thread)
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
      'source', 'synthetic_migration'
    ),
    'note', 'Synthetic trace created during migration from legacy schema'
  ) as data
FROM events e
JOIN conversations c ON c.created_from_raw_event_id = e.id
JOIN thread_extractions te ON te.conversation_id = c.id
WHERE NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id);

\echo 'Step 2c complete: Created traces for thread extractions'

-- ============================================================================
-- STEP 3: Migrate activity_log → projections
-- ============================================================================

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
JOIN traces t ON t.event_id = a.raw_event_id
WHERE t.step_order = 1;

\echo 'Step 3 complete: activity_log → projections'

-- ============================================================================
-- STEP 4: Migrate notes → projections
-- ============================================================================

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
JOIN traces t ON t.event_id = n.raw_event_id
WHERE t.step_order = 1;

\echo 'Step 4 complete: notes → projections'

-- ============================================================================
-- STEP 5: Migrate thread_extractions → projections
-- ============================================================================

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
JOIN traces tr ON tr.event_id = c.created_from_raw_event_id
WHERE tr.step_order = 1;

\echo 'Step 5 complete: thread_extractions → projections'

-- ============================================================================
-- STEP 6: Verify migration
-- ============================================================================

DO $$
DECLARE
  events_count INT;
  traces_count INT;
  projections_count INT;
  activities_count INT;
  notes_count INT;
  thread_extractions_count INT;
BEGIN
  SELECT COUNT(*) INTO events_count FROM events;
  SELECT COUNT(*) INTO traces_count FROM traces;
  SELECT COUNT(*) INTO projections_count FROM projections;
  SELECT COUNT(*) INTO activities_count FROM projections WHERE projection_type = 'activity';
  SELECT COUNT(*) INTO notes_count FROM projections WHERE projection_type = 'note';
  SELECT COUNT(*) INTO thread_extractions_count FROM projections WHERE projection_type = 'thread_extraction';
  
  RAISE NOTICE '';
  RAISE NOTICE '=== MIGRATION COMPLETE ===';
  RAISE NOTICE 'Events: %', events_count;
  RAISE NOTICE 'Traces: %', traces_count;
  RAISE NOTICE 'Projections: %', projections_count;
  RAISE NOTICE '';
  RAISE NOTICE 'Projections by type:';
  RAISE NOTICE '  - activities: %', activities_count;
  RAISE NOTICE '  - notes: %', notes_count;
  RAISE NOTICE '  - thread_extractions: %', thread_extractions_count;
  RAISE NOTICE '';
  
  -- Verify counts match old tables
  IF events_count != (SELECT COUNT(*) FROM raw_events) THEN
    RAISE WARNING 'Event count mismatch! Expected: %, Got: %', 
      (SELECT COUNT(*) FROM raw_events), events_count;
  END IF;
  
  IF activities_count != (SELECT COUNT(*) FROM activity_log) THEN
    RAISE WARNING 'Activity count mismatch! Expected: %, Got: %', 
      (SELECT COUNT(*) FROM activity_log), activities_count;
  END IF;
  
  IF notes_count != (SELECT COUNT(*) FROM notes) THEN
    RAISE WARNING 'Note count mismatch! Expected: %, Got: %', 
      (SELECT COUNT(*) FROM notes), notes_count;
  END IF;
  
  IF thread_extractions_count != (SELECT COUNT(*) FROM thread_extractions) THEN
    RAISE WARNING 'Thread extraction count mismatch! Expected: %, Got: %', 
      (SELECT COUNT(*) FROM thread_extractions), thread_extractions_count;
  END IF;
  
  RAISE NOTICE 'Verification complete. Check warnings above.';
END $$;

COMMIT;

\echo ''
\echo '✅ Data migration complete!'
\echo 'Next steps:'
\echo '  1. Query new tables to verify data integrity'
\echo '  2. Update n8n workflows to use new schema (Phase 4)'
\echo '  3. Run parallel for 1 week (Phase 5)'
\echo '  4. Drop old tables (Phase 6)'
