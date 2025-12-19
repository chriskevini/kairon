# Kairon Life OS - Event-Trace-Projection Architecture

This architecture is a modern take on **Event Sourcing**, optimized for the era of Large Language Models. By separating "The Truth" from "The Interpretation," you create a system that doesn't just store data, but "learns" and "evolves" over time.

---

## System Overview: The "AI-Driven Event-Trace-Projection" Pattern

### Core Concept

In traditional systems, you store the **Result** of an action (e.g., a "Completed" status). In Kairon, we store:
1. **The Action** (the Event) - What actually happened
2. **The Reasoning** (the Trace) - How the AI interpreted it
3. **The Interpretation** (the Projection) - The structured output

This allows you to re-interpret your entire history every time you upgrade your AI.

### Problems It Addresses

* **Data Obsolescence:** Old data is usually useless. Here, old data is a goldmine that can be re-processed by newer, smarter models.
* **The "Black Box" Problem:** You never have to guess why an AI made a decision; the reasoning is permanently logged.
* **Brittle Schemas:** You don't need to migrate your database every time you want to track a new AI-detected field.
* **Auditability:** Every change to the database state is linked back to a raw human or system action.
* **Corrections:** User corrections create new trace chains without destroying the original incorrect reasoning (valuable for learning).

---

## 1. The Four-Table Architecture

### Table: `events` (The Immutable Fact)

**Purpose:** Stores the raw input exactly as it happened.

**Schema:**
```sql
CREATE TABLE events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  event_type TEXT NOT NULL,
  source TEXT NOT NULL,
  payload JSONB NOT NULL,
  
  idempotency_key TEXT NOT NULL,  -- REQUIRED (never null)
  
  metadata JSONB DEFAULT '{}'::jsonb,
  
  UNIQUE (event_type, idempotency_key)
);

CREATE INDEX idx_events_received_at ON events(received_at DESC);
CREATE INDEX idx_events_type ON events(event_type);
CREATE INDEX idx_events_payload ON events USING gin(payload);

COMMENT ON COLUMN events.idempotency_key IS 'Required unique key per event_type. If source does not provide, generate one.';
```

**Implementation Example:**
```javascript
// Discord message event
{
  id: "evt-402",
  event_type: "discord_message",
  source: "discord",
  payload: {
    content: "working on router agent",
    discord_message_id: "1234567890",
    discord_channel_id: "chan-123",
    discord_guild_id: "guild-456",
    author_login: "chris",
    thread_id: null,
    timestamp: "2024-12-18T10:30:00Z"
  },
  idempotency_key: "1234567890"  // Same as discord_message_id
}

// User correction event
{
  id: "evt-403",
  event_type: "user_correction",
  source: "discord",
  payload: {
    original_event_id: "evt-402",
    original_projection_id: "proj-100",
    corrected_intent: "note",
    correction_reason: "This was a reflection, not an activity"
  },
  idempotency_key: "1234567890:correction"  // Unique per correction
}
```

**Event Types:**
- `discord_message` - User message in channel/thread
- `discord_reaction` - User added/removed reaction
- `user_stop` - User clicked 🛑 to stop processing
- `user_correction` - User corrected AI classification
- `thread_save` - User saved thread (triggers extraction)
- `cron_trigger` - Scheduled job (proactivity, summaries)
- `system_event` - System operations (void, cleanup)
- `fitbit_sleep` - Sleep session from Fitbit (future)
- `fitbit_activity` - Activity from Fitbit (future)

**Idempotency Key Generation (REQUIRED, never null):**
```javascript
function generateIdempotencyKey(eventType, payload) {
  switch(eventType) {
    case 'discord_message':
      return payload.discord_message_id;
    
    case 'discord_reaction':
      return `${payload.message_id}:${payload.emoji}:${payload.user_id}`;
    
    case 'user_stop':
      return `${payload.stopped_event_id}:stop:${Date.now()}`;
    
    case 'user_correction':
      return `${payload.original_event_id}:correction:${Date.now()}`;
    
    case 'thread_save':
      return `${payload.thread_id}:save:${Date.now()}`;
    
    case 'cron_trigger':
      const roundedTime = roundToMinute(payload.timestamp);
      return `${payload.job_name}:${roundedTime}`;
    
    case 'fitbit_sleep':
      return payload.sleep_session_id || `fitbit:sleep:${payload.start_time}:${payload.user_id}`;
    
    case 'fitbit_activity':
      return payload.activity_id || `fitbit:activity:${payload.start_time}:${payload.type}`;
    
    case 'system_event':
      // Generate deterministic hash
      return crypto.createHash('sha256')
        .update(JSON.stringify(payload))
        .digest('hex')
        .substring(0, 16);
    
    default:
      // Fallback for future event types: hash payload + timestamp
      return crypto.createHash('sha256')
        .update(eventType + JSON.stringify(payload) + Date.now())
        .digest('hex')
        .substring(0, 16);
  }
}
```

**Key Principle:** All events MUST have idempotency key. If source doesn't provide one, generate it.

---

### Table: `traces` (The AI Reasoning Chain)

**Purpose:** Stores the multi-step LLM reasoning chain that processes an event.

**Schema:**
```sql
CREATE TABLE traces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  parent_trace_id UUID NULL REFERENCES traces(id) ON DELETE CASCADE,
  
  -- Step identification
  step_name TEXT NOT NULL,    -- 'intent_classification', 'activity_extraction', 'note_extraction', etc.
  step_order INT NOT NULL,    -- 1, 2, 3... for ordering within a chain
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- All step data in JSONB (flexible schema)
  data JSONB NOT NULL,  -- Contains: result, prompt, model, confidence, reasoning, duration_ms, etc.
  
  -- Voiding/correction tracking
  voided_at TIMESTAMPTZ NULL,
  superseded_by_trace_id UUID NULL REFERENCES traces(id)
);

CREATE INDEX idx_traces_event ON traces(event_id);
CREATE INDEX idx_traces_parent ON traces(parent_trace_id) WHERE parent_trace_id IS NOT NULL;
CREATE INDEX idx_traces_data ON traces USING gin(data);
```

**Implementation Example:**
```javascript
// Multi-extraction trace (root channel)
{
  id: "trace-900",
  event_id: "evt-402",
  parent_trace_id: null,
  step_name: "multi_extraction",
  step_order: 1,
  data: {
    result: {
      activity: { category: 'work', description: 'working on router agent' },
      note: { category: 'reflection', text: 'realized error handling needs improvement' }
    },
    prompt: 'Analyze this message and extract ALL present items...',
    model: 'gpt-4o-mini',  // Only if n8n exposes it in future
    duration_ms: 456
  }
}

// Thread summarization trace
{
  id: "trace-901",
  event_id: "evt-405",
  parent_trace_id: null,
  step_name: "thread_summarization",
  step_order: 1,
  data: {
    result: {
      notes: [
        { category: 'reflection', text: 'Need to improve error handling in router' },
        { category: 'fact', text: 'Router agent is critical infrastructure' }
      ],
      todos: [
        { description: 'Refactor error handling', priority: 'high' }
      ]
    },
    prompt: 'Summarize this conversation and extract insights/todos...',
    model: 'gpt-4o-mini',
    duration_ms: 1200
  }
}
```

**Important:** Shortcut detection (!!, .., ++, ::) is deterministic and happens BEFORE trace creation. Shortcuts are not stored as traces.

**Trace Chaining:**
- `parent_trace_id` links traces into a chain
- `step_order` provides explicit ordering
- `event_id` always points back to the source event
- Voided traces keep their data but are marked with `voided_at` and `superseded_by_trace_id`

---

### Table: `projections` (The Structured Outputs)

**Purpose:** The high-speed, queryable structured data for UI and RAG.

**Schema:**
```sql
CREATE TABLE projections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- References (denormalized for query speed)
  trace_id UUID NOT NULL REFERENCES traces(id) ON DELETE CASCADE,
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  trace_chain UUID[] NOT NULL,  -- Full chain from root to leaf: ['trace-900', 'trace-901', 'trace-902']
  
  -- Projection classification
  projection_type TEXT NOT NULL,  -- 'activity', 'note', 'todo', 'thread_extraction', 'assistant_message'
  
  -- The structured data (JSONB for flexibility)
  data JSONB NOT NULL,
  
  -- Lifecycle management
  status TEXT NOT NULL DEFAULT 'pending',  -- 'pending', 'auto_confirmed', 'confirmed', 'voided'
  confirmed_at TIMESTAMPTZ NULL,
  voided_at TIMESTAMPTZ NULL,
  voided_reason TEXT NULL,  -- 'user_correction', 'user_rejected', 'duplicate', 'superseded', 'system_correction'
  voided_by_event_id UUID NULL REFERENCES events(id),
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Correction tracking
  superseded_by_projection_id UUID NULL REFERENCES projections(id),
  supersedes_projection_id UUID NULL REFERENCES projections(id),
  
  -- Quality tracking (nullable - not used initially)
  quality_score NUMERIC NULL,
  user_edited BOOLEAN NULL,
  
  metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX idx_projections_trace ON projections(trace_id);
CREATE INDEX idx_projections_event ON projections(event_id);
CREATE INDEX idx_projections_type_status ON projections(projection_type, status);
CREATE INDEX idx_projections_data ON projections USING gin(data);
```

**Implementation Example:**
```javascript
// Activity projection
{
  id: "proj-1200",
  trace_id: "trace-902",
  event_id: "evt-402",
  trace_chain: ["trace-900", "trace-901", "trace-902"],
  projection_type: "activity",
  data: {
    category: "work",
    description: "working on router agent",
    timestamp: "2024-12-18T10:30:00Z",
    confidence: 0.95,
    all_scores: { work: 98, admin: 2 }
  },
  status: "auto_confirmed",  // Direct capture, no user review needed
  confirmed_at: "2024-12-18T10:30:01Z"
}

// Thread extraction (pending user review)
{
  id: "proj-1201",
  trace_id: "trace-910",
  event_id: "evt-405",
  trace_chain: ["trace-908", "trace-909", "trace-910"],
  projection_type: "thread_extraction",
  data: {
    item_type: "reflection",
    text: "Need to improve error handling in the router",
    display_order: 1,
    conversation_id: "conv-123"
  },
  status: "pending",  // Waiting for user to save thread
  created_at: "2024-12-18T11:00:00Z"
}
```

**Status Lifecycle:**
```
pending          → Created, awaiting user action (thread extractions)
auto_confirmed   → Directly confirmed (!! activity, .. note)
confirmed        → User explicitly approved (saved thread extraction)
voided           → Rejected/cancelled/corrected
```

---

### Table: `embeddings` (RAG Support)

**Purpose:** Store vector embeddings for semantic search and RAG.

**Schema:**
```sql
CREATE TABLE embeddings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Reference to source projection
  projection_id UUID NOT NULL REFERENCES projections(id) ON DELETE CASCADE,
  
  -- Embedding metadata
  model TEXT NOT NULL,          -- 'text-embedding-3-small', 'voyage-2', 'text-embedding-3-large'
  model_version TEXT NULL,      -- Track version for reproducibility
  embedding vector(1536),       -- pgvector type, dimension varies by model
  
  -- What was embedded (denormalized for speed)
  embedded_text TEXT NOT NULL,
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_embeddings_projection ON embeddings(projection_id);
CREATE INDEX idx_embeddings_model ON embeddings(model);
CREATE INDEX idx_embeddings_vector ON embeddings USING hnsw (embedding vector_cosine_ops);
```

**Implementation Example:**
```javascript
// Multiple embeddings for same projection (multi-model strategy)
{
  id: "emb-500",
  projection_id: "proj-1200",
  model: "text-embedding-3-small",
  embedding: [0.123, -0.456, ...],  // 1536 dimensions
  embedded_text: "working on router agent (work activity)"
}

{
  id: "emb-501",
  projection_id: "proj-1200",
  model: "voyage-2",
  embedding: [0.234, -0.567, ...],  // Different model, different vector
  embedded_text: "working on router agent (work activity)"
}
```

**Note:** This table will be unpopulated initially. Embeddings will be added when RAG functionality is implemented.

**Benefits of Dedicated Embeddings Table:**
- ✅ Easy model upgrades (add new embeddings without touching projections)
- ✅ A/B testing (compare retrieval quality across models)
- ✅ Selective re-embedding (re-embed specific projections when extraction improves)
- ✅ Multi-model queries (use best model for each query type)

---

## 2. Key Implementation Patterns

### Pattern A: Extraction System (Root Channel vs Threads)

**Core Principle:** Root channel messages are atomic (no context needed). Thread messages require full conversation context.

#### Root Channel (#arcane-shell) - Immediate Multi-Extraction

**Goal:** Extract ALL present items (activity, note, todo) from a single message.

**Direct Capture with Shortcut (!! activity):**
```
1. Event: discord_message with "!! working on router"
2. Shortcut detection (deterministic, pre-trace): Detected '!!' → Skip to activity extraction
3. Trace 1: Activity extraction ONLY (LLM respects shortcut)
   → Extracts: activity (ignores potential notes/todos due to shortcut)
4. Projection created:
   - activity, status='auto_confirmed'
```

**Tag Shortcuts:**
```javascript
// Shortcuts skip multi-extraction, go straight to handler
!! → Extract ONLY activity (no notes/todos)
.. → Extract ONLY note (no activities/todos)
++ → Thread start ONLY (no extraction)
:: → Command ONLY (no extraction)
(no tag) → Multi-extraction (all types)
```
1. Event: discord_message with "working on router. realized error handling needs improvement"
2. No tag detected
3. Trace 1: Multi-extraction (LLM, single call)
   → Extracts: activity + note
4. Projections created:
   - activity: { category: 'work', description: 'working on router', full_message: '...' }
   - note: { category: 'reflection', text: 'realized error handling needs improvement', full_message: '...' }
```

**Why Multi-Extraction?**
- ✅ Richer capture (don't lose insights buried in activity messages)
- ✅ Single LLM call (faster, cheaper than sequential)
- ✅ Full message context preserved in each projection
- ✅ Time-sensitive activities get accurate timestamps

**LLM Prompt (Multi-Extraction):**
```javascript
const MULTI_EXTRACTION_PROMPT = `
Analyze this message and extract ALL present items.

Message: "${message}"

Rules:
- activity: Current work/action being done (time-sensitive)
  Categories: work, leisure, study, health, sleep, relationships, admin
- note: Insight, realization, fact, or decision (timeless)
  Categories: fact (external knowledge), reflection (internal knowledge)
- todo: Something that needs to be done

Output JSON (omit keys if not present):
{
  "activity": { "category": "work", "description": "..." },
  "note": { "category": "reflection", "text": "..." },
  "todo": { "description": "...", "priority": "medium" }
}

Examples:
"working on router" 
→ { "activity": { "category": "work", "description": "working on router" } }

"realized error handling needs improvement"
→ { "note": { "category": "reflection", "text": "realized error handling needs improvement" } }

"working on router. realized error handling needs improvement"
→ { 
    "activity": { "category": "work", "description": "working on router" },
    "note": { "category": "reflection", "text": "realized error handling needs improvement" }
  }
`;
```

#### Thread Messages - No Immediate Extraction

**Why threads are different:**
- ❌ **Don't extract from every message** (spammy, requires long context)
- ❌ **Don't extract activities** (not time-sensitive, inaccurate timestamps)
- ✅ **Extract once on thread save** (richer context, better quality)

**Thread Flow:**
```
1. Event: discord_message in thread "How can I improve productivity?"
   → Stored in thread_messages (audit trail)
   → NO extraction, NO trace
   → Agent responds

2. User continues chatting (multiple messages)
   → All stored in thread_messages
   → NO extraction yet

3. User clicks "Save thread" (or types `--`)
   → Event: thread_save
   → Trace 1: Summarize entire thread with full conversation context
   → Projections created:
     - Multiple notes (category: fact or reflection)
     - Multiple todos
     - All use thread save timestamp (when user confirmed insights are worth keeping)
```

**Key Differences:**

| Aspect | Root Channel | Threads |
|--------|-------------|---------|
| **Context needed** | ❌ No (atomic) | ✅ Yes (long conversation) |
| **Extraction timing** | Immediate | On save only |
| **Activities extracted** | ✅ Yes (time-sensitive) | ❌ No (not time-sensitive) |
| **Timestamp** | Message time | Thread save time |
| **Projections** | 1-3 per message | Many per thread |

**Key Insight:** Root channel = atomic captures with accurate timestamps. Threads = rich extractions with full context.

---

### Pattern B: User Corrections with Progressive Feedback (Race-Free)

**Problem:** User corrects misclassification while trace chain is still processing.

**Solution:** Cancellation token + progressive emoji feedback + parallel chain execution.

#### Progressive Emoji Feedback (Less Spammy)

**Flow:**
```
User: "working on router"

T0: Message received
    → Add 🛑 emoji immediately (stop button)
    
T1: Multi-extraction trace starts
    → Add 🕒 emoji (activity detected)
    
T2: Projections created
    → Add ✅ emoji (saved)
    → Replace 🛑 with 🔄 (regenerate button)
    
Final: 🔄 🕒 ✅
```

**If user clicks 🛑 during processing:**
```
T0: User sends "working on router"
    Event-A created (evt-1, type='discord_message')
    Add 🛑 emoji
    ↓
T1: CHAIN-A starts processing Event-A
    Trace-A1: Multi-extraction → "activity"
    Add 🕒 emoji
    ↓
T2: User clicks 🛑 emoji
    Event-B created (evt-2, type='user_stop')
    payload: { stopped_event_id: 'evt-1' }
    ↓
    Set cancellation token on Event-A:
    UPDATE events SET metadata = {'correction_in_progress': true} WHERE id = 'evt-1'
    ↓
    Remove all emoji except 🛑
    ↓
T3: CHAIN-A checks token before next step
    Sees correction_in_progress = true
    Voids Trace-A1, stops execution
    ↓
T4: Bot sends NEW message:
    "Processing stopped. What should this be?"
    [📝 Note] [✅ Todo] [💭 Thread] [❌ Cancel]
    ↓
T5: User picks [📝 Note]
    Event-C created (evt-3, type='user_correction')
    payload: { 
      original_event_id: 'evt-1',
      corrected_type: 'note'
    }
    ↓
T6: CHAIN-B starts processing Event-C (NOT Event-A!)
    Trace-B1: Extract note from Event-A's content
    Projection-B: note, status='confirmed'
    ↓
T7: Void any projections from CHAIN-A (if they exist)
    Add 🔄 emoji to original message (can regenerate later)
```

**If user clicks 🔄 after completion (regenerate):**
```
User clicks 🔄 on completed message

Bot sends NEW message showing trace chain:
"📝 working on router

What was detected:
🕒 Activity: work - 'working on router'

Regenerate from:
[🎯 Extract differently] [🗑️ Delete entirely]"

User clicks [🎯 Extract differently]:
"Choose different type:"
[📝 Note] [✅ Todo] [💭 Thread]

User picks [📝 Note]:
→ Void old projection
→ Create new Event (type='user_correction')
→ Start new extraction chain as note
→ Create new projection with corrected type
```

**Implementation:**

```javascript
// 1. Add progressive emoji feedback
async function addTraceEmoji(messageId, traceResult) {
  const emojiMap = {
    'activity': '🕒',
    'note': '📝',
    'todo': '✅',
    'thread': '💭',
    'complete': '✅'
  };
  
  await discord.addReaction(messageId, emojiMap[traceResult]);
}

// 2. User clicks 🛑 - Set cancellation token
await db.query(`
  UPDATE events 
  SET metadata = jsonb_set(metadata, '{correction_in_progress}', 'true')
  WHERE id = $1
`, [eventId]);

// 3. CHAIN-A checks before each expensive step
const event = await db.query('SELECT metadata FROM events WHERE id = $1', [eventId]);
if (event.metadata?.correction_in_progress) {
  // Cancel this chain
  await db.query(`
    UPDATE traces 
    SET voided_at = NOW()
    WHERE event_id = $1 AND voided_at IS NULL
  `, [eventId]);
  
  return { cancelled: true }; // Stop execution
}

// 4. Replace 🛑 with 🔄 when done
async function finalizeMessage(messageId) {
  await discord.removeReaction(messageId, '🛑');
  await discord.addReaction(messageId, '🔄');
}

// 5. When CHAIN-B creates projection, void CHAIN-A projection
await db.query(`
  UPDATE projections
  SET 
    status = 'voided',
    voided_at = NOW(),
    voided_reason = 'user_correction',
    voided_by_event_id = $2,
    superseded_by_projection_id = $3
  WHERE event_id = $1
    AND id != $3
    AND status NOT IN ('voided', 'confirmed')
    AND created_at < $4
`, [originalEventId, correctionEventId, newProjectionId, correctionTime]);
```

**Race Condition Prevention:**
- Cancellation token set atomically in event metadata
- Each trace step checks token before expensive LLM operations
- Voiding uses WHERE clauses that prevent double-voiding
- `created_at < correction_time` ensures only older projections are voided

**Emoji Legend:**
- 🛑 - Stop processing (click to cancel current chain)
- 🔄 - Regenerate (click to re-extract with different options)
- 🕒 - Activity detected
- 📝 - Note detected
- ✅ - Todo detected / Saved successfully
- 💭 - Thread started

**Key Insights:**
- **Single message** - All emoji on original message (not spammy)
- **Progressive feedback** - User sees what's happening in real-time
- **Stop at any point** - 🛑 allows cancellation during processing
- **Regenerate after** - 🔄 allows re-extraction with different options
- **Correction event is separate** - CHAIN-B processes correction event, not original message event

---

### Pattern C: The "Void Pattern" (Correction without Deletion)

**Problem:** Need to hide incorrect data without losing audit trail.

**Solution:** Void projections and traces, keep all data.

**System Voiding (spam, duplicates):**
```sql
-- Create system event
INSERT INTO events (event_type, source, payload) VALUES
  ('system_event', 'system', '{
    "action": "void_spam",
    "target_projection_ids": ["proj-500", "proj-501", ...],
    "reason": "Bot spam detected"
  }');

-- Void projections
UPDATE projections
SET 
  status = 'voided',
  voided_at = NOW(),
  voided_reason = 'bot_spam',
  voided_by_event_id = 'evt-system-1'
WHERE id = ANY(ARRAY['proj-500', 'proj-501']);
```

**Querying (exclude voided):**
```sql
-- Show only valid activities
SELECT * FROM projections
WHERE projection_type = 'activity'
  AND status IN ('auto_confirmed', 'confirmed')
ORDER BY created_at DESC;

-- Show corrections for learning
SELECT 
  p_wrong.data->>'category' as incorrect_category,
  p_correct.data->>'category' as corrected_category,
  e.payload->>'content' as message
FROM projections p_wrong
JOIN projections p_correct ON p_wrong.superseded_by_projection_id = p_correct.id
JOIN events e ON p_wrong.event_id = e.id
WHERE p_wrong.voided_reason = 'user_correction';
```

---

### Pattern C: Regeneration with Trace Registry

**Problem:** User wants to regenerate projection with different options. How do we know what options are available without duplicating metadata?

**Solution:** Derive regeneration points from trace chain + centralized TRACE_STEP_REGISTRY.

#### Trace Step Registry (Hardcoded in n8n)

```javascript
const TRACE_STEP_REGISTRY = {
  multi_extraction: {
    label: 'Extract all items',
    regeneration_options: ['activity', 'note', 'todo'],  // Can re-extract as different type
    prompt_template: `Analyze this message and extract ALL present items.

Message: "\${message}"

Rules:
- activity: Current work/action being done (time-sensitive)
  Categories: work, leisure, study, health, sleep, relationships, admin
- note: Insight, realization, fact, or decision (timeless)
  Categories: fact (external knowledge), reflection (internal knowledge)
- todo: Something that needs to be done

Output JSON (omit keys if not present):
{
  "activity": { "category": "work", "description": "..." },
  "note": { "category": "reflection", "text": "..." },
  "todo": { "description": "...", "priority": "medium" }
}

Examples:
"working on router" → { "activity": { "category": "work", "description": "working on router" } }
"realized error handling needs work" → { "note": { "category": "reflection", "text": "..." } }
"working on router. realized error handling needs work" → { "activity": {...}, "note": {...} }`
  },
  
  thread_summarization: {
    label: 'Summarize thread',
    regeneration_options: null,  // Can regenerate entire summary, no partial options
    prompt_template: `Summarize this conversation and extract insights/todos.

Conversation:
\${conversation_history}

Output JSON:
{
  "notes": [
    { "category": "fact|reflection", "text": "..." }
  ],
  "todos": [
    { "description": "...", "priority": "low|medium|high" }
  ]
}`
  }
};

// Helper: Build prompt from template
function buildPrompt(stepName, variables) {
  const config = TRACE_STEP_REGISTRY[stepName];
  let prompt = config.prompt_template;
  
  for (const [key, value] of Object.entries(variables)) {
    prompt = prompt.replace(new RegExp(`\\$\\{${key}\\}`, 'g'), value);
  }
  
  return prompt;
}

// Usage
const prompt = buildPrompt('multi_extraction', {
  message: 'working on router. realized error handling needs improvement'
});
```

#### Derive Regeneration Options from Traces

```javascript
// Get regeneration points for a projection
async function getRegenerationPoints(projection) {
  // Get all traces in chain
  const traces = await db.query(`
    SELECT * FROM traces 
    WHERE id = ANY($1) 
    ORDER BY step_order
  `, [projection.trace_chain]);
  
  // Map each trace to regeneration point using registry
  return traces.rows
    .map(trace => {
      const stepDef = TRACE_STEP_REGISTRY[trace.step_name];
      if (!stepDef || !stepDef.regeneration_options) return null;
      
      return {
        step: trace.step_order,
        trace_id: trace.id,
        label: stepDef.label,
        options: stepDef.regeneration_options,
        current_value: extractCurrentValue(trace.data.result, projection.projection_type)
      };
    })
    .filter(point => point !== null);
}

// Show regenerate UI
async function showRegenerateUI(projection, messageId) {
  const traces = await db.query(`
    SELECT * FROM traces WHERE id = ANY($1) ORDER BY step_order
  `, [projection.trace_chain]);
  
  const points = await getRegenerationPoints(projection);
  
  // Build summary
  const summary = `📝 "${projection.data.full_message}"

What was detected:
${formatProjectionSummary(projection)}

Regenerate from:`;
  
  const buttons = [
    ...points.map(p => ({
      label: `🎯 ${p.label} (currently: ${p.current_value})`,
      custom_id: `regen:${projection.id}:${p.step}`
    })),
    {
      label: '🗑️ Delete entirely',
      custom_id: `delete:${projection.id}`
    }
  ];
  
  await discord.sendMessage({ content: summary, components: buttons });
}

// User clicks regenerate option
async function handleRegenerate(projectionId, step) {
  const projection = await getProjection(projectionId);
  const point = (await getRegenerationPoints(projection)).find(p => p.step === step);
  
  // Show options for this step
  const buttons = point.options.map(opt => ({
    label: getEmojiForOption(opt) + ' ' + opt,
    custom_id: `regen_confirm:${projectionId}:${step}:${opt}`
  }));
  
  await discord.sendMessage({
    content: `Choose different ${point.label.toLowerCase()}:`,
    components: buttons
  });
}

// User confirms regeneration option
async function handleRegenerateConfirm(projectionId, step, newOption) {
  const projection = await getProjection(projectionId);
  const originalEvent = await getEvent(projection.event_id);
  
  // 1. Create correction event
  const correctionEvent = await createEvent({
    event_type: 'user_correction',
    payload: {
      original_event_id: originalEvent.id,
      original_projection_id: projectionId,
      regenerate_from_step: step,
      corrected_option: newOption
    }
  });
  
  // 2. Void old projection
  await db.query(`
    UPDATE projections
    SET status = 'voided', voided_at = NOW(), voided_reason = 'user_regenerated'
    WHERE id = $1
  `, [projectionId]);
  
  // 3. Start new trace chain from correction event
  // Re-extract with new option
  const newTrace = await runExtraction(originalEvent.payload.content, newOption);
  const newProjection = await createProjection(newTrace, correctionEvent.id);
  
  // 4. Link old → new
  await db.query(`
    UPDATE projections
    SET superseded_by_projection_id = $2
    WHERE id = $1
  `, [projectionId, newProjection.id]);
  
  await discord.sendMessage(`✅ Regenerated as ${newOption}`);
}
```

**Benefits:**
- ✅ No metadata duplication (derives from trace_chain)
- ✅ Single source of truth (TRACE_STEP_REGISTRY)
- ✅ Easy to add new trace types (update registry)
- ✅ Prompts colocated with step definitions

**Future Migration to DB (when needed):**
```sql
-- If prompt iteration becomes too frequent, move to DB
CREATE TABLE prompts (
  step_name TEXT PRIMARY KEY,
  template TEXT NOT NULL,
  variables JSONB NOT NULL,
  version INT DEFAULT 1
);

-- Export hardcoded registry to DB
INSERT INTO prompts (step_name, template, variables) VALUES
  ('multi_extraction', '...', '{"regeneration_options": ["activity", "note", "todo"]}'::jsonb);
```

### Pattern D: Semantic Replay (AI Upgrade)

**Problem:** You improved your LLM prompt or switched models. Want to re-process old data.

**Solution:** Create new trace chains from existing events.

```javascript
// 1. Select events to replay
const oldEvents = await db.query(`
  SELECT * FROM events 
  WHERE event_type = 'discord_message'
    AND received_at > '2024-01-01'
    AND payload->>'tag' IS NULL  -- Only untagged messages
`);

// 2. For each event, create new trace chain
for (const event of oldEvents.rows) {
  // Void old projections
  await db.query(`
    UPDATE projections
    SET 
      status = 'voided',
      voided_at = NOW(),
      voided_reason = 'reprocessed'
    WHERE event_id = $1 AND status != 'voided'
  `, [event.id]);
  
  // Run new classification with improved prompt
  const newTrace = await runImprovedClassifier(event.payload.content);
  
  // Create new projections from new traces
  await createProjections(newTrace);
}

// Result: Same events, new interpretations!
```

**Benefits:**
- ✅ Old data becomes valuable again
- ✅ Can compare old vs new classifications
- ✅ Audit trail shows improvement over time

---

## 3. Migration Plan

### Current State (Kairon Schema as of 2024-12-18)

**Current Tables:**
- `raw_events` - Append-only event log (Discord messages, cron triggers)
- `routing_decisions` - LLM classification decisions
- `activity_log` - Activities with `category::activity_category` enum
- `notes` - Notes with `category::note_category` enum
- `todos` - Todo items with status tracking
- `conversations` - Thread metadata
- `thread_messages` - Thread message history (formerly conversation_messages)
- `thread_extractions` - LLM-extracted insights from threads
- `user_state` - Current user state (sleeping, last_observation_at)
- `config` - Key-value configuration

**Enums:**
```sql
activity_category AS ENUM ('work', 'leisure', 'study', 'health', 'sleep', 'relationships', 'admin')
note_category AS ENUM ('fact', 'reflection')
```

---

### Phase 1: Create New Schema (Non-Destructive)

**Goal:** Add new 4-table structure alongside existing tables.

```sql
-- ============================================================================
-- NEW SCHEMA: Events, Traces, Projections, Embeddings
-- ============================================================================

-- Enable pgvector for embeddings (if not already enabled)
CREATE EXTENSION IF NOT EXISTS vector;

-- 1. EVENTS
CREATE TABLE events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  event_type TEXT NOT NULL,
  source TEXT NOT NULL,
  payload JSONB NOT NULL,
  
  idempotency_key TEXT,
  
  metadata JSONB DEFAULT '{}'::jsonb,
  
  UNIQUE (event_type, idempotency_key)
);

CREATE INDEX idx_events_received_at ON events(received_at DESC);
CREATE INDEX idx_events_type ON events(event_type);
CREATE INDEX idx_events_payload ON events USING gin(payload);

COMMENT ON TABLE events IS 'Immutable event log (new schema) - replaces raw_events';

-- 2. TRACES
CREATE TABLE traces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  parent_trace_id UUID NULL REFERENCES traces(id) ON DELETE CASCADE,
  
  step_name TEXT NOT NULL,
  step_order INT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  data JSONB NOT NULL,
  
  voided_at TIMESTAMPTZ NULL,
  superseded_by_trace_id UUID NULL REFERENCES traces(id)
);

CREATE INDEX idx_traces_event ON traces(event_id);
CREATE INDEX idx_traces_parent ON traces(parent_trace_id) WHERE parent_trace_id IS NOT NULL;
CREATE INDEX idx_traces_data ON traces USING gin(data);

COMMENT ON TABLE traces IS 'LLM reasoning chains - replaces routing_decisions + adds multi-step tracking';

-- 3. PROJECTIONS
CREATE TABLE projections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  trace_id UUID NOT NULL REFERENCES traces(id) ON DELETE CASCADE,
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  trace_chain UUID[] NOT NULL,
  
  projection_type TEXT NOT NULL,
  data JSONB NOT NULL,
  
  status TEXT NOT NULL DEFAULT 'pending',
  confirmed_at TIMESTAMPTZ NULL,
  voided_at TIMESTAMPTZ NULL,
  voided_reason TEXT NULL,
  voided_by_event_id UUID NULL REFERENCES events(id),
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  superseded_by_projection_id UUID NULL REFERENCES projections(id),
  supersedes_projection_id UUID NULL REFERENCES projections(id),
  
  quality_score NUMERIC NULL,
  user_edited BOOLEAN NULL,
  
  metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX idx_projections_trace ON projections(trace_id);
CREATE INDEX idx_projections_event ON projections(event_id);
CREATE INDEX idx_projections_type_status ON projections(projection_type, status);
CREATE INDEX idx_projections_data ON projections USING gin(data);

COMMENT ON TABLE projections IS 'Structured outputs - replaces activity_log, notes, todos, thread_extractions';

-- 4. EMBEDDINGS
CREATE TABLE embeddings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  projection_id UUID NOT NULL REFERENCES projections(id) ON DELETE CASCADE,
  
  model TEXT NOT NULL,
  model_version TEXT NULL,
  embedding vector(1536),
  
  embedded_text TEXT NOT NULL,
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_embeddings_projection ON embeddings(projection_id);
CREATE INDEX idx_embeddings_model ON embeddings(model);
CREATE INDEX idx_embeddings_vector ON embeddings USING hnsw (embedding vector_cosine_ops);

COMMENT ON TABLE embeddings IS 'Vector embeddings for RAG (unpopulated initially)';
```

---

### Phase 2: Create Migration Views

**Goal:** Query new schema as if it were old schema (backward compatibility).

```sql
-- View: activity_log compatibility
CREATE VIEW activity_log_v2 AS
SELECT 
  p.id,
  p.event_id as raw_event_id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  p.data->>'description' as description,
  p.data->>'thread_id' as thread_id,
  (p.data->>'confidence')::numeric as confidence,
  p.metadata
FROM projections p
WHERE p.projection_type = 'activity'
  AND p.status IN ('auto_confirmed', 'confirmed');

-- View: notes compatibility
CREATE VIEW notes_v2 AS
SELECT 
  p.id,
  p.event_id as raw_event_id,
  (p.data->>'timestamp')::timestamptz as timestamp,
  p.data->>'category' as category,
  p.data->>'text' as text,
  p.data->>'thread_id' as thread_id,
  p.metadata
FROM projections p
WHERE p.projection_type = 'note'
  AND p.status IN ('auto_confirmed', 'confirmed');

-- View: todos compatibility
CREATE VIEW todos_v2 AS
SELECT 
  p.id,
  p.event_id as raw_event_id,
  p.data->>'description' as description,
  p.status as status,
  p.data->>'priority' as priority,
  (p.data->>'is_goal')::boolean as is_goal,
  (p.data->>'due_date')::date as due_date,
  p.confirmed_at as completed_at,
  p.created_at,
  p.metadata
FROM projections p
WHERE p.projection_type = 'todo';

-- View: thread_extractions compatibility
CREATE VIEW thread_extractions_v2 AS
SELECT 
  p.id,
  p.data->>'conversation_id' as conversation_id,
  p.data->>'item_type' as item_type,
  p.data->>'text' as text,
  (p.data->>'display_order')::int as display_order,
  CASE 
    WHEN p.status = 'voided' THEN NULL
    WHEN p.projection_type = 'note' THEN 'note'
    WHEN p.projection_type = 'todo' THEN 'todo'
    ELSE NULL
  END as saved_as,
  p.superseded_by_projection_id as saved_id,
  p.data->>'summary_message_id' as summary_message_id,
  p.created_at
FROM projections p
WHERE p.projection_type = 'thread_extraction';
```

---

### Phase 3: Migrate Existing Data

**Goal:** Copy data from old tables to new schema.

```sql
-- ============================================================================
-- MIGRATION SCRIPT: Old Schema → New Schema
-- ============================================================================

-- BACKUP FIRST!
-- pg_dump -U n8n_user -d kairon -F c -f backups/pre_projection_migration_$(date +%Y%m%d_%H%M%S).dump

-- 1. Migrate raw_events → events
INSERT INTO events (id, received_at, event_type, source, payload, idempotency_key)
SELECT 
  id,
  received_at,
  CASE 
    WHEN source_type = 'discord' THEN 'discord_message'
    WHEN source_type = 'cron' THEN 'cron_trigger'
    ELSE 'system_event'
  END as event_type,
  source_type as source,
  jsonb_build_object(
    'content', raw_text,
    'clean_text', clean_text,
    'tag', tag,
    'discord_guild_id', discord_guild_id,
    'discord_channel_id', discord_channel_id,
    'discord_message_id', discord_message_id,
    'message_url', message_url,
    'author_login', author_login,
    'thread_id', thread_id
  ) || COALESCE(metadata, '{}'::jsonb) as payload,
  discord_message_id as idempotency_key
FROM raw_events;

-- 2. Migrate routing_decisions → traces (single-step traces)
INSERT INTO traces (id, event_id, parent_trace_id, step_name, step_order, created_at, data)
SELECT 
  id,
  raw_event_id as event_id,
  NULL as parent_trace_id,
  CASE 
    WHEN forced_by = 'tag' THEN 'tag_detection'
    WHEN forced_by = 'rule' THEN 'rule_based_routing'
    WHEN forced_by = 'agent' THEN 'intent_classification'
    ELSE 'unknown_routing'
  END as step_name,
  1 as step_order,
  routed_at as created_at,
  jsonb_build_object(
    'result', jsonb_build_object(
      'intent', LOWER(intent),
      'confidence', confidence,
      'forced_by', forced_by
    )
  ) || COALESCE(payload, '{}'::jsonb) as data
FROM routing_decisions;

-- 3. Migrate activity_log → projections
INSERT INTO projections (id, trace_id, event_id, trace_chain, projection_type, data, status, created_at, confirmed_at)
SELECT 
  a.id,
  t.id as trace_id,
  a.raw_event_id as event_id,
  ARRAY[t.id] as trace_chain,  -- Single-step chain for now
  'activity' as projection_type,
  jsonb_build_object(
    'timestamp', a.timestamp,
    'category', a.category::text,
    'description', a.description,
    'thread_id', a.thread_id,
    'confidence', a.confidence
  ) || COALESCE(a.metadata, '{}'::jsonb) as data,
  'auto_confirmed' as status,
  a.timestamp as created_at,
  a.timestamp as confirmed_at
FROM activity_log a
JOIN traces t ON t.event_id = a.raw_event_id
WHERE t.step_order = 1;  -- Link to routing trace

-- 4. Migrate notes → projections
INSERT INTO projections (id, trace_id, event_id, trace_chain, projection_type, data, status, created_at, confirmed_at)
SELECT 
  n.id,
  t.id as trace_id,
  n.raw_event_id as event_id,
  ARRAY[t.id] as trace_chain,
  'note' as projection_type,
  jsonb_build_object(
    'timestamp', n.timestamp,
    'category', n.category::text,
    'text', n.text,
    'thread_id', n.thread_id
  ) || COALESCE(n.metadata, '{}'::jsonb) as data,
  'auto_confirmed' as status,
  n.timestamp as created_at,
  n.timestamp as confirmed_at
FROM notes n
JOIN traces t ON t.event_id = n.raw_event_id
WHERE t.step_order = 1;

-- 5. Migrate todos → projections
INSERT INTO projections (id, trace_id, event_id, trace_chain, projection_type, data, status, created_at, confirmed_at, voided_at, voided_reason)
SELECT 
  t.id,
  tr.id as trace_id,
  COALESCE(t.raw_event_id, (SELECT id FROM events ORDER BY received_at DESC LIMIT 1)) as event_id,  -- Fallback for suggested todos
  ARRAY[tr.id] as trace_chain,
  'todo' as projection_type,
  jsonb_build_object(
    'description', t.description,
    'priority', t.priority,
    'is_goal', t.is_goal,
    'due_date', t.due_date,
    'goal_deadline', t.goal_deadline,
    'parent_todo_id', t.parent_todo_id,
    'completed_by_activity_id', t.completed_by_activity_id,
    'suggested_by_conversation_id', t.suggested_by_conversation_id
  ) || COALESCE(t.metadata, '{}'::jsonb) as data,
  CASE 
    WHEN t.status = 'pending' THEN 'pending'
    WHEN t.status = 'suggested' THEN 'pending'
    WHEN t.status = 'done' THEN 'confirmed'
    WHEN t.status = 'dismissed' THEN 'voided'
    ELSE 'pending'
  END as status,
  t.created_at,
  t.completed_at as confirmed_at,
  CASE WHEN t.status = 'dismissed' THEN t.updated_at ELSE NULL END as voided_at,
  CASE WHEN t.status = 'dismissed' THEN 'user_rejected' ELSE NULL END as voided_reason
FROM todos t
LEFT JOIN traces tr ON tr.event_id = COALESCE(t.raw_event_id, (SELECT id FROM events ORDER BY received_at DESC LIMIT 1))
WHERE tr.step_order = 1 OR tr.id IS NULL;

-- 6. Migrate thread_extractions → projections
INSERT INTO projections (id, trace_id, event_id, trace_chain, projection_type, data, status, created_at, voided_at, voided_reason)
SELECT 
  te.id,
  tr.id as trace_id,
  (SELECT created_from_raw_event_id FROM conversations WHERE id = te.conversation_id) as event_id,
  ARRAY[tr.id] as trace_chain,
  'thread_extraction' as projection_type,
  jsonb_build_object(
    'conversation_id', te.conversation_id,
    'item_type', te.item_type,
    'text', te.text,
    'display_order', te.display_order,
    'summary_message_id', te.summary_message_id
  ) as data,
  CASE 
    WHEN te.saved_as IS NULL THEN 'pending'
    ELSE 'confirmed'
  END as status,
  te.created_at,
  CASE WHEN te.saved_as = 'voided' THEN NOW() ELSE NULL END as voided_at,
  CASE WHEN te.saved_as = 'voided' THEN 'user_rejected' ELSE NULL END as voided_reason
FROM thread_extractions te
LEFT JOIN conversations c ON te.conversation_id = c.id
LEFT JOIN traces tr ON tr.event_id = c.created_from_raw_event_id
WHERE tr.step_order = 1 OR tr.id IS NULL;

-- 7. Verify migration
DO $$
BEGIN
  RAISE NOTICE '=== Migration Complete ===';
  RAISE NOTICE 'Events: %', (SELECT COUNT(*) FROM events);
  RAISE NOTICE 'Traces: %', (SELECT COUNT(*) FROM traces);
  RAISE NOTICE 'Projections: %', (SELECT COUNT(*) FROM projections);
  RAISE NOTICE 'Projections by type:';
  RAISE NOTICE '  - activities: %', (SELECT COUNT(*) FROM projections WHERE projection_type = 'activity');
  RAISE NOTICE '  - notes: %', (SELECT COUNT(*) FROM projections WHERE projection_type = 'note');
  RAISE NOTICE '  - todos: %', (SELECT COUNT(*) FROM projections WHERE projection_type = 'todo');
  RAISE NOTICE '  - thread_extractions: %', (SELECT COUNT(*) FROM projections WHERE projection_type = 'thread_extraction');
END $$;
```

---

### Phase 4: Update n8n Workflows

**Goal:** Update workflows to use new schema instead of old tables.

**Changes needed in n8n workflows:**

1. **Save_Activity.json** → Write to projections table
```javascript
// OLD: Insert into activity_log
INSERT INTO activity_log (raw_event_id, timestamp, category, description, metadata)
VALUES ($1, NOW(), $2::activity_category, $3, $4);

// NEW: Insert into projections
INSERT INTO projections (trace_id, event_id, trace_chain, projection_type, data, status, confirmed_at)
VALUES ($1, $2, $3, 'activity', $4, 'auto_confirmed', NOW());
```

2. **Save_Note.json** → Write to projections table
```javascript
// OLD: Insert into notes
INSERT INTO notes (raw_event_id, timestamp, category, text, metadata)
VALUES ($1, NOW(), $2::note_category, $3, $4);

// NEW: Insert into projections
INSERT INTO projections (trace_id, event_id, trace_chain, projection_type, data, status, confirmed_at)
VALUES ($1, $2, $3, 'note', $4, 'auto_confirmed', NOW());
```

3. **Route_Message.json** → Create events + traces instead of raw_events + routing_decisions
```javascript
// OLD: Insert into raw_events, then routing_decisions
INSERT INTO raw_events (...) RETURNING *;
INSERT INTO routing_decisions (raw_event_id, intent, forced_by, confidence);

// NEW: Insert into events, then traces
INSERT INTO events (event_type, source, payload, idempotency_key) 
VALUES ('discord_message', 'discord', $payload, $discord_message_id)
ON CONFLICT (event_type, idempotency_key) DO NOTHING
RETURNING *;

INSERT INTO traces (event_id, step_name, step_order, data)
VALUES ($event_id, 'intent_classification', 1, $classification_result);
```

4. **Add cancellation token checking** in all multi-step workflows
```javascript
// Before each expensive LLM call
const event = await db.query('SELECT metadata FROM events WHERE id = $1', [eventId]);
if (event.rows[0].metadata.correction_in_progress) {
  // Void current traces and stop
  await db.query(`
    UPDATE traces 
    SET voided_at = NOW() 
    WHERE event_id = $1 AND voided_at IS NULL
  `, [eventId]);
  return { cancelled: true };
}
```

5. **Add correction button handler** (new workflow)
```javascript
// Discord interaction: User clicks 👎
// 1. Set cancellation token
await db.query(`
  UPDATE events 
  SET metadata = jsonb_set(metadata, '{correction_in_progress}', 'true')
  WHERE id = $1
`, [eventId]);

// 2. Show correction options
await discord.sendMessage({
  content: "What should this be instead?",
  components: [
    { type: 2, label: "📝 Note", custom_id: "correct_to_note" },
    { type: 2, label: "✅ Todo", custom_id: "correct_to_todo" },
    { type: 2, label: "💭 Thread", custom_id: "correct_to_thread" }
  ]
});
```

---

### Phase 5: Parallel Running (Testing)

**Goal:** Run both schemas in parallel to verify correctness.

**Strategy:**
1. Keep old tables as read-only backup
2. All new writes go to new schema (events/traces/projections)
3. Query both schemas and compare results
4. After 1 week of parallel running with no issues → proceed to Phase 6

**Testing checklist:**
- [ ] Direct capture (`!! activity`) creates correct projection
- [ ] Untagged message gets classified and creates projection
- [ ] Thread extractions are created with `status='pending'`
- [ ] Thread save updates extractions to `status='confirmed'`
- [ ] User correction sets cancellation token and voids old chain
- [ ] Corrected projection supersedes original
- [ ] Queries using compatibility views return same results as old tables

---

### Phase 6: Drop Old Tables (Final Migration)

**Goal:** Remove old schema after verification.

```sql
-- ============================================================================
-- FINAL MIGRATION: Drop Old Tables
-- ============================================================================

-- BACKUP FIRST! (even though we've been running in parallel)
-- pg_dump -U n8n_user -d kairon -F c -f backups/final_backup_$(date +%Y%m%d_%H%M%S).dump

-- Drop old views first
DROP VIEW IF EXISTS recent_activities;
DROP VIEW IF EXISTS recent_notes;
DROP VIEW IF EXISTS open_todos;
DROP VIEW IF EXISTS recent_todo_completions;
DROP VIEW IF EXISTS stale_todos;
DROP VIEW IF EXISTS recent_thread_summaries;
DROP VIEW IF EXISTS unsaved_extractions;

-- Drop old tables (CASCADE will drop dependent objects)
DROP TABLE IF EXISTS thread_extractions CASCADE;
DROP TABLE IF EXISTS thread_messages CASCADE;  -- Formerly conversation_messages
DROP TABLE IF EXISTS conversations CASCADE;
DROP TABLE IF EXISTS todos CASCADE;
DROP TABLE IF EXISTS notes CASCADE;
DROP TABLE IF EXISTS activity_log CASCADE;
DROP TABLE IF EXISTS routing_decisions CASCADE;
DROP TABLE IF EXISTS raw_events CASCADE;

-- Drop old enums
DROP TYPE IF EXISTS activity_category;
DROP TYPE IF EXISTS note_category;

-- Rename compatibility views to original names (optional)
ALTER VIEW activity_log_v2 RENAME TO activity_log_compat;
ALTER VIEW notes_v2 RENAME TO notes_compat;
ALTER VIEW todos_v2 RENAME TO todos_compat;
ALTER VIEW thread_extractions_v2 RENAME TO thread_extractions_compat;

-- Create new convenient views
CREATE VIEW recent_projections AS
SELECT 
  p.id,
  p.projection_type,
  p.status,
  p.data,
  p.created_at,
  e.payload->>'author_login' as author,
  e.payload->>'content' as original_message
FROM projections p
JOIN events e ON p.event_id = e.id
WHERE p.status IN ('auto_confirmed', 'confirmed')
ORDER BY p.created_at DESC;

CREATE VIEW projection_audit_trail AS
SELECT 
  p.id as projection_id,
  p.projection_type,
  p.status,
  e.event_type,
  e.received_at as event_time,
  array_length(p.trace_chain, 1) as trace_depth,
  p.created_at,
  CASE 
    WHEN p.voided_at IS NOT NULL THEN 'voided'
    WHEN p.superseded_by_projection_id IS NOT NULL THEN 'superseded'
    ELSE 'active'
  END as lifecycle_status
FROM projections p
JOIN events e ON p.event_id = e.id
ORDER BY e.received_at DESC;

-- Verify final state
DO $$
BEGIN
  RAISE NOTICE '=== Final Migration Complete ===';
  RAISE NOTICE 'Old tables dropped';
  RAISE NOTICE 'New schema active:';
  RAISE NOTICE '  - events: %', (SELECT COUNT(*) FROM events);
  RAISE NOTICE '  - traces: %', (SELECT COUNT(*) FROM traces);
  RAISE NOTICE '  - projections: %', (SELECT COUNT(*) FROM projections);
  RAISE NOTICE '  - embeddings: %', (SELECT COUNT(*) FROM embeddings);
END $$;
```

---

## 4. Summary of Benefits

### Antifragility
* **Gets smarter over time**: Re-process old events with new models
* **Corrections don't destroy data**: User feedback becomes training data
* **Model experiments**: Try different prompts/models, compare results

### Traceability
* **Full audit trail**: Every projection traces back to source event
* **Understand mistakes**: See exact prompt and reasoning that led to wrong classification
* **Performance monitoring**: Track classification accuracy, LLM costs, latency

### Flexibility
* **JSONB everywhere**: Add new fields without schema migration
* **Multi-step reasoning**: Complex workflows with cancellation support
* **Extensible event types**: Add new sources without code changes

### RAG-Ready
* **Dedicated embeddings table**: Easy model upgrades, multi-model queries
* **Clean structured data**: Projections are already high-quality for embedding
* **Semantic replay**: Re-embed when extraction logic improves

---

## 5. Future Enhancements

### Phase 7: RAG Implementation
- Populate embeddings table for all projections
- Implement semantic search in thread agent
- A/B test different embedding models

### Phase 8: Quality Scoring
- Track user corrections to compute classification accuracy
- Use correction data to fine-tune classification prompts
- Implement active learning (prioritize uncertain classifications for review)

### Phase 9: Multi-User Support
- Add user_id to events/projections
- Implement visibility/permissions
- Shared vs private projections

### Phase 10: Advanced Replays
- Time-travel queries ("what did the system think in January?")
- Batch reprocessing with improved models
- Synthetic data generation for testing

---

**This is designed to be the last major migration. All future improvements happen through JSONB field additions and new trace steps, not schema changes.**
