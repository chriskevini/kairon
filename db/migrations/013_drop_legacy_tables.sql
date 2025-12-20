-- Migration 013: Drop Legacy Tables
-- 
-- This migration removes tables that have been fully migrated to the simplified 5-table architecture.
-- All data from these tables has been migrated to either events, traces, or projections.
--
-- Tables being dropped:
--   - threads: Now derived from events (thread_id stored in payload)
--   - conversation_messages: Migrated to projections (type: thread_response)
--   - activity_log: Migrated to projections (type: activity)
--   - notes: Migrated to projections (type: note)
--   - thread_extractions: Migrated to projections (type: thread_extraction)
--   - raw_events: Never used, replaced by events table
--   - routing_decisions: Migrated to traces
--
-- Prerequisites:
--   - Migration 012 must have run (migrated conversation_messages to projections)
--   - All workflows must be updated to not reference these tables
--   - Backup should be taken before running this migration

BEGIN;

-- Drop views first (if any exist that reference these tables)
DROP VIEW IF EXISTS unsaved_extractions CASCADE;

-- Drop legacy tables
-- Using CASCADE to handle any remaining foreign key constraints
DROP TABLE IF EXISTS threads CASCADE;
DROP TABLE IF EXISTS conversation_messages CASCADE;
DROP TABLE IF EXISTS activity_log CASCADE;
DROP TABLE IF EXISTS notes CASCADE;
DROP TABLE IF EXISTS thread_extractions CASCADE;
DROP TABLE IF EXISTS raw_events CASCADE;
DROP TABLE IF EXISTS routing_decisions CASCADE;

-- Add comment to schema
COMMENT ON SCHEMA public IS 'Kairon: 5-table architecture (events, traces, projections, embeddings, config). Legacy tables dropped in migration 013.';

COMMIT;
