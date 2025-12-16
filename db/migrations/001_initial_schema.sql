-- Kairon Life OS - Initial Schema Migration
-- Phase 1: Core tables for ledger, routing, and conversations

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- RAW EVENTS (Append-only truth)
-- ============================================================================

CREATE TABLE raw_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source_type TEXT NOT NULL CHECK (source_type IN ('discord', 'cron')),
  
  -- Discord metadata (nullable for cron events)
  discord_guild_id TEXT,
  discord_channel_id TEXT,
  discord_message_id TEXT UNIQUE, -- idempotency key
  message_url TEXT,
  author_login TEXT,
  thread_id TEXT,
  
  -- Content
  raw_text TEXT NOT NULL,
  clean_text TEXT NOT NULL, -- tag stripped
  tag TEXT, -- '!!', '++', '::', or null
  
  -- Additional metadata
  metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX idx_raw_events_received_at ON raw_events(received_at DESC);
CREATE INDEX idx_raw_events_thread_id ON raw_events(thread_id) WHERE thread_id IS NOT NULL;
CREATE INDEX idx_raw_events_author ON raw_events(author_login) WHERE author_login IS NOT NULL;
CREATE INDEX idx_raw_events_source ON raw_events(source_type);

COMMENT ON TABLE raw_events IS 'Append-only log of all events entering the system';
COMMENT ON COLUMN raw_events.discord_message_id IS 'Unique message ID for idempotent processing';
COMMENT ON COLUMN raw_events.clean_text IS 'Message text with tag prefix removed';

-- ============================================================================
-- ROUTING DECISIONS (Separate from raw events for clean separation)
-- ============================================================================

CREATE TABLE routing_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_event_id UUID UNIQUE NOT NULL REFERENCES raw_events(id) ON DELETE CASCADE,
  intent TEXT NOT NULL CHECK (intent IN ('Activity', 'Note', 'ThreadStart', 'Chat', 'Commit', 'Command')),
  forced_by TEXT NOT NULL CHECK (forced_by IN ('tag', 'rule', 'agent')),
  confidence NUMERIC CHECK (confidence >= 0.0 AND confidence <= 1.0), -- for agent classifications
  payload JSONB DEFAULT '{}'::jsonb, -- agent reasoning, tool calls, etc.
  routed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_routing_decisions_raw_event ON routing_decisions(raw_event_id);
CREATE INDEX idx_routing_decisions_intent ON routing_decisions(intent);
CREATE INDEX idx_routing_decisions_routed_at ON routing_decisions(routed_at DESC);

COMMENT ON TABLE routing_decisions IS 'Auditable record of how each event was classified and routed';
COMMENT ON COLUMN routing_decisions.forced_by IS 'How intent was determined: tag (deterministic), rule (hardcoded), or agent (LLM)';

-- ============================================================================
-- CATEGORIES (User-editable)
-- ============================================================================

CREATE TABLE activity_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT UNIQUE NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  is_sleep_category BOOLEAN NOT NULL DEFAULT false,
  sort_order INT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_activity_categories_active ON activity_categories(active) WHERE active = true;

COMMENT ON TABLE activity_categories IS 'User-defined activity categories (work, leisure, sleep, etc.)';
COMMENT ON COLUMN activity_categories.is_sleep_category IS 'Flag for sleep detection logic (no hardcoded name matching)';

CREATE TABLE note_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT UNIQUE NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  sort_order INT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_note_categories_active ON note_categories(active) WHERE active = true;

COMMENT ON TABLE note_categories IS 'User-defined note categories (idea, reflection, decision, etc.)';

-- ============================================================================
-- ACTIVITY LOG (Point-in-time observations)
-- ============================================================================

CREATE TABLE activity_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_event_id UUID NOT NULL REFERENCES raw_events(id) ON DELETE CASCADE,
  timestamp TIMESTAMPTZ NOT NULL,
  category_id UUID NOT NULL REFERENCES activity_categories(id),
  description TEXT NOT NULL,
  thread_id TEXT, -- if created from thread commit
  confidence NUMERIC CHECK (confidence >= 0.0 AND confidence <= 1.0), -- agent confidence
  metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX idx_activity_log_timestamp ON activity_log(timestamp DESC);
CREATE INDEX idx_activity_log_category ON activity_log(category_id);
CREATE INDEX idx_activity_log_thread ON activity_log(thread_id) WHERE thread_id IS NOT NULL;
CREATE INDEX idx_activity_log_raw_event ON activity_log(raw_event_id);

COMMENT ON TABLE activity_log IS 'Point-in-time activity observations (no durations stored)';
COMMENT ON COLUMN activity_log.thread_id IS 'Set if activity was created from a thread commit';

-- ============================================================================
-- NOTES
-- ============================================================================

CREATE TABLE notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_event_id UUID NOT NULL REFERENCES raw_events(id) ON DELETE CASCADE,
  timestamp TIMESTAMPTZ NOT NULL,
  category_id UUID NOT NULL REFERENCES note_categories(id),
  title TEXT,
  text TEXT NOT NULL,
  thread_id TEXT, -- if created from thread commit
  metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX idx_notes_timestamp ON notes(timestamp DESC);
CREATE INDEX idx_notes_category ON notes(category_id);
CREATE INDEX idx_notes_thread ON notes(thread_id) WHERE thread_id IS NOT NULL;
CREATE INDEX idx_notes_raw_event ON notes(raw_event_id);

COMMENT ON TABLE notes IS 'Thoughts, insights, reflections, questions';
COMMENT ON COLUMN notes.thread_id IS 'Set if note was created from a thread commit';

-- ============================================================================
-- USER STATE (Single user for MVP)
-- ============================================================================

CREATE TABLE user_state (
  user_login TEXT PRIMARY KEY,
  sleeping BOOLEAN NOT NULL DEFAULT false,
  last_observation_at TIMESTAMPTZ,
  mode TEXT NOT NULL DEFAULT 'ledger' CHECK (mode IN ('ledger', 'converse')),
  updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE user_state IS 'Current state for the user (sleeping, last activity, etc.)';
COMMENT ON COLUMN user_state.sleeping IS 'Derived from activity_categories.is_sleep_category';
COMMENT ON COLUMN user_state.last_observation_at IS 'Timestamp of last activity logged (for proactivity)';

-- ============================================================================
-- CONVERSATIONS (Threads)
-- ============================================================================

CREATE TABLE conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  created_from_raw_event_id UUID REFERENCES raw_events(id),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'committed', 'archived')),
  topic TEXT,
  committed_at TIMESTAMPTZ,
  committed_by_raw_event_id UUID REFERENCES raw_events(id),
  note_id UUID REFERENCES notes(id),
  activity_id UUID REFERENCES activity_log(id),
  metadata JSONB DEFAULT '{}'::jsonb -- initial context retrieved, etc.
);

CREATE INDEX idx_conversations_thread_id ON conversations(thread_id);
CREATE INDEX idx_conversations_status ON conversations(status);
CREATE INDEX idx_conversations_created_at ON conversations(created_at DESC);

COMMENT ON TABLE conversations IS 'Discord thread metadata and commit references';
COMMENT ON COLUMN conversations.metadata IS 'Stores initial context retrieved, thread title changes, etc.';

CREATE TABLE conversation_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  raw_event_id UUID REFERENCES raw_events(id),
  timestamp TIMESTAMPTZ NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
  text TEXT NOT NULL
);

CREATE INDEX idx_conversation_messages_conv ON conversation_messages(conversation_id, timestamp);
CREATE INDEX idx_conversation_messages_timestamp ON conversation_messages(timestamp DESC);

COMMENT ON TABLE conversation_messages IS 'Full conversation history for threads (audit trail)';
COMMENT ON COLUMN conversation_messages.raw_event_id IS 'NULL for assistant messages';

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

CREATE TABLE config (
  key TEXT PRIMARY KEY,
  value TEXT,
  updated_at TIMESTAMPTZ DEFAULT now(),
  updated_by_raw_event_id UUID REFERENCES raw_events(id)
);

COMMENT ON TABLE config IS 'System configuration (north_star, etc.)';

-- ============================================================================
-- FUNCTIONS & TRIGGERS
-- ============================================================================

-- Update updated_at timestamp automatically
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_user_state_updated_at BEFORE UPDATE ON user_state
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_activity_categories_updated_at BEFORE UPDATE ON activity_categories
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_note_categories_updated_at BEFORE UPDATE ON note_categories
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_config_updated_at BEFORE UPDATE ON config
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- VIEWS (Helpful queries)
-- ============================================================================

-- Recent activities with category names
CREATE VIEW recent_activities AS
SELECT 
  a.id,
  a.timestamp,
  ac.name AS category_name,
  a.description,
  a.thread_id,
  a.confidence,
  re.author_login,
  re.message_url
FROM activity_log a
JOIN activity_categories ac ON a.category_id = ac.id
JOIN raw_events re ON a.raw_event_id = re.id
ORDER BY a.timestamp DESC;

COMMENT ON VIEW recent_activities IS 'Activities with denormalized category names for easy querying';

-- Recent notes with category names
CREATE VIEW recent_notes AS
SELECT 
  n.id,
  n.timestamp,
  nc.name AS category_name,
  n.title,
  n.text,
  n.thread_id,
  re.author_login,
  re.message_url
FROM notes n
JOIN note_categories nc ON n.category_id = nc.id
JOIN raw_events re ON n.raw_event_id = re.id
ORDER BY n.timestamp DESC;

COMMENT ON VIEW recent_notes IS 'Notes with denormalized category names for easy querying';

-- ============================================================================
-- GRANTS (Adjust as needed for your setup)
-- ============================================================================

-- Grant permissions to n8n user (adjust username as needed)
-- GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO n8n_user;
-- GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO n8n_user;
