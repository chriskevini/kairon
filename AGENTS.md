# Agent Guidelines

Instructions for AI agents working on Kairon - a life-tracking system using n8n workflows + Discord.

## Quick Start

```bash
# Setup git hooks (one-time)
git config core.hooksPath .githooks

# Workflow development
./scripts/workflows/n8n-export.sh          # Pull changes from server
./scripts/workflows/n8n-sync.sh            # Push changes to server
./scripts/workflows/n8n-sync.sh --dry-run  # Preview what would sync

# The pre-commit hook automatically validates and sanitizes workflows
```

## Project Structure

```
n8n-workflows/       # Workflow JSON files (synced with server)
scripts/workflows/   # n8n-export.sh, n8n-sync.sh, sanitize, validate, lint
scripts/db/          # run-migration.sh, db-query.sh
db/migrations/       # SQL migrations
prompts/             # LLM prompts
discord_relay.py     # Discord bot that forwards to n8n
```

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

**Current architecture** (Migration 006+):
- `events` - Immutable event log
- `traces` - LLM reasoning chains  
- `projections` - Structured outputs (activities, notes, todos)
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
| `n8n-sync.sh` | Push local workflows to server |
| `n8n-export.sh` | Pull workflows from server |
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
