# Clean Architecture Implementation Plan

> **Priority:** Clean architecture first, then features  
> **Timeline:** 2-3 weeks  
> **Status:** Ready to execute

---

## Overview

Implementing todo system and save thread functionality with **static categories architecture**.

**Key decisions:**
- ✅ Static categories (no user-editing)
- ✅ Save thread creates note only (not activity)
- ✅ Tags: symbols (`!!`, `..`, `$$`, `--`) + semantic words (`act`, `note`, `todo`, `save`)
- ✅ `--` or `save` for thread saving (symmetric with `++` / `ask`)

---

## Phase 1: Static Categories Migration (Week 1)

### Day 1-2: Test Migration

```bash
# 1. Create backup
pg_dump -U n8n_user -d kairon -F c -f backups/pre_static_categories_$(date +%Y%m%d).dump

# 2. Create test database
createdb -U n8n_user kairon_test

# 3. Restore to test
pg_restore -U n8n_user -d kairon_test backups/pre_static_categories_*.dump

# 4. Run migration on test
psql -U n8n_user -d kairon_test -f db/migrations/002_static_categories.sql

# 5. Verify
psql -U n8n_user -d kairon_test -c "\d activity_log"
psql -U n8n_user -d kairon_test -c "SELECT DISTINCT category FROM activity_log;"
psql -U n8n_user -d kairon_test -c "SELECT * FROM recent_activities LIMIT 5;"

# 6. Check for errors
psql -U n8n_user -d kairon_test -c "SELECT COUNT(*) FROM activity_log;"
# Should match pre-migration count

# 7. Clean up test
dropdb -U n8n_user kairon_test
```

**Validation checklist:**
- [ ] All activity_log rows have category (no NULLs)
- [ ] All notes rows have category (no NULLs)
- [ ] Views work without JOINs
- [ ] Category tables dropped successfully
- [ ] conversations.activity_id removed

### Day 3: Production Migration

```bash
# 1. Final backup
pg_dump -U n8n_user -d kairon -F c -f backups/pre_static_categories_production_$(date +%Y%m%d_%H%M%S).dump

# 2. Verify backup
ls -lh backups/pre_static_categories_production_*

# 3. Run migration (log output)
psql -U n8n_user -d kairon -f db/migrations/002_static_categories.sql 2>&1 | tee logs/migration_002_$(date +%Y%m%d_%H%M%S).log

# 4. Check for errors
grep -i error logs/migration_002_*.log
# Should return nothing

# 5. Verify
psql -U n8n_user -d kairon -c "SELECT COUNT(*) FROM activity_log;"
psql -U n8n_user -d kairon -c "SELECT DISTINCT category FROM activity_log;"
psql -U n8n_user -d kairon -c "SELECT * FROM recent_activities LIMIT 5;"
```

**Success criteria:**
- Migration completes without errors
- All counts match pre-migration
- Views return data
- No NULL categories

### Day 4-5: Update Workflows

**Activity_Handler.json:**

```javascript
// OLD: Query category_id
const categoryResult = await db.query(
  'SELECT id FROM activity_categories WHERE name = $1',
  [$categoryName]
);

// NEW: Use enum directly
const category = $categoryName;  // 'work', 'leisure', etc.

// Update INSERT query
INSERT INTO activity_log (raw_event_id, timestamp, category, description, confidence)
VALUES ($1, $2, $3, $4, $5)
```

**Note_Handler.json:**

```javascript
// OLD: Query category_id
const categoryResult = await db.query(
  'SELECT id FROM note_categories WHERE name = $1',
  [$categoryName]
);

// NEW: Use enum directly
const category = $categoryName;  // 'idea', 'reflection', etc.

// Update INSERT query
INSERT INTO notes (raw_event_id, timestamp, category, title, text)
VALUES ($1, $2, $3, $4, $5)
```

**Update all LLM prompts:**

Remove category queries, use static lists:

```
Activity categories: work, leisure, study, health, sleep, relationships, admin
Note categories: idea, reflection, decision, question, meta
```

**Testing:**
- [ ] Send `!! working on project` → Creates activity with category='work'
- [ ] Send `.. interesting insight` → Creates note with category='idea'
- [ ] Check database: `SELECT * FROM recent_activities LIMIT 5;`
- [ ] Verify no errors in n8n logs

---

## Phase 2: Tag System Updates (Week 1, Day 5)

### Update Discord_Message_Router.json

**1. Update Tag Parser node:**

```javascript
// Parse tags at start of message only
const tagRegex = /^(!!|\.\.|\+\+|--|::|$$|act|note|ask|save|cmd|todo)(\s+|$)/i;
const match = $json.content.match(tagRegex);

if (match) {
  const rawTag = match[1].toLowerCase();
  const tagMap = {
    '!!': '!!', '..': '..', '++': '++', '--': '--', '::': '::', '$$': '$$',
    'act': '!!', 'note': '..', 'ask': '++', 'save': '--', 'cmd': '::', 'todo': '$$'
  };
  
  const tag = tagMap[rawTag];
  const cleanText = $json.content.slice(match[0].length).trim();
  
  return {
    tag: tag,
    clean_text: cleanText,
    raw_text: $json.content
  };
} else {
  return {
    tag: null,
    clean_text: $json.content,
    raw_text: $json.content
  };
}
```

**2. Update Switch node:**

Add cases for `--` (save) and `$$` (todo):

```javascript
// Current: !!, .., ++, ::
// Add: --, $$

switch (tag) {
  case '!!': // Activity
  case '..': // Note
  case '++': // Thread start
  case '--': // Thread save (NEW)
  case '::': // Command
  case '$$': // Todo (NEW)
}
```

**3. Update Intent Classifier prompt:**

Rename node: "Message Classifier" → "Intent Classifier"

Add `$$` to prompt (will do in Phase 3 with full todo implementation)

**Testing:**
- [ ] `act working` → tag='!!'
- [ ] `note insight` → tag='..'
- [ ] `ask question` → tag='++'
- [ ] `save` → tag='--'
- [ ] `todo buy milk` → tag='$$'
- [ ] `working on act` → tag=null (not at start)

---

## Phase 3: Save Thread Implementation (Week 2)

### Prerequisites

- ✅ Static categories migrated
- ✅ Tag parsing updated
- ✅ `conversations` table has no `activity_id` column

### Implementation

**1. Create Save_Thread_Handler.json workflow:**

```
Input: event object { thread_id, raw_event_id, ... }

Steps:
1. Get conversation from DB
   SELECT * FROM conversations WHERE thread_id = $1

2. Load all conversation messages
   SELECT * FROM conversation_messages 
   WHERE conversation_id = $1 
   ORDER BY timestamp ASC

3. Format messages for LLM
   [
     { role: 'user', content: '...' },
     { role: 'assistant', content: '...' },
     ...
   ]

4. Call LLM with save-thread.md prompt
   POST to OpenRouter/OpenAI
   Parse JSON response: { note: { category, title, text } }

5. Insert note into notes table
   INSERT INTO notes (raw_event_id, timestamp, category, title, text, thread_id)
   VALUES ($1, NOW(), $2, $3, $4, $5)
   RETURNING id

6. Update conversation
   UPDATE conversations
   SET status = 'committed',
       committed_at = NOW(),
       committed_by_raw_event_id = $raw_event_id,
       note_id = $note_id
   WHERE thread_id = $thread_id

7. React to Discord message
   Add ✅ emoji

8. Send confirmation
   "Thread saved! Created note: [title]"

9. Close Discord thread (optional)
   Use Discord API to archive thread
```

**2. Update Discord_Message_Router.json:**

Wire `--` tag to Save_Thread_Handler:

```javascript
// In switch node, -- case:
if (tag === '--') {
  if (!thread_id) {
    // Error: can only save in threads
    return { error: 'Can only use -- to save a thread conversation' };
  }
  
  // Call Save_Thread_Handler
  executeWorkflow('Save_Thread_Handler', { event: $json.event });
}
```

**3. Update routing_decisions table:**

```sql
-- Add 'ThreadSave' intent
ALTER TABLE routing_decisions DROP CONSTRAINT routing_decisions_intent_check;
ALTER TABLE routing_decisions ADD CONSTRAINT routing_decisions_intent_check
  CHECK (intent IN ('Activity', 'Note', 'ThreadStart', 'ThreadSave', 'Chat', 'Command', 'Todo'));
```

**Testing:**
- [ ] Start thread: `++ what did I work on yesterday?`
- [ ] Have conversation (multiple back-and-forth)
- [ ] Save: `--` or `save`
- [ ] Check database:
  - `SELECT * FROM conversations WHERE status = 'committed';`
  - `SELECT * FROM notes WHERE thread_id IS NOT NULL;`
- [ ] Verify note created with correct category
- [ ] Verify thread closed in Discord

---

## Phase 4: Todo Implementation (Week 2-3)

### Day 1: Migration

```bash
# 1. Backup
pg_dump -U n8n_user -d kairon -F c -f backups/pre_todos_$(date +%Y%m%d).dump

# 2. Run migration
psql -U n8n_user -d kairon -f db/migrations/003_add_todos.sql

# 3. Verify
psql -U n8n_user -d kairon -c "\d todos"
psql -U n8n_user -d kairon -c "SELECT * FROM open_todos LIMIT 1;"
```

### Day 2-3: Basic Todo Handler

**Create Todo_Handler.json:**

```
Input: event object { raw_event_id, clean_text, ... }

Steps:
1. Extract description from clean_text

2. Insert into todos
   INSERT INTO todos (raw_event_id, description, status, priority)
   VALUES ($1, $2, 'pending', 'medium')
   RETURNING id

3. React with ✅

4. Send confirmation
   "Added to todos: [description]"
```

**Update Discord_Message_Router.json:**

Add `$$` case to switch:

```javascript
if (tag === '$$') {
  executeWorkflow('Todo_Handler', { event: $json.event });
}
```

**Update Intent Classifier:**

Add `$$` examples to prompt (see todo-intent-design.md for full prompt).

**Testing:**
- [ ] `$$ buy milk` → Creates todo
- [ ] `todo email John` → Creates todo
- [ ] Untagged `need to buy milk` → LLM classifies as $$ → creates todo
- [ ] Check: `SELECT * FROM open_todos;`

### Day 4: Auto-Completion

**Update Activity_Handler.json:**

After storing activity:

```javascript
// Query matching todos
const matchingTodos = await db.query(`
  SELECT id, description, 
         similarity(description, $1) AS score
  FROM todos
  WHERE status = 'pending'
    AND similarity(description, $1) > 0.6
  ORDER BY score DESC
  LIMIT 3
`, [activityDescription]);

if (matchingTodos.length === 1) {
  // Auto-complete
  await db.query(`
    UPDATE todos
    SET status = 'done',
        completed_at = NOW(),
        completed_by_activity_id = $1
    WHERE id = $2
  `, [activityId, matchingTodos[0].id]);
  
  // Send message
  sendMessage(`✅ Completed todo: ${matchingTodos[0].description}`);
  
} else if (matchingTodos.length > 1) {
  // Show selection prompt
  sendMessage(`✅ Completed a todo! Which one?
1️⃣ ${matchingTodos[0].description}
2️⃣ ${matchingTodos[1].description}
3️⃣ ${matchingTodos[2].description}

React with number or ignore.`);
}
```

**Testing:**
- [ ] Create: `$$ buy milk`
- [ ] Complete: `!! bought milk at store` → Auto-completes todo
- [ ] Check: `SELECT * FROM recent_todo_completions;`

### Day 5: Commands

**Update Command_Handler.json:**

Add todo commands:

```javascript
// ::todos - list open todos
if (command === 'todos') {
  const todos = await db.query('SELECT * FROM open_todos LIMIT 20');
  
  return `📋 **Open Todos** (${todos.length})
${todos.map((t, i) => `${i+1}. ${priorityEmoji(t.priority)} ${t.description}`).join('\n')}`;
}

// ::todos done - list recent completions
if (command === 'todos' && args[0] === 'done') {
  const completed = await db.query('SELECT * FROM recent_todo_completions LIMIT 10');
  
  return `✅ **Recently Completed**
${completed.map(t => `• ${t.description} (${timeAgo(t.completed_at)})`).join('\n')}`;
}

// ::done <text> - manually complete todo
if (command === 'done') {
  const partialText = args.join(' ');
  const matches = await db.query(`
    SELECT id, description
    FROM todos
    WHERE status = 'pending'
      AND description ILIKE '%' || $1 || '%'
    LIMIT 3
  `, [partialText]);
  
  if (matches.length === 1) {
    await db.query('UPDATE todos SET status = done, completed_at = NOW() WHERE id = $1', [matches[0].id]);
    return `✅ Completed: ${matches[0].description}`;
  } else if (matches.length === 0) {
    return `❌ No matching todos found for: ${partialText}`;
  } else {
    return `Multiple matches. Be more specific:\n${matches.map(m => `• ${m.description}`).join('\n')}`;
  }
}
```

**Testing:**
- [ ] `::todos` → Lists open todos
- [ ] `::todos done` → Lists completions
- [ ] `::done milk` → Completes "buy milk" todo

---

## Phase 5: Polish & Integration (Week 3)

### Daily Summary Integration

**Update Daily_Summary_Generator.json:**

```javascript
// Add todos section
const openTodos = await db.query(`
  SELECT description, priority, due_date
  FROM open_todos
  LIMIT 10
`);

summary += `\n\n📋 **Open Todos** (${openTodos.length})\n`;
summary += openTodos.map(t => 
  `${priorityEmoji(t.priority)} ${t.description}${t.due_date ? ' (due ' + formatDate(t.due_date) + ')' : ''}`
).join('\n');
```

### Proactive Reminders (Basic)

**Create Todo_Reminder.json (cron workflow):**

```
Trigger: Every 6 hours

Steps:
1. Query stale todos
   SELECT * FROM stale_todos

2. Format message
   ⏰ **Todo Reminders**
   
   🔴 OVERDUE:
   • [description] (due X days ago)
   
   🟡 DUE TODAY:
   • [description]
   
   🟢 GETTING OLD:
   • [description] (created X days ago)

3. Post to Discord if any found
```

### Documentation Updates

- [ ] Update AGENTS.md with new tag system
- [ ] Update README.md with save thread feature
- [ ] Mark implementation sections as [IMPLEMENTED: date]

---

## Success Criteria

### Week 1 Complete:
- ✅ Static categories migrated
- ✅ All workflows updated for enums
- ✅ Tag parsing supports symbols + words
- ✅ `--` / `save` tag working

### Week 2 Complete:
- ✅ Save thread creates notes
- ✅ Threads can be saved with `--` or `save`
- ✅ Basic todos working (`$$` tag + LLM classification)
- ✅ Auto-completion working

### Week 3 Complete:
- ✅ Todo commands (list, done)
- ✅ Daily summary includes todos
- ✅ Proactive reminders
- ✅ Documentation updated

---

## Rollback Plans

### Static Categories (Migration 002)

```bash
# Restore from backup
pg_restore -U n8n_user -d kairon -c backups/pre_static_categories_production_*.dump
```

### Todos (Migration 003)

```bash
# Drop todos tables
psql -U n8n_user -d kairon -c "DROP TABLE IF EXISTS todos CASCADE;"
psql -U n8n_user -d kairon -c "DROP VIEW IF EXISTS open_todos, recent_todo_completions, stale_todos;"
```

---

## Next Steps

**Ready to start?**

1. Review migration 002 (static categories)
2. Test on copy database
3. Run in production
4. Update workflows
5. Proceed to Phase 2

**Questions or concerns before starting?**
