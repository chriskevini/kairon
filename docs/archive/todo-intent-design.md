# First-Class Todo Intent Design Doc

> **Status:** Design phase  
> **Last Updated:** 2024-12-17  
> **Implementation:** Pending

---

## Overview

We are introducing a **fourth primary intent** for user messages: **Todo** (symbol: `$$`).

This elevates discrete reminders and tasks from being a sub-process within notes (`..`) to a **first-class intent**, parallel to:

- `!!` → Activity
- `..` → Note (introspective: idea, decision, reflection, fact)
- `++` → Discussion / conversation
- `$$` → Todo (actionable reminder or task creation)

**Why this change?**  
Pure reminders like "need to buy milk" or "email John tomorrow" are fundamentally different from introspective notes. Treating them as a distinct intent:
- Preserves raw message purity
- Avoids polluting note categories
- Enables direct, reliable routing to a dedicated todo system
- Matches actual user intent more accurately

---

## Intent Symbol Choice

- **Symbol:** `$$`
- **Rationale:**
  - `>>` conflicts with mobile keyboard accessibility (hidden behind symbols)
  - `$$` is easy to type on both mobile and desktop
  - Visually distinct from existing `!!`, `..`, `++`
  - Mnemonically suggests "money/task list" or simply "do this"

---

## Updated Intent Definitions

| Symbol | Name        | Description                                                                 | Typical Signals                                      |
|--------|-------------|-----------------------------------------------------------------------------|-------------------------------------------------------|
| !!     | Activity    | Describing what the user is currently doing or just did                     | action verbs (working, refining, testing, woke up)   |
| ..     | Note        | Introspective jotting: ideas, decisions, reflections, facts                 | self-observation, suggestions, commitments, knowledge|
| ++     | Discussion  | Seeking response, asking questions, expressing uncertainty for engagement   | questions, "how", "why", "not sure", help requests   |
| $$     | Todo        | Creating a discrete, actionable reminder or task                            | "need to", "remember to", "buy", "call", "pay", imperatives |

---

## Database Schema

### Todos Table

Extends existing schema (see `db/migrations/001_initial_schema.sql`).

**Design Decision:** Single hierarchical table with optional parent relationship for sub-tasks and goals.

```sql
-- Enable similarity matching extension
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE todos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_event_id UUID NULL REFERENCES raw_events(id) ON DELETE SET NULL,
  parent_todo_id UUID NULL REFERENCES todos(id) ON DELETE CASCADE,
  
  -- Core fields
  description TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'suggested', 'done', 'dismissed')),
  priority TEXT DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high')),
  
  -- Goal tracking
  is_goal BOOLEAN NOT NULL DEFAULT FALSE,
  goal_deadline DATE NULL,
  
  -- Metadata
  due_date DATE NULL,
  completed_at TIMESTAMPTZ NULL,
  completed_by_activity_id UUID NULL REFERENCES activity_log(id),
  suggested_by_conversation_id UUID NULL REFERENCES conversations(id),
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Metadata
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT no_goal_parents CHECK (NOT is_goal OR parent_todo_id IS NULL),
  CONSTRAINT no_goal_due_date CHECK (NOT is_goal OR due_date IS NULL)
);

CREATE INDEX idx_todos_status ON todos(status) WHERE status IN ('pending', 'suggested');
CREATE INDEX idx_todos_parent ON todos(parent_todo_id) WHERE parent_todo_id IS NOT NULL;
CREATE INDEX idx_todos_created_at ON todos(created_at DESC);
CREATE INDEX idx_todos_due_date ON todos(due_date) WHERE due_date IS NOT NULL;
CREATE INDEX idx_todos_description_trgm ON todos USING gin (description gin_trgm_ops);

COMMENT ON TABLE todos IS 'Hierarchical todos/goals with automatic completion detection and sub-task support';
COMMENT ON COLUMN todos.raw_event_id IS 'NULL for agent-suggested todos';
COMMENT ON COLUMN todos.parent_todo_id IS 'NULL for root todos/goals, set for sub-tasks';
COMMENT ON COLUMN todos.is_goal IS 'TRUE for high-level goals (e.g., "ship project by January")';
COMMENT ON COLUMN todos.goal_deadline IS 'Overall deadline for goals (use due_date for tasks)';
COMMENT ON COLUMN todos.status IS 'pending: active, suggested: awaiting user approval, done: completed, dismissed: rejected/cancelled';
COMMENT ON COLUMN todos.completed_by_activity_id IS 'Activity that triggered auto-completion';
COMMENT ON COLUMN todos.suggested_by_conversation_id IS 'Thread that suggested this todo';
```

### Routing Decisions Update

Add `Todo` to existing intent enum:

```sql
ALTER TABLE routing_decisions 
  DROP CONSTRAINT IF EXISTS routing_decisions_intent_check;

ALTER TABLE routing_decisions
  ADD CONSTRAINT routing_decisions_intent_check 
  CHECK (intent IN ('Activity', 'Note', 'ThreadStart', 'Chat', 'Commit', 'Command', 'Todo'));
```

### Views

```sql
-- Open todos view (hierarchical)
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
  
  -- Child todos
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

-- Recent completions view
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

-- Stale todos needing attention
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
  EXTRACT(day FROM NOW() - t.created_at) AS age_days
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
```

---

## Pipeline Flow

### [CURRENT STATE: Tag-based routing with LLM fallback]

The system currently uses deterministic tag matching (`!!`, `..`, `++`, `::`) with LLM-based classification for untagged messages.

**Routing Logic:**

1. User sends message via Discord
2. `discord_relay.py` → webhook → `Discord_Message_Router` workflow
3. **Parse tag from message (if present)**
   - Regex matches: `!!`, `..`, `++`, `::`, `$$`
   - **NEW:** Also match `todo` or `to-do` (case insensitive)
     - `todo buy milk` → normalized to `$$`
     - `to-do email John` → normalized to `$$`
4. If **tag = `$$`** (explicit):
   - Store in `raw_events` with tag='$$'
   - Create routing decision with intent='Todo', forced_by='tag'
   - Call `Todo_Handler` workflow
5. If **no tag**:
   - Store in `raw_events` with tag=null
   - Call **Intent Classifier** LLM (renamed from "Message Classifier")
   - Parse probabilities: `!!|X`, `..|Y`, `++|Z`, `$$|W`
   - Route to highest-probability intent
   - Create routing decision with intent=[winner], forced_by='agent', confidence=[score/100]
6. If **in thread**:
   - Check if commit command (`++`)
   - Otherwise continue conversation

**Handling after routing to Todo_Handler:**

| Scenario | Action |
|----------|--------|
| Explicit `$$ buy milk` | Create todo with description="buy milk", status='pending' |
| Untagged "need to buy milk" | LLM classifies as $$, create todo with description="need to buy milk", status='pending' |
| Thread agent suggests | Creates todo with status='suggested', shows approval prompt |

---

## Mixed Message Handling

**Design Decision:** Single dominant intent (Phase 1)

**Rationale:**
- Raw message is always preserved in `raw_events.raw_text`
- With future RAG implementation, semantic search will retrieve todos/notes/activities regardless of classification
- Simpler to implement and reason about
- Covers 90%+ of real usage

**Example:**
```
"I've been thinking about my career a lot lately. Need to call my mentor tomorrow."

LLM Output:
$$|60   <- Winner (strongest signal is actionable task)
..|35
!!|3
++|2

Result: Creates todo "Need to call my mentor tomorrow"
Note: Reflection context preserved in raw_events.raw_text for future RAG retrieval
```

**Future Phase 2 (with RAG):**
- Semantic search across all `raw_events.raw_text` regardless of classification
- "Retroactive" = old messages become discoverable via embeddings even if mis-classified
- Example: Message classified as Note but contains "need to call", semantic search for "todos about calling" will find it
- No reprocessing/reclassification needed (just embed existing raw_text)

---

## Todo Lifecycle & Auto-Completion

### States

- **`pending`**: Active todo waiting for completion
- **`suggested`**: Agent-suggested todo awaiting user approval
- **`done`**: Completed (either manually or auto-detected)
- **`dismissed`**: User rejected or cancelled

### Auto-Completion Detection

**Trigger:** Every time an activity is logged (in `Activity_Handler` workflow)

**Algorithm:**

```sql
-- After inserting activity, check for matching todos
SELECT 
  t.id,
  t.description,
  similarity(t.description, $new_activity_description) AS score
FROM todos t
WHERE t.status = 'pending'
  AND similarity(t.description, $new_activity_description) > 0.6
ORDER BY score DESC
LIMIT 3;
```

**Matching Logic:**
- Uses PostgreSQL's `pg_trgm` trigram similarity (fast, fuzzy matching)
- Threshold: 0.6 (tunable based on user feedback)
- If **1 match**: Auto-complete with high confidence
- If **2+ matches**: Show user quick selection prompt
- If **0 matches**: No action

**Examples:**
```
Todo: "buy milk"
Activity: "bought milk at store" → similarity: 0.85 → ✅ Auto-complete

Todo: "email John about meeting"
Activity: "sent email to John" → similarity: 0.72 → ✅ Auto-complete

Todo: "fix authentication bug"
Activity: "debugging auth issues" → similarity: 0.55 → ❌ No match (below threshold)
```

### Manual Completion

User can explicitly complete todos:
- `::done <partial-description>` → Find matching todo by similarity
- React with ✅ emoji on the todo creation message

### Agent-Suggested Todos

Thread agent can suggest todos during conversations.

**Workflow:**
1. User discusses plans in thread
2. Agent identifies actionable item
3. Agent creates todo with `status='suggested'`
4. Discord shows reaction prompt: "💡 Suggested: [description] | ✅ Accept | ❌ Dismiss"
5. User reacts:
   - ✅ → Update `status='pending'`
   - ❌ → Update `status='dismissed'`

---

## Updated Intent Classifier Prompt

**[CURRENT STATE: n8n-workflows/Discord_Message_Router.json - Intent Classifier node]**

**Node renamed:** "Message Classifier" → "Intent Classifier"

Add `$$` intent to existing LLM prompt:

```
You are an intent classifier for a life-tracking system.

Assign probability scores (0-100) to each intent. Scores must add up to exactly 100.

# Intents

!! → Logging an activity  
Describes what the user is currently doing or has recently done (e.g., working on projects, 
refining systems, testing, debugging, actively planning, brainstorming, eating, waking up).  
Strong indicators: action verbs indicating ongoing/recent personal action.

.. → Jotting a note  
A detached idea, general reflection, observation, decision, or future-oriented thought 
without a current or recent action anchor.

++ → Starting conversation / seeking response  
Clear question seeking an answer, request for advice, or expression of uncertainty 
intended to elicit a reply.

$$ → Creating a todo/reminder  
Discrete actionable task or reminder for future action.  
Strong indicators: "need to", "remember to", "should", imperatives ("buy", "call", "email"), 
explicit task language.

# Key Guidelines
- Heavily favor !! over .. when any action verb suggests ongoing or recent activity.
- Strongly favor $$ for "need to", "remember to", direct imperatives, or explicit task creation.
- Use .. only for pure ideas, generalizations, reflections, or decisions lacking "right now" or "must do" feel.
- Use ++ only for explicit questions or help-seeking language.
- Mixed signals: choose the dominant intent.

# Output EXACTLY these four lines, nothing else:
!!|X
..|Y
++|Z
$$|W

(X+Y+Z+W=100, integers only)

# Examples

need to buy milk
$$|94
..|3
!!|2
++|1

remember to email John tomorrow
$$|92
..|5
++|2
!!|1

I'm out of milk again and it's messing with my mornings — need to buy some
..|55
$$|40
!!|3
++|2

bought milk at the store
!!|96
..|2
$$|1
++|1

John loves dark roast coffee
..|90
!!|3
$$|4
++|3

decided to always buy oat milk from now on
..|88
$$|10
!!|1
++|1

should I email John or call him?
++|85
$$|10
..|3
!!|2

just woke up and brainstorming new features
!!|94
..|4
$$|1
++|1

# User Message
{{ $('Discord Webhook').item.json.body.content }}
```

---

## Bot Response Patterns

### Todo Creation (via `$$` tag or LLM classification)

```
✅ Added to todos: "buy milk"
```

### Auto-Completion Detection

```
✅ Completed todo: "buy milk"
```

### Multiple Match Prompt

```
✅ Completed a todo! Which one?
1️⃣ buy milk
2️⃣ get groceries
3️⃣ buy coffee beans

React with the number or ignore if none match.
```

### Agent Suggestion

```
💡 Suggested todo: "email John about quarterly review"
✅ Add to todos | ❌ Dismiss
```

### Daily Digest

Include open todos section:

```
📋 **Open Todos** (3)
🔴 [HIGH] Email John (due today)
🟡 [MED] Buy milk
🟢 [LOW] Clean desk
```

---

## Implementation Plan

### Phase 1: Core Todo Infrastructure

**Database:**
- [x] Design schema (this doc)
- [ ] Write migration: `db/migrations/002_add_todos.sql`
- [ ] Create seed data if needed
- [ ] Test migration on dev database

**n8n Workflows:**
- [ ] Create `Todo_Handler.json` workflow
  - Input: `event` object from router
  - Extract description from `clean_text`
  - Insert into `todos` table
  - React with ✅ emoji
  - Return success
- [ ] Update `Discord_Message_Router.json`
  - Add `$$` to tag parsing regex
  - Add `$$` branch in Switch node
  - Route to `Todo_Handler` workflow
- [ ] Update Message Classifier prompt (LLM node)
  - Add `$$` intent with examples
  - Update output format to 4 lines
  - Update parser to handle `$$|X` line

**Testing:**
- [ ] Test explicit: `$$ buy milk`
- [ ] Test untagged: `need to buy milk`
- [ ] Test edge cases: empty message, very long message
- [ ] Verify `routing_decisions` table updated correctly

### Phase 2: Auto-Completion

**n8n Workflows:**
- [ ] Update `Activity_Handler.json`
  - After storing activity, query matching todos
  - If 1 match found:
    - Update todo: `status='done'`, `completed_at=NOW()`, `completed_by_activity_id=<activity_id>`
    - React with ✅ on original todo message
    - Post completion message
  - If 2+ matches:
    - Post selection prompt with numbered reactions
  - If 0 matches:
    - Continue normally

**Database:**
- [ ] Test `pg_trgm` similarity on sample data
- [ ] Tune similarity threshold (start at 0.6)
- [ ] Add index: `CREATE INDEX idx_todos_description_trgm ON todos USING gin (description gin_trgm_ops);`

**Testing:**
- [ ] Test exact match: "buy milk" → "bought milk"
- [ ] Test fuzzy match: "email John" → "sent email to John"
- [ ] Test partial match: "fix auth bug" → "debugging authentication"
- [ ] Test multiple matches
- [ ] Test no matches

### Phase 3: Agent-Suggested Todos

**n8n Workflows:**
- [ ] Update `Thread_Agent.json` or `Thread_Continuation_Agent.json`
  - Add system prompt section about suggesting todos
  - Provide tool/mechanism to create suggested todos
- [ ] Create reaction handler for approval/dismissal
  - Listen for ✅ / ❌ reactions on suggestion messages
  - Update todo status accordingly

**Testing:**
- [ ] Test in conversation: "I really need to fix my sleep schedule"
- [ ] Test approval flow
- [ ] Test dismissal flow

### Phase 4: Commands & Views

**n8n Workflows:**
- [ ] Update `Command_Handler.json`
  - `::todos` → list open todos
  - `::todos done` → list recent completions
  - `::done <partial-text>` → manually complete todo
  - `::todo <description>` → create todo (alternative to `$$`)

**Daily Summary:**
- [ ] Update `Daily_Summary_Generator.json`
  - Query open todos
  - Include in summary with priority/due date

**Testing:**
- [ ] Test all commands
- [ ] Test daily summary includes todos

### Phase 5: Polish & Iteration

- [ ] User testing and feedback
- [ ] Tune similarity threshold based on real usage
- [ ] Add priority setting via syntax: `$$ [HIGH] buy milk`
- [ ] Add due date parsing: `$$ buy milk tomorrow` → due_date = tomorrow
- [ ] Consider recurring todos
- [ ] Performance testing with large todo lists

---

## Edge Cases & Considerations

### Ambiguous Classification

**Scenario:** Message could be both note and todo
```
"I should start waking up earlier"
```

**LLM Output:**
```
..|60   (sounds like reflection)
$$|35   (could be interpreted as commitment)
!!|3
++|2
```

**Result:** Creates note (dominant intent)  
**RAG Future:** Semantic search will still retrieve this when user searches for sleep-related todos

### Duplicate Todos

**Scenario:** User creates similar todos
```
$$ buy milk
$$ get milk from store
```

**Handling:**
- Allow duplicates (user intent may differ: different stores, different urgency)
- Auto-completion will match both (user can pick via reaction)
- Future: Add duplicate detection warning before creation

### Failed Auto-Completion

**Scenario:** Todo description doesn't match activity well
```
Todo: "email John"
Activity: "wrote message for John"
Similarity: 0.52 (below threshold)
```

**Handling:**
- No auto-completion triggered
- Todo stays pending
- User can manually complete with `::done email John`

### Completion Without Todo

**Scenario:** User says "bought milk" but never created a todo
```
Activity: "bought milk"
Matching todos: 0
```

**Handling:**
- No action taken
- Activity logged normally
- No false "completed" messages

### Thread Commit with Embedded Todo

**Scenario:** Thread conversation mentions actionable item, user commits
```
Thread: "I should probably reach out to Sarah about that project"
User: ++
```

**Handling:**
- Thread summarized into note
- Agent could suggest todo: "reach out to Sarah" (Phase 3)
- Note captures full context

---

## Future Enhancements (Post-RAG)

### Multi-Intent Extraction

Once RAG is implemented with vector embeddings:

```sql
-- Add embeddings to raw_events
ALTER TABLE raw_events ADD COLUMN embedding VECTOR(1536);

-- Semantic search for todos regardless of classification
SELECT re.raw_text, re.received_at
FROM raw_events re
WHERE re.embedding <-> $query_embedding < 0.7
ORDER BY re.embedding <-> $query_embedding
LIMIT 20;
```

This allows retroactive extraction of todos from messages originally classified as notes/activities.

### Smart Todo Extraction

- Extract multiple actionable items from single message
- Extract due dates from natural language
- Extract priority from context (urgency markers)
- Link related todos automatically

### Recurring Todos

- Daily/weekly/monthly patterns
- Auto-create next instance on completion
- Skip/snooze functionality

### Todo Categories

- Allow user-defined categories (work, personal, health, etc.)
- Filter views by category
- Category-specific defaults (priority, due date)

---

## Benefits Summary

- **Raw messages preserved exactly once** - No data loss, RAG-ready
- **Intents accurately reflect user purpose** - 4-intent model covers all use cases
- **Todos get proper lifecycle management** - Creation → Completion → Archive
- **Auto-completion reduces friction** - No manual checkboxes needed
- **Agent can suggest actionable next steps** - Proactive assistance
- **Notes stay pure and introspective** - No task management pollution
- **System is conceptually complete** - Four distinct user intents fully supported

---

## Design Decisions - Resolved

### 1. Sub-tasks & Goals - SUPPORTED

**Decision:** Single hierarchical table with `parent_todo_id` and `is_goal` flag.

**Usage:**
- Goals: `$$ [GOAL] ship project by January`
- Sub-tasks: Agent suggests linking related todos to goals
- Unlimited depth (though 2 levels typical: Goal → Task)

**Display:** Recursive CTE query groups parent with children, indented in Discord

**Example:**
```
🎯 **Goals**
📦 Ship project by January (due: Jan 31)
  ├─ ✅ Finish authentication module
  ├─ 📝 Write documentation
  └─ ⏳ Deploy to staging

📋 **Todos**
🛒 Buy milk
📧 Email John
```

### 2. Priority Auto-Escalation - NO

**Decision:** Conversational reminders instead of automatic escalation.

**Rationale:** Priority is user intent. Auto-escalation assumes stale = important, which isn't always true.

**Instead:** Weekly conversation suggesting escalation or dismissal:
```
"You have 3 todos older than 2 weeks:
1. Email John (created 18 days ago)
2. Fix broken link (created 22 days ago)

Want to escalate to high priority, dismiss, or keep as-is?"
```

### 3. Todo Templates - FUTURE SCOPE

Not in current implementation. Could be added with RAG: "Your morning routine usually includes X, Y, Z. Create template?"

### 4. Location-Based Todos - FUTURE SCOPE

Not in current implementation. Would require location tracking.

### 5. Proactive Reminders - YES, AWESOME

**Decision:** Three trigger types for proactive reminders:

**A. Context-Relevant (Thread Agent)**

When user discusses related topic, agent mentions relevant todos:

```javascript
// Added to Thread Agent system prompt
When user discusses a topic, check for related open todos and mention naturally.

Example:
User: "I need to catch up with my mentor"
Agent: "By the way, you have an open todo: 'call mentor' from 3 days ago. Good timing!"
```

**B. Time-Based (Periodic Workflow)**

New workflow: `Todo_Reminder.json` (runs every 6 hours)

```sql
SELECT description, due_date, created_at, priority
FROM stale_todos  -- uses view defined above
ORDER BY urgency, created_at;
```

Posts to Discord:
```
⏰ **Todo Reminders**

🔴 OVERDUE:
• Email John (due 2 days ago)

🟡 DUE TODAY:
• Buy milk

🟢 GETTING OLD:
• Fix broken link (created 22 days ago - want to dismiss?)
```

**C. Activity-Based (With RAG - Future)**

When logging activity, check for semantically similar todos:

```sql
-- After storing activity
SELECT t.description, t.priority
FROM todos t
JOIN embeddings e ON e.source_table = 'todos' AND e.source_id = t.id
WHERE t.status = 'pending'
  AND e.embedding <=> $activity_embedding < 0.7
LIMIT 3;
```

Example:
```
User: !! working on email
Bot: 💡 Reminder: You have a pending todo "email John about meeting"
```

---

## References

- `db/migrations/001_initial_schema.sql` - Existing schema
- `n8n-workflows/Discord_Message_Router.json` - Current routing implementation
- `n8n-workflows/Activity_Handler.json` - Activity processing
- `AGENTS.md` - Architecture guidelines
- Future: `docs/rag-implementation-design.md` (to be written)
