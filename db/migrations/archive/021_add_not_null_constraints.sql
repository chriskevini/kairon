-- Migration 021: Add NOT NULL constraints to foreign keys and idempotency_key
-- 
-- These columns were designed to be required but were left nullable during
-- initial development. Data audit confirms no null values exist.
--
-- Prerequisites: Run the following queries to verify no nulls before applying:
--   SELECT COUNT(*) FROM projections WHERE trace_id IS NULL OR event_id IS NULL;
--   SELECT COUNT(*) FROM events WHERE idempotency_key IS NULL;

BEGIN;

-- Add NOT NULL to projections.trace_id
ALTER TABLE projections
  ALTER COLUMN trace_id SET NOT NULL;

-- Add NOT NULL to projections.event_id  
ALTER TABLE projections
  ALTER COLUMN event_id SET NOT NULL;

-- Add NOT NULL to events.idempotency_key
ALTER TABLE events
  ALTER COLUMN idempotency_key SET NOT NULL;

COMMIT;
