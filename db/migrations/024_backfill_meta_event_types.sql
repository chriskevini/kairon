-- Migration: 024_backfill_meta_event_types.sql
-- Classify existing 'discord_message' events as 'discord_command' if they have meta tags (:: or --)

BEGIN;

-- 1. Update events with '::' (cmd) or '--' (save) tags
-- We use the payload->>'tag' to identify these.
UPDATE events
SET event_type = 'discord_command'
WHERE event_type = 'discord_message'
  AND payload->>'tag' IN ('::', '--');

-- 2. Verify classification
-- (This is a comment for manual verification if needed:
-- SELECT event_type, payload->>'tag', COUNT(*) 
-- FROM events 
-- GROUP BY 1, 2;
-- )

COMMIT;
