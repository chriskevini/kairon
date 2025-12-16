-- Seed data for Kairon Life OS
-- Categories and initial configuration

-- ============================================================================
-- ACTIVITY CATEGORIES
-- ============================================================================

INSERT INTO activity_categories (name, is_sleep_category, sort_order) VALUES
  ('work', false, 1),
  ('leisure', false, 2),
  ('study', false, 3),
  ('relationships', false, 4),
  ('sleep', true, 5),
  ('health', false, 6)
ON CONFLICT (name) DO NOTHING;

-- ============================================================================
-- NOTE CATEGORIES
-- ============================================================================

INSERT INTO note_categories (name, sort_order) VALUES
  ('idea', 1),
  ('reflection', 2),
  ('decision', 3),
  ('question', 4),
  ('meta', 5)
ON CONFLICT (name) DO NOTHING;

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

INSERT INTO config (key, value) VALUES
  ('north_star', NULL) -- User will set this with ::north_star set <text>
ON CONFLICT (key) DO NOTHING;

-- ============================================================================
-- USER STATE (Initialize for single user)
-- ============================================================================

-- You'll need to set your Discord username here
-- INSERT INTO user_state (user_login, sleeping, last_observation_at) VALUES
--   ('your_discord_username', false, NULL)
-- ON CONFLICT (user_login) DO NOTHING;
