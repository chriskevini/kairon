-- Migration 007: Add extraction_trace_id to thread_extractions for complete audit trail
--
-- Purpose: Connect thread extractions to the LLM trace that generated them,
--          enabling complete audit trail from saved note/todo back to original
--          thread context and LLM reasoning.
--
-- Safety: Adding nullable column with foreign key (safe, no data loss)

BEGIN;

-- Add extraction_trace_id column (nullable for now, will backfill)
ALTER TABLE thread_extractions
ADD COLUMN extraction_trace_id UUID REFERENCES traces(id);

-- Add index for lookups
CREATE INDEX idx_thread_extractions_extraction_trace_id 
ON thread_extractions(extraction_trace_id);

-- Add comment explaining the relationship
COMMENT ON COLUMN thread_extractions.extraction_trace_id IS 
'References the thread_extraction trace that generated this item via LLM. Enables complete audit trail from saved projection back to original thread context.';

COMMIT;

-- Note: Existing rows will have NULL extraction_trace_id
-- Save_Chat workflow will populate this for new extractions going forward
-- To backfill existing data, would need to:
--   1. Find conversation's raw_event_id from thread_extractions.conversation_id
--   2. Look up traces with step_name='thread_extraction' for that event
--   3. Update thread_extractions with the trace_id
-- This is optional since old extractions may not have traces anyway
