# Agent Guidelines

Instructions for AI agents working on Kairon - a life-tracking system using n8n workflows + Discord.

## Quick Start

```bash
# Setup git hooks (one-time)
git config core.hooksPath .githooks

# Workflow development
./scripts/workflows/n8n-pull.sh            # Pull changes from server
./scripts/workflows/n8n-push.sh            # Push changes to server
./scripts/workflows/n8n-push.sh --dry-run  # Preview what would push

# The pre-commit hook automatically validates and sanitizes workflows
```

## Project Structure

```
n8n-workflows/       # Workflow JSON files (synced with server)
scripts/workflows/   # n8n-push.sh, n8n-pull.sh, sanitize, validate, lint
scripts/db/          # run-migration.sh, db-query.sh
scripts/ssh-setup.sh # SSH connection reuse (ControlMaster) - reduces rate-limiting
db/migrations/       # SQL migrations
prompts/             # LLM prompts
discord_relay.py     # Discord bot that forwards to n8n
```

## SSH Scripts (Optimized for Rate-Limiting)

All SSH scripts use connection multiplexing to minimize rate-limiting:
- **Automatic connection reuse** via `ssh-setup.sh` (ControlMaster)
- **Reduced connection counts** through batched operations
- **Tar pipes** for efficient file transfers

See `docs/SSH_OPTIMIZATIONS.md` for implementation details.

## n8n Best Practices

### The ctx Pattern (CRITICAL)

Every workflow uses a `ctx` object to pass data between nodes. This prevents data loss when native nodes (Postgres, HTTP) overwrite `$json`.

```javascript
// All data flows through ctx with namespaced keys
{
  ctx: {
    event: { event_id, channel_id, clean_text, tag, ... },  // From trigger
    routing: { intent, confidence },                         // From classification  
    db: { inserted_id, user_record },                        // From queries
    llm: { completion_text, tokens_used }                    // From LLM calls
  }
}
```

**Rules:**
1. First node after trigger initializes `ctx.event`
2. Code nodes: `return { ctx: { ...$json.ctx, new_namespace: {...} } }`
3. Native nodes need a "Merge" wrapper to restore ctx
4. Set nodes: enable `includeOtherFields: true`
5. Read data from `$json.ctx.*`, never `$('Node Name').item.json`

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

### Common Patterns

```javascript
// Initialize arrays
trace_chain: $json.trace_chain || []

// Format Postgres arrays in Code nodes, not query expressions
const trace_chain_pg = `{${trace_chain.join(',')}}`;

// Validate before access
const event = $('Node').item?.json;
if (!event?.event_id) return { error: true, response: "❌ Missing data" };

// Always use snake_case for object keys
{ event_id: "...", clean_text: "...", user_id: "..." }
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

```
!!  → Activity only
..  → Note only
++  → Start chat thread
::  → Command
(none) → LLM classification → multi-extraction
```

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `n8n-push.sh` | Push local workflows to server |
| `n8n-pull.sh` | Pull workflows from server |
| `sanitize_workflows.sh` | Remove pinData (auto-run by hooks) |
| `validate_workflows.sh` | Check JSON syntax |
| `lint_workflows.py` | Check ctx pattern compliance |
| `inspect_workflow.py` | View nodes, search workflows |
| `run-migration.sh` | Run DB migrations with backup |
| `db-query.sh` | Run SQL on remote DB |

## Git Workflow

The pre-commit hook handles validation and sanitization automatically. Just commit normally:

```bash
git add n8n-workflows/
git commit -m "feat: add new workflow"
```

If the hook blocks your commit, it will tell you what's wrong.

## Commit Messages

```
feat: new feature
fix: bug fix
refactor: code restructuring
docs: documentation
chore: maintenance
```

## Troubleshooting

**Workflow not running:** Check if activated, check webhook URL, check `journalctl -u n8n -f`

**Data not flowing:** Check ctx object is preserved through all nodes, check Merge wrappers after native nodes

**SSH connection refused:** Server may rate-limit. Scripts batch operations to avoid this.
