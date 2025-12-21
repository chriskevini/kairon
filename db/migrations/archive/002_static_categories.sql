-- Kairon Life OS - Migration 002: Static Categories
-- Converts from user-editable categories to static enums
-- See: docs/static-categories-decision.md

-- ⚠️ IMPORTANT: Test on a copy first! See: docs/database-migration-safety.md

-- ============================================================================
-- BACKUP CHECKPOINT
-- ============================================================================

-- Before running, create backup:
-- pg_dump -U n8n_user -d kairon -F c -f backups/pre_static_categories_$(date +%Y%m%d_%H%M%S).dump

-- ============================================================================
-- VALIDATION: Check for custom category names
-- ============================================================================

-- Check activity categories
DO $$
DECLARE
  custom_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO custom_count
  FROM activity_categories
  WHERE name NOT IN ('work', 'leisure', 'study', 'health', 'sleep', 'relationships', 'admin');
  
  IF custom_count > 0 THEN
    RAISE NOTICE 'WARNING: Found % custom activity categories that need mapping:', custom_count;
    RAISE NOTICE '%', (
      SELECT string_agg(name, ', ')
      FROM activity_categories
      WHERE name NOT IN ('work', 'leisure', 'study', 'health', 'sleep', 'relationships', 'admin')
    );
  END IF;
END $$;

-- Check note categories
DO $$
DECLARE
  custom_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO custom_count
  FROM note_categories
  WHERE name NOT IN ('idea', 'reflection', 'decision', 'question', 'meta');
  
  IF custom_count > 0 THEN
    RAISE NOTICE 'WARNING: Found % custom note categories that need mapping:', custom_count;
    RAISE NOTICE '%', (
      SELECT string_agg(name, ', ')
      FROM note_categories
      WHERE name NOT IN ('idea', 'reflection', 'decision', 'question', 'meta')
    );
    RAISE EXCEPTION 'Custom categories found. Update migration to handle them before proceeding.';
  END IF;
END $$;

-- ============================================================================
-- CREATE STATIC CATEGORY ENUMS
-- ============================================================================

CREATE TYPE activity_category AS ENUM (
  'work',
  'leisure',
  'study',
  'health',
  'sleep',
  'relationships',
  'admin'
);

COMMENT ON TYPE activity_category IS 'Static activity categories - no longer user-editable';

CREATE TYPE note_category AS ENUM (
  'idea',
  'reflection',
  'decision',
  'question',
  'meta'
);

COMMENT ON TYPE note_category IS 'Static note categories - no longer user-editable';

-- ============================================================================
-- MIGRATE ACTIVITY_LOG
-- ============================================================================

-- Add new column
ALTER TABLE activity_log ADD COLUMN category_new activity_category;

-- Migrate data (map category_id → name → enum)
UPDATE activity_log a
SET category_new = (
  SELECT c.name::activity_category 
  FROM activity_categories c 
  WHERE c.id = a.category_id
);

-- Verify no nulls (all categories mapped successfully)
DO $$
DECLARE
  null_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO null_count FROM activity_log WHERE category_new IS NULL;
  IF null_count > 0 THEN
    RAISE EXCEPTION 'Migration failed: % activity_log rows have NULL category_new', null_count;
  END IF;
END $$;

-- Drop old column and FK constraint
ALTER TABLE activity_log DROP CONSTRAINT activity_log_category_id_fkey;
ALTER TABLE activity_log DROP COLUMN category_id;

-- Rename new column and add NOT NULL
ALTER TABLE activity_log RENAME COLUMN category_new TO category;
ALTER TABLE activity_log ALTER COLUMN category SET NOT NULL;

-- Add index on new column
CREATE INDEX idx_activity_log_category_new ON activity_log(category);

COMMENT ON COLUMN activity_log.category IS 'Static category enum - no FK needed';

-- ============================================================================
-- MIGRATE NOTES
-- ============================================================================

-- Add new column
ALTER TABLE notes ADD COLUMN category_new note_category;

-- Migrate data
UPDATE notes n
SET category_new = (
  SELECT c.name::note_category 
  FROM note_categories c 
  WHERE c.id = n.category_id
);

-- Verify no nulls
DO $$
DECLARE
  null_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO null_count FROM notes WHERE category_new IS NULL;
  IF null_count > 0 THEN
    RAISE EXCEPTION 'Migration failed: % notes rows have NULL category_new', null_count;
  END IF;
END $$;

-- Drop old column and FK constraint
ALTER TABLE notes DROP CONSTRAINT notes_category_id_fkey;
ALTER TABLE notes DROP COLUMN category_id;

-- Rename and set NOT NULL
ALTER TABLE notes RENAME COLUMN category_new TO category;
ALTER TABLE notes ALTER COLUMN category SET NOT NULL;

-- Drop title column (we want pure user thoughts, not LLM-derived titles)
ALTER TABLE notes DROP COLUMN IF EXISTS title;

COMMENT ON COLUMN notes.text IS 'Pure user thought (clean_text) - no LLM modification';

-- Add index
CREATE INDEX idx_notes_category_new ON notes(category);

COMMENT ON COLUMN notes.category IS 'Static category enum - no FK needed';

-- ============================================================================
-- UPDATE VIEWS
-- ============================================================================

-- Drop old views
DROP VIEW IF EXISTS recent_activities;
DROP VIEW IF EXISTS recent_notes;

-- Recreate with new schema (no JOINs needed)
CREATE VIEW recent_activities AS
SELECT 
  a.id,
  a.timestamp,
  a.category,  -- Direct column, not JOIN
  a.description,
  a.thread_id,
  a.confidence,
  re.author_login,
  re.message_url
FROM activity_log a
JOIN raw_events re ON a.raw_event_id = re.id
ORDER BY a.timestamp DESC;

COMMENT ON VIEW recent_activities IS 'Activities with categories (no JOIN needed - static enums)';

CREATE VIEW recent_notes AS
SELECT 
  n.id,
  n.timestamp,
  n.category,  -- Direct column, not JOIN
  n.title,
  n.text,
  n.thread_id,
  re.author_login,
  re.message_url
FROM notes n
JOIN raw_events re ON n.raw_event_id = re.id
ORDER BY n.timestamp DESC;

COMMENT ON VIEW recent_notes IS 'Notes with categories (no JOIN needed - static enums)';

-- ============================================================================
-- DROP OLD CATEGORY TABLES
-- ============================================================================

-- These are no longer needed
DROP TABLE IF EXISTS activity_categories CASCADE;
DROP TABLE IF EXISTS note_categories CASCADE;

-- ============================================================================
-- UPDATE CONVERSATIONS TABLE
-- ============================================================================

-- Remove activity_id (save thread now creates note only, not activity)
ALTER TABLE conversations DROP COLUMN IF EXISTS activity_id;

COMMENT ON COLUMN conversations.note_id IS 'Note created when thread is saved (no activity created)';

-- ============================================================================
-- MIGRATION COMPLETE
-- ============================================================================

-- Verify final state
DO $$
BEGIN
  RAISE NOTICE '=== Migration 002 Complete ===';
  RAISE NOTICE 'Activity categories: %', (SELECT COUNT(*) FROM activity_log);
  RAISE NOTICE 'Note categories: %', (SELECT COUNT(*) FROM notes);
  RAISE NOTICE 'Old category tables dropped: activity_categories, note_categories';
  RAISE NOTICE 'Conversations.activity_id removed (save creates note only)';
END $$;

-- ============================================================================
-- ROLLBACK (TEST ONLY - DO NOT RUN IN PRODUCTION)
-- ============================================================================

/*
To rollback (only use on test database):

-- Restore from backup is recommended, but if needed:

ALTER TABLE activity_log DROP COLUMN category;
ALTER TABLE notes DROP COLUMN category;
DROP TYPE activity_category;
DROP TYPE note_category;

-- Then restore backup:
-- pg_restore -U n8n_user -d kairon backups/pre_static_categories_*.dump
*/
