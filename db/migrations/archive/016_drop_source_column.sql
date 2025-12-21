-- Migration 016: Drop redundant source column from events table
--
-- Purpose: The source column is redundant with event_type.
--   - discord_message/discord_reaction events always come from Discord
--   - system events always come from our system
--   The trigger_reason (cron/manual/regenerate) belongs in payload, not as a column.
--
-- Safety: Safe to drop - information is derivable from event_type.

BEGIN;

ALTER TABLE events DROP COLUMN IF EXISTS source;

COMMIT;
