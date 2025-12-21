# Save Thread (--) Feature Design

## Philosophy: Maximum User Agency

**Core principle:** Give users full control. No forced closures, no nagging, no automatic cleanup.

---

## User Flow

### 1. User Sends `-- save` in Thread

**What happens:**
```
User: "-- save"
Bot: 💭 (thinking emoji - analyzing thread)
Bot: (sends structured summary + prompts)
```

**LLM analyzes entire thread history and extracts:**
- **Key insights** (observations, realizations, patterns)
- **Decisions made** (commitments, choices, resolutions)
- **Action items** (todos, next steps, things to do)

**Bot responds with:**
```markdown
📊 **Thread Summary**

**Insights** (save as notes?)
• [insight 1]
• [insight 2]

**Decisions** (save as notes?)
• [decision 1]
• [decision 2]

**Action Items** (save as todos?)
• [ ] [todo 1]
• [ ] [todo 2]

---

**How to save:**
`-- note 1 3` - Save insights #1 and #3 as notes
`-- todo 1 2` - Save action items #1 and #2 as todos
`-- done` - Mark thread complete (optional)
```

### 2. User Selects What to Save

**Option A: Save specific items**
```
User: "-- note 1 3"
Bot: ✅ Saved 2 notes:
     • [insight 1 preview...]
     • [insight 3 preview...]
```

**Option B: Save as todos**
```
User: "-- todo 1 2"
Bot: ✅ Created 2 todos:
     • [ ] [todo 1 preview...]
     • [ ] [todo 2 preview...]
```

**Option C: Mix and match**
```
User: "-- note 1"
User: "-- todo 2 3"
Bot: ✅ Saved 1 note + 2 todos
```

**Option D: Mark done without saving**
```
User: "-- done"
Bot: ✅ Thread marked complete. You can always come back to it!
```

### 3. User Decides When to Leave Thread

**User just... stops responding.**
- Thread stays `active` in DB
- No nagging
- No automatic closure
- User can return anytime

**Discord auto-archives thread after 24h/7d (Discord's setting)**
- This is Discord's behavior, not ours
- We don't fight it
- Thread remains `active` in our DB

---

## Database Schema

### Conversations Table (existing)
```sql
CREATE TABLE conversations (
  id uuid PRIMARY KEY,
  thread_id text NOT NULL UNIQUE,
  status text DEFAULT 'active',  -- active, completed
  topic text,
  created_at timestamptz DEFAULT NOW(),
  ...
);
```

**Status values:**
- `active` - Thread is ongoing (default, never auto-changes)
- `completed` - User explicitly marked done with `-- done`

### Thread Extractions Table (new)
```sql
CREATE TABLE thread_extractions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid REFERENCES conversations(id),
  extraction_type text NOT NULL,  -- 'insight', 'decision', 'action_item'
  text text NOT NULL,
  display_order int NOT NULL,  -- 1, 2, 3 for numbered list
  saved_as text,  -- 'note', 'todo', NULL (not saved yet)
  saved_id uuid,  -- FK to notes or todos table
  created_at timestamptz DEFAULT NOW()
);
```

**Why this table?**
- Stores LLM extractions before user decides what to save
- Enables numbered selection (`-- note 1 3`)
- Tracks what's already been saved (prevent duplicates)
- Allows partial saving (save some now, others later)

---

## Workflow: Save_Thread_Handler

### Trigger
- Router detects `--` tag
- Checks if in thread
- Executes Save_Thread_Handler workflow

### Node Flow

#### 1. Check Thread Exists
```sql
SELECT id FROM conversations WHERE thread_id = $1 AND status = 'active';
```
- If not found: "❌ No active conversation found in this thread"

#### 2. Get Previous Extraction (if exists)
```sql
SELECT * FROM thread_extractions 
WHERE conversation_id = $1 
ORDER BY created_at DESC 
LIMIT 1;
```
- Check if extraction is recent (< 5 minutes ago)
- If yes, user is probably responding to extraction (go to step 5)
- If no, user wants new extraction (go to step 3)

#### 3. Extract Thread History
```sql
SELECT role, text, timestamp 
FROM conversation_messages 
WHERE conversation_id = $1 
ORDER BY timestamp ASC;
```

#### 4. LLM Extraction Prompt
```markdown
You are analyzing a conversation thread to extract actionable items.

## Thread History
{full conversation history}

## Task
Extract and categorize:

1. **Insights** - Key realizations, patterns, observations
2. **Decisions** - Commitments, choices, resolutions made
3. **Action Items** - Concrete todos, next steps

## Output Format
Use this EXACT format (one item per line):

INSIGHT|The user realized they work better in mornings
INSIGHT|Deep work requires 2+ hour blocks
DECISION|Will switch to async communication
DECISION|No meetings before 10am
ACTION|Set up morning deep work block in calendar
ACTION|Draft async communication guidelines

## Rules
- Be specific and concrete
- Use user's own words when possible
- Only include items explicitly discussed
- Max 10 items total
- If no items in a category, skip it
```

#### 5. Parse LLM Output + Store Extractions
```javascript
const lines = llmOutput.split('\n').filter(line => line.includes('|'));
const extractions = [];

lines.forEach((line, index) => {
  const [type, text] = line.split('|').map(s => s.trim());
  const displayOrder = index + 1;
  
  extractions.push({
    conversation_id: conversationId,
    extraction_type: type.toLowerCase(),  // 'insight', 'decision', 'action'
    text: text,
    display_order: displayOrder,
    saved_as: null,
    saved_id: null
  });
});

// Bulk insert into thread_extractions
```

#### 6. Format Response
```javascript
const insights = extractions.filter(e => e.extraction_type === 'insight');
const decisions = extractions.filter(e => e.extraction_type === 'decision');
const actions = extractions.filter(e => e.extraction_type === 'action');

let response = '📊 **Thread Summary**\n\n';

if (insights.length > 0) {
  response += '**Insights** (save as notes?)\n';
  insights.forEach(item => {
    response += `${item.display_order}. ${item.text}\n`;
  });
  response += '\n';
}

if (decisions.length > 0) {
  response += '**Decisions** (save as notes?)\n';
  decisions.forEach(item => {
    response += `${item.display_order}. ${item.text}\n`;
  });
  response += '\n';
}

if (actions.length > 0) {
  response += '**Action Items** (save as todos?)\n';
  actions.forEach(item => {
    response += `${item.display_order}. [ ] ${item.text}\n`;
  });
  response += '\n';
}

response += '---\n\n**How to save:**\n';
response += '`-- note 1 3` - Save items #1 and #3 as notes\n';
response += '`-- todo 1 2` - Save items #1 and #2 as todos\n';
response += '`-- done` - Mark thread complete (optional)';
```

#### 7. Parse User Selection (subsequent `--` messages)
```javascript
// Parse: "-- note 1 3"
const match = cleanText.match(/^(note|todo|done)(\s+(\d+(\s+\d+)*))?$/i);
if (!match) {
  return "Use format: `-- note 1 3` or `-- todo 1 2` or `-- done`";
}

const action = match[1].toLowerCase();  // 'note', 'todo', 'done'
const numbers = match[3] ? match[3].split(/\s+/).map(n => parseInt(n)) : [];
```

#### 8A. Save as Notes
```sql
-- Get extractions by display_order
SELECT * FROM thread_extractions 
WHERE conversation_id = $1 
  AND display_order = ANY($2::int[])
  AND saved_as IS NULL;

-- For each extraction:
INSERT INTO notes (timestamp, category, text, metadata)
VALUES (
  NOW(),
  'reflection',  -- Thread insights are always reflections
  $1,
  jsonb_build_object('from_thread', true, 'conversation_id', $2)
)
RETURNING id;

-- Update thread_extractions
UPDATE thread_extractions 
SET saved_as = 'note', saved_id = $1 
WHERE id = $2;
```

#### 8B. Save as Todos (when migration 003 is ready)
```sql
INSERT INTO todos (text, status, created_from_thread)
VALUES ($1, 'pending', $2)
RETURNING id;

UPDATE thread_extractions 
SET saved_as = 'todo', saved_id = $1 
WHERE id = $2;
```

#### 8C. Mark Thread Complete
```sql
UPDATE conversations 
SET status = 'completed', updated_at = NOW() 
WHERE id = $1;
```

---

## Thread Lifecycle

### Active Thread (default)
```
User: ++ what should I focus on?
Bot: [creates conversation, status='active']
Bot: [conversation continues...]
User: [stops responding]
```
→ Thread remains `active` indefinitely
→ No automatic changes
→ User can return anytime

### Discord Auto-Archive (24h or 7d)
```
Discord: [archives thread after inactivity period]
```
→ Our DB: Still `active`
→ Why? User might unarchive and continue
→ We don't poll Discord for archive status (unnecessary complexity)

### User Explicitly Closes
```
User: -- done
Bot: ✅ Thread marked complete
```
→ DB: `status='completed'`
→ User can still send messages (Discord allows)
→ Bot will still respond (Thread_Continuation_Agent checks thread_id not status)

---

## Questions & Decisions

### Q: What if user sends `-- save` multiple times?

**A: Show updated list with already-saved items marked**
```markdown
📊 **Thread Summary**

**Insights**
1. [insight 1] ✅ Saved as note
2. [insight 2]
3. [insight 3] ✅ Saved as note

**Action Items**
4. [ ] [todo 1]
5. [ ] [todo 2] ✅ Saved as todo

**How to save:**
`-- note 2` - Save remaining insight
`-- todo 4` - Save remaining action item
```

### Q: What if Discord thread is archived?

**A: No special handling**
- User can unarchive and continue
- Bot responds normally
- DB status unchanged

### Q: Should we poll for deleted threads?

**A: No**
- Adds complexity (periodic job, Discord API calls)
- Minimal value (orphaned records don't hurt)
- User agency: Let them decide when thread is "done"
- If needed later, can add cleanup job that runs monthly

### Q: Should bot notify if no response after X days?

**A: No**
- Violates "maximum user agency" principle
- User might be intentionally pausing
- If user wants reminder, they can set it themselves
- Bot should be responsive, not proactive

### Q: What if extraction misses something important?

**A: User can always manually save**
- They can still use `.. note` to capture missed insights
- Extraction is a helper, not a requirement
- User has full control

### Q: What about thread topic/title?

**A: Auto-generate from first message, allow user to change later**
```sql
-- Thread_Handler already stores topic
UPDATE conversations SET topic = $1 WHERE id = $2;
```
- Could add `-- topic <new topic>` command later
- Not critical for MVP

---

## Implementation Phases

### Phase 1: Basic Extraction (MVP)
- [x] Thread_Handler creates conversations
- [ ] Save_Thread_Handler workflow
- [ ] LLM extraction (insights, decisions, actions)
- [ ] Display numbered summary
- [ ] `-- note 1 3` saves to notes table
- [ ] `-- done` marks complete

### Phase 2: Todo Integration
- [ ] Migration 003 (todos table)
- [ ] `-- todo 1 2` saves to todos table
- [ ] Todo status tracking

### Phase 3: Enhancements
- [ ] Show ✅ for already-saved items
- [ ] `-- topic <new title>` command
- [ ] Thread stats (::thread stats)
- [ ] RAG: Search across thread history

---

## Open Questions for You

1. **Category for thread-derived notes:** Always `reflection`, or let LLM choose `fact` vs `reflection`?
   - My vote: Always `reflection` (thread insights are internal knowledge)

2. **Should `-- done` be required to close thread?**
   - My vote: No, it's optional. User can just stop responding.

3. **Should we show thread status in `::stats`?**
   - Example: "Active threads: 3, Completed threads: 12"
   - My vote: Yes, useful info

4. **Extraction prompt: Show full conversation or summarize?**
   - My vote: Full conversation (max ~10-20 messages), more accurate

What do you think of this design? Any changes or additions?
