-- Migration 010: Update conversations table to reference events instead of raw_events
--
-- Problem: conversations.created_from_raw_event_id and committed_by_raw_event_id
-- reference raw_events, but workflows now store to the new events table.
-- This causes FK violations when Start_Chat tries to insert.
--
-- Solution: Change the FK references from raw_events to events and rename columns.

BEGIN;

-- Step 1: Drop the old foreign key constraints
ALTER TABLE conversations 
  DROP CONSTRAINT IF EXISTS conversations_created_from_raw_event_id_fkey;
ALTER TABLE conversations 
  DROP CONSTRAINT IF EXISTS conversations_committed_by_raw_event_id_fkey;

-- Step 2: Rename columns to reflect they now reference events
ALTER TABLE conversations 
  RENAME COLUMN created_from_raw_event_id TO created_from_event_id;
ALTER TABLE conversations 
  RENAME COLUMN committed_by_raw_event_id TO committed_by_event_id;

-- Step 3: Clear any existing values (they reference raw_events IDs which won't exist in events)
-- This is safe because these are optional columns and the old data is stale
UPDATE conversations SET created_from_event_id = NULL, committed_by_event_id = NULL;

-- Step 4: Add new foreign key constraints referencing events table
ALTER TABLE conversations 
  ADD CONSTRAINT conversations_created_from_event_id_fkey 
  FOREIGN KEY (created_from_event_id) REFERENCES events(id);
ALTER TABLE conversations 
  ADD CONSTRAINT conversations_committed_by_event_id_fkey 
  FOREIGN KEY (committed_by_event_id) REFERENCES events(id);

COMMIT;
