# Agent Guidelines

This document contains instructions for AI coding agents working on the Kairon project.

---

## ⚠️ Local Configuration

**Run `./scripts/show-local-config.sh` to see local development setup** (SSH access, docker containers, etc.)

This reads from `.env.local` which is `.gitignored` and contains environment-specific info not suitable for public repos. The script exists because AI agents cannot read `.env*` files directly.

---

## Table of Contents

1. [n8n Best Practices](#n8n-best-practices) ⭐ **START HERE**
2. [Workflow Export & Sanitization](#workflow-export--sanitization)
3. [Environment Variables](#environment-variables)
4. [Database Schema](#database-schema)
5. [Code Style & Conventions](#code-style--conventions)
6. [Git Commit Guidelines](#git-commit-guidelines)
7. [Testing Workflows](#testing-workflows)
8. [Documentation Updates](#documentation-updates)

---

## n8n Best Practices

### ⚠️ CRITICAL: Read This First

These patterns prevent the most common n8n workflow bugs. Following them will save hours of debugging.

### 1. Context Object Structure

**Problem:** Nested object access like `$json.event.trace_chain` breaks silently when parent is undefined. But flat shapes create field collisions and make it unclear where data came from.

**Solution:** Use a structured `ctx` object with namespaced keys. The `ctx` object is always initialized at workflow start, so nested access is safe.

```javascript
// ✅ CORRECT: Structured ctx object with namespaces
{
  ctx: {
    event: {
      event_id: "uuid",
      message_id: "discord-id",
      clean_text: "the message",
      raw_text: "!! the message",
      tag: "!!" | ".." | "++" | "::" | null,
      guild_id: "...",
      channel_id: "...",
      thread_id: null,
      trace_chain: [],
      trace_chain_pg: "{}"
    },
    routing: {
      intent: "activity" | "note" | "chat" | "command",
      confidence: 0.95
    },
    db: {
      inserted_id: "uuid",
      conversation_id: null
    },
    llm: {
      completion_text: "...",
      tokens_used: 42
    }
  }
}

// ❌ WRONG: Random nested shape without initialization
{
  event: {
    id: "uuid",
    trace_chain: []  // $json.event.trace_chain fails if event undefined
  },
  context: {
    thread_history: []  // $json.context.thread_history fails if context undefined
  }
}
```

**Why ctx object?**
- `ctx` is ALWAYS initialized at workflow start, so `$json.ctx.event` is always safe
- Namespaces prevent field collisions (`ctx.db.user_id` vs `ctx.event.user_id`)
- Clear provenance: you know where each field came from
- See **Section 8: Context Object Pattern** for full implementation details

### 2. PostgreSQL Array Format

**Problem:** n8n's expression parser truncates complex expressions in `queryReplacement` parameters.

**Solution:** Format PostgreSQL arrays in upstream Code nodes, not in query expressions.

```javascript
// ✅ CORRECT: Format in Code node, use simple reference in query
// In Code node (e.g., "Prepare Trace Data"):
const trace_chain = $json.trace_chain || [];
const trace_chain_pg = `{${trace_chain.join(',')}}`;
return { ...$json, trace_chain_pg };

// In Postgres node queryReplacement:
// $1 = {{ $json.trace_chain_pg }}

// ❌ WRONG: Complex expression in queryReplacement (gets truncated!)
// $1 = {{ `{${($json.trace_chain || []).join(',')}}` }}
```

### 3. Always Initialize Arrays

**Problem:** Operations on undefined arrays fail silently or throw errors.

**Solution:** Initialize arrays with defaults at workflow entry.

```javascript
// ✅ CORRECT: Initialize at start of workflow
const data = {
  ...$json,
  trace_chain: $json.trace_chain || [],
  thread_history: $json.thread_history || [],
  errors: []
};

// ❌ WRONG: Assume arrays exist
const chain = $json.trace_chain;  // undefined if not set
chain.push(newId);  // TypeError: Cannot read property 'push' of undefined
```

### 4. Validate Before Access

**Problem:** Accessing properties on undefined objects crashes workflows.

**Solution:** Always validate objects exist before accessing nested properties.

```javascript
// ✅ CORRECT: Validate before access
const event = $('Previous Node').item?.json;
if (!event || !event.event_id) {
  return {
    error: true,
    response: "❌ Missing event data",
    ...($json || {})
  };
}
const eventId = event.event_id;

// ❌ WRONG: Assume data exists
const eventId = $('Previous Node').item.json.event_id;  // Crashes if any part is undefined
```

### 5. Switch Node Fallbacks

**Problem:** Switch nodes with no matching case produce no output, causing downstream nodes to fail.

**Solution:** Always include a "fallback" or "default" case.

```javascript
// ✅ CORRECT: Switch with fallback
// Switch node rules:
// Rule 0: tag equals "!!" → Activity path
// Rule 1: tag equals ".." → Note path
// Rule 2: tag equals "++" → Chat path
// Rule 3: tag equals "::" → Command path
// Fallback: (always enabled) → Default path (e.g., chat)

// ❌ WRONG: Switch with no fallback
// If tag is null or unexpected value, nothing outputs
```

### 6. Error Response Pattern

**Problem:** Workflows die silently, users see nothing.

**Solution:** Always return a response object, even on errors.

```javascript
// ✅ CORRECT: Always return response
try {
  // risky operation
  return { success: true, data: result, ...$json };
} catch (error) {
  return {
    success: false,
    error: true,
    response: `❌ Operation failed: ${error.message}`,
    channel_id: $json.channel_id,  // Preserve routing info
    message_id: $json.message_id
  };
}

// ❌ WRONG: Let errors propagate silently
const result = riskyOperation();  // If this fails, workflow dies
return result;
```

### 7. Preserving Data Through Branches

**Problem:** Data gets lost when workflow branches and merges.

**Solution:** Always spread original data and add new fields.

```javascript
// ✅ CORRECT: Preserve all fields
return {
  ...$json,           // Keep all existing fields
  new_field: value,   // Add new fields
  trace_id: newTraceId
};

// ❌ WRONG: Return only new data (loses context)
return {
  trace_id: newTraceId  // Lost: event_id, channel_id, etc.
};
```

### 8. Context Object Pattern (CRITICAL)

**Problem:** Every node overwrites `$json` with its output. Postgres nodes return query results, losing the event context. This forces brittle node name references like `$('Some Node').item.json.field` scattered throughout workflows.

**Solution:** Maintain a single `ctx` (context) object that flows through the entire workflow, with each node adding its output under a namespaced key.

#### Core Concept

```javascript
// All data flows through a ctx object with namespaced keys
{
  ctx: {
    event: { event_id, channel_id, clean_text, ... },  // From trigger
    routing: { intent, confidence },                     // From classification
    db: { inserted_id, user_record },                   // From queries
    llm: { completion_text, tokens_used }               // From LLM calls
  }
}
```

**Why this wins:**
- **Refactor-safe:** Rename/move nodes without breaking references
- **Explicit dependencies:** Every node reads from `$json.ctx.*`, not random node names
- **No collisions:** `ctx.source_user.id` vs `ctx.target_user.id` are unambiguous
- **AI-friendly:** Simple, consistent rule for agents to follow

#### Standard Namespaces

| Namespace | Purpose | Example Fields |
|-----------|---------|----------------|
| `ctx.event` | Trigger/webhook data | `event_id`, `channel_id`, `clean_text`, `tag` |
| `ctx.routing` | Classification results | `intent`, `confidence`, `all_scores` |
| `ctx.db` | Database query results | `inserted_id`, `user_record`, `history` |
| `ctx.llm` | LLM/AI responses | `completion_text`, `tokens_used` |
| `ctx.http` | External API responses | `status`, `body`, `headers` |
| `ctx.command` | Parsed command data | `name`, `args`, `raw` |

#### Implementation

##### 1. Initialize Context (First Node After Trigger)

Every workflow starts with a Code node that wraps trigger data:

```javascript
// Name: "Initialize Context"
// Place immediately after trigger/webhook
return {
  ctx: {
    event: {
      event_id: $json.event_id,
      message_id: $json.message_id,
      channel_id: $json.channel_id,
      clean_text: $json.clean_text,
      raw_text: $json.raw_text,
      tag: $json.tag,
      guild_id: $json.guild_id,
      user_id: $json.user_id,
      thread_id: $json.thread_id || null,
      trace_chain: $json.trace_chain || [],
      trace_chain_pg: $json.trace_chain_pg || '{}'
    }
  }
};
```

##### 2. Code Nodes: Spread and Extend

Every Code node spreads existing context and adds to its namespace:

```javascript
// ✅ CORRECT: Spread ctx, add new namespace
const result = doSomething($json.ctx.event.clean_text);
return {
  ctx: {
    ...$json.ctx,
    processed: {
      result: result,
      timestamp: new Date().toISOString()
    }
  }
};

// ❌ WRONG: Overwrite ctx or return flat data
return { result: result };  // Lost: ctx.event, ctx.routing, etc.
```

##### 3. Native Node Wrappers (Postgres, HTTP, LLM)

Native nodes overwrite `$json`. Add a **wrapper Code node** immediately after:

```javascript
// Name: "Merge [Node Name]" (e.g., "Merge Get User")
// Place immediately after the native node
const queryResult = $input.first().json;

return {
  ctx: {
    ...$('Previous Context Node').first().json.ctx,  // Get ctx from before native node
    db: {
      // Add query results under semantic namespace
      user_id: queryResult.id,
      user_name: queryResult.name,
      created_at: queryResult.created_at
    }
  }
};
```

**Naming convention:** Wrapper nodes are named `Merge [Original Node Name]`:
- Postgres node: "Get User" → Wrapper: "Merge Get User"
- HTTP node: "Call API" → Wrapper: "Merge Call API"
- LLM node: "Generate Response" → Wrapper: "Merge Generate Response"

##### 4. Set Nodes: Include Other Fields

For Set nodes, always enable pass-through:

```json
{
  "parameters": {
    "assignments": { ... },
    "includeOtherFields": true  // CRITICAL: Preserves ctx
  }
}
```

##### 5. Execute Workflow Nodes

Use passthrough to send full context to sub-workflows:

```json
{
  "parameters": {
    "inputSource": "passthrough"  // Sends $json (including ctx) to sub-workflow
  }
}
```

Sub-workflows receive `ctx` and should follow the same pattern.

#### Complete Example

**Workflow:** Process Discord message → Query DB → Call LLM → Insert result → Respond

```
Webhook → Init Context → Get User → Merge Get User → Call LLM → Merge LLM → Insert Result → Merge Insert → Send Response
```

**Data shape evolution:**

```javascript
// After "Init Context"
{
  ctx: {
    event: { event_id: "abc", channel_id: "123", clean_text: "hello", ... }
  }
}

// After "Merge Get User"
{
  ctx: {
    event: { event_id: "abc", channel_id: "123", clean_text: "hello", ... },
    db: { user_id: "u1", user_name: "Chris", preferences: {...} }
  }
}

// After "Merge LLM"
{
  ctx: {
    event: { event_id: "abc", channel_id: "123", clean_text: "hello", ... },
    db: { user_id: "u1", user_name: "Chris", preferences: {...} },
    llm: { completion_text: "Hello! How can I help?", tokens_used: 42 }
  }
}

// After "Merge Insert"
{
  ctx: {
    event: { ... },
    db: { user_id: "u1", ..., inserted_id: "msg-123" },
    llm: { completion_text: "Hello! How can I help?", tokens_used: 42 }
  }
}

// "Send Response" reads:
// Channel: $json.ctx.event.channel_id
// Message: $json.ctx.llm.completion_text
```

#### Anti-Pattern: Scattered Node References

```javascript
// ❌ WRONG: Node references scattered throughout workflow
const event = $('Execute Workflow Trigger').first().json;
const user = $('Get User').first().json;
const llmResult = $('Call LLM').first().json;
const dbResult = $('Insert Record').first().json;

// ✅ CORRECT: Everything flows through ctx
const { event, db, llm } = $json.ctx;
const channel = event.channel_id;
const response = llm.completion_text;
```

**The Rule:** Node name references should ONLY appear in wrapper nodes (the one place where you merge native node output back into ctx). Everywhere else, use `$json.ctx.*`.

#### Context Pruning (Optional)

At natural workflow boundaries, prune ctx to only needed fields:

```javascript
// Name: "Prune Context" (before sub-workflow or at major boundary)
return {
  ctx: {
    event: {
      event_id: $json.ctx.event.event_id,
      channel_id: $json.ctx.event.channel_id
      // Drop: clean_text, raw_text, etc. (no longer needed)
    },
    result: $json.ctx.llm.completion_text
    // Drop: db, routing, etc.
  }
};
```

#### Context Object Checklist

Before committing any workflow:

- [ ] First node after trigger initializes `ctx.event`
- [ ] Every Code node returns `{ ctx: { ...$json.ctx, namespace: {...} } }`
- [ ] Every native node (Postgres, HTTP, LLM) has a "Merge" wrapper node
- [ ] Set nodes have `includeOtherFields: true`
- [ ] Execute Workflow nodes have `inputSource: "passthrough"`
- [ ] Final nodes read from `$json.ctx.*`, never from `$('Node Name')`
- [ ] Only wrapper nodes contain node name references

### Quick Reference: Data Shape Checklist

Before any Code node or Postgres query:

- [ ] All data flows through `ctx` object
- [ ] Namespaces used: `ctx.event`, `ctx.routing`, `ctx.db`, `ctx.llm`, `ctx.http`, `ctx.command`
- [ ] Arrays initialized with defaults (`|| []`)
- [ ] PostgreSQL arrays formatted in Code nodes (`trace_chain_pg`)
- [ ] Validation before accessing optional data
- [ ] Error path returns response to user
- [ ] Context preserved with spread (`...$json.ctx`)

---

## Workflow Export & Sanitization

### ⚠️ CRITICAL: Always Sanitize Before Committing

**Before committing any changes to n8n workflow files:**

```bash
# Run sanitization script
./scripts/workflows/sanitize_workflows.sh

# Verify changes
git diff n8n-workflows/*.json

# Only then commit
git add n8n-workflows/*.json
git commit -m "your message"
```

**Note:** A pre-commit hook automatically validates workflow files. See [Pre-Commit Hook](#pre-commit-hook) for setup.

### Why Sanitize?

n8n workflow exports contain a `pinData` section with test execution data that includes:
- Real Discord IDs (guild, channel, message IDs)
- Real webhook paths
- User information
- Actual message content from testing

**The sanitization script removes this sensitive data.**

### Workflow Export Process

1. **Make changes in n8n UI**
2. **Test the workflow** with real data
3. **Export the workflow** (Download as JSON)
4. **Save to** `n8n-workflows/` directory
5. **Run sanitization script:** `./scripts/workflows/sanitize_workflows.sh`
6. **Review the diff:** `git diff n8n-workflows/*.json`
7. **Commit the sanitized file**

### Manual Verification Checklist

Before committing workflow files, verify:

- [ ] No `pinData` section exists
- [ ] No hardcoded Discord IDs (should use `{{ $env.DISCORD_* }}`)
- [ ] No hardcoded webhook paths (should use `{{ $env.WEBHOOK_PATH }}`)
- [ ] No real API keys or tokens
- [ ] No personal/test data in node configurations

---

## Environment Variables

### Required Variables

All sensitive configuration must use environment variables:

| Variable | Usage | Example |
|----------|-------|---------|
| `WEBHOOK_PATH` | Webhook security path | `abc123xyz789` |
| `DISCORD_GUILD_ID` | Discord server ID | Used in conditionals |
| `DISCORD_CHANNEL_ARCANE_SHELL` | Main input channel | For posting responses |
| `DISCORD_CHANNEL_KAIRON_LOGS` | Logging channel | For debug/classification logs |
| `OPENROUTER_API_KEY` | LLM API access | For Message Classifier |
| `POSTGRES_*` | Database credentials | For all DB operations |

### Using Environment Variables in n8n

**Syntax:**
```javascript
{{ $env.VARIABLE_NAME }}
```

**Example node configurations:**
```javascript
// Webhook node - Path field
{{ $env.WEBHOOK_PATH }}

// Discord node - Channel ID field
{{ $env.DISCORD_CHANNEL_KAIRON_LOGS }}

// Code node - Accessing in JavaScript
const guildId = $env.DISCORD_GUILD_ID;
const webhookPath = $env.WEBHOOK_PATH;
```

### Never Hardcode

❌ **Don't do this:**
```javascript
"path": "asoiaf92746087"
"channelId": "1450655614421303367"
```

✅ **Do this instead:**
```javascript
"path": "={{ $env.WEBHOOK_PATH }}"
"channelId": "={{ $env.DISCORD_CHANNEL_KAIRON_LOGS }}"
```

---

## Database Schema

### ⚠️ IMPORTANT: Migration in Progress

**Current state:** Transitioning from legacy schema to Event-Trace-Projection architecture (see `docs/simplified-extensible-schema.md`)

**Target schema (Migration 006):**
- **`events`** - Immutable event log (replaces raw_events)
- **`traces`** - LLM reasoning chains (replaces routing_decisions, adds multi-step support)
- **`projections`** - Structured outputs (replaces activity_log, notes, todos, thread_extractions)
- **`embeddings`** - Vector embeddings for RAG (new table, unpopulated initially)

**Legacy schema (still active):**
- `raw_events`, `routing_decisions`, `activity_log`, `notes`, `todos`, `conversations`, `thread_messages`, `user_state`, `config`

### Schema Locations

- **Current schema:** `db/migrations/001-005_*.sql`
- **New architecture design:** `docs/simplified-extensible-schema.md`
- **Migration 006 (pending):** `db/migrations/006_events_traces_projections.sql`

### New Architecture: Event-Trace-Projection Pattern

**Core Principle:** Separate "The Truth" (events) from "The Interpretation" (traces + projections)

**4-Table Structure:**

1. **`events`** - Immutable facts (Discord messages, reactions, corrections, cron)
   - All events MUST have idempotency_key (never null)
   - Event types: discord_message, user_correction, thread_save, cron_trigger, etc.
   - Payload stored as JSONB (flexible schema)

2. **`traces`** - LLM reasoning chains (multi-step, cancellable)
   - Links: event_id (source) + parent_trace_id (chain structure)
   - All LLM data in JSONB: result, prompt, confidence, duration_ms
   - Supports voiding/correction via voided_at + superseded_by_trace_id

3. **`projections`** - Structured outputs (activities, notes, todos, thread_extractions)
   - References: trace_id + event_id + trace_chain (full audit trail)
   - Categories stored as strings in JSONB (no enums = no migrations)
   - Status lifecycle: pending → auto_confirmed/confirmed → voided
   - Correction tracking: superseded_by_projection_id, voided_reason

4. **`embeddings`** - Vector embeddings for RAG (unpopulated initially)
   - One-to-many with projections (multi-model support)
   - Easy model upgrades without touching projections

**Key Design Decisions:**

- **JSONB-first:** All LLM output in JSONB, minimal fixed columns
- **No category enums:** Categories hardcoded in n8n prompts (easy iteration)
- **Tag detection ≠ trace:** Tags (!!, .., ++, ::) are deterministic, happen before traces
- **Multi-extraction:** Single LLM call extracts all types (activity + note + todo)
- **Progressive feedback:** Single message with emoji updates (🛑 → 🕒 → ✅ → 🔄)
- **Correction without deletion:** Void old projection, create new one, keep audit trail

### Category System (Hardcoded in Prompts, Not DB)

**Activity categories:** work, leisure, study, health, sleep, relationships, admin
**Note categories:** fact (external knowledge), reflection (internal knowledge)

**Why hardcoded in prompts instead of enums?**
- ✅ No migrations when adding categories
- ✅ Fast iteration on category definitions
- ✅ Categories stored as strings in JSONB
- ✅ Can migrate to DB table later if iteration speed becomes bottleneck

### Important Patterns

**Root Channel vs Threads (Critical Distinction):**
```javascript
// Root channel (#arcane-shell): Immediate multi-extraction
// - Atomic messages (no context needed)
// - Extract ALL types: activity + note + todo
// - Time-sensitive (accurate timestamps)
// - Single LLM call per message

// Threads: Extract once on save
// - Long conversations (full context needed)
// - NO continuous extraction (spammy, inaccurate)
// - NO activities extracted (not time-sensitive)
// - Extract on thread save only
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

**Idempotency (events table):**
```sql
-- ✅ Always use ON CONFLICT for events
INSERT INTO events (event_type, source, payload, idempotency_key)
VALUES ('discord_message', 'discord', $1, $2)
ON CONFLICT (event_type, idempotency_key) DO NOTHING
RETURNING *;
```

**Query projections (exclude voided):**
```sql
-- ✅ Show only valid activities
SELECT * FROM projections
WHERE projection_type = 'activity'
  AND status IN ('auto_confirmed', 'confirmed')
  AND data->>'category' = 'work'
ORDER BY (data->>'timestamp')::timestamptz DESC;

-- ✅ Show recent notes
SELECT * FROM projections
WHERE projection_type = 'note'
  AND status IN ('auto_confirmed', 'confirmed')
ORDER BY created_at DESC;
```

**Trace chains (audit trail):**
```sql
-- ✅ Get full reasoning chain for a projection
SELECT t.* FROM traces t
WHERE t.id = ANY((SELECT trace_chain FROM projections WHERE id = $1));

-- ✅ Find corrections
SELECT 
  p_old.data->>'category' as old_category,
  p_new.data->>'category' as new_category
FROM projections p_old
JOIN projections p_new ON p_old.superseded_by_projection_id = p_new.id
WHERE p_old.voided_reason = 'user_correction';
```

---

## Code Style & Conventions

### Object Key Naming

**IMPORTANT:** Always use `snake_case` for object keys in all workflows.

```javascript
// ✅ Correct
{
  raw_event_id: "uuid",
  clean_text: "message",
  guild_id: "123",
  all_scores: { work: 0.9, leisure: 0.1 }
}

// ❌ Wrong
{
  rawEventId: "uuid",      // camelCase
  CleanText: "message",    // PascalCase
  "guild-id": "123",       // kebab-case
  AllScores: { work: 0.9 } // PascalCase
}
```

**Why snake_case?**
- Consistent with database column names
- Easier to map between DB and JSON
- Standard in Python ecosystem (discord_relay.py)
- More readable in n8n expressions

### n8n Workflow Naming

- **Workflows:** PascalCase with underscores: `Discord_Message_Router`, `Command_Handler`
- **Nodes:** Descriptive names: "Parse Tag", "Store Raw Event", "Handle !! Activity"
- **Sticky notes:** Use for documentation sections

### n8n Merge Nodes

**CRITICAL:** Always configure Merge nodes properly!

```json
// ✅ Correct
{
  "parameters": {
    "mode": "append",
    "numberInputs": 2  // or 3, 4, etc. - must match actual connections!
  },
  "type": "n8n-nodes-base.merge"
}

// ❌ Wrong
{
  "parameters": {},  // Missing mode and numberInputs!
  "type": "n8n-nodes-base.merge"
}
```

**Why this matters:**
- `mode: "append"` - Combines all inputs into one array (what we almost always want)
- `mode: "combine"` - Tries to merge by position (rarely useful, causes issues)
- `numberInputs` - Must match the number of incoming connections or nodes won't connect

**Common mistake:** Creating merge node with empty parameters, then wondering why connections fail or data is duplicated.

### Node Organization

**Visual Layout:**
- Left to right flow: Webhook → Processing → Response
- Group related nodes with sticky note backgrounds
- Use consistent spacing (align nodes to grid)

**Node Colors (via sticky notes):**
- 🟦 Blue: Main routing path
- 🟨 Yellow: LLM/AI operations
- 🟩 Green: Database operations
- 🟧 Orange: External API calls
- 🟪 Purple: Thread/conversation handling

---

## Error Handling & Resilience

### ⚠️ CRITICAL: Workflows Must Be Antifragile

**Principle:** Workflows should NEVER die silently. Always inform the user when something goes wrong.

### Error Handling Patterns

#### 1. **Database Queries - Always Handle Failures**

```javascript
// ✅ Good: Set alwaysOutputData and handle empty results
{
  "parameters": {
    "operation": "executeQuery",
    "query": "SELECT * FROM activities WHERE id = $1",
    "options": { "queryReplacement": "={{ $json.short_id || '' }}" }
  },
  "alwaysOutputData": true  // Continue even if query fails
}

// In downstream Code node:
const result = $input.item.json;
if (!result || !result.id) {
  return {
    response: "❌ Activity not found with that ID",
    ...event
  };
}
```

#### 2. **SQL Queries - Handle Missing Parameters**

```sql
-- ❌ Bad: Breaks when $1 is empty or null
WHERE item_type = $1

-- ✅ Good: Provide fallback values
WHERE COALESCE($1, 'activities') IN ('activities', 'activity', '')

-- ✅ Good: Handle optional parameters
WHERE $1::text = '' OR category_name = $1::text
```

#### 3. **LLM Calls - Always Have Fallbacks**

```javascript
// ✅ Good: Use needsFallback in LLM chain
{
  "parameters": {
    "promptType": "define",
    "text": "...",
    "needsFallback": true  // Use fallback model if primary fails
  },
  "type": "@n8n/n8n-nodes-langchain.chainLlm"
}
```

#### 4. **Code Nodes - Validate Inputs**

```javascript
// ✅ Good: Check for required data before processing
const args = $('Parse Command and Args').item?.json?.args;
if (!args || args.length === 0) {
  return {
    response: "❌ Missing required argument. Use `::help` for syntax.",
    ...event
  };
}

// ✅ Good: Handle array access safely
const shortId = args[0] || '';
if (shortId.length < 8) {
  return {
    response: "❌ Invalid short ID format. Use `::recent` to see valid IDs.",
    ...event
  };
}

// ✅ Good: Provide helpful error messages
try {
  // risky operation
} catch (error) {
  return {
    response: `❌ Operation failed: ${error.message}\\n\\nUse \`::help\` for correct syntax.`,
    ...event
  };
}
```

#### 5. **User-Facing Error Messages**

**Always include:**
- ❌ Error icon to signal failure
- Clear description of what went wrong
- Hint about how to fix it or where to get help
- Reference to `::help` when appropriate

**Examples:**

```javascript
// ✅ Excellent error messages
"❌ No activities found with ID: a1b2c3d4. Use `::recent activities` to see valid IDs."

"❌ Missing required argument. Syntax: `::delete activity <short-id>`"

"❌ Database query failed. Please try again or use `::help` for assistance."

"❌ Config key 'north_star' not found. Use `::set north_star <value>` to set it first."

// ❌ Bad error messages (never do this)
"Error"
"Failed"
"undefined"
"Query error" (no context or fix)
```

### Testing for Antifragility

**Before committing any workflow, test these edge cases:**

1. **No arguments:** `::recent` (should default to activities, limit 10)
2. **Invalid arguments:** `::delete activity` (missing short_id)
3. **Non-existent IDs:** `::delete activity zzzzzzz`
4. **Empty database:** Test when no activities/notes exist
5. **SQL injection attempts:** `::delete activity '; DROP TABLE--`
6. **Very long inputs:** 500+ character messages
7. **Special characters:** Emojis, unicode, quotes in text
8. **Concurrent requests:** Multiple users at once

### Workflow Configuration for Error Handling

**Postgres nodes:**
```json
{
  "parameters": { "..." },
  "alwaysOutputData": true,  // IMPORTANT: Always set this
  "continueOnFail": false     // Fail loudly, don't hide errors
}
```

**Code nodes:**
```json
{
  "parameters": { "jsCode": "..." },
  "continueOnFail": false,  // Let errors bubble up
  "onError": "stopWorkflow"  // Don't continue with bad data
}
```

### Common Pitfalls

**❌ Don't do this:**
```javascript
// No validation
const result = $input.item.json.data;
return result.value; // What if data is undefined?
```

**✅ Do this instead:**
```javascript
// Defensive programming
const data = $input.item?.json?.data;
if (!data || !data.value) {
  return {
    response: "❌ No data returned from query",
    ...event
  };
}
return { response: data.value, ...event };
```

### Error Handling Checklist

Before committing, verify:

- [ ] All Postgres nodes have `alwaysOutputData: true`
- [ ] All SQL queries handle NULL/$1='' cases
- [ ] All Code nodes validate inputs before processing
- [ ] All error paths return user-friendly messages
- [ ] All error messages include hints or next steps
- [ ] Tested with missing/invalid arguments
- [ ] Tested with empty database state
- [ ] No workflow dies silently (user always gets feedback)

---

### Python (discord_relay.py)

```python
# Follow PEP 8
# Use type hints where helpful
# Use environment variables for config
# Log important events

import os
from typing import Optional

WEBHOOK_URL = os.getenv('N8N_WEBHOOK_URL')
```

### SQL Queries in n8n

```sql
-- Use parameterized queries (prevent SQL injection)
SELECT * FROM activity_log 
WHERE timestamp > $1 
  AND category_id = $2
LIMIT $3;

-- Format for readability
-- Use CTEs for complex queries
WITH recent_acts AS (
  SELECT * FROM activity_log 
  WHERE timestamp > NOW() - INTERVAL '24 hours'
)
SELECT * FROM recent_acts;
```

---

## Git Commit Guidelines

### Commit Message Format

```
<type>: <short summary>

<detailed description>

<bullet points of changes>
- Change 1
- Change 2

<manual steps if needed>
```

### Types

- `feat:` New feature
- `fix:` Bug fix
- `refactor:` Code restructuring (no behavior change)
- `docs:` Documentation only
- `chore:` Maintenance (deps, config, etc.)
- `security:` Security improvements

### Examples

**Good commit:**
```
refactor: Rename Discord_Message_Ingestion to Discord_Message_Router

- Rename workflow for consistency with naming convention
- Update all documentation references
- Create external Command_Handler workflow
- Add ++ fallback when LLM classification fails

Manual steps:
- Update webhook path in n8n UI to use {{ $env.WEBHOOK_PATH }}
```

**Bad commit:**
```
update stuff
```

### Pre-Commit Checklist

Before every commit:

- [ ] Run `./scripts/workflows/sanitize_workflows.sh` if workflows changed
- [ ] Update relevant documentation (README, docs/)
- [ ] Test changes if possible
- [ ] Check for sensitive data: `git diff | grep -E "(password|token|secret|api_key)"`
- [ ] Review diff: `git diff --staged`

---

## Testing Workflows

### Testing in n8n UI

**Use pinned test data:**
1. Create test execution data
2. Pin it to the webhook node
3. Test workflow with "Test Workflow" button
4. **IMPORTANT:** Delete pinned data before exporting

**Test message examples:**
```javascript
// Activity (tagged)
{ "content": "!! working on the router agent" }

// Activity (untagged - triggers LLM)
{ "content": "debugging authentication bug" }

// Note (untagged)
{ "content": "interesting insight about async communication" }

// Thread start
{ "content": "what did I work on yesterday?" }

// Command
{ "content": ":: ping" }
```

### End-to-End Testing

**Test flow:**
1. Send actual Discord message in #arcane-shell
2. Check Discord for emoji reaction
3. Check #kairon-logs for classification output
4. Verify database: `SELECT * FROM raw_events ORDER BY received_at DESC LIMIT 5;`
5. Check n8n execution logs

**Key test scenarios:**
- Tagged message (`!!`, `..`, `++`, `::`)
- Untagged message (triggers LLM classifier)
- Message in thread
- Malformed message
- Very long message
- Empty message
- Command with args

---

## Documentation Updates

### When to Update Documentation

**Always update documentation when:**
- Adding/changing workflows
- Modifying database schema
- Adding environment variables
- Changing architecture
- Adding new commands
- Modifying prompts

### Documentation Files

| File | Purpose | Update When |
|------|---------|-------------|
| `README.md` | High-level architecture | Major changes |
| `docs/router-agent-implementation.md` | Router implementation | Router changes |
| `docs/n8n-environment-variables.md` | Environment variables | New env vars |
| `docs/n8n-workflow-implementation.md` | Workflow details | Workflow changes |
| `docs/database-setup.md` | Database setup | Schema changes |
| `docs/discord-bot-setup.md` | Discord relay setup | Bot changes |
| `.env.example` | Environment template | New env vars |
| `AGENTS.md` | This file | Agent guidelines change |

### Documentation Style

**Use clear sections:**
```markdown
## Section Title

Brief description of what this section covers.

### Subsection

Specific details.

**Example:**
```code example```
```

**Use status markers:**
- ✅ Completed/implemented
- ⏳ TODO/pending
- ❌ Deprecated/don't use
- ⚠️ Important warning

**Code examples:**
- Always include working examples
- Show both wrong (❌) and correct (✅) approaches
- Include expected output where helpful

---

## Architecture Decisions

### Current Design Patterns

**1. External Handler Workflows**
- Router only does classification + dispatch
- All handlers are separate workflows
- Cleaner, more maintainable
- Easier to test individually

**2. LLM Classification (Not Tool Calling)**
- Simple TAG|CONFIDENCE output format
- Faster, cheaper than function calling (~70% fewer tokens)
- Reuses existing tag routing logic
- Fallback to `++` (conversation) on failure

**3. Hybrid Routing**
- Tags (`!!`, `..`, `++`, `::`) = fast deterministic path
- No tag = LLM classification path
- Best of both worlds: speed + intelligence

**4. Append-Only Event Log**
- `raw_events` table is append-only
- Never delete from raw_events
- Enables replay, debugging, audit trail

**5. Category IDs (Not Names)**
- All FKs use category IDs
- Users can rename categories without breaking history
- Special flags (e.g., `is_sleep_category`) avoid name-based logic

### Design Principles

1. **Security First** - Never commit secrets
2. **Idempotency** - All operations should be safe to retry
3. **Explicit Over Implicit** - Use clear names, avoid magic
4. **Minimize LLM Context** - Only include what's necessary
5. **Fail Safe** - Default to conversation mode (`++`) when uncertain
6. **User Editable** - Categories, config should be user-changeable
7. **Audit Trail** - Keep raw_events forever

---

## Common Pitfalls

### ❌ Don't Do This

**1. Committing unsanitized workflows**
```bash
# ❌ Don't
git add n8n-workflows/*.json
git commit -m "update workflow"
```

**2. Hardcoding IDs**
```javascript
// ❌ Don't
const channelId = "1450655614421303367";
```

**3. Deleting from raw_events**
```sql
-- ❌ Don't
DELETE FROM raw_events WHERE ...;
```

**4. Using category names in queries**
```sql
-- ❌ Don't
WHERE category_name = 'work'
```

**5. Assuming message order**
```javascript
// ❌ Don't assume first() always works
const tag = $json.content.match(/!!|\\+\\+/)[0];
```

### ✅ Do This Instead

**1. Always sanitize before committing**
```bash
# ✅ Do
./scripts/workflows/sanitize_workflows.sh
git add n8n-workflows/*.json
git commit -m "update workflow"
```

**2. Use environment variables**
```javascript
// ✅ Do
const channelId = $env.DISCORD_CHANNEL_KAIRON_LOGS;
```

**3. Keep raw_events immutable**
```sql
-- ✅ Do (if you need to mark as processed)
UPDATE raw_events SET metadata = jsonb_set(metadata, '{processed}', 'true')
WHERE id = $1;
```

**4. Use category IDs with subqueries**
```sql
-- ✅ Do
WHERE category_id = (SELECT id FROM activity_categories WHERE name = 'work')
```

**5. Use safe extraction with fallbacks**
```javascript
// ✅ Do
const match = $json.content.match(/!!|\\+\\+|::|\\.\\./)
const tag = match ? match[0] : null;
```

---

## Troubleshooting

### Workflow Not Executing

**Check:**
1. Is workflow activated?
2. Are environment variables set? Test with: `return [{ json: { test: $env.WEBHOOK_PATH } }]`
3. Is webhook URL correct in discord_relay.py?
4. Check n8n logs: `docker logs n8n` or `journalctl -u n8n -f`
5. Check Discord bot logs: `journalctl -u kairon-relay -f`

### LLM Classification Failing

**Check:**
1. OpenRouter API key set? `echo $OPENROUTER_API_KEY`
2. Check #kairon-logs for error messages
3. Check raw_events table: `SELECT * FROM raw_events ORDER BY received_at DESC LIMIT 5;`
4. Is fallback to `++` working? (Should always route somewhere)
5. Try reducing prompt length if hitting token limits

### Database Errors

**Check:**
1. Schema up to date? `psql kairon < db/migrations/001_initial_schema.sql`
2. Seed data loaded? `psql kairon < db/seeds/001_initial_data.sql`
3. Connection string correct in n8n credentials?
4. Postgres running? `docker ps` or `systemctl status postgresql`
5. Check n8n execution logs for actual SQL error

### Changes Not Appearing

**Check:**
1. Did you save the workflow in n8n UI?
2. Did you activate the workflow after changes?
3. Did you restart n8n after environment variable changes?
4. Clear browser cache (n8n UI can cache aggressively)
5. Try deactivating and reactivating the workflow

---

## Quick Reference

### Essential Commands

```bash
# Sanitize workflows before commit
./scripts/workflows/sanitize_workflows.sh

# Check for sensitive data
git diff | grep -E "(password|token|secret|key|[0-9]{18})"

# View recent database events
docker exec -it postgres-db psql -U n8n_user -d kairon -c "SELECT * FROM raw_events ORDER BY received_at DESC LIMIT 10;"

# Check n8n logs
docker logs -f n8n
# or
journalctl -u n8n -f

# Check Discord bot logs
journalctl -u kairon-relay -f

# Restart n8n (Docker)
docker-compose restart n8n

# Restart n8n (systemd)
sudo systemctl restart n8n

# Generate new webhook path
openssl rand -hex 16

# Test Discord bot connection
curl -X POST $N8N_WEBHOOK_URL -H "Content-Type: application/json" -d '{"content": "test"}'
```

### Development Scripts

The following scripts help with workflow development and maintenance:

#### validate_workflows.sh - JSON Validation

Validates that all workflow JSON files are syntactically correct.

```bash
# Validate all workflows
./scripts/workflows/validate_workflows.sh

# Validate specific file
./scripts/workflows/validate_workflows.sh n8n-workflows/Execute_Command.json
```

**Exit codes:**
- `0` - All files valid
- `1` - One or more files invalid

**When to use:** Before committing, after editing JSON directly, after exports from n8n.

---

#### lint_workflows.py - Context Pattern Linter

Checks workflows for compliance with the `ctx` object pattern and n8n best practices.

```bash
# Lint all workflows
./scripts/workflows/lint_workflows.py

# Lint specific workflow
./scripts/workflows/lint_workflows.py n8n-workflows/Execute_Command.json
```

**Exit codes:**
- `0` - All checks passed
- `1` - Errors found (must fix)
- `2` - Warnings only (should review)

**What it checks:**
- ✅ `ctx` object initialization after trigger
- ✅ Code nodes return `{ ctx: { ...ctx, namespace: {...} } }`
- ✅ If nodes check `$json.ctx.validation.valid`
- ✅ Postgres nodes use `$json.ctx.*` for parameters
- ✅ Discord nodes use `$json.ctx.event.*` for IDs
- ✅ Set nodes have `includeOtherFields: true` when setting ctx
- ✅ Switch nodes have fallback outputs
- ✅ Merge nodes have proper configuration
- ⚠️ Scattered node references (should use ctx instead)

**Example output:**
```
Execute_Command.json - PASS
✓ ctx initialized in 'Parse Command and Args' (Set node)
✓ 'Query Get Config': correctly uses ctx for query parameters
✓ 'If Valid Get': correctly checks ctx.validation.valid

Route_Discord_Event.json - FAIL
✗ 'Store Message Event': uses node reference without ctx
! 'Route by Event Type': Switch node has no fallback output
```

---

#### inspect_workflow.py - Workflow Inspector

Inspect workflow structure, view node details, and search across workflows.

```bash
# Show workflow overview
./scripts/workflows/inspect_workflow.py n8n-workflows/Execute_Command.json

# List all nodes grouped by type
./scripts/workflows/inspect_workflow.py n8n-workflows/Execute_Command.json --nodes

# Show specific node details (including code)
./scripts/workflows/inspect_workflow.py n8n-workflows/Execute_Command.json --node "Validate Get"

# Show all Code node contents
./scripts/workflows/inspect_workflow.py n8n-workflows/Execute_Command.json --code

# Show connection graph
./scripts/workflows/inspect_workflow.py n8n-workflows/Execute_Command.json --connections

# Search for pattern across workflows
./scripts/workflows/inspect_workflow.py "n8n-workflows/*.json" --find "ctx.event"
./scripts/workflows/inspect_workflow.py "n8n-workflows/*.json" --find "validation.valid"
```

**Common use cases:**
- Finding where a field is used: `--find "ctx.db.conversation_id"`
- Viewing node code without opening n8n: `--node "Node Name"`
- Understanding workflow structure: `--connections`
- Checking which nodes exist: `--nodes`

---

#### Recommended Workflow Development Flow

```bash
# 1. After making changes in n8n UI, export and save
#    (Download workflow JSON, save to n8n-workflows/)

# 2. Validate JSON syntax
./scripts/workflows/validate_workflows.sh

# 3. Check ctx pattern compliance
./scripts/workflows/lint_workflows.py

# 4. Review specific nodes if needed
./scripts/workflows/inspect_workflow.py n8n-workflows/MyWorkflow.json --node "Problem Node"

# 5. Sanitize before commit
./scripts/workflows/sanitize_workflows.sh

# 6. Commit
git add n8n-workflows/*.json
git commit -m "feat: add new workflow feature"
```

### Pre-Commit Hook

A pre-commit hook automatically validates workflow files before each commit. It checks:
- JSON syntax validity
- Absence of `pinData` (sensitive test data)

**Setup (one-time per clone):**
```bash
git config core.hooksPath .githooks
```

The hook will block commits if:
- Any workflow JSON is invalid
- Any workflow contains `pinData`

If blocked, run `./scripts/workflows/sanitize_workflows.sh` and re-stage files.

### File Locations

```
kairon/
├── scripts/
│   ├── workflows/               # Workflow development tools
│   │   ├── validate_workflows.sh   # JSON syntax validation
│   │   ├── lint_workflows.py       # ctx pattern linter
│   │   ├── inspect_workflow.py     # Workflow inspector/search
│   │   ├── sanitize_workflows.sh   # Remove sensitive data
│   │   └── n8n-sync.sh             # Sync workflows to remote server
│   ├── db/                      # Database scripts
│   │   ├── run-migration.sh        # Run migrations with backup
│   │   ├── db-query.sh             # Run SQL queries remotely
│   │   ├── setup_db.sh             # Initial DB setup
│   │   └── find_postgres_*.sh      # Postgres discovery
│   └── show-local-config.sh     # Show .env and .env.local (for AI agents)
├── .githooks/
│   └── pre-commit               # Workflow validation hook
├── n8n-workflows/               # n8n workflow exports (sanitized)
│   ├── Route_Discord_Event.json
│   ├── Route_Message.json
│   ├── Execute_Command.json
│   └── ...
├── db/
│   ├── migrations/              # Database schema
│   └── seeds/                   # Initial data
├── docs/                        # Detailed documentation
├── prompts/                     # LLM prompts
├── discord_relay.py             # Discord bot
├── .env                         # Environment config (not committed)
├── .env.example                 # Environment variable template
├── README.md                    # Main documentation
└── AGENTS.md                    # This file
```

### n8n Expression Cheatsheet

```javascript
// Environment variables
{{ $env.VARIABLE_NAME }}

// Previous node output
{{ $('Node Name').item.json.field }}
{{ $('Node Name').first().json.field }}
{{ $('Node Name').all()[0].json.field }}

// Current item
{{ $json.field }}

// Regular expressions
{{ $json.content.match(/pattern/).first() }}
{{ $json.content.replace(/pattern/, 'replacement') }}

// Fallback values
{{ $json.field || 'default' }}
{{ $json.field ?? 'default' }}

// Conditionals in Set node
{{ $json.value > 5 ? 'high' : 'low' }}

// Arrays
{{ $json.items.length }}
{{ $json.items.map(i => i.name) }}
{{ $json.items.filter(i => i.active) }}
```

---

## Getting Help

### Resources

1. **Project Documentation:** Start with `README.md` and `docs/` folder
2. **n8n Documentation:** https://docs.n8n.io/
3. **Discord API:** https://discord.com/developers/docs
4. **PostgreSQL Docs:** https://www.postgresql.org/docs/

### When Asking Questions

**Provide:**
- What you're trying to do
- What you expected to happen
- What actually happened
- Relevant logs/errors
- Steps to reproduce

**Example:**
```
Issue: LLM classifier not outputting valid tags

Expected: Should output "!!|high" format
Actual: Getting "Activity: work" format
Logs: [paste n8n execution log]

Steps to reproduce:
1. Send message "working on router" to #arcane-shell
2. Check #kairon-logs output
3. See incorrect format
```

---

## Contributing

### Workflow for Changes

1. **Understand the change** - Read relevant docs
2. **Make changes in n8n UI** - Test thoroughly
3. **Export workflows** - Download as JSON
4. **Sanitize exports** - Run `./scripts/workflows/sanitize_workflows.sh`
5. **Update documentation** - Keep docs in sync
6. **Test end-to-end** - Real Discord messages
7. **Commit with good message** - Follow guidelines above
8. **Push to main** - Or create PR if major change

### Code Review Checklist

When reviewing changes:

- [ ] Workflows sanitized (no pinData)
- [ ] No hardcoded secrets/IDs
- [ ] Environment variables used correctly
- [ ] Documentation updated
- [ ] Commit message follows guidelines
- [ ] Changes tested end-to-end
- [ ] No breaking changes to database schema (or migration provided)
- [ ] Backwards compatible with existing data

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2024-12-17 | Initial version with sanitization guidelines |

---

**Remember:** When in doubt, sanitize! It's better to run `./sanitize_workflows.sh` too often than to accidentally commit sensitive data.
