# Router Agent Implementation Guide

## Overview

The Router Agent is responsible for classifying untagged messages and extracting structured data using an AI agent with tools. This guide explains how to implement it in n8n.

## Current Status

❌ **Not Implemented** - The workflow currently has a placeholder node called "Router Agent Placeholder" that needs to be replaced with actual AI Agent logic.

## Architecture

```
Untagged Message
    ↓
1. Fetch User Context (Postgres queries)
    ↓
2. Build Agent Prompt (Code node)
    ↓
3. AI Agent with Tools
    ↓
4. Route Based on Tool Called (Switch node)
    ↓
5. Execute appropriate handler
```

## Implementation Steps

### Step 1: Add "Fetch User Context" Node

**Node Type:** Postgres (Execute Query)

**Position:** Before Router Agent Placeholder node

**Query:**
```sql
-- Fetch all context in one query using CTEs
WITH recent_acts AS (
  SELECT category_name, description, timestamp
  FROM recent_activities
  WHERE author_login = '{{ $json.author.login }}'
  ORDER BY timestamp DESC
  LIMIT 3
),
activity_cats AS (
  SELECT array_agg(DISTINCT name ORDER BY name) as categories
  FROM activity_categories
  WHERE active = true
),
note_cats AS (
  SELECT array_agg(DISTINCT name ORDER BY name) as categories
  FROM note_categories
  WHERE active = true
),
user_info AS (
  SELECT sleeping, last_observation_at
  FROM user_state
  WHERE user_login = '{{ $json.author.login }}'
)
SELECT 
  (SELECT json_agg(row_to_json(recent_acts)) FROM recent_acts) as recent_activities,
  (SELECT categories FROM activity_cats) as activity_categories,
  (SELECT categories FROM note_cats) as note_categories,
  (SELECT sleeping FROM user_info) as user_sleeping,
  (SELECT last_observation_at FROM user_info) as last_observation
;
```

**Output:** Stores context data for use in agent prompt

---

### Step 2: Build Agent Prompt

**Node Type:** Code (JavaScript)

**Code:**
```javascript
// Load the router agent system prompt template
const promptTemplate = `You are a routing agent for a life tracking and coaching system.

## User Context

- **User:** {{ $json.author.login }}
- **Time:** {{ $json.timestamp }}
- **Current State:** {{ $json.user_sleeping ? "Sleeping" : "Awake" }}

## Recent Activities (Last 3)

{{ $json.recent_activities ? $json.recent_activities.map(a => 
  \`- [\${a.observed_at}] \${a.category_name}: \${a.description}\`
).join('\\n') : 'None' }}

## Available Categories

**Activity Categories:**
{{ $json.activity_categories ? $json.activity_categories.join(', ') : 'work, personal, health, sleep, leisure' }}

**Note Categories:**
{{ $json.note_categories ? $json.note_categories.join(', ') : 'idea, decision, reflection, goal' }}

## Current Message

"{{ $json.clean_text }}"

---

## Your Task

Analyze the message and call the appropriate tool with extracted parameters.

## Available Tools

### 1. log_activity(category_name, description)

**Use when:**
- User is stating what they're currently doing or have done
- Present or past tense action statements
- Clear activity observations

**Examples:**
- "debugging authentication bug" → log_activity("work", "debugging authentication bug")
- "took a coffee break" → log_activity("leisure", "coffee break")
- "going to bed" → log_activity("sleep", "going to bed")

### 2. store_note(category_name, title, text)

**Use when:**
- Declarative thoughts, insights, or observations (NOT questions)
- Ideas or reflections to remember
- Decisions made

**Examples:**
- "I should prioritize morning deep work" → store_note("idea", "Morning Deep Work", "I should prioritize morning deep work")
- "decided to switch to async communication" → store_note("decision", "Async Communication", "decided to switch to async communication")

**Important:** Do NOT use store_note for questions.

### 3. start_thinking_session(topic)

**Use when:**
- User asks a question (interrogative)
- User requests help or exploration
- User wants to brainstorm

**Examples:**
- "what did I work on yesterday?" → start_thinking_session("what did I work on yesterday?")
- "help me figure out my priorities" → start_thinking_session("help me figure out my priorities")
- "why am I so tired lately?" → start_thinking_session("why am I so tired lately?")

### 4. get_recent_context(type, timeframe)

**Use when:**
- Message is ambiguous or refers to unstated context
- Pronouns like "it", "that", "this" without clear referent

**Parameters:**
- type: "activities" | "messages" | "notes"
- timeframe: "1h" | "today" | "3d"

---

## Decision Guidelines

1. **Activity statements** are typically:
   - "I'm [doing X]"
   - "[doing X]" (implied present tense)
   - "Finished [X]"

2. **Notes** are typically:
   - "Interesting [observation]"
   - "I should [idea]"
   - "Decided to [decision]"

3. **Thinking sessions** are typically:
   - Questions (who, what, when, where, why, how)
   - "Help me [X]"
   - "Let's [explore/think about] [X]"

4. **If truly ambiguous:**
   - Bias toward start_thinking_session (safest, non-destructive)

## Output Format

Call exactly ONE tool with appropriate parameters. Do not explain your reasoning.`;

// Replace template variables
const prompt = promptTemplate
  .replace(/{{ \$json\.(\w+) }}/g, (match, key) => $json[key] || '')
  .replace(/{{ \$json\.author\.login }}/g, $json.author.login)
  .replace(/{{ \$json\.user_sleeping \? "Sleeping" : "Awake" }}/g, 
    $json.user_sleeping ? "Sleeping" : "Awake");

return {
  ...$json,
  agent_prompt: prompt
};
```

---

### Step 3: Add AI Agent Node

**Node Type:** AI Agent (or OpenAI/Anthropic with function calling)

**Configuration:**

- **Model:** `claude-3-5-sonnet-20241022` (recommended) or `gpt-4-turbo`
- **System Prompt:** `={{ $json.agent_prompt }}`
- **User Message:** `={{ $json.clean_text }}`
- **Temperature:** `0.1` (low for consistent classification)

**Tools/Functions:**

```json
[
  {
    "name": "log_activity",
    "description": "Log an activity the user is doing or has done",
    "parameters": {
      "type": "object",
      "properties": {
        "category_name": {
          "type": "string",
          "description": "The activity category (e.g., work, personal, health, sleep, leisure)"
        },
        "description": {
          "type": "string",
          "description": "Brief description of the activity"
        }
      },
      "required": ["category_name", "description"]
    }
  },
  {
    "name": "store_note",
    "description": "Store a declarative thought, insight, idea, or decision (NOT questions)",
    "parameters": {
      "type": "object",
      "properties": {
        "category_name": {
          "type": "string",
          "description": "The note category (e.g., idea, decision, reflection, goal)"
        },
        "title": {
          "type": "string",
          "description": "Optional title for the note"
        },
        "text": {
          "type": "string",
          "description": "The note content"
        }
      },
      "required": ["category_name", "text"]
    }
  },
  {
    "name": "start_thinking_session",
    "description": "Start a conversational thinking session for questions or exploration",
    "parameters": {
      "type": "object",
      "properties": {
        "topic": {
          "type": "string",
          "description": "The question or topic to explore"
        }
      },
      "required": ["topic"]
    }
  },
  {
    "name": "get_recent_context",
    "description": "Get recent context when message is ambiguous",
    "parameters": {
      "type": "object",
      "properties": {
        "type": {
          "type": "string",
          "enum": ["activities", "messages", "notes"],
          "description": "Type of context to retrieve"
        },
        "timeframe": {
          "type": "string",
          "enum": ["1h", "today", "3d"],
          "description": "Timeframe for context"
        }
      },
      "required": ["type", "timeframe"]
    }
  }
]
```

**Output:** The agent will call one of these tools. n8n will output the tool name and parameters.

---

### Step 4: Route Based on Tool Called

**Node Type:** Switch

**Conditions:**

1. **Output 0:** `tool_name` equals `log_activity`
2. **Output 1:** `tool_name` equals `store_note`
3. **Output 2:** `tool_name` equals `start_thinking_session`
4. **Output 3:** `tool_name` equals `get_recent_context`

---

### Step 5: Implement Tool Handlers

#### Output 0: Handle log_activity

**Node Type:** Code (to look up category_id, then insert)

**Code:**
```javascript
// Look up category_id from category_name
const categoryName = $input.item.json.tool_arguments.category_name;
const timestamp = $input.item.json.timestamp;
const description = $input.item.json.tool_arguments.description;
const authorLogin = $input.item.json.author.login;
const rawEventId = $input.item.json.raw_event_id; // From Store Raw Event node

return {
  ...$input.item.json,
  insert_activity: {
    category_name: categoryName,
    description: description,
    timestamp: timestamp,
    author_login: authorLogin,
    raw_event_id: rawEventId
  }
};
```

**Then add Postgres node:**

**Query:**
```sql
INSERT INTO activity_log (
  raw_event_id,
  timestamp,
  category_id,
  description
)
SELECT 
  '{{ $json.raw_event_id }}',
  '{{ $json.timestamp }}',
  ac.id,
  '{{ $json.tool_arguments.description.replace(/'/g, "''") }}'
FROM activity_categories ac
WHERE ac.name = '{{ $json.tool_arguments.category_name }}'
  AND ac.active = true
RETURNING *;
```

**Then:** Set emoji to 🕒 and continue to "Send Emoji Reaction"

---

#### Output 1: Handle store_note

**Node Type:** Postgres (Insert)

**Query:**
```sql
INSERT INTO notes (
  raw_event_id,
  timestamp,
  category_id,
  title,
  text
)
SELECT 
  '{{ $json.raw_event_id }}',
  '{{ $json.timestamp }}',
  nc.id,
  {{ $json.tool_arguments.title ? "'" + $json.tool_arguments.title.replace(/'/g, "''") + "'" : "NULL" }},
  '{{ $json.tool_arguments.text.replace(/'/g, "''") }}'
FROM note_categories nc
WHERE nc.name = '{{ $json.tool_arguments.category_name }}'
  AND nc.active = true
RETURNING *;
```

**Then:** Set emoji to 📝 and continue to "Send Emoji Reaction"

---

#### Output 2: Handle start_thinking_session

**Nodes Needed:**

1. **Create Discord Thread** (HTTP Request to Discord API)
   - URL: `https://discord.com/api/v10/channels/{{ $json.channel_id }}/messages/{{ $json.message_id }}/threads`
   - Method: POST
   - Body: `{ "name": "{{ $json.tool_arguments.topic | truncate(100) }}" }`

2. **Insert Conversation** (Postgres)
   ```sql
   INSERT INTO conversations (
     thread_id,
     created_from_raw_event_id,
     status,
     topic
   ) VALUES (
     '{{ $json.thread_id }}',
     '{{ $json.raw_event_id }}',
     'active',
     '{{ $json.tool_arguments.topic.replace(/'/g, "''") }}'
   )
   RETURNING *;
   ```

3. **Call Thread_Agent sub-workflow** (TODO: implement)

**Then:** Set emoji to 💭 and continue to "Send Emoji Reaction"

---

#### Output 3: Handle get_recent_context

**Node Type:** Postgres (Query based on type and timeframe)

**Logic:** 
- Fetch the requested context
- Loop back to "Build Agent Prompt" with additional context
- Re-run the agent

**Then:** Continue based on new tool call

---

## Testing

### Test Cases

1. **Activity statement:** `"working on the router agent implementation"`
   - Expected: Calls `log_activity("work", "working on the router agent implementation")`
   - Expected emoji: 🕒

2. **Note/Insight:** `"I think async communication reduces context switching"`
   - Expected: Calls `store_note("reflection", null, "I think async communication reduces context switching")`
   - Expected emoji: 📝

3. **Question:** `"what did I work on yesterday?"`
   - Expected: Calls `start_thinking_session("what did I work on yesterday?")`
   - Expected: Creates Discord thread
   - Expected emoji: 💭

4. **Ambiguous:** `"still working on it"`
   - Expected: Calls `get_recent_context("activities", "today")`
   - Expected: Fetches context and re-runs agent

---

## Integration Points

The Router Agent integrates with:
- **activity_log** table: Writes activities
- **notes** table: Writes notes
- **conversations** table: Creates threads
- **Discord API**: Creates threads
- **Thread_Agent sub-workflow**: Handles conversational flow

---

## Performance Considerations

- **Context queries are fast:** Single CTE query fetches all context at once
- **Agent calls are async:** User sees immediate emoji reaction (🤖) while agent processes
- **Tool calls are deterministic:** Once agent decides, execution is fast

---

## Future Enhancements

1. **Add caching:** Cache recent activities/categories for 5 minutes
2. **Add retry logic:** If agent fails to call a tool, retry once
3. **Add fallback:** If ambiguous, default to `start_thinking_session` instead of error
4. **Add analytics:** Track which tools are called most often
5. **Fine-tune prompt:** Adjust based on real-world usage patterns

---

## References

- System Prompt: `/prompts/router-agent.md`
- Design Doc: `/README.md` (Section 5.4)
- Database Schema: `/db/migrations/001_initial_schema.sql`
