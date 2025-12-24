# Onboarding: n8n Workflow Production Fix

**Date:** 2025-12-24
**Status:** In Progress - Critical Production Issue
**Environment:** Remote DigitalOcean server accessed via SSH

## Executive Summary

Production n8n workflows stopped saving data to PostgreSQL. Events are being logged, but **traces and projections are not being created**. The workflows execute successfully (status: "success") but database INSERTs are silently failing.

## Architecture Overview

```
Discord Message
      │
      ▼
┌─────────────────┐
│ discord_relay.py│  (Python bot on server)
└────────┬────────┘
         │ HTTP POST
         ▼
┌─────────────────┐
│  Route_Event    │  (n8n webhook entry point)
│  - Stores event │
│  - Initializes  │
│    ctx.event    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Route_Message  │  (Determines intent by tag)
│  - :: commands  │
│  - !! activity  │
│  - (none) = LLM │
└────────┬────────┘
         │ (untagged messages)
         ▼
┌─────────────────┐
│  Multi_Capture  │  (LLM extraction)
│  - Calls LLM    │
│  - Parses JSON  │
│  - Builds SQL   │
└────────┬────────┘
         │ ctx.db_queries
         ▼
┌─────────────────┐
│ Execute_Queries │  (SQL execution sub-workflow)
│  - Loops queries│
│  - Returns ctx  │
│    with results │
└─────────────────┘
         │
         ▼
    PostgreSQL
    (traces, projections tables)
```

## The Problem

### Symptoms
1. Discord messages are received and events are stored in `events` table ✅
2. n8n workflows execute with status "success" ✅
3. **No traces are created in `traces` table** ❌
4. **No projections are created in `projections` table** ❌
5. Commands like `::ping` work (they don't use Execute_Queries)

### Root Cause: n8n Code Node v2 Breaking Changes

n8n updated their Code node to v2, which introduced strict mode restrictions:

**In `runOnceForEachItem` mode, these are NO LONGER ALLOWED:**
- `$input.first()`, `$input.last()`, `$input.all()`
- `$('NodeName').first()`, `$('NodeName').last()`, `$('NodeName').all()`
- `$('NodeName').item`
- Returning arrays (must return single object)

**The fix pattern:**
```javascript
// OLD (broken in runOnceForEachItem mode)
const data = $('PreviousNode').first().json;
return { json: { ... } };

// FIX: Change mode to runOnceForAllItems
// and wrap return in array
const data = $('PreviousNode').first().json;
return [{ json: { ... } }];
```

### Secondary Issue: Postgres Node Parameter Name

The Postgres node v2.4 changed the parameter name:
- **Old:** `queryReplacement`
- **New:** `values`

This may be causing SQL parameters to not bind correctly.

## What Has Been Fixed

### 1. Route_Event.json
**Nodes fixed:**
- `Initialize Message Context` - Changed to `runOnceForAllItems`, wrapped return in `[]`
- `Initialize Reaction Context` - Changed to `runOnceForAllItems`, wrapped return in `[]`

**Deployed:** Yes ✅

### 2. Multi_Capture.json
**Nodes fixed:**
- `ParseResponse` - Changed to `runOnceForAllItems`, wrapped return in `[]`
- `SplitCaptures` - Changed to `runOnceForAllItems` (returns array intentionally)
- `CollectResults` - Changed to `runOnceForAllItems`, wrapped return in `[]`
- `PrepareEmojiItems` - Changed to `runOnceForAllItems` (returns array intentionally)
- `MergeCtxForVerbose` - Changed to `runOnceForAllItems`, wrapped return in `[]`
- `BuildEmbeddingQuery` - Changed to `runOnceForAllItems`, wrapped return in `[]`

**Deployed:** Yes ✅

### 3. Execute_Queries.json
**Change made:**
- Changed Postgres node `options.queryReplacement` to `options.values`

**Deployed:** NO - This is the next step ❌

## Current Hypothesis

The Execute_Queries workflow is receiving the correct `ctx.db_queries` array, but the Postgres node is not binding the parameters correctly because it's using the deprecated `queryReplacement` option instead of `values`.

**Evidence:**
- Workflows show "success" status
- Manual SQL inserts work fine
- No errors in n8n logs
- The LLM is returning valid JSON (visible in execution data)

## Remote Access Details

### SSH Connection
```bash
# Server alias (from ~/.ssh/config)
ssh DigitalOcean

# IP: 164.92.84.170
# User: ubuntu (or configured user)
```

### SSH Rate Limiting Issue
The server rate-limits SSH connections. Use ControlMaster to avoid this:

```bash
# Helper script that manages ControlMaster
./scripts/remote.sh status    # Check n8n executions
./scripts/remote.sh logs 5    # Last 5 min of logs
./scripts/remote.sh deploy <file>  # Deploy workflow (has issues, see below)
```

### n8n API Access
```bash
N8N_API_KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIyYTg1MWEyZC1iN2U1LTRiM2MtYWVmYi02ZWFhYTc5ZTA2NTkiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwiaWF0IjoxNzY2NDgyMTA4fQ.RXx1C0vabBntIpSp0olFU9qWlQvnY_Ouw5znKVn8dtE'

# List workflows
curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" 'http://localhost:5678/api/v1/workflows' | jq '.data[] | {id, name}'

# Get specific workflow
curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" 'http://localhost:5678/api/v1/workflows/<ID>'

# Update workflow (MUST use minimal JSON - see below)
curl -s -X PUT -H 'Content-Type: application/json' -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -d @/tmp/deploy_workflow.json 'http://localhost:5678/api/v1/workflows/<ID>'

# Activate workflow
curl -s -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" \
  'http://localhost:5678/api/v1/workflows/<ID>/activate'
```

### Database Access
```bash
# Kairon database (application data)
ssh DigitalOcean "source ~/kairon/.env && docker exec postgres-db psql -U \$DB_USER -d \$DB_NAME -c '<SQL>'"

# n8n database (execution history)
ssh DigitalOcean "docker exec postgres-db psql -U n8n_user -d n8n_chat_memory -c '<SQL>'"
```

### Workflow IDs on Production
| Workflow | ID |
|----------|-----|
| Route_Event | IdpHzWCchShvArHM |
| Route_Message | G0XzfbZiT3P98B4S |
| Multi_Capture | DX0m48INGS7vEwbu |
| Execute_Queries | CgUAxK0i4YhrZ2Wp |

## Deployment Gotchas

### 1. n8n API Rejects Extra Fields
The PUT endpoint rejects workflows with extra fields. Must strip to minimal:

```bash
# Create minimal JSON for deployment
jq '{name, nodes, connections, settings}' workflow.json > /tmp/minimal_workflow.json
scp /tmp/minimal_workflow.json DigitalOcean:/tmp/deploy_workflow.json

# Then update via API on server
ssh DigitalOcean "curl -s -X PUT ... -d @/tmp/deploy_workflow.json ..."
```

### 2. Workflow IDs Differ Between Environments
Local JSON files have different IDs than production. Always query the API for the correct ID:

```bash
curl -s -H "X-N8N-API-KEY: $KEY" 'http://localhost:5678/api/v1/workflows' | \
  jq '.data[] | select(.name=="Execute_Queries") | .id'
```

### 3. Sub-workflow References
Execute Workflow nodes reference sub-workflows by ID. These IDs are different in prod vs dev. The deploy.sh script handles remapping, but manual deploys don't.

## Testing

### Send Test Message via curl
```bash
curl -s -X POST "https://n8n.chrisirineo.com/webhook/asoiaf92746087" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message",
    "guild_id": "1234567890",
    "channel_id": "1234567890",
    "message_id": "test-'$(date +%s)'",
    "author": {"login": "test_user", "id": "123456", "display_name": "Test User"},
    "content": "working on a coding project",
    "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'"
  }'
```

### Verify Database State
```bash
# Check recent events (should see test message)
SELECT id, idempotency_key, received_at FROM events 
WHERE received_at > NOW() - INTERVAL '10 minutes' ORDER BY received_at DESC;

# Check traces (SHOULD have entries but currently EMPTY)
SELECT id, step_name, created_at FROM traces 
WHERE created_at > NOW() - INTERVAL '10 minutes';

# Check projections (SHOULD have entries but currently EMPTY)
SELECT id, projection_type, created_at FROM projections 
WHERE created_at > NOW() - INTERVAL '10 minutes';
```

### Check n8n Execution Status
```bash
./scripts/remote.sh status
# Or directly:
ssh DigitalOcean "docker exec postgres-db psql -U n8n_user -d n8n_chat_memory -c \"
  SELECT e.id, w.name, e.status, e.mode, e.\\\"startedAt\\\"
  FROM execution_entity e
  JOIN workflow_entity w ON e.\\\"workflowId\\\" = w.id
  ORDER BY e.id DESC LIMIT 15;\""
```

## Next Steps

1. **Deploy Execute_Queries.json** with `values` instead of `queryReplacement`
   ```bash
   cd /home/chris/Work/kairon
   jq '{name, nodes, connections, settings}' n8n-workflows/Execute_Queries.json > /tmp/minimal_workflow.json
   scp /tmp/minimal_workflow.json DigitalOcean:/tmp/deploy_workflow.json
   # Then update via API with ID: CgUAxK0i4YhrZ2Wp
   ```

2. **Test with curl** - Send a test message and verify traces/projections are created

3. **If still failing**, add debug logging to Execute_Queries to see what SQL/params are being received

4. **Commit all fixes** once verified working

## Files Modified (Not Yet Committed)

```
n8n-workflows/Route_Event.json      # Fixed Initialize Context nodes
n8n-workflows/Multi_Capture.json    # Fixed 6 Code nodes
n8n-workflows/Execute_Queries.json  # Changed queryReplacement -> values
scripts/remote.sh                   # New SSH helper (untracked)
```

## Key Patterns in Codebase

### The ctx Pattern
All workflows pass a `ctx` object containing event data and query results:

```javascript
{
  ctx: {
    event: {
      event_id: "uuid",
      clean_text: "message content",
      trace_chain: ["uuid"],
      // ... more fields
    },
    db_queries: [{
      key: "trace",
      sql: "INSERT INTO traces ... RETURNING id",
      params: [param1, param2, ...]
    }],
    db: {
      // Results from Execute_Queries
      trace: { row: {...}, rows: [...], count: 1 }
    }
  }
}
```

### Execute_Queries Flow
1. Receives `ctx.db_queries` array
2. Loops through each query
3. Resolves `$results.key.field` references for chaining
4. Executes via Postgres node
5. Stores results in `ctx.db[key]`
6. Returns updated ctx

## Contact

- **Webhook URL:** https://n8n.chrisirineo.com/webhook/asoiaf92746087
- **n8n UI:** https://n8n.chrisirineo.com (requires login)
- **Server:** DigitalOcean (SSH alias: DigitalOcean)
