-- Migration 015: Remove step_order column (derivable from trace_chain)
--
-- Purpose: Eliminate redundant step_order column. It equals trace_chain.length + 1
--          and provides no additional information.
--
-- Rationale:
--   - step_order is always derivable: COALESCE(array_length(trace_chain, 1), 0) + 1
--   - No queries rely on step_order for filtering or ordering
--   - Simplifies INSERT statements in workflows
--   - Reduces schema complexity
--
-- Safety: Safe to drop - data is fully derivable from trace_chain

BEGIN;

-- Drop the column
ALTER TABLE traces DROP COLUMN IF EXISTS step_order;

-- Add a view or function if needed for backward compatibility
-- (None needed - no code uses step_order)

COMMIT;
