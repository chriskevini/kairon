-- Seed data for Kairon Life OS
-- Initial configuration for fresh installs
--
-- Note: As of Migration 006+, categories are stored as strings in JSONB
-- (not separate tables). This file only seeds the config table.

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

INSERT INTO config (key, value) VALUES
  ('north_star', '')  -- User sets this with ::north_star set <text>
ON CONFLICT (key) DO NOTHING;

-- Optional: Set default timezone
-- INSERT INTO config (key, value) VALUES
--   ('timezone', 'America/New_York')
-- ON CONFLICT (key) DO NOTHING;
