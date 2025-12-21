-- Kairon Database Schema
-- This is the canonical schema. For fresh installs, run this file.
-- Historical migrations are archived in db/migrations/archive/

BEGIN;

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

--------------------------------------------------------------------------------
-- CORE TABLES
--------------------------------------------------------------------------------

-- Events: Immutable log of all incoming events (Discord messages, system triggers)
CREATE TABLE IF NOT EXISTS events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  event_type TEXT NOT NULL,  -- 'discord_message', 'system', 'discord_reaction'
  payload JSONB NOT NULL DEFAULT '{}',
  idempotency_key TEXT NOT NULL,
  metadata JSONB DEFAULT '{}',
  timezone TEXT,  -- User's timezone at event time (e.g., 'America/New_York')
  
  UNIQUE (event_type, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_events_received_at ON events(received_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_event_type ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_idempotency ON events(idempotency_key) WHERE idempotency_key IS NOT NULL;
-- Note: GIN index on payload removed in migration 020 (unused - queries use ->> not @>)

-- Traces: One trace per LLM call, always references an event
CREATE TABLE IF NOT EXISTS traces (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  event_id UUID NOT NULL REFERENCES events(id),
  step_name TEXT NOT NULL,  -- 'multi_capture', 'nudge', 'daily_summary', 'thread_response', etc.
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  data JSONB NOT NULL DEFAULT '{}',  -- {input, prompt, completion, result, duration_ms}
  trace_chain UUID[] NOT NULL DEFAULT '{}',  -- Always includes event_id
  voided_at TIMESTAMPTZ,
  superseded_by_trace_id UUID REFERENCES traces(id)
);

CREATE INDEX IF NOT EXISTS idx_traces_event_id ON traces(event_id);
CREATE INDEX IF NOT EXISTS idx_traces_step_name ON traces(step_name);
CREATE INDEX IF NOT EXISTS idx_traces_created_at ON traces(created_at DESC);

-- Projections: Structured outputs from traces (activities, notes, todos, nudges, summaries)
CREATE TABLE IF NOT EXISTS projections (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  trace_id UUID NOT NULL REFERENCES traces(id),
  event_id UUID NOT NULL REFERENCES events(id),
  trace_chain UUID[] NOT NULL DEFAULT '{}',  -- Always includes event_id, trace_id
  projection_type TEXT NOT NULL,  -- 'activity', 'note', 'todo', 'nudge', 'daily_summary', 'thread_response', 'thread_extraction'
  data JSONB NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'auto_confirmed',  -- 'pending', 'auto_confirmed', 'confirmed', 'voided'
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  confirmed_at TIMESTAMPTZ,
  voided_at TIMESTAMPTZ,
  voided_reason TEXT,
  voided_by_event_id UUID REFERENCES events(id),
  superseded_by_projection_id UUID REFERENCES projections(id),
  supersedes_projection_id UUID REFERENCES projections(id),
  quality_score NUMERIC,
  user_edited BOOLEAN DEFAULT FALSE,
  metadata JSONB DEFAULT '{}',
  timezone TEXT  -- User's timezone at projection time (e.g., 'America/New_York')
);

CREATE INDEX IF NOT EXISTS idx_projections_type ON projections(projection_type);
CREATE INDEX IF NOT EXISTS idx_projections_status ON projections(status);
CREATE INDEX IF NOT EXISTS idx_projections_event_id ON projections(event_id);
CREATE INDEX IF NOT EXISTS idx_projections_trace_id ON projections(trace_id);
CREATE INDEX IF NOT EXISTS idx_projections_created_at ON projections(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_projections_data_timestamp ON projections(((data->>'timestamp')::timestamptz) DESC);
-- Note: GIN index on data removed in migration 020 (unused - queries use ->> not @>)

-- Config: User configuration (north_star, timezone, etc.)
CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by_raw_event_id UUID REFERENCES events(id)
);

-- Embeddings: Vector embeddings for RAG (future use)
CREATE TABLE IF NOT EXISTS embeddings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  projection_id UUID REFERENCES projections(id),
  model TEXT NOT NULL,
  model_version TEXT,
  embedding_data JSONB NOT NULL,
  embedded_text TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_embeddings_projection_id ON embeddings(projection_id);

--------------------------------------------------------------------------------
-- CONVENIENCE VIEWS
--------------------------------------------------------------------------------

-- Activity log (recent activities)
CREATE OR REPLACE VIEW activity_log_v2 AS
SELECT 
  p.id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  p.data->>'description' as description,
  p.status,
  p.created_at,
  p.event_id,
  p.trace_id,
  p.timezone,
  e.payload->>'discord_message_id' as discord_message_id,
  e.payload->>'discord_channel_id' as discord_channel_id
FROM projections p
LEFT JOIN events e ON p.event_id = e.id
WHERE p.projection_type = 'activity'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

-- Notes
CREATE OR REPLACE VIEW notes_v2 AS
SELECT 
  p.id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  p.data->>'text' as text,
  p.status,
  p.created_at,
  p.event_id,
  p.trace_id,
  p.timezone
FROM projections p
WHERE p.projection_type = 'note'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

-- Todos
CREATE OR REPLACE VIEW todos_v2 AS
SELECT 
  p.id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'text' as text,
  COALESCE(p.data->>'status', 'pending') as todo_status,
  p.data->>'priority' as priority,
  p.status as projection_status,
  p.created_at,
  p.event_id,
  p.trace_id,
  p.timezone
FROM projections p
WHERE p.projection_type = 'todo'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

-- Recent projections (all types)
CREATE OR REPLACE VIEW recent_projections AS
SELECT 
  p.id,
  p.projection_type,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  COALESCE(p.data->>'description', p.data->>'text') as text,
  p.status,
  p.created_at,
  p.timezone,
  e.payload->>'discord_guild_id' as guild_id,
  e.payload->>'discord_channel_id' as channel_id,
  e.payload->>'discord_message_id' as message_id
FROM projections p
LEFT JOIN events e ON p.event_id = e.id
WHERE p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

-- Thread history (for conversation context)
CREATE OR REPLACE VIEW thread_history AS
SELECT
  p.id,
  p.event_id,
  p.trace_id,
  p.data->>'thread_id' as thread_id,
  p.data->>'role' as role,
  p.data->>'content' as content,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.created_at,
  p.timezone
FROM projections p
WHERE p.projection_type = 'thread_response'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz ASC;

-- Projection audit trail
CREATE OR REPLACE VIEW projection_audit_trail AS
SELECT
  p.id,
  p.projection_type,
  p.status,
  p.created_at,
  p.voided_at,
  p.voided_reason,
  p.trace_chain,
  t.step_name as trace_step,
  e.event_type,
  e.received_at as event_time
FROM projections p
LEFT JOIN traces t ON p.trace_id = t.id
LEFT JOIN events e ON p.event_id = e.id
ORDER BY p.created_at DESC;

-- Thread extractions
CREATE OR REPLACE VIEW thread_extractions_v2 AS
SELECT 
  p.id,
  p.data->>'thread_id' as thread_id,
  p.data->>'extraction_type' as extraction_type,
  p.data->>'content' as content,
  p.data->'metadata' as metadata,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.status,
  p.created_at,
  p.event_id,
  p.trace_id,
  p.timezone
FROM projections p
WHERE p.projection_type = 'thread_extraction'
  AND p.status IN ('auto_confirmed', 'confirmed')
ORDER BY (p.data->>'timestamp')::timestamptz DESC;

COMMIT;
