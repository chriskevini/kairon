# Agent Guidelines

Instructions for AI agents working on Kairon - a life-tracking system using n8n workflows + Discord.



## Local Development

Kairon supports local development testing with Docker containers.

### Environment Variables

For local development, these variables are optional (docker-compose.dev.yml provides defaults):

- `DB_USER` - Database user (default: postgres)
- `DB_NAME` - Database name (default: kairon_dev)
- `N8N_DEV_ENCRYPTION_KEY` - n8n encryption key (default: dev-local-encryption-key-32chars)
- `NO_MOCKS` - Set to "1" to use real APIs instead of mocks

### Setup

```bash
# Start local n8n + PostgreSQL
docker-compose -f docker-compose.dev.yml up -d

# Load database schema
docker exec -i postgres-dev-local psql -U ${DB_USER:-postgres} -d ${DB_NAME:-kairon_dev} < db/schema.sql

# Transform workflows for dev
mkdir -p n8n-workflows-transformed
for wf in n8n-workflows/*.json; do
  if ! cat "$wf" | python scripts/transform_for_dev.py > "n8n-workflows-transformed/$(basename "$wf")" 2>/dev/null; then
    echo "Warning: Failed to transform $(basename "$wf")"
  fi
done

# Push all transformed workflows
N8N_API_URL=http://localhost:5679 N8N_API_KEY="" WORKFLOW_DIR=n8n-workflows-transformed ./scripts/workflows/n8n-push-local.sh

# Or push single workflow manually (for quick iteration)
curl -X POST http://localhost:5679/api/v1/workflows \
  -H "Content-Type: application/json" \
  -d "$(jq '{name, nodes, connections, settings}' n8n-workflows-transformed/Route_Event.json)"
```

### Services

- **n8n:** http://localhost:5679 (no API authentication - N8N_API_KEY is empty)
- **PostgreSQL:** localhost:5433, database: kairon_dev (default)

### Testing Webhooks

```bash
# Send test message
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message",
    "guild_id": "test-guild",
    "channel_id": "test-channel",
    "message_id": "test123",
    "author": {"login": "testuser", "id": "12345", "display_name": "Test User"},
    "content": "$$ buy milk",
    "timestamp": "2025-12-26T12:00:00Z"
  }'
```

### Workflow Transformation

`transform_for_dev.py` modifies workflows for local testing:
- Converts Schedule Triggers to Webhook Triggers
- Mocks external APIs (Discord, LLM) with Code nodes
- Preserves webhook paths for testing

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

### Database Queries: Execute_Queries vs Inline Postgres

**Use Execute_Queries sub-workflow when:**
- Multiple queries need to run sequentially with result chaining
- You need trace_id from INSERT to use in subsequent queries
- Example: Store trace → Store projection (Multi_Capture, Capture_Thread)

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
- Command-style workflows with many separate branches (Execute_Command)
- Simple query → format → respond flow

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

## Deployment

Use `scripts/deploy.sh` for production workflow deployments with comprehensive testing and automatic rollback. For development testing, use local containers.

### Production Deployment

```bash
# Full pipeline: unit tests → dev → functional tests → prod + rollback protection
./scripts/deploy.sh

# Dev environment only + comprehensive functional tests
./scripts/deploy.sh dev

# Prod environment only (deprecated - bypasses safety testing)
./scripts/deploy.sh prod
```

**Pipeline stages:**
- **Stage 0:** Unit tests (structural + Python tests)
- **Stage 1:** Dev deployment (transform workflows, push to dev n8n)
- **Stage 1b:** Redeploy (optional, with real APIs for testing)
- **Stage 2:** Functional tests (2a: mock, 2b: real APIs, 2d: tag parsing)
- **Stage 3:** Prod deployment (backup → deploy → deep smoke tests → **automatic rollback on failure**)

The script automatically detects environment and includes safety features like proactive backups and fail-safe rollback.

**Pre-push hook:** Workflow changes trigger automatic deployment. Skip with `git push --no-verify` if needed.

**Safety features:** Production deployments are protected by automated rollback - any failure triggers immediate restoration to the previous working state.

### Local Development Testing

For iterative development, use local Docker containers:

```bash
# Start local environment
docker-compose -f docker-compose.dev.yml up -d

# Transform and push workflows
./scripts/transform_for_dev.py < n8n-workflows/Route_Event.json > temp.json
curl -X POST http://localhost:5679/api/v1/workflows -H "Content-Type: application/json" -d "$(jq . temp.json)"
```

**Note:** Local testing uses mock APIs by default. Set `NO_MOCKS=1` for real API testing.

### Workflow ID References

**Always use the n8n API to get workflow IDs** - never hardcode them or guess from the UI.

```bash
# Production: Get workflow IDs from n8n
curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/workflows" | \
  jq '.data[] | {name, id}'

# Development (local): No API key needed
curl -s "http://localhost:5679/api/v1/workflows" | \
  jq '.data[] | {name, id}'

# Get a specific workflow by name
curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/workflows" | \
  jq -r '.data[] | select(.name == "Execute_Command") | .id'
```

**Why API over UI:**
- IDs differ between prod, dev, and local instances
- UI can show stale cached values
- API is the source of truth for what n8n actually uses

**Execute Workflow nodes** must use `mode: "list"` for portability:
- `mode`: "list" (enables environment-agnostic workflow references)
- `value`: The workflow ID (n8n resolves from cachedResultName at runtime)
- `cachedResultName`: The target workflow name (stable across environments)
- `cachedResultUrl`: `/workflow/{workflow_id}` (generated by n8n UI)

**Why mode:list?**
- Workflow names are stable across dev/prod/staging
- Workflow IDs change between environments
- No deployment transformation or ID remapping needed
- Aligns with n8n community best practices

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

## Testing Workflows

### Unit Test Framework

All workflows undergo structural and functional testing before deployment.

```bash
# Run all tests (structural + functional)
./scripts/deploy.sh dev  # Runs STAGE 0: Unit Tests automatically

# Run tests manually
python3 scripts/workflows/unit_test_framework.py --all  # Structural
pytest n8n-workflows/tests/                             # Functional

# Test specific workflow
python3 scripts/workflows/unit_test_framework.py n8n-workflows/Route_Message.json
pytest n8n-workflows/tests/test_Route_Message.py

# Generate test template for new workflow
python3 scripts/workflows/unit_test_framework.py --generate New_Workflow.json
```

### Writing Tests

**Tier 1 workflows** (high risk/importance) must have both structural and functional tests.

**Test checklist for new workflows**:
- [ ] **Structural**: No orphan nodes, consistent connection naming, trigger presence.
- [ ] **ctx Pattern**: Ensure nodes read from/write to `ctx` correctly.
- [ ] **Logic**: Verify JS code logic (regex, aliases, mappings) using `pytest`.
- [ ] **Integration**: Verify database operations (`executeQuery`) and subworkflow calls.

Example functional test pattern:
```python
def test_ctx_preservation(self):
    workflow = load_workflow()
    nodes = workflow.get("nodes", [])
    prep_node = next((n for n in nodes if n["name"] == "Prepare Context"), None)
    assert prep_node is not None
    assert "ctx:" in prep_node["parameters"]["jsCode"]
```

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
# Production: Run a health check
docker exec -i postgres-db psql -U $DB_USER -d $DB_NAME < scripts/db/check_migration_status.sql

# Local dev: Run a health check
docker exec -i postgres-dev-local psql -U ${DB_USER:-postgres} -d ${DB_NAME:-kairon_dev} < scripts/db/check_migration_status.sql

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
