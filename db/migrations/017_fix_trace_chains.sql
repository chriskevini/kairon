-- Migration 017: Fix empty trace_chains in traces table
-- Traces should always have at least the event_id in their trace_chain

BEGIN;

-- Fix traces with empty trace_chain: set trace_chain = ARRAY[event_id, trace_id]
UPDATE traces
SET trace_chain = ARRAY[event_id, id]
WHERE trace_chain = '{}' OR trace_chain IS NULL;

-- Also fix projections with empty or missing event_id in trace_chain
UPDATE projections
SET trace_chain = ARRAY[event_id, trace_id]
WHERE (trace_chain = '{}' OR trace_chain IS NULL OR NOT (event_id = ANY(trace_chain)))
  AND event_id IS NOT NULL
  AND trace_id IS NOT NULL;

COMMIT;
