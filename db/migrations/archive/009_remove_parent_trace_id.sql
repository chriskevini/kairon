-- Migration 009: Remove parent_trace_id column (superseded by trace_chain)
--
-- Purpose: Eliminate redundant parent_trace_id now that trace_chain provides
--          complete ancestry information. Parent = trace_chain[length-1].
--
-- Rationale:
--   - parent_trace_id is derivable from trace_chain
--   - No queries currently use it directly
--   - Eliminates data redundancy and sync issues
--   - Simpler INSERT statements in workflows
--
-- Safety: Safe to drop - data not queried, fully superseded by trace_chain

BEGIN;

-- Drop index first
DROP INDEX IF EXISTS idx_traces_parent;

-- Drop foreign key constraint
ALTER TABLE traces DROP CONSTRAINT IF EXISTS traces_parent_trace_id_fkey;

-- Drop the column
ALTER TABLE traces DROP COLUMN IF EXISTS parent_trace_id;

-- Add comment explaining the change
COMMENT ON COLUMN traces.trace_chain IS 
'Full chain of trace IDs from originating event to this trace. Parent trace = trace_chain[array_length(trace_chain, 1)-1]. Supersedes old parent_trace_id column.';

COMMIT;
