# Kairon Database Schema

Complete reference for the Kairon PostgreSQL database schema, tables, relationships, and usage patterns.

## Table of Contents

- [Overview](#overview)
- [Core Tables](#core-tables)
- [Relationships](#relationships)
- [Migration History](#migration-history)
- [Query Patterns](#query-patterns)
- [Constraints & Indexes](#constraints--indexes)

## Overview

Kairon uses PostgreSQL with a normalized schema designed around the principle: **One LLM call = one trace. Everything traces back to an event.**

### Design Principles

1. **Event Sourcing**: Events are immutable, append-only logs
2. **Trace Everything**: Every LLM call creates a trace record
3. **Structured Projections**: LLM outputs become typed, queryable projections
4. **Configurable**: User preferences stored in flexible key-value store
5. **Future-Ready**: Embeddings table prepared for RAG functionality

### Schema Evolution

- **Version**: See `db/schema.sql` for current canonical schema
- **Migrations**: Historical changes in `db/migrations/archive/`
- **Backwards Compatible**: New fields added with defaults, no destructive changes

## Core Tables

### events

**Purpose**: Immutable log of all incoming events (Discord messages, system triggers)

```sql
CREATE TABLE events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  event_type TEXT NOT NULL,                    -- 'discord_message', 'system'
  payload JSONB NOT NULL DEFAULT '{}',         -- Full event data
  idempotency_key TEXT,                        -- Prevents duplicate processing
  UNIQUE(event_type, idempotency_key)          -- Enforce idempotency
);
```

**Key Fields:**
- `id`: Primary key, referenced by traces and projections
- `event_type`: Type of event ('discord_message', 'system', etc.)
- `payload`: Complete event data as JSONB
- `idempotency_key`: Unique identifier for deduplication
- `received_at`: When event was received

**Usage Patterns:**
```sql
-- Insert new event (idempotent)
INSERT INTO events (event_type, payload, idempotency_key)
VALUES ('discord_message', '{"content": "...", "author": "..."}', 'discord_msg_123')
ON CONFLICT (event_type, idempotency_key) DO NOTHING;

-- Query recent events
SELECT id, payload->>'content' as content, received_at
FROM events
WHERE event_type = 'discord_message'
ORDER BY received_at DESC
LIMIT 10;
```

### traces

**Purpose**: Records every LLM API call with metadata

```sql
CREATE TABLE traces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  llm_model TEXT,                             -- 'openai/gpt-4', 'anthropic/claude'
  llm_input_tokens INTEGER,                   -- Token usage tracking
  llm_output_tokens INTEGER,
  llm_duration_ms INTEGER,                    -- Response time
  confidence NUMERIC(3,2),                    -- 0.00-1.00 confidence score
  reasoning TEXT                              -- LLM reasoning/thinking
);
```

**Key Fields:**
- `event_id`: Links to the event that triggered this LLM call
- `llm_model`: Which model was used
- `llm_*_tokens`: Usage tracking for cost monitoring
- `confidence`: How confident the LLM was in its response
- `reasoning`: The LLM's internal reasoning (if available)

**Usage Patterns:**
```sql
-- Record LLM call
INSERT INTO traces (event_id, llm_model, llm_input_tokens, llm_output_tokens, confidence)
VALUES ('event-uuid', 'openai/gpt-4', 150, 75, 0.95);

-- Get LLM usage statistics
SELECT llm_model, COUNT(*) as calls,
       AVG(llm_input_tokens + llm_output_tokens) as avg_tokens,
       AVG(confidence) as avg_confidence
FROM traces
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY llm_model;
```

### projections

**Purpose**: Structured outputs from LLM processing (activities, notes, todos)

```sql
CREATE TABLE projections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id UUID REFERENCES traces(id) ON DELETE CASCADE,
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  trace_chain UUID[] NOT NULL DEFAULT '{}',     -- Ancestry for complex processing
  projection_type TEXT NOT NULL,                -- 'activity', 'note', 'todo'
  data JSONB NOT NULL DEFAULT '{}',             -- Structured output
  status TEXT NOT NULL DEFAULT 'pending',       -- 'pending', 'auto_confirmed', 'confirmed', 'voided'
  confirmed_at TIMESTAMPTZ,                     -- When user confirmed
  voided_at TIMESTAMPTZ,                        -- When invalidated
  voided_reason TEXT,                           -- Why invalidated
  voided_by_event_id UUID REFERENCES events(id), -- Event that voided this
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  superseded_by_projection_id UUID REFERENCES projections(id), -- Versioning
  supersedes_projection_id UUID REFERENCES projections(id),
  quality_score NUMERIC(3,2),                   -- 0.00-1.00 quality rating
  user_edited BOOLEAN DEFAULT FALSE,            -- Has been manually edited
  metadata JSONB DEFAULT '{}'::jsonb,           -- Additional metadata
  timezone TEXT                                 -- User's timezone context
);
```

**Key Fields:**
- `projection_type`: What type of structured data ('activity', 'note', 'todo')
- `data`: The actual structured content as JSONB
- `status`: Processing state and user confirmation status
- `trace_chain`: For complex multi-step processing
- `quality_score`: Optional quality rating
- `user_edited`: Whether manually modified by user

**Status Values:**
- `pending`: Initial state, not yet confirmed
- `auto_confirmed`: Automatically confirmed by system
- `confirmed`: Manually confirmed by user
- `voided`: Invalidated/cancelled

**Usage Patterns:**
```sql
-- Create new projection
INSERT INTO projections (event_id, trace_id, projection_type, data, status)
VALUES ('event-uuid', 'trace-uuid', 'activity', '{"text": "debugging auth"}', 'auto_confirmed');

-- Query active projections
SELECT id, projection_type, data->>'text' as content, created_at
FROM projections
WHERE status IN ('auto_confirmed', 'confirmed')
  AND voided_at IS NULL
ORDER BY created_at DESC
LIMIT 10;

-- Void a projection
UPDATE projections
SET status = 'voided', voided_at = NOW(), voided_reason = 'User correction'
WHERE id = 'projection-uuid';
```

### config

**Purpose**: User preferences and system configuration

```sql
CREATE TABLE config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key Configurations:**
- `north_star`: User's guiding principle
- `timezone`: User's timezone (e.g., 'America/Vancouver')
- `summary_time`: When to run daily summaries (e.g., '20:00')
- `last_summary_date`: Date of last summary run

**Usage Patterns:**
```sql
-- Set user preference
INSERT INTO config (key, value) VALUES ('timezone', 'America/Vancouver')
ON CONFLICT (key) UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- Get user config
SELECT key, value FROM config WHERE key IN ('timezone', 'north_star');
```

### prompt_modules

**Purpose**: Reusable prompt templates for LLM interactions

```sql
CREATE TABLE prompt_modules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  description TEXT,
  prompt_template TEXT NOT NULL,
  variables JSONB DEFAULT '[]'::jsonb,    -- Array of variable names
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Key Fields:**
- `name`: Unique identifier for the prompt module
- `prompt_template`: The template text with {{variable}} placeholders
- `variables`: JSON array of variable names used in template
- `description`: Human-readable description

**Usage Patterns:**
```sql
-- Create a prompt module
INSERT INTO prompt_modules (name, description, prompt_template, variables)
VALUES ('activity_extraction', 'Extract activity from message', 'Extract the activity from: {{message}}', '["message"]');

-- Use in workflow
SELECT prompt_template, variables
FROM prompt_modules
WHERE name = 'activity_extraction';
```

### embeddings

**Purpose**: Vector storage for Retrieval-Augmented Generation (RAG)

```sql
CREATE TABLE embeddings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  projection_id UUID NOT NULL REFERENCES projections(id) ON DELETE CASCADE,
  content TEXT NOT NULL,                        -- Text that was embedded
  embedding vector(1536),                       -- Vector representation
  model TEXT NOT NULL,                          -- Embedding model used
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Requires pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;
```

## Relationships

### Entity Relationship Diagram

```
events (immutable log)
├── traces (per LLM call)
│   └── projections (structured outputs)
│       └── embeddings (vector search)
└── projections (direct processing)
    └── embeddings (vector search)

config (user preferences)
```

### Foreign Key Constraints

- `traces.event_id → events.id` (CASCADE)
- `projections.event_id → events.id` (CASCADE)
- `projections.trace_id → traces.id` (SET NULL)
- `projections.superseded_by_projection_id → projections.id`
- `projections.voided_by_event_id → events.id`
- `embeddings.projection_id → projections.id` (CASCADE)

### Core Principle: Trace Everything

Every projection can be traced back to:
1. **Event** - What triggered the processing
2. **Trace** - Which LLM call produced it
3. **Projection Chain** - Version history and corrections

```sql
-- Complete audit trail for a projection
SELECT
  p.id as projection_id,
  p.projection_type,
  p.data,
  t.llm_model,
  t.confidence,
  e.payload->>'content' as original_message,
  e.received_at
FROM projections p
JOIN traces t ON p.trace_id = t.id
JOIN events e ON p.event_id = e.id
WHERE p.id = 'projection-uuid';
```

## Migration History

### Current Schema Version

See `db/schema.sql` for the canonical current schema.

### Migration Archive

Located in `db/migrations/archive/` with numbered files:

- `001_initial_schema.sql` - Base tables
- `002*_note_categories.sql` - Note categorization
- `003_add_todos.sql` - Todo functionality
- `004_thread_extractions.sql` - Thread support
- `017_fix_trace_chains.sql` - Trace chain improvements
- `025_schema_migrations.sql` - Migration tracking

### Migration Best Practices

1. **Test migrations** on copy of production data first
2. **Add defaults** for new required fields
3. **Use transactions** for multi-step changes
4. **Document breaking changes** clearly
5. **Test rollback** procedures

## Query Patterns

### Recent Activity Feed

```sql
SELECT
  p.projection_type,
  p.data->>'text' as content,
  p.created_at,
  e.payload->>'author_login' as author
FROM projections p
JOIN events e ON p.event_id = e.id
WHERE p.status IN ('auto_confirmed', 'confirmed')
  AND p.voided_at IS NULL
  AND p.created_at > NOW() - INTERVAL '7 days'
ORDER BY p.created_at DESC
LIMIT 50;
```

### Activity Statistics

```sql
SELECT
  projection_type,
  COUNT(*) as total,
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '24 hours') as last_24h,
  AVG(quality_score) as avg_quality
FROM projections
WHERE status IN ('auto_confirmed', 'confirmed')
  AND voided_at IS NULL
GROUP BY projection_type
ORDER BY total DESC;
```

### User Timeline

```sql
SELECT
  DATE(created_at) as date,
  projection_type,
  COUNT(*) as count
FROM projections p
JOIN events e ON p.event_id = e.id
WHERE e.payload->>'author_login' = 'username'
  AND p.status IN ('auto_confirmed', 'confirmed')
  AND p.created_at > NOW() - INTERVAL '30 days'
GROUP BY DATE(created_at), projection_type
ORDER BY date DESC;
```

### LLM Usage Tracking

```sql
SELECT
  DATE(created_at) as date,
  llm_model,
  COUNT(*) as calls,
  SUM(llm_input_tokens) as input_tokens,
  SUM(llm_output_tokens) as output_tokens,
  AVG(llm_duration_ms) as avg_response_time_ms,
  AVG(confidence) as avg_confidence
FROM traces
WHERE created_at > NOW() - INTERVAL '30 days'
GROUP BY DATE(created_at), llm_model
ORDER BY date DESC, calls DESC;
```

### Data Quality Monitoring

```sql
SELECT
  projection_type,
  status,
  COUNT(*) as count,
  AVG(quality_score) as avg_quality,
  COUNT(*) FILTER (WHERE user_edited = true) as user_edited_count
FROM projections
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY projection_type, status
ORDER BY projection_type, status;
```

## Constraints & Indexes

### Primary Keys
- `events.id` (UUID)
- `traces.id` (UUID)
- `projections.id` (UUID)
- `config.key` (TEXT)

### Unique Constraints
- `events(event_type, idempotency_key)` - Prevent duplicate events

### Foreign Keys
- `traces.event_id → events.id`
- `projections.event_id → events.id`
- `projections.trace_id → traces.id`
- `projections.voided_by_event_id → events.id`
- `embeddings.projection_id → projections.id`

### Indexes

**Performance Indexes:**
```sql
-- Events
CREATE INDEX idx_events_received_at ON events(received_at DESC);
CREATE INDEX idx_events_type_received ON events(event_type, received_at DESC);
CREATE INDEX idx_events_idempotency ON events(event_type, idempotency_key);

-- Traces
CREATE INDEX idx_traces_event ON traces(event_id);
CREATE INDEX idx_traces_created ON traces(created_at DESC);
CREATE INDEX idx_traces_model ON traces(llm_model);

-- Projections
CREATE INDEX idx_projections_created_at ON projections(created_at DESC);
CREATE INDEX idx_projections_event ON projections(event_id);
CREATE INDEX idx_projections_trace ON projections(trace_id);
CREATE INDEX idx_projections_type_status ON projections(projection_type, status);
CREATE INDEX idx_projections_status_created ON projections(status, created_at DESC);

-- Config
CREATE INDEX idx_config_updated ON config(updated_at DESC);
```

**JSONB Indexes:**
```sql
-- For payload queries
CREATE INDEX idx_events_payload_gin ON events USING GIN (payload);
CREATE INDEX idx_projections_data_gin ON projections USING GIN (data);
```

### Data Integrity

**Check Constraints:**
- `traces.confidence` between 0.00 and 1.00
- `projections.quality_score` between 0.00 and 1.00

**Not Null Constraints:**
- All primary keys
- `events.event_type`, `events.payload`, `events.received_at`
- `traces.event_id`, `traces.created_at`
- `projections.event_id`, `projections.projection_type`, `projections.data`, `projections.status`, `projections.created_at`

## Maintenance

### Vacuum & Analyze

```sql
-- Regular maintenance
VACUUM ANALYZE events;
VACUUM ANALYZE traces;
VACUUM ANALYZE projections;
```

### Archive Old Data

```sql
-- Move old projections to archive table
CREATE TABLE projections_archive AS
SELECT * FROM projections
WHERE created_at < NOW() - INTERVAL '1 year';

DELETE FROM projections WHERE id IN (
  SELECT id FROM projections_archive
);
```

### Monitor Table Sizes

```sql
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

---

**Last Updated:** 2025-12-26
**Schema Version:** 25 (see `db/schema.sql`)