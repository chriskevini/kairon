-- Migration: 025_schema_migrations.sql
-- Add migration version tracking table to track which migrations have been applied

BEGIN;

-- Create schema_migrations table
CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    checksum TEXT,
    description TEXT,
    migrated_by TEXT DEFAULT current_user
);

-- Create index on applied_at for history queries
CREATE INDEX IF NOT EXISTS idx_schema_migrations_applied_at
    ON schema_migrations(applied_at DESC);

-- Add comment
COMMENT ON TABLE schema_migrations IS 'Tracks database migrations that have been applied';
COMMENT ON COLUMN schema_migrations.version IS 'Migration file name without .sql extension (e.g., 001_initial_data)';
COMMENT ON COLUMN schema_migrations.applied_at IS 'Timestamp when migration was applied';
COMMENT ON COLUMN schema_migrations.checksum IS 'SHA256 checksum of migration file for integrity verification';
COMMENT ON COLUMN schema_migrations.description IS 'Human-readable description of migration purpose';

COMMIT;
