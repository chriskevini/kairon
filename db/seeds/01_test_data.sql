-- Kairon Dev Test Data
-- Minimal toy data for smoke tests
-- This file runs after 00_schema.sql on first container start

BEGIN;

-- Config: Basic user configuration
INSERT INTO config (key, value) VALUES
  ('north_star', 'Build meaningful projects and maintain work-life balance'),
  ('timezone', 'America/New_York')
ON CONFLICT (key) DO NOTHING;

-- Test Event: A sample Discord message event for smoke tests
INSERT INTO events (id, event_type, payload, idempotency_key, timezone) VALUES
  (
    '00000000-0000-0000-0000-000000000001',
    'discord_message',
    '{
      "discord_message_id": "test-msg-001",
      "discord_channel_id": "test-channel-001", 
      "discord_guild_id": "test-guild-001",
      "author_id": "test-user-001",
      "content": "Just finished a 2 hour deep work session on the API refactor",
      "clean_text": "Just finished a 2 hour deep work session on the API refactor",
      "timestamp": "2024-01-15T10:30:00Z"
    }',
    'test-msg-001',
    'America/New_York'
  )
ON CONFLICT DO NOTHING;

-- Test Trace: Sample trace linked to the test event
INSERT INTO traces (id, event_id, step_name, data, trace_chain) VALUES
  (
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    'multi_capture',
    '{
      "input": "Just finished a 2 hour deep work session on the API refactor",
      "duration_ms": 1500
    }',
    ARRAY['00000000-0000-0000-0000-000000000001']::uuid[]
  )
ON CONFLICT DO NOTHING;

-- Test Projection: Sample activity projection
INSERT INTO projections (id, trace_id, event_id, trace_chain, projection_type, data, status, timezone) VALUES
  (
    '00000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    ARRAY['00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002']::uuid[],
    'activity',
    '{
      "timestamp": "2024-01-15T10:30:00Z",
      "category": "deep_work",
      "description": "2 hour deep work session on API refactor"
    }',
    'auto_confirmed',
    'America/New_York'
  )
ON CONFLICT DO NOTHING;

COMMIT;
