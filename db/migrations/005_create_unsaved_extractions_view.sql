-- Migration 005: Create unsaved_extractions view
-- Purpose: Provides a convenient view for querying thread extractions that haven't been saved yet
-- Safe to run multiple times (uses CREATE OR REPLACE)

-- Create the view
CREATE OR REPLACE VIEW unsaved_extractions AS
SELECT 
  te.id,
  te.conversation_id,
  te.item_type,
  te.text,
  te.display_order,
  te.saved_as,
  te.saved_id,
  te.summary_message_id,
  te.created_at,
  c.topic as thread_topic,
  c.created_at as thread_created_at,
  c.thread_id
FROM thread_extractions te
JOIN conversations c ON te.conversation_id = c.id
WHERE te.saved_as IS NULL
ORDER BY te.created_at DESC;

-- Verify the view was created
SELECT 'View created successfully' as status;
