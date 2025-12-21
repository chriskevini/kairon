-- ============================================================================
-- Migration 006: Event-Trace-Projection Architecture
-- ============================================================================
--
-- Purpose: Create new 4-table schema alongside existing tables for parallel running
--
-- Tables Created:
--   - events: Immutable event log (replaces raw_events)
--   - traces: LLM reasoning chains (replaces routing_decisions + adds multi-step support)
--   - projections: Structured outputs (replaces activity_log, notes, todos, thread_extractions)
--   - embeddings: Vector embeddings for RAG (unpopulated initially)
--
-- Migration Strategy:
--   Phase 1: Create new tables (this file)
--   Phase 2: Create compatibility views
--   Phase 3: Migrate existing data
--   Phase 4: Update n8n workflows
--   Phase 5: Parallel running (1 week)
--   Phase 6: Drop old tables
--
-- ============================================================================

BEGIN;

-- Enable pgvector extension for embeddings (optional - skip if not available)
DO $$ 
BEGIN
    CREATE EXTENSION IF NOT EXISTS vector;
    RAISE NOTICE 'pgvector extension enabled';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'pgvector extension not available - embeddings table will be created without vector column';
END $$;

-- ============================================================================
-- 1. EVENTS TABLE (Immutable Facts)
-- ============================================================================

CREATE TABLE events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  event_type TEXT NOT NULL,
  source TEXT NOT NULL,
  payload JSONB NOT NULL,
  
  idempotency_key TEXT NOT NULL,  -- REQUIRED (never null)
  
  metadata JSONB DEFAULT '{}'::jsonb,
  
  UNIQUE (event_type, idempotency_key)
);

CREATE INDEX idx_events_received_at ON events(received_at DESC);
CREATE INDEX idx_events_type ON events(event_type);
CREATE INDEX idx_events_payload ON events USING gin(payload);

COMMENT ON TABLE events IS 'Immutable event log (new schema) - replaces raw_events';
COMMENT ON COLUMN events.idempotency_key IS 'Required unique key per event_type. If source does not provide, generate one.';
COMMENT ON COLUMN events.event_type IS 'Event types: discord_message, discord_reaction, user_stop, user_correction, thread_save, cron_trigger, system_event, fitbit_sleep, fitbit_activity';
COMMENT ON COLUMN events.payload IS 'All event data (flexible JSONB schema)';

-- ============================================================================
-- 2. TRACES TABLE (AI Reasoning Chains)
-- ============================================================================

CREATE TABLE traces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  parent_trace_id UUID NULL REFERENCES traces(id) ON DELETE CASCADE,
  
  -- Step identification
  step_name TEXT NOT NULL,    -- 'intent_classification', 'multi_extraction', 'thread_summarization', etc.
  step_order INT NOT NULL,    -- 1, 2, 3... for ordering within a chain
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- All step data in JSONB (flexible schema)
  data JSONB NOT NULL,  -- Contains: result, prompt, model, confidence, reasoning, duration_ms, etc.
  
  -- Voiding/correction tracking
  voided_at TIMESTAMPTZ NULL,
  superseded_by_trace_id UUID NULL REFERENCES traces(id)
);

CREATE INDEX idx_traces_event ON traces(event_id);
CREATE INDEX idx_traces_parent ON traces(parent_trace_id) WHERE parent_trace_id IS NOT NULL;
CREATE INDEX idx_traces_data ON traces USING gin(data);
CREATE INDEX idx_traces_step_name ON traces(step_name);

COMMENT ON TABLE traces IS 'LLM reasoning chains - replaces routing_decisions + adds multi-step tracking';
COMMENT ON COLUMN traces.step_name IS 'Trace step types: intent_classification, multi_extraction, activity_extraction, note_extraction, thread_summarization, tag_detection, rule_based_routing';
COMMENT ON COLUMN traces.data IS 'All LLM data: result, prompt, model, confidence, reasoning, duration_ms (flexible JSONB schema)';
COMMENT ON COLUMN traces.parent_trace_id IS 'Links traces into chains (NULL for root traces)';

-- ============================================================================
-- 3. PROJECTIONS TABLE (Structured Outputs)
-- ============================================================================

CREATE TABLE projections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- References (denormalized for query speed)
  trace_id UUID NOT NULL REFERENCES traces(id) ON DELETE CASCADE,
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  trace_chain UUID[] NOT NULL,  -- Full chain from root to leaf: ['trace-900', 'trace-901', 'trace-902']
  
  -- Projection classification
  projection_type TEXT NOT NULL,  -- 'activity', 'note', 'todo', 'thread_extraction', 'assistant_message'
  
  -- The structured data (JSONB for flexibility)
  data JSONB NOT NULL,
  
  -- Lifecycle management
  status TEXT NOT NULL DEFAULT 'pending',  -- 'pending', 'auto_confirmed', 'confirmed', 'voided'
  confirmed_at TIMESTAMPTZ NULL,
  voided_at TIMESTAMPTZ NULL,
  voided_reason TEXT NULL,  -- 'user_correction', 'user_rejected', 'duplicate', 'superseded', 'system_correction'
  voided_by_event_id UUID NULL REFERENCES events(id),
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Correction tracking
  superseded_by_projection_id UUID NULL REFERENCES projections(id),
  supersedes_projection_id UUID NULL REFERENCES projections(id),
  
  -- Quality tracking (nullable - not used initially)
  quality_score NUMERIC NULL,
  user_edited BOOLEAN NULL,
  
  metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX idx_projections_trace ON projections(trace_id);
CREATE INDEX idx_projections_event ON projections(event_id);
CREATE INDEX idx_projections_type_status ON projections(projection_type, status);
CREATE INDEX idx_projections_data ON projections USING gin(data);
CREATE INDEX idx_projections_created_at ON projections(created_at DESC);

COMMENT ON TABLE projections IS 'Structured outputs - replaces activity_log, notes, todos, thread_extractions';
COMMENT ON COLUMN projections.projection_type IS 'Projection types: activity, note, todo, thread_extraction, assistant_message';
COMMENT ON COLUMN projections.data IS 'All projection data: category, description, timestamp, etc. (flexible JSONB schema, NO ENUMS)';
COMMENT ON COLUMN projections.status IS 'Lifecycle: pending (awaiting user action) → auto_confirmed (direct capture) OR confirmed (user approved) → voided (rejected/corrected)';
COMMENT ON COLUMN projections.trace_chain IS 'Full audit trail: array of trace IDs from root to leaf';

-- ============================================================================
-- 4. EMBEDDINGS TABLE (RAG Support)
-- ============================================================================

-- Note: This table requires pgvector extension. If not available, it will be skipped.
DO $$ 
BEGIN
    -- Check if vector type exists (pgvector installed)
    IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'vector') THEN
        -- Create embeddings table with vector column
        CREATE TABLE embeddings (
          id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          
          -- Reference to source projection
          projection_id UUID NOT NULL REFERENCES projections(id) ON DELETE CASCADE,
          
          -- Embedding metadata
          model TEXT NOT NULL,          -- 'text-embedding-3-small', 'voyage-2', 'text-embedding-3-large'
          model_version TEXT NULL,      -- Track version for reproducibility
          embedding vector(1536),       -- pgvector type, dimension varies by model
          
          -- What was embedded (denormalized for speed)
          embedded_text TEXT NOT NULL,
          
          created_at TIMESTAMPTZ DEFAULT NOW()
        );

        CREATE INDEX idx_embeddings_projection ON embeddings(projection_id);
        CREATE INDEX idx_embeddings_model ON embeddings(model);
        CREATE INDEX idx_embeddings_vector ON embeddings USING hnsw (embedding vector_cosine_ops);

        COMMENT ON TABLE embeddings IS 'Vector embeddings for RAG (unpopulated initially)';
        COMMENT ON COLUMN embeddings.embedding IS 'Vector dimension varies by model: 1536 for text-embedding-3-small, 1024 for voyage-2';
        
        RAISE NOTICE 'embeddings table created with pgvector support';
    ELSE
        -- Create embeddings table without vector column (placeholder for future)
        CREATE TABLE embeddings (
          id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          
          -- Reference to source projection
          projection_id UUID NOT NULL REFERENCES projections(id) ON DELETE CASCADE,
          
          -- Embedding metadata
          model TEXT NOT NULL,
          model_version TEXT NULL,
          embedding_data JSONB,  -- Store as JSONB until pgvector is installed
          
          -- What was embedded (denormalized for speed)
          embedded_text TEXT NOT NULL,
          
          created_at TIMESTAMPTZ DEFAULT NOW()
        );

        CREATE INDEX idx_embeddings_projection ON embeddings(projection_id);
        CREATE INDEX idx_embeddings_model ON embeddings(model);

        COMMENT ON TABLE embeddings IS 'Vector embeddings for RAG (pgvector not available - using JSONB temporarily)';
        
        RAISE NOTICE 'embeddings table created WITHOUT pgvector (using JSONB placeholder)';
    END IF;
END $$;

-- ============================================================================
-- 5. MIGRATION VIEWS (Backward Compatibility)
-- ============================================================================

-- View: activity_log compatibility
CREATE VIEW activity_log_v2 AS
SELECT 
  p.id,
  p.event_id as raw_event_id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  p.data->>'description' as description,
  p.data->>'thread_id' as thread_id,
  (p.data->>'confidence')::numeric as confidence,
  p.metadata
FROM projections p
WHERE p.projection_type = 'activity'
  AND p.status IN ('auto_confirmed', 'confirmed');

COMMENT ON VIEW activity_log_v2 IS 'Backward compatibility view for activity_log table';

-- View: notes compatibility
CREATE VIEW notes_v2 AS
SELECT 
  p.id,
  p.event_id as raw_event_id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  p.data->>'text' as text,
  p.data->>'thread_id' as thread_id,
  p.metadata
FROM projections p
WHERE p.projection_type = 'note'
  AND p.status IN ('auto_confirmed', 'confirmed');

COMMENT ON VIEW notes_v2 IS 'Backward compatibility view for notes table';

-- View: todos compatibility
CREATE VIEW todos_v2 AS
SELECT 
  p.id,
  p.event_id as raw_event_id,
  p.data->>'description' as description,
  p.status as status,
  p.data->>'priority' as priority,
  (p.data->>'is_goal')::boolean as is_goal,
  (p.data->>'due_date')::date as due_date,
  p.confirmed_at as completed_at,
  p.created_at,
  p.metadata
FROM projections p
WHERE p.projection_type = 'todo';

COMMENT ON VIEW todos_v2 IS 'Backward compatibility view for todos table';

-- View: thread_extractions compatibility
CREATE VIEW thread_extractions_v2 AS
SELECT 
  p.id,
  p.data->>'conversation_id' as conversation_id,
  p.data->>'item_type' as item_type,
  p.data->>'text' as text,
  (p.data->>'display_order')::int as display_order,
  CASE 
    WHEN p.status = 'voided' THEN NULL
    WHEN p.projection_type = 'note' THEN 'note'
    WHEN p.projection_type = 'todo' THEN 'todo'
    ELSE NULL
  END as saved_as,
  p.superseded_by_projection_id as saved_id,
  p.data->>'summary_message_id' as summary_message_id,
  p.created_at
FROM projections p
WHERE p.projection_type = 'thread_extraction';

COMMENT ON VIEW thread_extractions_v2 IS 'Backward compatibility view for thread_extractions table';

-- ============================================================================
-- 6. HELPER VIEWS (New Convenience Views)
-- ============================================================================

-- View: Recent projections (all types)
CREATE VIEW recent_projections AS
SELECT 
  p.id,
  p.projection_type,
  p.status,
  p.data,
  p.created_at,
  e.payload->>'author_login' as author,
  e.payload->>'content' as original_message
FROM projections p
JOIN events e ON p.event_id = e.id
WHERE p.status IN ('auto_confirmed', 'confirmed')
ORDER BY p.created_at DESC;

COMMENT ON VIEW recent_projections IS 'Recent valid projections across all types';

-- View: Projection audit trail
CREATE VIEW projection_audit_trail AS
SELECT 
  p.id as projection_id,
  p.projection_type,
  p.status,
  e.event_type,
  e.received_at as event_time,
  array_length(p.trace_chain, 1) as trace_depth,
  p.created_at,
  CASE 
    WHEN p.voided_at IS NOT NULL THEN 'voided'
    WHEN p.superseded_by_projection_id IS NOT NULL THEN 'superseded'
    ELSE 'active'
  END as lifecycle_status
FROM projections p
JOIN events e ON p.event_id = e.id
ORDER BY e.received_at DESC;

COMMENT ON VIEW projection_audit_trail IS 'Full audit trail for all projections';

-- ============================================================================
-- 7. VERIFICATION
-- ============================================================================

DO $$
BEGIN
  RAISE NOTICE '=== Migration 006 Complete ===';
  RAISE NOTICE 'New tables created:';
  RAISE NOTICE '  - events (with pgvector support)';
  RAISE NOTICE '  - traces (multi-step LLM reasoning)';
  RAISE NOTICE '  - projections (JSONB-first, no enums)';
  RAISE NOTICE '  - embeddings (unpopulated, RAG support)';
  RAISE NOTICE '';
  RAISE NOTICE 'Compatibility views created:';
  RAISE NOTICE '  - activity_log_v2';
  RAISE NOTICE '  - notes_v2';
  RAISE NOTICE '  - todos_v2';
  RAISE NOTICE '  - thread_extractions_v2';
  RAISE NOTICE '';
  RAISE NOTICE 'Helper views created:';
  RAISE NOTICE '  - recent_projections';
  RAISE NOTICE '  - projection_audit_trail';
  RAISE NOTICE '';
  RAISE NOTICE 'Next steps:';
  RAISE NOTICE '  1. Run migration script to copy existing data (see docs/simplified-extensible-schema.md Phase 3)';
  RAISE NOTICE '  2. Update n8n workflows to write to new schema';
  RAISE NOTICE '  3. Parallel run for 1 week';
  RAISE NOTICE '  4. Drop old tables (migration 007)';
END $$;

COMMIT;
