# Agent Guidelines

Instructions for AI agents working on Kairon - a life-tracking system using n8n workflows + Discord.

## Project Structure

```
n8n-workflows/       # Workflow JSON files
db/
  migrations/        # SQL migrations (numbered, run in order)
  schema.sql         # Current database schema (reference only)
  seeds/             # Initial seed data
scripts/
  db/                # Database health checks and utilities
  workflows/         # Workflow JSON tools (lint, inspect, validate)
prompts/             # LLM prompts used in workflows
docs/                # Documentation
discord_relay.py     # Discord bot that forwards to n8n
```

## n8n Best Practices

### The ctx Pattern (CRITICAL)

Every workflow uses a `ctx` object to pass data between nodes. This prevents data loss when native nodes (Postgres, HTTP) overwrite `$json`.

#### Canonical ctx Shape

Use this standard structure across all workflows:

```javascript
{
  ctx: {
    // Core event data (REQUIRED - always present)
    event: {
      event_id: "uuid",              // Database event ID
      event_type: "discord_message", // Event type
      channel_id: "discord_id",      // Discord channel
      message_id: "discord_id",      // Discord message
      clean_text: "message text",    // Cleaned message content
      tag: "!!" | ".." | "++" | "--" | "::" | "$$" | null, // Route tag
      trace_chain: ["uuid"],         // LLM trace ancestry
      author_login: "username",      // Discord username
      timestamp: "ISO8601"           // Event timestamp
    },
    
    // LLM outputs (when workflow calls LLM)
    llm?: {
      completion_text: "llm output",
      confidence: 0.95,              // 0-1 confidence score
      duration_ms: 1234,             // Inference time
      model?: "openai/gpt-4"         // Optional model name
    },
    
    // Database results (when workflow queries/inserts)
    db?: {
      trace_id?: "uuid",             // Trace record ID
      projection_id?: "uuid",        // Projection record ID
      user_record?: {...}            // User/config data
    },
    
    // Validation results (for commands/inputs)
    validation?: {
      valid: true,
      error_message?: "Error details"
    },
    
    // Thread-specific (only in thread workflows)
    thread?: {
      thread_id: "uuid",
      history: [...],                // Conversation history
      extractions: [...]             // Extracted items
    },
    
    // Command-specific (only in Execute_Command)
    command?: {
      name: "get",                   // Command name
      args: ["key"]                  // Command arguments
    }
  }
}
```

**Rules:**
1. First node after trigger **must** initialize `ctx.event` with all required fields
2. Code nodes: `return { ctx: { ...$json.ctx, new_namespace: {...} } }`
3. Native nodes (Postgres, HTTP) need a "Merge" wrapper to restore ctx
4. Set nodes: **always** enable `includeOtherFields: true` when setting ctx fields
5. Read data from `$json.ctx.*`, **never** `$('Node Name').item.json`
6. Don't pollute ctx root with workflow-specific fields - use namespaces

#### Common Patterns

```javascript
// ✅ Initialize ctx.event in first node after trigger
return [{
  json: {
    ctx: {
      event: {
        event_id: $json.id,
        clean_text: $json.content,
        trace_chain: [$json.id],
        // ... all required fields
      }
    }
  }
}];

// ✅ Add namespace to existing ctx
return [{
  json: {
    ctx: {
      ...$json.ctx,
      llm: {
        completion_text: llmResponse,
        confidence: 0.95
      }
    }
  }
}];

// ✅ Read from ctx (not node references)
const eventId = $json.ctx.event.event_id;
const cleanText = $json.ctx.event.clean_text;

// ❌ DON'T: Mix flat and nested in ctx
return {
  ctx: {
    event_id: "...",        // ❌ Should be ctx.event.event_id
    event: { ... }
  }
};

// ❌ DON'T: Use node references (breaks ctx pattern)
const text = $('Previous Node').item.json.text;  // ❌
const text = $json.ctx.event.clean_text;         // ✅

// ❌ DON'T: Pollute ctx root with workflow fields
return {
  ctx: {
    event: {...},
    emoji_count: 3,         // ❌ Workflow-specific, no namespace
    has_extractions: true   // ❌ Should be in ctx.thread or similar
  }
};
```

### Execution Order & Parallelism

n8n does not run branches in parallel. When a node has multiple outgoing connections (fork), the first branch executes to completion (until it hits a leaf node or a merge node) before the second branch begins.

**Critical for Database Writes:**
If one branch writes to the database (e.g., `Store Projection`) and another branch reads that data (e.g., `Trigger Show Details` sub-workflow), you must ensure the write branch completes first.

- **Check Connections:** In the JSON, the order of nodes in the `main` output array determines execution order.
- **Merge Nodes:** Use a Merge node (set to "Wait for all inputs") to explicitly synchronize branches if subsequent nodes depend on data from all previous branches.
- **Wait Nodes:** If triggering an external system or sub-workflow that queries the database, a small `Wait` node in the receiver is a good safety net, but proper branch ordering in the sender is preferred.

### Sub-Workflow Pattern: Fire-and-Forget

When calling sub-workflows via Execute Workflow nodes, **do not expect ctx back**. Sub-workflows are fully responsible for their own lifecycle, including any cleanup or finalization (e.g., adding/removing reactions).

**Why:**
- Simpler contracts - Execute Workflow nodes are fire-and-forget
- Less coupling - Parent doesn't need to know ctx shape after sub-workflow transforms it
- Clearer ownership - Each workflow owns its complete lifecycle
- Easier debugging - No wondering if ctx got corrupted on return
- ctx shape stability - Only the trigger defines the shape

**Pattern:**
```
Parent Workflow                    Sub-Workflow
─────────────────                  ─────────────────
[Receive Event]                    
      │                            
[Add 🔵 Reaction]                  
      │                            
[Execute Workflow] ──────────────► [Execute Workflow Trigger]
      │ (fire-and-forget)                    │
      │                            [Do work, add own reaction]
      │                            [Remove 🔵 Reaction] ◄── sub-workflow handles cleanup
      │                                      │
      ▼                                      ▼
[Continue parent                   [End - nothing returned]
 logic if needed]
```

**Anti-pattern:** Don't do this:
```javascript
// ❌ Parent waiting for ctx back from sub-workflow
[Execute Sub-Workflow] → [Use $json.ctx from sub-workflow] → [Remove reaction]
```

#### Exception: Query_DB Wrapper

The `Query_DB` sub-workflow is the **only exception** to fire-and-forget. It's a utility wrapper that executes SELECT queries while preserving ctx. Supports both single and batch queries.

**Why this exists:**
- Database queries are the most common source of ctx-loss bugs
- Eliminates forking/merging patterns that are hard to understand
- Standardizes result shape across all workflows
- Since n8n doesn't parallelize branches anyway, sequential batch queries are just as fast

**Batch Usage (preferred for multiple queries):**
```javascript
// 1. Prepare ALL queries in a single Code node
return [{
  json: {
    ctx: {
      ...$json.ctx,
      db_queries: [
        { 
          key: 'history', 
          sql: 'SELECT * FROM thread_history WHERE thread_id = $1 ORDER BY timestamp',
          params: [$json.ctx.event.thread_id]
        },
        { 
          key: 'north_star', 
          sql: "SELECT value FROM config WHERE key = 'north_star'"
        },
        { 
          key: 'activities', 
          sql: 'SELECT * FROM projections WHERE projection_type = $1 LIMIT $2',
          params: ['activity', 10]
        }
      ]
    }
  }
}];

// 2. Call Query_DB sub-workflow (waitForSubWorkflow: true)

// 3. Results are keyed by the 'key' field:
const history = $json.ctx.db.history;           // { results: [...], count: N }
const northStar = $json.ctx.db.north_star;      // { results: [...], count: N }
const activities = $json.ctx.db.activities;     // { results: [...], count: N }

// Common patterns:
const northStarValue = $json.ctx.db.north_star.results[0]?.value || '(not set)';
const historyRows = $json.ctx.db.history.results;
```

**Single Query Usage (for simple cases):**
```javascript
// 1. Prepare query
return [{
  json: {
    ctx: {
      ...$json.ctx,
      db_queries: [{ 
        key: 'config',
        sql: "SELECT value FROM config WHERE key = 'verbose'",
      }]
    }
  }
}];

// 2. Call Query_DB, then access:
const verbose = $json.ctx.db.config.results[0]?.value === 'true';
```

**Workflow Pattern:**
```
[Trigger] → [Prepare Queries] → [Query_DB] → [Build Context] → [Rest of workflow...]
```

This replaces the old fan-out pattern:
```
// ❌ OLD: Fork to multiple Postgres nodes, then Merge
[Trigger] → [Query 1] ─┐
         → [Query 2] ──┼→ [Merge (5 inputs)] → [Build Context]
         → [Query 3] ──┤
         → [Query 4] ──┤
         → [ctx pass] ─┘

// ✅ NEW: Single linear flow
[Trigger] → [Prepare Queries] → [Query_DB] → [Build Context]
```

### Error Handling

Workflows must never die silently. Always return a response:

```javascript
if (!data) {
  return {
    response: "❌ Not found. Use `::help` for syntax.",
    channel_id: $json.ctx.event.channel_id
  };
}
```

### Additional Patterns

```javascript
// Initialize arrays from ctx
const traceChain = $json.ctx.event.trace_chain || [];

// Format Postgres arrays in Code nodes, not query expressions
const traceChainPg = `{${traceChain.join(',')}}`;

// Validate ctx before access
const ctx = $json.ctx;
if (!ctx?.event?.event_id) {
  return {
    ctx,
    error: true,
    response: "❌ Missing event data"
  };
}

// Always use snake_case for object keys
const projectionData = {
  event_id: ctx.event.event_id,
  clean_text: ctx.event.clean_text,
  user_id: ctx.db?.user_record?.id
};

// Safely access nested ctx properties
const channelId = $json.ctx?.event?.channel_id || 'unknown';
const confidence = $json.ctx?.llm?.confidence ?? 0.5;
```

### Switch Nodes

Always include a fallback/default case. Switch nodes with no match produce no output.

### Merge Nodes

Always set `mode: "append"` and `numberInputs` to match actual connections.

## Environment Variables

Use `{{ $env.VAR_NAME }}` in n8n, never hardcode IDs:

```javascript
// ✅ Correct
{{ $env.DISCORD_CHANNEL_KAIRON_LOGS }}

// ❌ Wrong  
"1450655614421303367"
```

Key variables: `WEBHOOK_PATH`, `DISCORD_GUILD_ID`, `DISCORD_CHANNEL_*`, `OPENROUTER_API_KEY`, `POSTGRES_*`

## Database Schema

**Core principle: One LLM call = one trace. Everything points back to an event.**

```
Event (immutable log)
  └── Trace (one per LLM call)
        ├── Projection (activity)
        ├── Projection (note)
        └── Projection (todo)
```

**Current architecture** (Migration 006+):
- `events` - Immutable event log (the root of everything)
- `traces` - LLM reasoning (one trace per LLM call, references event)
- `projections` - Structured outputs (reference their trace)
- `embeddings` - Vector embeddings for RAG

**Key patterns:**
- Events use `idempotency_key` with `ON CONFLICT DO NOTHING`
- Categories are strings in JSONB (not enums)
- Never delete from events table
- Query projections with `status IN ('auto_confirmed', 'confirmed')`

## Tag Routing

Tags are parsed at the start of messages. See `docs/tag-parsing-reference.md` for full parsing rules.

| Symbol | Word Alt | Intent | Workflow |
|--------|----------|--------|----------|
| `!!` | `act` | Activity capture | Direct save |
| `..` | `note` | Note capture | Direct save |
| `++` | `chat` | Start thread | Thread agent |
| `--` | `save` | Save & close thread | Save thread |
| `::` | `cmd` | Execute command | Command handler |
| `$$` | `todo` | Create todo | Todo handler |
| (none) | - | Auto-classify | LLM router → multi-extraction |

## Local Tools

| Script | Purpose |
|--------|---------|
| `sanitize_workflows.sh` | Remove pinData (auto-run by hooks) |
| `validate_workflows.sh` | Check JSON syntax |
| `lint_workflows.py` | Check ctx pattern compliance |
| `inspect_workflow.py` | Inspect workflows (nodes, code, SQL, connections) |
| `inspect_execution.py` | Debug n8n execution results |
| `fix_json_files.py` | Fix control characters in workflow JSON |
| `test_json_files.py` | Test and fix broken workflow JSON files |

### Database Health Scripts

SQL scripts in `scripts/db/` for checking database state:

| Script | Purpose |
|--------|---------|
| `check_duplicates.sql` | Find duplicate events and processing health |
| `check_migration_status.sql` | Check core table stats and orphaned events |
| `check_orphans_by_tag.sql` | Analyze processing health by tag type |
| `cleanup_test_events.sql` | Remove test/debug events (preview first!) |

**Usage:**
```bash
# Run a health check
docker exec -i postgres-db psql -U $DB_USER -d $DB_NAME < scripts/db/check_migration_status.sql

# Check processing by tag
docker exec -i postgres-db psql -U $DB_USER -d $DB_NAME < scripts/db/check_orphans_by_tag.sql
```

### inspect_workflow.py Usage

```bash
# Show workflow overview
./scripts/workflows/inspect_workflow.py n8n-workflows/Multi_Capture.json

# List all nodes grouped by type
./scripts/workflows/inspect_workflow.py n8n-workflows/Multi_Capture.json --nodes

# Show specific node details (code, SQL, params)
./scripts/workflows/inspect_workflow.py n8n-workflows/Multi_Capture.json --node "Parse Response"

# Show all Code node contents
./scripts/workflows/inspect_workflow.py n8n-workflows/Multi_Capture.json --code

# Extract all SQL queries
./scripts/workflows/inspect_workflow.py n8n-workflows/Multi_Capture.json --sql

# Show connection graph
./scripts/workflows/inspect_workflow.py n8n-workflows/Multi_Capture.json --connections

# Validate structure (broken connections, orphans, ctx issues)
./scripts/workflows/inspect_workflow.py n8n-workflows/*.json --validate

# Search for pattern in code/queries
./scripts/workflows/inspect_workflow.py n8n-workflows/*.json --find "ctx.event"
```

## Commit Messages

```
feat: new feature
fix: bug fix
refactor: code restructuring
docs: documentation
chore: maintenance
```
