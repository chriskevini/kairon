# Kairon — Life OS

## High-level Overview

**Kairon** is a Discord-first "operating system" for your day-to-day life.

- You type anything in **`#arcane-shell`** (the CLI)
- **Router** ingests every message, stores raw text in Postgres, and routes it intelligently
- Most of the time, Kairon is in **Ledger Mode** (logging + routing)
- When you want to brainstorm or ask questions, you start a **thread** (Chat Mode)
- When you type **`::commit`** inside the thread, Kairon summarizes it into structured entries

Kairon runs a scheduled **Proactivity** workflow every 30 minutes:
- If you're awake (based on logs) and haven't logged recently, it pings you to log now

**MVP focuses on:** raw ingest + activities + notes + threads + commit + proactivity

---

## 0) North Star / Product Definition

**Goal:** A Discord-native system that:
- Captures **raw truth** (append-only raw events)
- Routes intent intelligently with hybrid deterministic + agentic approach
- Maintains a clean ledger of **Activities** and **Notes**
- Supports multi-turn conversations in threads
- Nudges you every **30 minutes** when you forget to log
- Stays maintainable (sub-workflows + strict DB contracts)

**User-facing persona:** **Kairon** (single entity name; messages do not reveal internal module names)

---

## 1) UX Surface (Discord)

### Channels
- **`#arcane-shell`** — the CLI: all user input goes here
- **`#obsidian-board`** — system output: daily plan + summaries + dashboards (future)
- **`#kairon-log`** — audit feed: important system actions / errors / commits (optional)

### Threads (Converse Mode)
- Brainstorming and Q&A happen in **threads** off messages in `#arcane-shell`
- Threads are multi-turn conversations with memory and context retrieval
- Thread titles are automatically refined by the AI for better organization

### Tagging (optional overrides)

**Tags:**
```
!!           Force activity observation (optional speedup)
..           Force note (new - for thoughts/insights)
++           Force thread start (in channel) / commit (in thread)
::command    System commands
(no tag)     LLM classifies (Activity, Note, or Thread)
```

**Tag behavior:**
- Tags are **optional** - system works without them (LLM routing)
- Tags provide **fast path** - skip LLM classification (~500ms faster)
- Tags are **escape hatch** - override when LLM misclassifies

**Routing approach:**
- **Deterministic fast path:** `!!`, `..`, `++`, `::` → immediate routing
- **LLM classification:** No tag → LLM outputs `TAG|CONFIDENCE` → routes to tag handlers
- **Key insight:** LLM just decides which tag to apply, then reuses tag routing logic

### Emoji Reaction Feedback

After routing, Kairon reacts to your message:
- Activity logged: `🕒`
- Note stored: `📝`
- Thread started: `💭`
- Thread committed: `✅`
- Command executed: `⚙️`
- LLM classified: `🤖` (temporary during processing)
- Error: `⚠️`

---

## 2) Modes

### 2.1 Ledger Mode (default)
- All messages go through Router → structured ledger actions (activity/note)
- Router is hybrid: deterministic (with tags) + agentic (without tags)

### 2.2 Converse Mode (threads)
- Multi-turn conversation in a thread
- Messages stored as conversation turns, not as ledger spam
- `::commit` or `++` in thread converts to ledger entries (note + activity always)

---

## 3) Database (PostgreSQL) — "The Ledger"

### 3.1 Raw Ingest (append-only, mandatory)

**Table: `raw_events`**
```sql
CREATE TABLE raw_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source_type TEXT NOT NULL, -- 'discord' | 'cron'
  
  -- Discord metadata (nullable for cron)
  discord_guild_id TEXT,
  discord_channel_id TEXT,
  discord_message_id TEXT UNIQUE, -- idempotency
  message_url TEXT,
  author_login TEXT,
  thread_id TEXT,
  
  -- Content
  raw_text TEXT NOT NULL,
  clean_text TEXT NOT NULL, -- tag stripped
  tag TEXT, -- '!!', '++', '::', or null
  
  -- Additional
  metadata JSONB -- attachments, etc.
);

CREATE INDEX idx_raw_events_received_at ON raw_events(received_at);
CREATE INDEX idx_raw_events_thread_id ON raw_events(thread_id) WHERE thread_id IS NOT NULL;
```

**Why:** Debugging, replay, citations, resilience.

### 3.2 Routing Decisions (separate from raw events)

**Table: `routing_decisions`**
```sql
CREATE TABLE routing_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_event_id UUID UNIQUE NOT NULL REFERENCES raw_events(id),
  intent TEXT NOT NULL, -- 'Activity', 'Note', 'ThreadStart', 'Commit', 'Command'
  forced_by TEXT NOT NULL, -- 'tag' | 'rule' | 'agent'
  confidence NUMERIC, -- 0.0-1.0 (for agent classifications)
  payload JSONB, -- agent reasoning, tool calls, etc.
  routed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_routing_decisions_raw_event ON routing_decisions(raw_event_id);
```

**Why:** Keep raw_events pure, make routing auditable.

### 3.3 Categories (user-editable)

**Table: `activity_categories`**
```sql
CREATE TABLE activity_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT UNIQUE NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  is_sleep_category BOOLEAN NOT NULL DEFAULT false,
  sort_order INT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Seed data
INSERT INTO activity_categories (name, is_sleep_category) VALUES
  ('work', false),
  ('leisure', false),
  ('study', false),
  ('relationships', false),
  ('sleep', true),
  ('health', false);
```

**Table: `note_categories`**
```sql
CREATE TABLE note_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT UNIQUE NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  sort_order INT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Seed data
INSERT INTO note_categories (name) VALUES
  ('idea'),
  ('reflection'),
  ('decision'),
  ('question'),
  ('meta');
```

**Why:** User can rename/add categories without breaking history (FK by ID).

### 3.4 Activities (point-in-time observations)

**Table: `activity_log`**
```sql
CREATE TABLE activity_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_event_id UUID NOT NULL REFERENCES raw_events(id),
  timestamp TIMESTAMPTZ NOT NULL,
  category_id UUID NOT NULL REFERENCES activity_categories(id),
  description TEXT NOT NULL,
  thread_id TEXT, -- if created from thread commit
  confidence NUMERIC, -- agent confidence
  metadata JSONB
);

CREATE INDEX idx_activity_log_timestamp ON activity_log(timestamp);
CREATE INDEX idx_activity_log_category ON activity_log(category_id);
CREATE INDEX idx_activity_log_thread ON activity_log(thread_id) WHERE thread_id IS NOT NULL;
```

**No duration fields.** Durations derived later via sessionization.

### 3.5 Notes

**Table: `notes`**
```sql
CREATE TABLE notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_event_id UUID NOT NULL REFERENCES raw_events(id),
  timestamp TIMESTAMPTZ NOT NULL,
  category_id UUID NOT NULL REFERENCES note_categories(id),
  title TEXT,
  text TEXT NOT NULL,
  thread_id TEXT, -- if created from thread commit
  metadata JSONB
);

CREATE INDEX idx_notes_timestamp ON notes(timestamp);
CREATE INDEX idx_notes_category ON notes(category_id);
CREATE INDEX idx_notes_thread ON notes(thread_id) WHERE thread_id IS NOT NULL;
```

**Questions stored as notes** with `category='question'`.

### 3.6 User State (single user)

**Table: `user_state`**
```sql
CREATE TABLE user_state (
  user_login TEXT PRIMARY KEY,
  sleeping BOOLEAN NOT NULL DEFAULT false,
  last_observation_at TIMESTAMPTZ,
  mode TEXT NOT NULL DEFAULT 'ledger', -- informational
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

**Sleeping detection:**
- When activity category has `is_sleep_category=true` → set `sleeping=true`
- Any other activity → set `sleeping=false`

### 3.7 Conversation Storage (threads)

**Table: `conversations`**
```sql
CREATE TABLE conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  created_from_raw_event_id UUID REFERENCES raw_events(id),
  status TEXT NOT NULL DEFAULT 'active', -- 'active' | 'committed' | 'archived'
  topic TEXT,
  committed_at TIMESTAMPTZ,
  committed_by_raw_event_id UUID REFERENCES raw_events(id),
  note_id UUID REFERENCES notes(id),
  activity_id UUID REFERENCES activity_log(id),
  metadata JSONB -- initial context retrieved, etc.
);

CREATE INDEX idx_conversations_thread_id ON conversations(thread_id);
CREATE INDEX idx_conversations_status ON conversations(status);
```

**Table: `conversation_messages`**
```sql
CREATE TABLE conversation_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id),
  raw_event_id UUID REFERENCES raw_events(id),
  timestamp TIMESTAMPTZ NOT NULL,
  role TEXT NOT NULL, -- 'user' | 'assistant'
  text TEXT NOT NULL
);

CREATE INDEX idx_conversation_messages_conv ON conversation_messages(conversation_id, timestamp);
```

### 3.8 Configuration

**Table: `config`**
```sql
CREATE TABLE config (
  key TEXT PRIMARY KEY,
  value TEXT,
  updated_at TIMESTAMPTZ DEFAULT now(),
  updated_by_raw_event_id UUID REFERENCES raw_events(id)
);

-- Seed north_star
INSERT INTO config (key, value) VALUES ('north_star', NULL);
```

---

## 4) Workflows (n8n) — Sub-workflow Oriented

### 4.1 Top-level Workflows

1. **`Discord_Message_Router`** (formerly `Discord_Message_Ingestion`)
   - Trigger: webhook from Discord relay
   - Main routing logic (classification + dispatch to external handlers)
   
2. **`Periodic_Activity_Reminder`**
   - Trigger: cron every 30 minutes
   - Proactivity pings

3. (Future) **`Daily_Plan_Generator`**
4. (Future) **`Daily_Summary_Generator`**

### 4.2 Internal Sub-workflows Status

**Current implementation in `Discord_Message_Router.json`:**

**Internal (in router workflow):**
1. **`Message Classifier`** ✅ **IMPLEMENTED**
   - Simple LLM chain (not AI Agent)
   - Outputs: `TAG|CONFIDENCE` format
   - Uses minimal prompt (~250 tokens)
   - Fast, cheap classification (<500ms, <$0.001 per call)
   - **Fallback:** If LLM fails to output valid tag, defaults to `++` (safe conversation mode)

**External workflows (called via Execute Workflow node):**
2. **`Command_Handler`** ✅ **CREATED** (workflow exists, handlers pending)
   - Separate workflow file: `Command_Handler.json`
   - Receives: command_string, guild_id, channel_id
   - Returns: Discord message response
   
3. **`Activity_Handler`** ⏳ **TODO** (placeholder in router)
   - Extract category + description via LLM
   - Write to activity_log table
   
4. **`Note_Handler`** ⏳ **TODO** (placeholder in router)
   - Extract category + title/text via LLM
   - Write to notes table
   
5. **`Thread_Handler`** ⏳ **TODO** (placeholder in router)
   - Create Discord thread
   - Initialize conversation in database
   - Execute Thread_Agent for first response
   
6. **`Thread_Agent`** ⏳ **TODO**
   - AI Agent for multi-turn conversation
   - Tools: retrieve context, refine thread title
   - Memory: Window Buffer (10 messages)
   
7. **`Commit_Thread`** ⏳ **TODO** (placeholder in router)
   - LLM summarization (not agent)
   - Returns: note + activity JSON

**Architecture change:** All handlers are now external workflows to keep the router clean and maintainable. The router only does classification and dispatch.

---

## 5) Router — Hybrid Intelligence

### 5.1 Router Responsibilities

- Always store raw event first (idempotent by `discord_message_id`)
- Strip tag (first token) into `tag`; populate `clean_text`
- Decide intent using:
  1. **Tag-based (deterministic fast path):**
     - `!!` → Activity
     - `..` → Note
     - `++` → ThreadStart (or Commit if in thread)
     - `::` → Command
  2. **LLM classification (when no tag):**
     - No tag → LLM outputs `TAG|CONFIDENCE`
     - Parse and route to appropriate tag handler
     - **Key insight:** Reuses existing tag routing logic!
- Dispatch to handler
- React with emoji
- Update user_state (optional)

### 5.2 Intent Set

```
Activity      !!  or  LLM infers (→ !! tag)
Note          ..  or  LLM infers (→ .. tag)
ThreadStart   ++  or  LLM infers (→ ++ tag) for questions
Commit        ++  (only in threads)  or  ::commit
Command       ::command args
```

### 5.3 Router Decision Tree

```
1. Store raw_event (idempotent)
2. Parse first token → tag

3. If message in existing thread:
   a. If tag == '++' or command == '::commit':
      → Execute: Commit_Thread
   b. Else:
      → Execute: Thread_Agent

4. Else (message in #arcane-shell):
   a. If tag == '!!':
      → LLM extract category + description
      → Write to activity_log
   b. If tag == '..':
      → LLM extract category + title
      → Write to notes
   c. If tag == '++':
      → Create Discord thread
      → Execute: Thread_Agent
   d. If tag starts with '::':
      → Parse command name + args
      → Execute: Command_Handler
   e. Else (no tag):
      → LLM Classification:
         • Build minimal prompt (just tag definitions)
         • LLM outputs: TAG|CONFIDENCE
         • Parse & reconstruct: tag="..", content=".. original text"
         • Route back to step 4 (Check Tag)
      → Routes to appropriate handler (4a, 4b, 4c, or 4d)

5. React with emoji
6. [Optional] Store routing decision if LLM classified
```

### 5.4 LLM Classification (Simplified Approach)

**Why this is better than tool calling:**
- ✅ Simpler: Just text output, no tool schemas
- ✅ Faster: ~500ms vs ~2s (no function calling overhead)
- ✅ Cheaper: ~70% fewer tokens (minimal prompt, short output)
- ✅ Reuses code: Routes to existing tag handlers
- ✅ Debuggable: See exact LLM decision in logs

**Prompt strategy:**
- **Minimalist:** No context, no categories, no user info
- **Just essentials:** Tag definitions + examples + confidence guide
- **Output format:** `TAG|CONFIDENCE` (e.g., `!!|high` or `..|medium`)
- **Total tokens:** ~250 input + ~5 output = 255 tokens per classification

**Confidence tracking:**
- LLM outputs confidence level: `high`, `medium`, `low`
- Low confidence classifications logged to `routing_decisions` table
- Review low-confidence cases to improve prompt

**See:** `docs/router-agent-implementation.md` for full implementation guide and actual prompt used in n8n workflow

---

## 6) Chat Threads + `::commit`

### 6.1 Thread Creation

**Status:** ⏳ **TODO** - Placeholder node exists in workflow

**Trigger:**
- `++` tag in `#arcane-shell` (deterministic)
- LLM classifies as `++` (for questions/exploration)

**Actions (when implemented):**
1. Create Discord thread (initial title = first 50 chars)
2. Insert to `conversations` table (status='active')
3. Execute `Thread_Agent` sub-workflow

### 6.2 Thread Agent Configuration (TODO)

**Status:** ⏳ **TODO** - Will be implemented when Thread_Agent sub-workflow is built

**System Prompt:**
```
You are an AI life coach helping the user reflect and plan.

User: {{ user_login }}
User's North Star: {{ north_star || "Not set" }}

This is their guiding principle. Reference it when relevant to help them stay aligned.

You're in a thinking session about: "{{ initial_message }}"

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

**Memory:** Window Buffer (last 10 messages)

**Storage:**
- Full conversation also stored in `conversation_messages` (audit trail)
- n8n memory is just for agent context window

### 6.3 Thread Title Refinement

**Flow:**
```
User: what are the key factors affecting my productivity?

1. Router creates thread: "what are the key factors affec..."
2. Thread_Agent first response:
   - Analyzes topic
   - Calls refine_thread_title("Productivity Factors Analysis")
   - n8n executes: PATCH /channels/{thread_id} with new name
   - Retrieves recent work activities
   - Responds: "I see you've been working on X, Y, Z..."
```

**Optional:** On `::commit`, update thread title to match note title.

### 6.4 `::commit` Behavior (always creates note + activity)

**Status:** ⏳ **TODO** - Placeholder node exists in workflow

**Trigger:**
- `++` tag in thread
- `::commit` command in thread

**Single LLM call produces:**
```json
{
  "note": {
    "note_category_name": "idea|reflection|decision|question|meta",
    "title": "string",
    "text": "string"
  },
  "activity": {
    "activity_category_name": "work|leisure|study|relationships|sleep|health",
    "description": "Thinking session: <topic>"
  }
}
```

**Writes performed:**
1. Insert note into `notes` (with thread_id)
2. Insert activity into `activity_log` (with thread_id, always)
3. Update `conversations`:
   - status = 'committed'
   - committed_at = now()
   - note_id, activity_id (FK pointers)
4. Post confirmation to thread
5. React to commit message with ✅

---

## 7) Proactivity (30-minute Reminders)

### 7.1 Waking Hours Logic (irregular sleep supported)

**No fixed time windows.** "Waking" is derived from logs:

- If `user_state.sleeping = true` → do not ping
- Else if `now - user_state.last_observation_at >= 30 minutes` → ping

### 7.2 How Sleeping is Determined

On each new **activity** observation:
- If `activity_categories.is_sleep_category = true` → set `user_state.sleeping = true`
- Else → set `user_state.sleeping = false`
- Always update `user_state.last_observation_at`

### 7.3 Proactivity Message

**Post to `#arcane-shell`:**
```
Requesting current activity status... Reply with: `!! <what you're doing>`
```

**Future enhancement:** Include suggested tasks (once tasks exist).

---

## 8) Commands (`::`)

**Status:** ⏳ **TODO** - Command_Handler placeholder exists but not implemented

### 8.1 Core Commands (Phase 1 - Priority for Implementation)

```
::ping                     Test if system is working (replies "pong")
::status                   Show system status (db connected, workflows active, etc.)
::recent [limit]           Show recent activities/notes (last N items)
::stats                    Show counts (activities today, notes this week, etc.)

::north_star set <text>    Store your guiding principle
::north_star get           Display your north star
::north_star clear         Clear north star

::categories               List activity + note categories

::help                     Show available commands
```

### 8.2 Future Commands (Phase 2+)

```
::pause <duration>         Pause proactivity (e.g., ::pause 2h)
::resume                   Resume proactivity

::replay <timeframe>       Replay events (debugging)
::config <key> <value>     Set config values
::export <format>          Export data
```

---

## 9) Implementation Phases

### Phase 0 — Foundations ✅
- PostgreSQL tables (raw_events, routing_decisions, categories, activity_log, notes, user_state, conversations, conversation_messages, config)
- Discord channels: `#arcane-shell`, `#obsidian-board`, `#kairon-log`
- Webhook relay setup (message_id, channel_id, guild_id, thread_id, content, timestamp)

### Phase 1 — MVP Ledger + Threads (Current)
**Deliverables:**
- n8n workflows:
  - `Discord_Message_Router` - Main routing workflow ✅
  - `Command_Handler` - Command execution workflow (created, handlers pending)
  - External handler workflows (Activity_Handler, Note_Handler, Thread_Handler - all TODO)
- Store raw events (idempotent) ✅
- Hybrid router (tags + LLM classification) ✅
- LLM classification with `++` fallback ✅
- Emoji reactions ✅
- Activity/Note handling (placeholders - needs implementation)
- Thread conversations with memory (todo)
- `::commit` → note + activity (todo)
- Basic commands: `::ping`, `::status`, `::recent`, `::stats`, `::north_star`, `::categories`, `::help` (todo)

**Success criteria:**
- Can log activities with `!!` or naturally
- Can store notes naturally
- Can start threads with `++` or questions
- Threads have context retrieval
- Thread titles auto-refine
- Commit works (note + activity created)

### Phase 2 — Proactivity
- `Periodic_Activity_Reminder` workflow (cron 30min)
- Sleep detection logic
- Trainer-style pings

### Phase 3 — Tasks (Questforge)
- Add `tasks` + `task_events` tables
- `--` tag for task operations
- Commit can generate tasks from extracted actions

### Phase 4 — Obsidian Board Outputs
- Daily plan (once tasks exist)
- Daily summary + weekly rollups
- Post to `#obsidian-board`

### Phase 5 — Vector Memory (RAG)
- pgvector extension
- Embeddings generation (OpenAI text-embedding-3-small)
- Semantic context retrieval for threads
- Enhanced agent tools

### Phase 6 — Hardening
- Replay tools (`::replay last 1h`)
- Error reporting to `#kairon-log`
- Idempotency audit
- Redact event command

---

## 10) Discord Integration Notes

### Webhook Relay Requirements

Your Discord bot/script must forward:
```javascript
{
  guild_id: "...",
  channel_id: "...",
  message_id: "...",  // for idempotency + reactions
  thread_id: "..." | null,
  author: { login: "..." },
  content: "...",
  timestamp: "..."
}
```

### Message URL Format

```
https://discord.com/channels/{guild_id}/{channel_id}/{message_id}
```

Store this in `raw_events.message_url` for citations.

### Emoji Reactions

```javascript
// Add reaction
PUT /channels/{channel_id}/messages/{message_id}/reactions/{emoji}/@me

// Emojis
🕒  :clock3:
📝  :pencil:
💭  :thought_balloon:
✅  :white_check_mark:
⚠️  :warning:
🛑  :stop_sign:
```

### Thread Operations

```javascript
// Create thread
POST /channels/{channel_id}/messages/{message_id}/threads
{ "name": "Thread title" }

// Edit thread title
PATCH /channels/{thread_id}
{ "name": "New title" }

// Post to thread
POST /channels/{thread_id}/messages
{ "content": "Message text" }
```

---

## 11) Key Design Principles

### Append-Only Raw Events
- Never delete from `raw_events` (audit trail)
- All routing decisions traceable
- Replay possible

### User-Editable Categories
- Categories stored in DB (not hardcoded)
- FK by ID (renames don't break history)
- `is_sleep_category` flag (no name-based logic)

### Hybrid Routing
- Tags optional (power user speedup)
- Agent fallback (beginner friendly)
- Deterministic paths when possible

### Questions → Conversations
- Interrogative = desire to interact
- Start threads, not store notes
- More engaging UX

### Two-Agent Architecture
- Router Agent: Fast classification (single-turn)
- Thread Agent: Deep conversation (multi-turn + memory)
- Commit LLM: Simple summarization
- Clean separation of concerns

### No Context Forwarding
- Thread Agent re-reads initial message with full context
- No coupling between Router and Thread agents
- Simpler, more maintainable

### LLM Prompt Clarity
- "You are a routing agent for a life tracking system" (descriptive)
- NOT "You are Kairon" (meaningless token)
- "North Star" instead of "Covenant" (better LLM comprehension)

---

## 12) Success Metrics (Phase 1)

**Functional:**
- ✅ 100% message capture (no dropped events)
- ✅ < 3s latency for tagged messages
- ✅ < 5s latency for agentic routing
- ✅ Thread title refinement < 10s
- ✅ Commit creates both note + activity

**Quality:**
- ✅ > 90% accurate activity classification (spot check)
- ✅ > 85% accurate note classification
- ✅ Threads retrieve relevant context (subjective)

**Reliability:**
- ✅ Idempotent message handling (duplicate webhooks)
- ✅ Graceful LLM failures (fallback to note)
- ✅ Error logging to `#kairon-log`

---

## Appendix: Example Flows

### Flow 1: Activity Logging (Tagged)
```
User: !! debugging authentication bug

Router:
  1. Store raw_event (tag='!!', clean_text='debugging authentication bug')
  2. Deterministic: tag == '!!' → Activity
  3. LLM extract: category='work', description='debugging authentication bug'
  4. Write to activity_log
  5. Update user_state (sleeping=false, last_observation_at=now)
  6. React with 🕒
```

### Flow 2: Note Storage (LLM Classification)
```
User: interesting pattern in my productivity lately

Router:
  1. Store raw_event (tag=null, clean_text='interesting pattern...')
  2. No tag → Execute Message Classifier
  3. LLM outputs: ..|high
  4. Route to "Handle .. Note" handler
  5. [TODO: Extract category + write to notes]
  6. React with 📝
```

### Flow 3: Question → Thread
```
User: what was I working on yesterday?

Router:
  1. Store raw_event (tag=null, clean_text='what was I working on yesterday?')
  2. No tag → Execute Message Classifier
  3. LLM outputs: ++|high
  4. Route to "Handle ++ Thread Start" handler
  5. [TODO: Create Discord thread]
  6. [TODO: Execute Thread_Agent]

Thread_Agent (when implemented):
  7. Calls refine_thread_title('Yesterday Work Review')
  8. n8n: PATCH thread title
  9. Calls retrieve_recent_activities(timeframe='yesterday')
  9. Responds: "Yesterday you worked on: authentication refactor (3h), code review (1h)..."
  10. Store to conversation_messages
  11. Post to Discord thread
  12. React with 💭
```

### Flow 4: Thread Commit
```
User in thread: ++

Router:
  1. Store raw_event (tag='++', thread_id='123')
  2. In thread + tag='++' → Execute Commit_Thread

Commit_Thread:
  3. Load all conversation_messages for thread
  4. LLM call: summarize → JSON (note + activity)
  5. Write to notes (category='reflection', title='Work priorities analysis')
  6. Write to activity_log (category='work', description='Thinking session: work priorities')
  7. Update conversations (status='committed', note_id=X, activity_id=Y)
  8. Update thread title to match note title (optional)
  9. Post to thread: "Committed.\n- Note: Work priorities analysis (reflection)\n- Activity: Thinking session (work, 12m)"
  10. React with ✅
```

### Flow 5: Ambiguous Reference
```
User: still working on it

Router:
  1. Store raw_event (clean_text='still working on it')
  2. No tag → Execute Message Classifier
  3. LLM outputs: !!|medium (infers it's an activity based on phrase structure)
  4. Route to "Handle !! Activity" handler
  5. [TODO: Extract category + description, using context if needed]
  6. [TODO: Write to activity_log]
  7. React with 🕒
  
Note: For MVP, ambiguous messages may not resolve perfectly without context.
Future enhancement: Add context retrieval to activity/note handlers.
```

---

## Getting Started (Phase 1)

1. **Set up PostgreSQL:**
   ```bash
   createdb kairon
   psql kairon < schema.sql
   ```

2. **Set up n8n:**
   - Import `Discord_Message_Router.json` and `Command_Handler.json`
   - Configure credentials (OpenAI API, Discord bot token, Postgres)
   - Set environment variables (webhook URL, etc.)

3. **Set up Discord bot:**
   - Enable webhook relay to n8n
   - Grant `MANAGE_THREADS` permission
   - Configure channels: `#arcane-shell`, `#obsidian-board`, `#kairon-log`

4. **Test basic flow:**
   ```
   In #arcane-shell:
   !! testing the system
   
   Expected:
   - Activity logged
   - 🕒 reaction
   - Entry in activity_log
   ```

5. **Test thread flow:**
   ```
   In #arcane-shell:
   what did I work on today?
   
   Expected:
   - Thread created
   - Title refined
   - Response with context
   - 💭 reaction
   ```

6. **Test commit:**
   ```
   In thread:
   ++
   
   Expected:
   - Note + activity created
   - Confirmation posted
   - ✅ reaction
   ```

---

**Ready to build!**
