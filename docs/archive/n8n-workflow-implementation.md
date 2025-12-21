# n8n Workflow Implementation Guide

**NOTE:** This document describes the original architecture plan. The implementation has evolved:
- Workflow renamed: `Discord_Message_Ingestion` → `Discord_Message_Router`
- Architecture changed: Internal sub-workflows → External handler workflows
- Router Agent changed: AI Agent with tools → Simple LLM classifier outputting TAG|CONFIDENCE
- See README.md Section 4.2 for current implementation status

## Overview

This document describes the original planned implementation of `Discord_Message_Router` workflow.

## Main Workflow: Discord_Message_Router (formerly Discord_Message_Ingestion)

### Architecture Pattern

```
Discord Webhook (trigger)
  ↓
[Store Raw Event]
  ↓
[Parse Tag & Context]
  ↓
[Routing Decision Tree]
  ↓
  ├─ Tag-based (deterministic) → Direct handlers
  └─ Agentic → Execute: Router_Agent sub-workflow
  ↓
[Update User State]
  ↓
[Send Emoji Reaction]
  ↓
[Respond to Webhook]
```

### Node Structure

#### 1. Webhook Trigger
- **Type:** Webhook
- **Method:** POST
- **Path:** `/discord-webhook`
- **Response Mode:** Using 'Respond to Webhook' node
- **Authentication:** None (or API key if needed)

**Expected Payload:**
```json
{
  "guild_id": "string",
  "channel_id": "string",
  "message_id": "string",
  "thread_id": "string | null",
  "author": {
    "login": "string",
    "id": "string"
  },
  "content": "string",
  "timestamp": "ISO8601 datetime"
}
```

#### 2. Store Raw Event (Postgres Node)

**Operation:** Insert
**Table:** `raw_events`

**Query:**
```sql
INSERT INTO raw_events (
  source_type,
  discord_guild_id,
  discord_channel_id,
  discord_message_id,
  message_url,
  author_login,
  thread_id,
  raw_text,
  clean_text,
  tag
) VALUES (
  'discord',
  $1, -- guild_id
  $2, -- channel_id
  $3, -- message_id
  $4, -- message_url (computed)
  $5, -- author.login
  $6, -- thread_id
  $7, -- content
  $8, -- clean_text (computed)
  $9  -- tag (computed)
)
ON CONFLICT (discord_message_id) DO NOTHING
RETURNING id, clean_text, tag, thread_id;
```

**Computations needed (Code node before this):**
```javascript
const content = $json.content;
const firstToken = content.trim().split(/\s+/)[0];
let tag = null;
let clean_text = content;

if (firstToken === '!!' || firstToken === '++') {
  tag = firstToken;
  clean_text = content.slice(2).trim();
} else if (firstToken.startsWith('::')) {
  tag = firstToken;
  clean_text = content.slice(firstToken.length).trim();
}

const message_url = `https://discord.com/channels/${$json.guild_id}/${$json.channel_id}/${$json.message_id}`;

return {
  ...item.json,
  tag,
  clean_text,
  message_url
};
```

#### 3. Load Context (Postgres Node)

**Parallel queries:**

**Query 1: Get User State**
```sql
SELECT * FROM user_state 
WHERE user_login = $1;
```

**Query 2: Get Recent Activities (last 3)**
```sql
SELECT 
  a.timestamp,
  ac.name as category_name,
  a.description
FROM activity_log a
JOIN activity_categories ac ON a.category_id = ac.id
WHERE a.timestamp > NOW() - INTERVAL '24 hours'
ORDER BY a.timestamp DESC
LIMIT 3;
```

**Query 3: Get Categories**
```sql
-- Activity categories
SELECT name FROM activity_categories WHERE active = true ORDER BY sort_order;

-- Note categories
SELECT name FROM note_categories WHERE active = true ORDER BY sort_order;
```

#### 4. Routing Decision (Switch Node)

**Conditions:**

```javascript
// Branch 1: Message in thread
if ($('Store Raw Event').item.json.thread_id) {
  // Check if commit command
  if ($('Store Raw Event').item.json.tag === '++' || 
      $('Store Raw Event').item.json.tag === '::commit') {
    return 'commit';
  }
  return 'thread_chat';
}

// Branch 2: Activity tag
if ($('Store Raw Event').item.json.tag === '!!') {
  return 'activity_tagged';
}

// Branch 3: Thread start tag
if ($('Store Raw Event').item.json.tag === '++') {
  return 'thread_start_tagged';
}

// Branch 4: Command
if ($('Store Raw Event').item.json.tag?.startsWith('::')) {
  return 'command';
}

// Branch 5: Agentic routing (no tag)
return 'agentic';
```

### Sub-workflows (Internal, Disconnected Nodes)

#### Sub-workflow 1: Router_Agent

**Trigger:** Execute Workflow Trigger
**Type:** AI Agent node

**System Prompt:**
```
You are a routing agent for a life tracking and coaching system.

User: {{ $json.author_login }}
Time: {{ $json.timestamp }}
Sleeping: {{ $json.user_sleeping }}

Recent activities (last 3):
{{ $json.recent_activities }}

Active categories:
- Activities: {{ $json.activity_categories }}
- Notes: {{ $json.note_categories }}

Current message: "{{ $json.clean_text }}"

Available tools:

1. log_activity(category_name, description):
   - User stating current/past actions
   - Present/past tense statements
   - Examples: "debugging bug", "took a break", "finished report"

2. store_note(category_name, title, text):
   - Declarative thoughts, insights, observations (NOT questions)
   - Examples: "insight about productivity", "need to remember X"

3. start_thinking_session(topic):
   - Questions (interrogative)
   - Requests for help/exploration
   - "Let's think..." statements
   - Examples: "what did I work on yesterday?", "help me plan"

4. get_recent_context(type, timeframe):
   - Use if message is ambiguous or refers to unstated context
   - Types: "activities", "messages", "notes"
   - Timeframes: "1h", "today", "3d"

If truly ambiguous, bias toward start_thinking_session (conversational, safe, non-destructive).
```

**Tools:** (Defined as Code nodes or Execute Workflow nodes)

**After Router_Agent execution:**
- Store routing_decision to DB
- Branch based on tool called (log_activity / store_note / start_thinking_session)

#### Sub-workflow 2: Thread_Agent

**Trigger:** Execute Workflow Trigger
**Type:** AI Agent node

**System Prompt:**
```
You are an AI life coach helping the user reflect and plan.

User: {{ $json.author_login }}
User's North Star: {{ $json.north_star || "Not set" }}

This is their guiding principle. Reference it when relevant to help them stay aligned.

You're in a thinking session about: "{{ $json.initial_message }}"

Available tools:
- retrieve_recent_activities(categories, timeframe, limit)
- retrieve_recent_notes(categories, timeframe, limit)
- search_by_keyword(keyword, timeframe)
- refine_thread_title(title)

On your FIRST response only:
1. Analyze the topic
2. Call refine_thread_title() with a concise title (3-6 words, no question marks)
   Examples: "Productivity Factors Analysis", "Career Path Exploration"
3. Retrieve relevant context if needed (use tools)
4. Respond conversationally

For subsequent messages:
- Use retrieval tools when you need context about their past
- Don't retrieve unnecessarily
- Be conversational and supportive
```

**Memory:** Window Buffer Memory (10 messages)

**Tools:** (Defined as Code/Postgres nodes)

#### Sub-workflow 3: Commit_Thread

**Trigger:** Execute Workflow Trigger
**Type:** OpenAI node (not agent, simpler)

**Steps:**
1. Load all conversation_messages for thread_id
2. Call LLM with summarization prompt
3. Parse JSON response
4. Insert note + activity to DB
5. Update conversation status
6. Post confirmation to Discord

**Prompt:**
```
Summarize this thinking session into structured outputs.

Conversation:
{{ $json.conversation_messages }}

Output valid JSON only (no markdown):
{
  "note": {
    "category_name": "idea|reflection|decision|question|meta",
    "title": "brief title",
    "text": "summary of key insights"
  },
  "activity": {
    "category_name": "work|leisure|study|relationships|sleep|health",
    "description": "Thinking session: [topic]"
  }
}
```

#### Sub-workflow 4: Command_Handler

**Trigger:** Execute Workflow Trigger
**Type:** Switch + Code nodes

**Commands:**
```javascript
const command = $json.tag.slice(2); // Remove '::'
const args = $json.clean_text;

switch(command) {
  case 'north_star':
    return handleNorthStar(args);
  case 'categories':
    return handleCategories();
  case 'status':
    return handleStatus();
  case 'help':
    return handleHelp();
  case 'commit':
    return handleCommit();
  default:
    return { error: `Unknown command: ${command}` };
}
```

### Deterministic Handlers (in main workflow)

#### Handle Activity (Tagged)

**When:** Tag = `!!`

**Steps:**
1. Call OpenAI (simple completion, not agent) to extract category + description
2. Insert to activity_log
3. Store routing_decision (forced_by='tag')
4. Update user_state
5. React with 🕒

**Extraction Prompt:**
```
Extract structured activity data from this message.

Message: "{{ $json.clean_text }}"

Active activity categories: {{ $json.activity_categories }}

Output valid JSON only (no markdown):
{
  "category_name": "work|leisure|study|relationships|sleep|health",
  "description": "faithful description of the activity"
}

If ambiguous, choose the most likely category.
```

#### Handle Thread Start (Tagged)

**When:** Tag = `++` (not in thread)

**Steps:**
1. Create Discord thread
2. Insert to conversations table
3. Execute: Thread_Agent
4. React with 💭

### Update User State (Always)

**After any activity logged:**
```sql
UPDATE user_state
SET 
  last_observation_at = $1,
  sleeping = (
    SELECT is_sleep_category 
    FROM activity_categories 
    WHERE id = $2
  ),
  updated_at = NOW()
WHERE user_login = $3;
```

### Send Emoji Reaction

**Discord API Call:**
```
PUT /channels/{channel_id}/messages/{message_id}/reactions/{emoji}/@me
```

**Emoji mapping:**
```javascript
const emojiMap = {
  'Activity': '🕒',
  'Note': '📝',
  'ThreadStart': '💭',
  'Commit': '✅',
  'Command': '⚙️',
  'Error': '🛑',
  'Ambiguous': '⚠️'
};
```

### Respond to Webhook

**Always return 200 OK quickly:**
```json
{
  "status": "received",
  "message_id": "{{ $json.message_id }}"
}
```

## Implementation Order

1. ✅ Set up webhook trigger
2. ✅ Implement Store Raw Event + tag parsing
3. ✅ Implement routing decision tree (deterministic branches)
4. ✅ Implement deterministic handlers (!! tagged activities)
5. ✅ Implement Router_Agent sub-workflow
6. ✅ Implement Thread_Agent sub-workflow
7. ✅ Implement Commit_Thread sub-workflow
8. ✅ Implement Command_Handler sub-workflow
9. ✅ Test each path end-to-end

## Testing Checklist

### Test 1: Tagged Activity
```
Message: !! debugging auth bug
Expected:
  - Activity logged (work category)
  - 🕒 reaction
  - DB: raw_events + routing_decisions + activity_log
```

### Test 2: Agentic Note
```
Message: interesting insight about my morning routine
Expected:
  - Note stored (reflection category)
  - 📝 reaction
  - DB: raw_events + routing_decisions + notes
```

### Test 3: Question → Thread
```
Message: what did I work on yesterday?
Expected:
  - Thread created
  - Thread title refined
  - Context retrieved
  - Response posted
  - 💭 reaction
```

### Test 4: Thread Commit
```
In thread: ++
Expected:
  - Note created
  - Activity created (thinking session)
  - Thread status = committed
  - ✅ reaction
  - Confirmation posted
```

### Test 5: Command
```
Message: ::north_star set I will focus on deep work
Expected:
  - Config updated
  - Confirmation posted
  - ⚙️ reaction
```

## Error Handling

### Idempotency
- `discord_message_id` UNIQUE constraint prevents duplicate processing
- ON CONFLICT DO NOTHING in raw_events insert

### LLM Failures
- Catch JSON parse errors
- Default to 'Note' if classification fails
- Log errors to #kairon-log channel

### Discord API Failures
- Retry reactions (non-critical)
- Log failures but don't block workflow
- Thread creation failures should error (critical)

## Performance Optimization

### Deterministic Fast Paths
- Tag parsing: ~10ms
- DB insert: ~50ms
- Total for tagged activities: < 200ms

### Agentic Paths
- Router Agent: ~2-3s (LLM call)
- Thread Agent: ~3-5s (with retrieval)
- Acceptable for non-tagged messages

### Parallel Queries
- Load user_state + recent_activities + categories in parallel
- Use n8n's batch processing where possible

## Next Steps

1. Export workflow JSON from n8n
2. Store in `n8n-workflows/Discord_Message_Router.json` ✅
3. Version control all prompts separately
4. Document Discord bot setup
5. Create integration tests
