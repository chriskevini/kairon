# Thread Continuation Agent Implementation

## Overview

Thread_Continuation_Agent provides context-aware, grounded responses in Discord thread conversations by pre-fetching activities, notes, and conversation history.

**Performance:** <7 seconds response time (mimo-v2-flash)

---

## Architecture

```
User sends message in thread
  ↓
Discord Relay → Router
  ↓
If in Thread → If Commit (checks for --) → Handle Thread Continuation
  ↓
Thread_Continuation_Agent:
  1. Get Conversation (thread_id → conversation_id)
  2. Get Conversation History (last 10 messages)
  3. [PARALLEL]
     ├─ Get North Star
     ├─ Get Recent Activities (last 20)
     └─ Get Recent Notes (last 10)
  4. Wait for Context (Merge: append mode, 3 inputs)
  5. Build Context (format for prompt)
  6. Generate Response (mimo-v2-flash primary, nemotron fallback)
  7. Post to Thread
  8. Store Assistant Message
```

---

## Key Features

### Context Retrieval
- **Activities:** Last 20 from `recent_activities` view
- **Notes:** Last 10 from `recent_notes` view  
- **History:** Last 10 messages from current conversation
- **North Star:** User's guiding principle

### Fast Models
- **Primary:** `xiaomi/mimo-v2-flash:free`
- **Fallback:** `nvidia/nemotron-nano-9b-v2:free`
- **Response time:** <7 seconds (tested!)

### Grounded Responses
- References specific activities by timestamp
- Quotes relevant notes
- Maintains conversation flow with history
- Provides actionable insights based on actual data

---

## Tag System

| Symbol | Context | Meaning | Handler |
|--------|---------|---------|---------|
| `!!` | Any | Activity | Activity_Handler |
| `..` | Any | Note | Note_Handler |
| `++` | Main channel | Start thread | Thread_Handler |
| `::` | Any | Command | Command_Handler |
| `--` | Thread only | Commit thread (future) | Commit_Thread (TODO) |
| (none) | Main channel | LLM classification → tag | Intent Classifier → handlers |
| (none) | Thread | Continue conversation | Thread_Continuation_Agent |

---

## Router Flow

### Main Channel Messages

```
Discord Webhook
  ↓
React with 🔵 (acknowledgment)
  ↓
Parse Tag (extract !!|++|::|..|-- if present)
  ↓
If in Thread? NO → If Tag Detected?
  
  Tag exists:
    → Build Event Object (use parsed tag)
    → Store Raw Event
    → Add Raw Event ID  
    → Check Tag → Route to handler
    → Wait 1s → Remove 🔵
  
  No tag:
    → Intent Classifier (LLM)
    → Build Event Object (use classified tag)
    → Store Raw Event
    → Add Raw Event ID
    → Check Tag → Route to handler
    → Wait 1s → Remove 🔵
```

### Thread Messages

```
Discord Webhook
  ↓
React with 🔵 (acknowledgment)
  ↓
Parse Tag
  ↓
If in Thread? YES → Build Event Object (tag = null)
  → Store Raw Event
  → Add Raw Event ID
  → If Commit? (checks for -- tag)
  
     Tag == "--":
       → Commit Thread (TODO: summarize + extract)
       → Wait 1s → Remove 🔵
     
     Tag != "--":
       → Handle Thread Continuation
       → Wait 1s → Remove 🔵
```

**Key insight:** Thread messages get `tag = null` because they're always continuations (no routing needed).

---

## Prompt Design

### Thread_Handler (Initial Response)

**Purpose:** Classify question type and set expectations

```markdown
Assess the question type:
- Simple/direct → Answer directly (2-3 sentences)
- Planning/reflection → Mention context gathering + ask clarifying question

If simple:
  Answer directly and concisely

If needs context:
  Say: "Let me pull up your recent activities and notes..."
  Ask 1 clarifying question
  2-3 sentences total
```

**Example responses:**

**Simple:**
> Activities are what you're doing (actions, tasks), while notes are your thoughts and insights.

**Complex:**
> Let me pull up your recent activities and notes to give you a grounded answer. What's most pressing for you right now - finishing something you started or starting something new?

### Thread_Continuation_Agent

**Purpose:** Provide grounded, context-aware continuation

**Prompt structure:**
1. North Star
2. Recent Activities (last 20, formatted with timestamps)
3. Recent Notes (last 10, formatted with titles)
4. Instructions (5 points)
5. Style (single line)
6. Conversation History (just above current message)
7. Current Message

**Key improvements:**
- Conversation history placed right before current message (better attention)
- Simplified style to single line (easy to edit in DB later)
- Removed "Discord" reference (adds nothing)
- Removed repetitive North Star mentions

---

## Database Interactions

### Queries Used

**Get Conversation:**
```sql
SELECT id, created_from_raw_event_id, topic, metadata
FROM conversations
WHERE thread_id = $1 AND status = 'active'
LIMIT 1;
```

**Get Conversation History:**
```sql
SELECT role, text, timestamp
FROM conversation_messages
WHERE conversation_id = $1::uuid
ORDER BY timestamp DESC
LIMIT 10;
```

**Get Recent Activities:**
```sql
SELECT timestamp, category_name, description
FROM recent_activities
ORDER BY timestamp DESC
LIMIT 20;
```

**Get Recent Notes:**
```sql
SELECT timestamp, category_name, title, text
FROM recent_notes
ORDER BY timestamp DESC
LIMIT 10;
```

**Get North Star:**
```sql
SELECT value FROM config WHERE key = 'north_star';
```

**Store Assistant Message:**
```sql
INSERT INTO conversation_messages (
  conversation_id, raw_event_id, timestamp, role, text
) VALUES ($1::uuid, $2::uuid, NOW(), 'assistant', $3)
RETURNING *;
```

### Avoiding Duplicates

**Problem:** Postgres queries returning multiple rows cause duplicate items in merge node.

**Solution:** Use `.first()` or `.all()` appropriately in Build Context:
```javascript
const conversation = $('Get Conversation').first().json;
const historyItems = $('Get Conversation History').all(); // Intentional - need all messages
```

---

## Build Context Logic

```javascript
// Get event and conversation
const event = $('execute_workflow_trigger').first().json.event;
const conversation = $('Get Conversation').first().json;

// Get history (reversed for chronological order)
const historyItems = $('Get Conversation History').all();
const history = historyItems.reverse().map(item => ({
  role: item.json.role,
  text: item.json.text
}));

// Get context from merged inputs
const allInputs = $input.all();

// Extract north star (single value, no key)
const northStarItem = allInputs.find(
  item => item.json.value !== undefined && item.json.key === undefined
);
const northStar = northStarItem ? northStarItem.json.value : 'Not set';

// Extract activities (has category_name and description)
const activities = allInputs
  .filter(item => item.json.category_name && item.json.description)
  .map(item => ({
    timestamp: item.json.timestamp,
    category: item.json.category_name,
    description: item.json.description
  }));

// Extract notes (has category_name and title)
const notes = allInputs
  .filter(item => item.json.category_name && item.json.title)
  .map(item => ({
    timestamp: item.json.timestamp,
    category: item.json.category_name,
    title: item.json.title,
    text: item.json.text
  }));

return [{
  json: {
    ...event,  // Standard pattern: spread event first
    conversation_id: conversation.id,
    north_star: northStar,
    history: history,
    activities: activities,
    notes: notes
  }
}];
```

---

## Merge Node Configuration

**CRITICAL:** Always configure merge nodes with these parameters:

```json
{
  "parameters": {
    "mode": "append",
    "numberInputs": 3
  },
  "type": "n8n-nodes-base.merge",
  "typeVersion": 3
}
```

**Why:**
- `mode: "append"` - Combines all inputs into one array (what we want)
- `mode: "combine"` - Merges by position (causes issues)
- `numberInputs` - Must match number of connections

**Common mistake:** Empty parameters `{}` causes connection failures and data duplication.

---

## Standard Event Pattern

All handlers follow this pattern:

```javascript
return [{
  json: {
    ...event,           // Spread event FIRST (provides base fields)
    handler_field_1,    // Handler-specific fields can overwrite
    handler_field_2
  }
}];
```

**Why event first?**
- Provides default values for all fields
- Allows specific fields to overwrite (e.g., thread_id, conversation_id)
- Consistent across all handlers

---

## Testing

### Test Flow

```
1. Start thread:
   User: ++ what should I focus on today?
   Kairon: Creates thread, asks clarifying question

2. User elaborates in thread:
   User: I want to finish the router but also need deep work
   
3. Thread_Continuation_Agent activates (<7s):
   - Loads conversation history (2 messages)
   - Fetches last 20 activities
   - Fetches last 10 notes
   - Generates grounded response:
     "I see you've spent 8h on the router this week and captured
      a note about needing deep work. How about: 2h deep work
      this morning, then finish the router this afternoon?"

4. Conversation continues with full context each time
```

### Test Cases

**Thread continuation (no tag):**
```
++ help me think about my priorities
[in thread] I'm feeling scattered
→ Should load context and respond with grounded insights
```

**Thread with tag (activity in thread):**
```
++ let's plan my day
[in thread] !! working on the router agent
→ Should still work, stores activity
```

**Thread commit (future):**
```
++ help me think about X
[in thread] conversation happens...
[in thread] -- (commit symbol)
→ TODO: Summarize thread, create note/activity, close conversation
```

---

## Known Issues & Future Work

### Current Limitations

1. **No thread commit implementation** - `--` symbol recognized but Commit_Thread is placeholder
2. **Pre-fetches all context** - No smart classification (simple vs complex questions)
3. **No semantic search** - SQL only, no vector similarity
4. **Fixed context window** - Always last N items, not relevance-based

### Future Enhancements (Priority Order)

#### Week 2-3: Implement Thread Commit
```
-- symbol triggers:
1. Load full conversation history
2. Summarize with LLM
3. Extract key insights → create note
4. Extract actions → create activities
5. Close conversation (status = 'closed')
```

#### Week 4-5: Add Vector Search (pgvector)
```
1. Install pgvector extension
2. Add embedding columns to notes, activities
3. Generate embeddings for existing data
4. Add semantic search tools:
   - searchNotesBySemantic(query, limit)
   - searchActivitiesBySemantic(query, limit)
5. Update Thread_Continuation_Agent to use semantic search
```

#### Week 6+: Agentic Tools
```
Convert from pre-fetch to agentic:
1. Use n8n AI Agent node
2. Tools: getActivities(hours, category), getNotes(query), searchSemantic(query)
3. LLM decides which tools to call
4. More flexible, only fetches relevant context
```

#### Week 8+: Full RAG Pipeline
```
1. Hybrid search (vector + keyword)
2. Relevance ranking
3. Context compression (LLM summary of retrieved docs)
4. Multi-hop retrieval
5. Conversation memory search ("we discussed this before...")
```

---

## Configuration

### Environment Variables

All sensitive values use environment variables:

```bash
# Required for Thread_Continuation_Agent
OPENROUTER_API_KEY=your_key_here
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=kairon
POSTGRES_USER=n8n_user
POSTGRES_PASSWORD=your_password

# Required for Router
WEBHOOK_PATH=your_webhook_path
DISCORD_GUILD_ID=your_guild_id
DISCORD_CHANNEL_ARCANE_SHELL=channel_id
DISCORD_CHANNEL_KAIRON_LOGS=logs_channel_id
```

### Manual Setup Steps

1. **Import Thread_Continuation_Agent.json** to n8n UI

2. **Activate workflow** in n8n

3. **Update Router workflow ID:**
   - Open Discord_Message_Router in n8n
   - Find "Handle Thread Continuation" node
   - Update `workflowId` from `THREAD_CONTINUATION_AGENT_ID` to actual ID

4. **Test:**
   ```
   In #arcane-shell:
   ++ help me plan my day
   
   In thread:
   I'm not sure where to start
   
   Should get grounded response in <7s
   ```

---

## Troubleshooting

### Thread continuation not working

**Check:**
1. Thread_Continuation_Agent workflow activated?
2. Router has correct workflow ID for "Handle Thread Continuation"?
3. Thread_id exists in event object? Check raw_events table
4. Conversation exists in conversations table?

### Slow responses (>10s)

**Check:**
1. Are activities/notes tables large? (Should be fast with views)
2. Is OpenRouter API slow? (Try different model)
3. Are there network issues?
4. Check n8n execution logs for bottlenecks

### Context not showing in responses

**Check:**
1. Do activities/notes exist? Query views directly
2. Is Build Context extracting correctly? Check node output
3. Is prompt using the right variable names?
4. Check LLM response - is it ignoring context?

### Merge node connection failures

**Check:**
1. `mode: "append"` set?
2. `numberInputs` matches actual connections?
3. Try deleting and recreating merge node with correct params

---

## Performance Metrics

**Measured (tested):**
- Thread_Continuation_Agent: <7 seconds
- Context retrieval (3 parallel queries): ~1-2 seconds
- LLM generation (mimo-v2-flash): ~3-4 seconds
- Total: ~5-7 seconds

**Target:**
- Keep response time <10 seconds
- Consider caching for frequently accessed data
- Monitor as data grows

---

## Related Documentation

- [Thread Initial Response Trade-offs](./thread-initial-response-tradeoffs.md) - Decision log for context-lite vs full context
- [Router Agent Implementation](./router-agent-implementation.md) - Main routing logic
- [Database Setup](./database-setup.md) - Schema and views
- [AGENTS.md](../AGENTS.md) - Coding guidelines and best practices
