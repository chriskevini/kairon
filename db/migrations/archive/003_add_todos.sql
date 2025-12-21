-- Kairon Life OS - Migration 003: Add Todos Support
-- Adds first-class todo intent with hierarchical goals/sub-tasks
-- See: docs/todo-intent-design.md

-- ============================================================================
-- PREREQUISITES
-- ============================================================================

-- Ensure pg_trgm extension for fuzzy matching
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================================
-- TODOS TABLE
-- ============================================================================

CREATE TABLE todos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Source references
  raw_event_id UUID NULL REFERENCES raw_events(id) ON DELETE SET NULL,
  parent_todo_id UUID NULL REFERENCES todos(id) ON DELETE CASCADE,
  
  -- Core fields
  description TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'suggested', 'done', 'dismissed')),
  priority TEXT DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high')),
  
  -- Goal tracking (for high-level objectives)
  is_goal BOOLEAN NOT NULL DEFAULT FALSE,
  goal_deadline DATE NULL,
  
  -- Task metadata
  due_date DATE NULL,
  completed_at TIMESTAMPTZ NULL,
  completed_by_activity_id UUID NULL REFERENCES activity_log(id),
  suggested_by_conversation_id UUID NULL REFERENCES conversations(id),
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Additional metadata (for extensibility)
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Business logic constraints
  CONSTRAINT no_goal_parents CHECK (NOT is_goal OR parent_todo_id IS NULL),
  CONSTRAINT no_goal_due_date CHECK (NOT is_goal OR due_date IS NULL)
);

-- Indexes for common queries
CREATE INDEX idx_todos_status ON todos(status) WHERE status IN ('pending', 'suggested');
CREATE INDEX idx_todos_parent ON todos(parent_todo_id) WHERE parent_todo_id IS NOT NULL;
CREATE INDEX idx_todos_created_at ON todos(created_at DESC);
CREATE INDEX idx_todos_due_date ON todos(due_date) WHERE due_date IS NOT NULL;
CREATE INDEX idx_todos_description_trgm ON todos USING gin (description gin_trgm_ops);

-- Table and column documentation
COMMENT ON TABLE todos IS 'Hierarchical todos/goals with automatic completion detection and sub-task support';
COMMENT ON COLUMN todos.raw_event_id IS 'NULL for agent-suggested todos';
COMMENT ON COLUMN todos.parent_todo_id IS 'NULL for root todos/goals, set for sub-tasks';
COMMENT ON COLUMN todos.is_goal IS 'TRUE for high-level goals (e.g., "ship project by January")';
COMMENT ON COLUMN todos.goal_deadline IS 'Overall deadline for goals (distinct from task due_date)';
COMMENT ON COLUMN todos.status IS 'pending: active, suggested: awaiting approval, done: completed, dismissed: rejected';
COMMENT ON COLUMN todos.completed_by_activity_id IS 'Activity that triggered auto-completion';
COMMENT ON COLUMN todos.suggested_by_conversation_id IS 'Thread that suggested this todo';

-- ============================================================================
-- UPDATE ROUTING DECISIONS
-- ============================================================================

-- Add 'Todo' to existing intent enum
ALTER TABLE routing_decisions 
  DROP CONSTRAINT IF EXISTS routing_decisions_intent_check;

ALTER TABLE routing_decisions
  ADD CONSTRAINT routing_decisions_intent_check 
  CHECK (intent IN ('Activity', 'Note', 'ThreadStart', 'Chat', 'Commit', 'Command', 'Todo'));

COMMENT ON CONSTRAINT routing_decisions_intent_check ON routing_decisions 
  IS 'Valid intents: Activity, Note, ThreadStart, Chat, Commit, Command, Todo';

-- ============================================================================
-- VIEWS
-- ============================================================================

-- Hierarchical view of open todos (goals with sub-tasks)
CREATE VIEW open_todos AS
WITH RECURSIVE todo_tree AS (
  -- Root todos/goals
  SELECT 
    t.id,
    t.parent_todo_id,
    t.description,
    t.status,
    t.priority,
    t.is_goal,
    t.goal_deadline,
    t.due_date,
    t.created_at,
    re.author_login,
    re.message_url,
    0 AS depth,
    t.id::text AS path
  FROM todos t
  LEFT JOIN raw_events re ON t.raw_event_id = re.id
  WHERE t.parent_todo_id IS NULL 
    AND t.status IN ('pending', 'suggested')
  
  UNION ALL
  
  -- Child todos (sub-tasks)
  SELECT 
    t.id,
    t.parent_todo_id,
    t.description,
    t.status,
    t.priority,
    t.is_goal,
    t.goal_deadline,
    t.due_date,
    t.created_at,
    re.author_login,
    re.message_url,
    tt.depth + 1,
    tt.path || '/' || t.id::text
  FROM todos t
  LEFT JOIN raw_events re ON t.raw_event_id = re.id
  JOIN todo_tree tt ON t.parent_todo_id = tt.id
  WHERE t.status IN ('pending', 'suggested')
)
SELECT * FROM todo_tree
ORDER BY 
  path,  -- Groups parent with children
  CASE priority WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 END,
  due_date NULLS LAST,
  goal_deadline NULLS LAST,
  created_at DESC;

COMMENT ON VIEW open_todos IS 'Hierarchical view of active todos/goals with sub-tasks';

-- Recent completions
CREATE VIEW recent_todo_completions AS
SELECT 
  t.id,
  t.description,
  t.is_goal,
  t.completed_at,
  t.created_at,
  a.description AS completed_by_activity,
  re.author_login
FROM todos t
LEFT JOIN activity_log a ON t.completed_by_activity_id = a.id
LEFT JOIN raw_events re ON t.raw_event_id = re.id
WHERE t.status = 'done'
ORDER BY t.completed_at DESC;

COMMENT ON VIEW recent_todo_completions IS 'Recently completed todos with triggering activities';

-- Stale todos needing attention (for proactive reminders)
CREATE VIEW stale_todos AS
SELECT 
  t.id,
  t.description,
  t.priority,
  t.due_date,
  t.created_at,
  CASE
    WHEN t.due_date < CURRENT_DATE THEN 'overdue'
    WHEN t.due_date = CURRENT_DATE THEN 'due_today'
    WHEN t.created_at < NOW() - INTERVAL '14 days' AND t.due_date IS NULL THEN 'old'
    ELSE 'active'
  END AS urgency,
  EXTRACT(day FROM NOW() - t.created_at)::integer AS age_days
FROM todos t
WHERE t.status = 'pending'
  AND (
    t.due_date <= CURRENT_DATE
    OR (t.due_date IS NULL AND t.created_at < NOW() - INTERVAL '14 days')
  )
ORDER BY
  CASE 
    WHEN t.due_date < CURRENT_DATE THEN 1
    WHEN t.due_date = CURRENT_DATE THEN 2
    ELSE 3
  END,
  t.created_at;

COMMENT ON VIEW stale_todos IS 'Overdue or old todos for proactive reminders';

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Auto-update updated_at timestamp
CREATE TRIGGER update_todos_updated_at 
  BEFORE UPDATE ON todos
  FOR EACH ROW 
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- GRANTS
-- ============================================================================

-- Grant permissions to n8n user (adjust username as needed)
-- Uncomment if needed:
-- GRANT ALL PRIVILEGES ON todos TO n8n_user;
-- GRANT ALL PRIVILEGES ON SEQUENCE todos_id_seq TO n8n_user;

-- ============================================================================
-- ROLLBACK (for testing - do not run in production)
-- ============================================================================

-- To rollback this migration (TEST ONLY):
-- DROP VIEW IF EXISTS stale_todos;
-- DROP VIEW IF EXISTS recent_todo_completions;
-- DROP VIEW IF EXISTS open_todos;
-- DROP TABLE IF EXISTS todos CASCADE;
-- ALTER TABLE routing_decisions DROP CONSTRAINT IF EXISTS routing_decisions_intent_check;
-- ALTER TABLE routing_decisions ADD CONSTRAINT routing_decisions_intent_check 
--   CHECK (intent IN ('Activity', 'Note', 'ThreadStart', 'Chat', 'Commit', 'Command'));
