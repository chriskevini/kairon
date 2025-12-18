-- Migration 002b: Remove title column from notes
-- This is an addendum to migration 002 (can be run independently)

-- Drop view that depends on title column
DROP VIEW IF EXISTS recent_notes;

-- Drop title column (we want pure user thoughts, not LLM-derived titles)
ALTER TABLE notes DROP COLUMN IF EXISTS title;

COMMENT ON COLUMN notes.text IS 'Pure user thought (clean_text) - no LLM modification';

-- Recreate view without title
CREATE VIEW recent_notes AS
SELECT 
  n.id,
  n.timestamp,
  n.category,  -- Direct column, not JOIN (static enum)
  n.text,
  n.thread_id,
  re.author_login,
  re.message_url
FROM notes n
JOIN raw_events re ON n.raw_event_id = re.id
ORDER BY n.timestamp DESC;

COMMENT ON VIEW recent_notes IS 'Notes with pure user thoughts (no LLM-derived titles)';

-- Verify
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'notes' AND column_name = 'title'
  ) THEN
    RAISE EXCEPTION 'Migration failed: title column still exists';
  END IF;
  
  RAISE NOTICE '✅ Title column removed successfully';
  RAISE NOTICE 'Notes table now stores only pure user thoughts (text column)';
  RAISE NOTICE 'View recent_notes recreated without title';
END $$;
