-- ============================================================================
-- DROP SLEEPING STATE: Remove ephemeral sleeping column from user_state
-- ============================================================================
-- Sleep is an activity category that can be derived from projections.
-- No need to maintain redundant ephemeral state.
--
-- Query to check if user is sleeping:
-- SELECT data->>'category' = 'sleep' as is_sleeping
-- FROM projections
-- WHERE projection_type = 'activity'
-- ORDER BY data->>'timestamp' DESC
-- LIMIT 1;
-- ============================================================================

BEGIN;

-- Drop the sleeping column (no longer needed)
ALTER TABLE user_state DROP COLUMN IF EXISTS sleeping;

\echo 'Dropped sleeping column from user_state';

-- Verify schema
\d user_state

COMMIT;

\echo ''
\echo '✅ Sleeping state removed!'
\echo 'Sleep can now be derived from activity projections.'
