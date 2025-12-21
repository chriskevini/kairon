-- Kairon Life OS - Migration 004: Thread Extractions & Save Thread Feature
-- Adds thread_extractions table for storing LLM-extracted insights/todos
-- See: docs/save-thread-design-v3-final.md

-- ============================================================================
-- THREAD_EXTRACTIONS TABLE
-- ============================================================================

CREATE TABLE thread_extractions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Thread reference
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  
  -- Extracted content
  item_type TEXT NOT NULL CHECK (item_type IN ('reflection', 'fact', 'todo')),
  text TEXT NOT NULL,
  display_order INT NOT NULL,
  
  -- Saving status
  saved_as TEXT NULL CHECK (saved_as IN ('note', 'todo', NULL)),
  saved_id UUID NULL,  -- References notes.id or todos.id
  
  -- Discord reference (for emoji reactions)
  summary_message_id TEXT NULL,  -- Discord message ID where summary was posted
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Ensure unique ordering within a conversation
  UNIQUE (conversation_id, display_order)
);

-- Indexes for common queries
CREATE INDEX idx_thread_extractions_conversation ON thread_extractions(conversation_id);
CREATE INDEX idx_thread_extractions_summary_msg ON thread_extractions(summary_message_id) WHERE summary_message_id IS NOT NULL;
CREATE INDEX idx_thread_extractions_unsaved ON thread_extractions(conversation_id, item_type) WHERE saved_as IS NULL;

-- Table and column documentation
COMMENT ON TABLE thread_extractions IS 'LLM-extracted insights, facts, and todos from conversation threads';
COMMENT ON COLUMN thread_extractions.conversation_id IS 'References the thread this extraction came from';
COMMENT ON COLUMN thread_extractions.item_type IS 'reflection: internal insight, fact: external knowledge, todo: action item';
COMMENT ON COLUMN thread_extractions.display_order IS 'Order of items in the summary (for emoji numbering: 1, 2, 3...)';
COMMENT ON COLUMN thread_extractions.saved_as IS 'NULL: not saved yet, note: saved to notes table, todo: saved to todos table';
COMMENT ON COLUMN thread_extractions.saved_id IS 'UUID of the note or todo record created from this extraction';
COMMENT ON COLUMN thread_extractions.summary_message_id IS 'Discord message ID where summary was posted (for emoji reaction handling)';

-- ============================================================================
-- UPDATE CONVERSATIONS TABLE
-- ============================================================================

-- Update status constraint to include 'completed' and 'deleted'
-- Note: conversations.status already exists with values ('active', 'committed', 'archived')
-- We'll extend it to also allow 'completed' and 'deleted'
ALTER TABLE conversations
  DROP CONSTRAINT IF EXISTS conversations_status_check;

ALTER TABLE conversations
  ADD CONSTRAINT conversations_status_check 
  CHECK (status IN ('active', 'committed', 'archived', 'completed', 'deleted'));

-- Index already exists from previous migration
-- CREATE INDEX IF NOT EXISTS idx_conversations_status ON conversations(status);

COMMENT ON COLUMN conversations.status IS 'active: ongoing, committed/archived: old system, completed: saved via --, deleted: user deleted thread';

-- ============================================================================
-- VIEWS
-- ============================================================================

-- View for recent thread summaries
CREATE VIEW recent_thread_summaries AS
SELECT 
  c.id AS conversation_id,
  c.thread_id,
  c.created_at,
  c.status,
  COUNT(te.id) AS extraction_count,
  COUNT(te.id) FILTER (WHERE te.saved_as IS NOT NULL) AS saved_count,
  MAX(te.created_at) AS summary_created_at,
  MAX(te.summary_message_id) AS latest_summary_message_id
FROM conversations c
LEFT JOIN thread_extractions te ON c.id = te.conversation_id
WHERE c.status IN ('active', 'completed')
GROUP BY c.id, c.thread_id, c.created_at, c.status
ORDER BY c.created_at DESC;

COMMENT ON VIEW recent_thread_summaries IS 'Overview of threads with extraction counts and save status';

-- View for unsaved extractions (for proactive reminders)
CREATE VIEW unsaved_extractions AS
SELECT 
  te.id,
  te.conversation_id,
  te.item_type,
  te.text,
  te.display_order,
  te.created_at,
  c.thread_id,
  c.created_at AS thread_created_at,
  EXTRACT(day FROM NOW() - te.created_at)::integer AS age_days
FROM thread_extractions te
JOIN conversations c ON te.conversation_id = c.id
WHERE te.saved_as IS NULL
  AND c.status = 'active'
ORDER BY te.created_at DESC, te.display_order;

COMMENT ON VIEW unsaved_extractions IS 'Extracted items not yet saved to notes/todos (for optional reminders)';

-- ============================================================================
-- GRANTS
-- ============================================================================

-- Grant permissions to n8n user (adjust username as needed)
-- Uncomment if needed:
-- GRANT ALL PRIVILEGES ON thread_extractions TO n8n_user;

-- ============================================================================
-- ROLLBACK (for testing - do not run in production)
-- ============================================================================

-- To rollback this migration (TEST ONLY):
-- DROP VIEW IF EXISTS unsaved_extractions;
-- DROP VIEW IF EXISTS recent_thread_summaries;
-- ALTER TABLE conversations DROP COLUMN IF EXISTS status;
-- DROP TABLE IF EXISTS thread_extractions CASCADE;
