-- Migration 008: Graduate trace_chain from JSONB to dedicated column
--
-- Purpose: Make trace_chain a first-class indexed column for efficient queries
--          and consistent with projections table structure.
--
-- Rationale:
--   - trace_chain is fundamental relationship, not just metadata
--   - Enables efficient ancestry queries (find all traces in a chain)
--   - Consistent with projection.trace_chain structure
--   - Better query performance and referential integrity
--
-- Safety: Adding nullable column, no data loss

BEGIN;

-- Add trace_chain column to traces table
ALTER TABLE traces
ADD COLUMN trace_chain UUID[];

-- Migrate existing data from JSONB to column
-- (Currently trace_chain is being passed but may not be stored in data)
-- This will be NULL for existing rows, populated going forward

-- Add GIN index for array containment queries
CREATE INDEX idx_traces_trace_chain ON traces USING GIN (trace_chain);

-- Add comment
COMMENT ON COLUMN traces.trace_chain IS 
'Full chain of trace IDs from originating event to this trace. Enables complete audit trail traversal.';

COMMIT;

-- Note: Workflows will need to be updated to write trace_chain to column
-- instead of (or in addition to) JSONB data field
