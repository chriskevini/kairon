# Kairon Best Practices

Core patterns, conventions, and guidelines for developing Kairon workflows and systems.

## Table of Contents

- [The ctx Pattern](#the-ctx-pattern)
- [Workflow Design Principles](#workflow-design-principles)
- [Node Configuration](#node-configuration)
- [Database Patterns](#database-patterns)
- [Error Handling](#error-handling)
- [Testing Conventions](#testing-conventions)

## The ctx Pattern

### Overview

Every workflow uses a `ctx` object to pass data between nodes. This prevents data loss when native nodes (Postgres, HTTP) overwrite `$json`.

### Canonical ctx Shape

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

### ctx Rules

1. **First node after trigger** MUST initialize `ctx.event` with all required fields
2. **Code nodes**: `return { ctx: { ...$json.ctx, new_namespace: {...} } }`
3. **Native nodes** (Postgres, HTTP) need a "Merge" wrapper to restore ctx
4. **Set nodes**: Always enable `includeOtherFields: true` when setting ctx fields
5. **Read data from** `$json.ctx.*`, **never** `$('Node Name').item.json`
6. **Don't pollute ctx root** with workflow-specific fields - use namespaces

### Common Patterns

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

## Workflow Design Principles

### Execution Order & Parallelism

n8n does not run branches in parallel. When a node has multiple outgoing connections (fork), the first branch executes to completion before the second branch begins.

**Critical for Database Writes:**
If one branch writes to the database and another branch reads that data, ensure the write branch completes first.

- **Check Connections:** Order in the `main` output array determines execution order
- **Merge Nodes:** Use "Wait for all inputs" to synchronize branches
- **Wait Nodes:** Add small delays for external system synchronization

### Sub-Workflow Pattern: Fire-and-Forget

When calling sub-workflows via Execute Workflow nodes, **do not expect ctx back**. Sub-workflows are fully responsible for their own lifecycle.

**Why:**
- Simpler contracts - Execute Workflow nodes are fire-and-forget
- Less coupling - Parent doesn't need to know ctx shape after sub-workflow transforms it
- Clearer ownership - Each workflow owns its complete lifecycle

**Pattern:**
```
Parent Workflow                    Sub-Workflow
─────────────────                  ─────────────────
[Receive Event]                    [Execute Workflow Trigger]
      │                                     │
[Add 🔵 Reaction]                   [Do work, add own reaction]
      │                             [Remove 🔵 Reaction]
      │                                     │
      ▼                                     ▼
[Continue parent]                  [End - nothing returned]
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

## Node Configuration

### Switch Nodes

Always include a fallback/default case. Switch nodes with no match produce no output.

### Merge Nodes

Always set `mode: "append"` and `numberInputs` to match actual connections.

### Execute Workflow Nodes

Must use `mode: "list"` for portability:
- `mode`: "list" (enables environment-agnostic workflow references)
- `value`: The workflow ID (n8n resolves from cachedResultName at runtime)
- `cachedResultName`: The target workflow name (stable across environments)

## Database Patterns

### Database Queries: Execute_Queries vs Inline Postgres

**Use Execute_Queries sub-workflow when:**
- Multiple queries need to run sequentially with result chaining
- You need trace_id from INSERT to use in subsequent queries

```javascript
// Build queries with chaining
return [{
  json: {
    ctx: {
      ...ctx,
      db_queries: [
        {
          key: 'trace',
          sql: 'INSERT INTO traces (...) RETURNING id',
          params: [...]
        },
        {
          key: 'projection',
          sql: 'INSERT INTO projections (trace_id, ...) VALUES ($1, ...)',
          params: ['$results.trace.row.id', ...]  // Chain from previous result
        }
      ]
    }
  }
}];

// After Execute_Queries, results in ctx.db.trace.row, ctx.db.projection.row
```

**Use inline Postgres nodes when:**
- Single independent query per branch
- Command-style workflows with many separate branches

### Database Schema Principles

**Core principle: One LLM call = one trace. Everything points back to an event.**

```
Event (immutable log)
  └── Trace (one per LLM call)
        ├── Projection (activity)
        ├── Projection (note)
        └── Projection (todo)
```

- Events use `idempotency_key` with `ON CONFLICT DO NOTHING`
- Categories are strings in JSONB (not enums)
- Never delete from events table
- Query projections with `status IN ('auto_confirmed', 'confirmed')`

## Tag Routing

Tags are parsed at the start of messages:

| Symbol | Word Alt | Intent | Workflow |
|--------|----------|--------|----------|
| `!!` | `act` | Activity capture | Direct save |
| `..` | `note` | Note capture | Direct save |
| `++` | `chat` | Start thread | Thread agent |
| `--` | `save` | Save & close thread | Save thread |
| `::` | `cmd` | Execute command | Command handler |
| `$$` | `todo`, `to-do` | Create todo | Todo handler |
| (none) | - | Auto-classify | LLM router → multi-extraction |

## Testing Conventions

### Unit Test Framework

All workflows undergo structural and functional testing.

**Tier 1 workflows** (high risk/importance) must have both structural and functional tests.

**Test checklist for new workflows:**
- [ ] **Structural**: No orphan nodes, consistent connection naming, trigger presence
- [ ] **ctx Pattern**: Ensure nodes read from/write to `ctx` correctly
- [ ] **Logic**: Verify JS code logic (regex, aliases, mappings) using `pytest`
- [ ] **Integration**: Verify database operations and subworkflow calls

### Database Health Scripts

SQL scripts in `scripts/db/` for checking database state:

| Script | Purpose |
|--------|---------|
| `check_duplicates.sql` | Find duplicate events and processing health |
| `check_migration_status.sql` | Check core table stats and orphaned events |
| `check_orphans_by_tag.sql` | Analyze processing health by tag type |
| `cleanup_test_events.sql` | Remove test/debug events (preview first!) |

## Environment Variables

Use `{{ $env.VAR_NAME }}` in n8n, never hardcode IDs:

```javascript
// ✅ Correct
{{ $env.DISCORD_CHANNEL_KAIRON_LOGS }}

// ❌ Wrong
"1450655614421303367"
```

Key variables: `WEBHOOK_PATH`, `DISCORD_GUILD_ID`, `DISCORD_CHANNEL_*`, `OPENROUTER_API_KEY`, `POSTGRES_*`

## Commit Messages

```
feat: new feature
fix: bug fix
refactor: code restructuring
docs: documentation
chore: maintenance
```