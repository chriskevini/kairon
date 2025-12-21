-- Migration 018: Backfill message_url in projection data
-- 
-- The Handle_Correction workflow now stores message_url in projection data
-- so that ::recent can display links even after corrections (which change
-- the event_id to point to the correction event, not the original message).
--
-- This migration backfills message_url for existing projections that have
-- a discord_message event with the required fields.

UPDATE projections p
SET data = p.data || jsonb_build_object(
    'message_url',
    'https://discord.com/channels/' || 
    (e.payload->>'discord_guild_id') || '/' || 
    (e.payload->>'discord_channel_id') || '/' || 
    (e.payload->>'discord_message_id')
)
FROM events e
WHERE p.event_id = e.id
  AND e.event_type = 'discord_message'
  AND p.data->>'message_url' IS NULL
  AND e.payload->>'discord_guild_id' IS NOT NULL
  AND e.payload->>'discord_channel_id' IS NOT NULL
  AND e.payload->>'discord_message_id' IS NOT NULL;
