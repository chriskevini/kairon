-- ============================================================================
-- DROP USER_STATE: All fields are derivable from events/projections
-- ============================================================================
-- Analysis:
-- - last_observation_at → Derivable from MAX(events.received_at)
-- - mode → Never queried, dead code
-- - updated_at → Redundant with last_observation_at
--
-- Queries to derive state:
-- 
-- Last observation time:
-- SELECT MAX(received_at) FROM events WHERE payload->>'author_login' = 'chr15';
--
-- Sleep status:
-- SELECT data->>'category' = 'sleep' FROM projections 
-- WHERE projection_type = 'activity' ORDER BY created_at DESC LIMIT 1;
--
-- This is the final schema cleanup. No more migrations after this!
-- ============================================================================

BEGIN;

-- Drop user_state table entirely
DROP TABLE IF EXISTS user_state CASCADE;

\echo 'Dropped user_state table';

-- Verify it's gone
SELECT 
  COUNT(*) as remaining_user_state_tables 
FROM information_schema.tables 
WHERE table_name = 'user_state' AND table_schema = 'public';

COMMIT;

\echo ''
\echo '✅ user_state table dropped!'
\echo ''
\echo 'All user state is now derived from events/projections:'
\echo '  - Last observation: MAX(events.received_at)'
\echo '  - Sleep status: latest activity projection category'
\echo '  - No more stale state, single source of truth!'
