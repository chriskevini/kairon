-- Kairon Life OS - Migration 002c: Fix Note Categories (v2 - handles partial migration state)
-- Reduces note_category enum to 2 categories for maximum simplicity
-- 
-- RATIONALE:
-- The clearest semantic boundary in notes is: internal vs external knowledge
-- 
-- CATEGORY DESIGN:
-- - fact → External, objective, declarative knowledge (birthdays, preferences, facts about people/things)
-- - reflection → Internal, subjective knowledge (insights, decisions, observations, realizations)
-- 
-- WHY 2 CATEGORIES?
-- 1. Clear semantic boundary (easy to classify, easy to audit)
-- 2. Minimal collision with other systems:
--    - "question" → Handled by thread system (++ chat tag)
--    - "idea" → Handled by todo system ($$ todo tag)
-- 3. Optimal for hybrid RAG (metadata filtering + semantic search)
-- 4. Enables cross-type queries (facts × todos, reflections × activities)
-- 5. Simple mental model

-- ============================================================================
-- BACKUP CHECKPOINT
-- ============================================================================

-- Before running:
-- pg_dump -U n8n_user -d kairon -F c -f backups/pre_note_categories_fix_$(date +%Y%m%d_%H%M%S).dump

-- ============================================================================
-- CHECK EXISTING DATA
-- ============================================================================

-- See what categories are currently in use
DO $$
BEGIN
  RAISE NOTICE 'Current note category distribution:';
  RAISE NOTICE '%', (
    SELECT COALESCE(string_agg(category::text || ': ' || count::text, ', '), 'No notes found')
    FROM (
      SELECT category, COUNT(*) as count 
      FROM notes 
      GROUP BY category
    ) t
  );
END $$;

-- ============================================================================
-- STEP 1: DROP DEPENDENT VIEW
-- ============================================================================

DROP VIEW IF EXISTS recent_notes;

-- ============================================================================
-- STEP 2: MIGRATE EXISTING NOTES (if any old categories exist)
-- ============================================================================

-- First, convert column to text so we can work with it
ALTER TABLE notes ALTER COLUMN category TYPE text;

-- Map old categories to new ones (if they exist)
-- Since all existing notes are 'reflection', this is a no-op
UPDATE notes 
SET category = 'reflection'
WHERE category IN ('question', 'idea', 'decision', 'meta', 'reflection');

-- Update any that might be 'fact' already (keep as fact)
-- No action needed, they're already 'fact'

-- ============================================================================
-- STEP 3: RECREATE ENUM TYPE
-- ============================================================================

-- Drop old enum if it exists
DROP TYPE IF EXISTS note_category CASCADE;

-- Create new 2-category enum
CREATE TYPE note_category AS ENUM (
  'fact',
  'reflection'
);

COMMENT ON TYPE note_category IS 'Binary note categories: external knowledge (fact) vs internal knowledge (reflection). Optimized for hybrid RAG with cross-type queries.';

-- ============================================================================
-- STEP 4: CONVERT COLUMN BACK TO ENUM
-- ============================================================================

-- Convert text column back to enum
ALTER TABLE notes ALTER COLUMN category TYPE note_category USING category::note_category;

-- Ensure NOT NULL constraint
ALTER TABLE notes ALTER COLUMN category SET NOT NULL;

-- Add index
CREATE INDEX IF NOT EXISTS idx_notes_category ON notes(category);

COMMENT ON COLUMN notes.category IS 'Static category enum (fact or reflection) - no FK needed';

-- ============================================================================
-- STEP 5: RECREATE VIEW
-- ============================================================================

CREATE VIEW recent_notes AS
SELECT 
  n.id,
  n.timestamp,
  n.category,  -- Direct column, not JOIN
  n.text,
  n.thread_id,
  re.author_login,
  re.message_url
FROM notes n
JOIN raw_events re ON n.raw_event_id = re.id
ORDER BY n.timestamp DESC;

COMMENT ON VIEW recent_notes IS 'Notes with categories (no JOIN needed - static enums)';

-- ============================================================================
-- VERIFY MIGRATION
-- ============================================================================

DO $$
BEGIN
  RAISE NOTICE '=== Migration 002c Complete ===';
  RAISE NOTICE 'Note categories reduced to 2: fact, reflection';
  RAISE NOTICE 'Total notes migrated: %', (SELECT COUNT(*) FROM notes);
  RAISE NOTICE 'New distribution: %', (
    SELECT COALESCE(string_agg(category::text || ': ' || count::text, ', '), 'No notes found')
    FROM (
      SELECT category, COUNT(*) as count 
      FROM notes 
      GROUP BY category
    ) t
  );
  
  -- Verify enum values
  RAISE NOTICE 'Enum values: %', (SELECT array_agg(enumlabel ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'note_category'::regtype);
END $$;

-- ============================================================================
-- ROLLBACK (TEST ONLY)
-- ============================================================================

/*
To rollback:
pg_restore -U n8n_user -d kairon backups/pre_note_categories_fix_*.dump
*/
