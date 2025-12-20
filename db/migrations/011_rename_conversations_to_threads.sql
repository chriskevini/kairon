-- Migration 011: Rename conversations table to threads with workflow-friendly column names
--
-- Aligns database terminology with workflow naming:
-- - conversations → threads
-- - created_from_event_id → started_from_event_id  
-- - committed_by_event_id → saved_by_event_id

BEGIN;

-- Step 1: Rename columns first (while table still has old name)
ALTER TABLE conversations 
  RENAME COLUMN created_from_event_id TO started_from_event_id;
ALTER TABLE conversations 
  RENAME COLUMN committed_by_event_id TO saved_by_event_id;
ALTER TABLE conversations
  RENAME COLUMN committed_at TO saved_at;

-- Step 2: Rename the table
ALTER TABLE conversations RENAME TO threads;

-- Step 3: Rename constraints to match new table name
ALTER TABLE threads 
  RENAME CONSTRAINT conversations_pkey TO threads_pkey;
ALTER TABLE threads 
  RENAME CONSTRAINT conversations_thread_id_key TO threads_thread_id_key;
ALTER TABLE threads 
  RENAME CONSTRAINT conversations_status_check TO threads_status_check;
ALTER TABLE threads 
  RENAME CONSTRAINT conversations_created_from_event_id_fkey TO threads_started_from_event_id_fkey;
ALTER TABLE threads 
  RENAME CONSTRAINT conversations_committed_by_event_id_fkey TO threads_saved_by_event_id_fkey;
ALTER TABLE threads 
  RENAME CONSTRAINT conversations_note_id_fkey TO threads_note_id_fkey;

-- Step 4: Rename indexes
ALTER INDEX idx_conversations_created_at RENAME TO idx_threads_created_at;
ALTER INDEX idx_conversations_status RENAME TO idx_threads_status;
ALTER INDEX idx_conversations_thread_id RENAME TO idx_threads_thread_id;

-- Step 5: Update foreign key references from other tables
-- conversation_messages.conversation_id → thread_id
ALTER TABLE conversation_messages 
  RENAME COLUMN conversation_id TO thread_id;
ALTER TABLE conversation_messages
  DROP CONSTRAINT conversation_messages_conversation_id_fkey;
ALTER TABLE conversation_messages
  ADD CONSTRAINT conversation_messages_thread_id_fkey 
  FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE;

-- thread_extractions.conversation_id → thread_id
ALTER TABLE thread_extractions 
  RENAME COLUMN conversation_id TO thread_id;
ALTER TABLE thread_extractions
  DROP CONSTRAINT thread_extractions_conversation_id_fkey;
ALTER TABLE thread_extractions
  ADD CONSTRAINT thread_extractions_thread_id_fkey 
  FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE;

COMMIT;
