-- Migration 014: Create thread_history view
--
-- This view provides a unified interface for retrieving all messages in a thread,
-- handling the quirk where the initial message has discord_message_id = thread_id
-- but thread_id = NULL (because the thread didn't exist when the event was recorded).
--
-- Pattern:
--   - Initial message: discord_message_id = X, thread_id = NULL
--   - Follow-up messages: thread_id = X
--   - In Discord, thread_id equals message_id of the message that started the thread
--
-- Usage:
--   SELECT * FROM thread_history WHERE thread_id = $1 ORDER BY timestamp;

BEGIN;

CREATE OR REPLACE VIEW thread_history AS
SELECT thread_id, timestamp, role, text FROM (
  -- Initial messages that started threads (message_id becomes thread_id)
  SELECT 
    e.payload->>'discord_message_id' as thread_id,
    (e.payload->>'timestamp')::timestamptz as timestamp,
    'user' as role,
    e.payload->>'clean_text' as text
  FROM events e
  WHERE e.event_type = 'discord_message'
    AND e.payload->>'discord_message_id' IS NOT NULL
    -- Only include messages that actually started a thread
    -- (there exists a follow-up message or assistant response with this thread_id)
    AND EXISTS (
      SELECT 1 FROM events e2 
      WHERE e2.payload->>'thread_id' = e.payload->>'discord_message_id'
      UNION
      SELECT 1 FROM projections p 
      WHERE p.projection_type = 'thread_response' 
        AND p.data->>'thread_id' = e.payload->>'discord_message_id'
    )

  UNION ALL

  -- Follow-up user messages in threads
  SELECT 
    e.payload->>'thread_id' as thread_id,
    (e.payload->>'timestamp')::timestamptz as timestamp,
    'user' as role,
    e.payload->>'clean_text' as text
  FROM events e
  WHERE e.event_type = 'discord_message'
    AND e.payload->>'thread_id' IS NOT NULL

  UNION ALL

  -- Assistant responses from projections
  SELECT
    p.data->>'thread_id' as thread_id,
    (p.data->>'timestamp')::timestamptz as timestamp,
    'assistant' as role,
    p.data->>'response_text' as text
  FROM projections p
  WHERE p.projection_type = 'thread_response'
    AND p.status = 'auto_confirmed'
    AND p.data->>'thread_id' IS NOT NULL
) all_messages;

COMMENT ON VIEW thread_history IS 'Unified view of all messages in a thread (user + assistant), handling the quirk where initial messages have thread_id=NULL';

COMMIT;
