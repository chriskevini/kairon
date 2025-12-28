-- Migration 026: Add mock Discord responses table for testing
-- This table stores expected Discord API responses in dev/test mode
-- allowing regression tests to verify workflows without requiring Discord credentials

CREATE TABLE IF NOT EXISTS mock_discord_responses (
    id SERIAL PRIMARY KEY,
    event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    response_type VARCHAR(50) NOT NULL, -- 'reaction', 'message', 'thread_start', etc.
    response_data JSONB NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mock_responses_event_id ON mock_discord_responses(event_id);
CREATE INDEX IF NOT EXISTS idx_mock_responses_type ON mock_discord_responses(response_type);
CREATE INDEX IF NOT EXISTS idx_mock_responses_created ON mock_discord_responses(created_at);

COMMENT ON TABLE mock_discord_responses IS 'Stores mock Discord API responses for testing';
COMMENT ON COLUMN mock_discord_responses.event_id IS 'Reference to the event that triggered the response';
COMMENT ON COLUMN mock_discord_responses.response_type IS 'Type of Discord response (reaction, message, thread_start, etc.)';
COMMENT ON COLUMN mock_discord_responses.response_data IS 'Response payload (emoji, message content, etc.)';
