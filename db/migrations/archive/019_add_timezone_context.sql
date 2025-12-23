-- Migration 019: Add timezone context to events and projections
-- This allows preserving the user's local timezone context at the time of the event,
-- even if they move to a different timezone later.

BEGIN;

-- 1. Add timezone column to events
ALTER TABLE events ADD COLUMN IF NOT EXISTS timezone TEXT;

-- 2. Add timezone column to projections
ALTER TABLE projections ADD COLUMN IF NOT EXISTS timezone TEXT;

-- 3. Backfill existing records with current config timezone
DO $$
DECLARE
    current_tz TEXT;
BEGIN
    SELECT value INTO current_tz FROM config WHERE key = 'timezone';
    IF current_tz IS NULL THEN
        current_tz := 'UTC';
    END IF;

    UPDATE events SET timezone = current_tz WHERE timezone IS NULL;
    UPDATE projections SET timezone = current_tz WHERE timezone IS NULL;
END $$;

-- 4. Update Views to include timezone

-- Activity log
DROP VIEW IF EXISTS activity_log_v2;
CREATE OR REPLACE VIEW activity_log_v2 AS
SELECT 
  p.id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  p.data->>'description' as description,
  p.status,
  p.created_at,
  p.event_id,
  p.trace_id,
  p.timezone,
  e.payload->>'discord_message_id' as discord_message_id,
  e.payload->>'discord_channel_id' as discord_channel_id
FROM projections p
LEFT JOIN events e ON p.event_id = e.id
WHERE p.projection_type = 'activity'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

-- Notes
DROP VIEW IF EXISTS notes_v2;
CREATE OR REPLACE VIEW notes_v2 AS
SELECT 
  p.id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  p.data->>'text' as text,
  p.status,
  p.created_at,
  p.event_id,
  p.trace_id,
  p.timezone
FROM projections p
WHERE p.projection_type = 'note'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

-- Todos
DROP VIEW IF EXISTS todos_v2;
CREATE OR REPLACE VIEW todos_v2 AS
SELECT 
  p.id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'text' as text,
  COALESCE(p.data->>'status', 'pending') as todo_status,
  p.data->>'priority' as priority,
  p.status as projection_status,
  p.created_at,
  p.event_id,
  p.trace_id,
  p.timezone
FROM projections p
WHERE p.projection_type = 'todo'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

-- Recent projections
DROP VIEW IF EXISTS recent_projections;
CREATE OR REPLACE VIEW recent_projections AS
SELECT 
  p.id,
  p.projection_type,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  COALESCE(p.data->>'description', p.data->>'text') as text,
  p.status,
  p.created_at,
  p.timezone,
  e.payload->>'discord_guild_id' as guild_id,
  e.payload->>'discord_channel_id' as channel_id,
  e.payload->>'discord_message_id' as message_id
FROM projections p
LEFT JOIN events e ON p.event_id = e.id
WHERE p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

-- Thread history
DROP VIEW IF EXISTS thread_history;
CREATE OR REPLACE VIEW thread_history AS
SELECT
  p.id,
  p.event_id,
  p.trace_id,
  p.data->>'thread_id' as thread_id,
  p.data->>'role' as role,
  p.data->>'content' as content,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.created_at,
  p.timezone
FROM projections p
WHERE p.projection_type = 'thread_response'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz ASC;

-- Thread extractions
DROP VIEW IF EXISTS thread_extractions_v2;
CREATE OR REPLACE VIEW thread_extractions_v2 AS
SELECT 
  p.id,
  p.data->>'thread_id' as thread_id,
  p.data->>'extraction_type' as extraction_type,
  p.data->>'content' as content,
  p.data->'metadata' as metadata,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.status,
  p.created_at,
  p.event_id,
  p.trace_id,
  p.timezone
FROM projections p
WHERE p.projection_type = 'thread_extraction'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

COMMIT;
