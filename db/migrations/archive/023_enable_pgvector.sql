-- Migration: 023_enable_pgvector.sql
-- Description: Enable pgvector extension and add embedding columns
-- Part of: Proactive Agent Architecture (Phase 2)
-- Prerequisites:
--   1. pgvector extension installed on PostgreSQL server
--   2. Database user has CREATE EXTENSION privilege

BEGIN;

-- Check if pgvector is available
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector') THEN
    RAISE EXCEPTION 'pgvector extension not available. Install: apt install postgresql-15-pgvector';
  END IF;
END $$;

-- Enable the vector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Add embedding column to prompt_modules for semantic selection
ALTER TABLE prompt_modules 
  ADD COLUMN IF NOT EXISTS embedding vector(384);

-- Index for prompt module similarity search (small dataset, lists=10)
CREATE INDEX IF NOT EXISTS idx_prompt_modules_embedding 
  ON prompt_modules USING ivfflat (embedding vector_cosine_ops) 
  WITH (lists = 10);

-- Add vector column to existing embeddings table
-- Note: embedding_data (JSONB) remains for metadata compatibility
ALTER TABLE embeddings 
  ADD COLUMN IF NOT EXISTS embedding vector(384);

-- Index for projection embedding similarity search (larger dataset, lists=100)
CREATE INDEX IF NOT EXISTS idx_embeddings_vector 
  ON embeddings USING ivfflat (embedding vector_cosine_ops) 
  WITH (lists = 100);

COMMIT;
