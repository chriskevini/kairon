-- Migration 020: Drop unused GIN indexes
-- 
-- These indexes were added but have 0 scans in production (per pg_stat_user_indexes).
-- All current queries use ->> (text extraction), not @> (containment).
-- GIN indexes only optimize containment queries, providing no benefit here.
-- 
-- Future RAG implementation will use pgvector, not GIN on JSONB.
-- Dropping these reduces write overhead without affecting read performance.

BEGIN;

-- Drop unused GIN indexes on JSONB columns
DROP INDEX IF EXISTS idx_events_payload_gin;
DROP INDEX IF EXISTS idx_projections_data_gin;

-- Drop unused B-tree indexes on JSONB (also 0 scans)
DROP INDEX IF EXISTS idx_events_payload;
DROP INDEX IF EXISTS idx_projections_data;
DROP INDEX IF EXISTS idx_traces_data;
DROP INDEX IF EXISTS idx_traces_trace_chain;

-- Note: Keeping idx_projections_data_timestamp - it IS used for ORDER BY queries

COMMIT;

-- Verify remaining indexes
-- Run: SELECT indexname FROM pg_indexes WHERE tablename IN ('events', 'projections', 'traces');
