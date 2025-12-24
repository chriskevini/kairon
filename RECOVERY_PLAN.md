# Production Recovery Plan

## Current State
- Webhook executions failing in prod
- Root cause: Code nodes using `$input.first()` in `runOnceForEachItem` mode
- Multiple failed fix attempts have created uncertainty about actual prod state

## Strategy
1. No tests, no dev environment
2. One workflow at a time
3. Direct SSH deployment
4. Verify each step before proceeding

## Phase 1: Establish Baseline

### Step 1.1: Get actual prod workflow state
```bash
ssh DigitalOcean 'cd ~/n8n-export && rm -f *.json'
ssh DigitalOcean 'curl -s -H "X-N8N-API-KEY: $(grep N8N_API_KEY ~/.env | cut -d= -f2)" \
  "http://localhost:5678/api/v1/workflows" | jq -r ".data[].name"'
```

### Step 1.2: Export Route_Event from prod
```bash
ssh DigitalOcean 'curl -s -H "X-N8N-API-KEY: $(grep N8N_API_KEY ~/.env | cut -d= -f2)" \
  "http://localhost:5678/api/v1/workflows" | \
  jq -r ".data[] | select(.name==\"Route_Event\") | .id"'
# Use that ID to export
```

### Step 1.3: Check current execution status
```bash
ssh DigitalOcean 'docker exec postgres-db psql -U n8n_user -d n8n_chat_memory -c "
SELECT status, mode, COUNT(*) 
FROM execution_entity 
WHERE \"stoppedAt\" > NOW() - INTERVAL '\''1 hour'\''
GROUP BY status, mode;"'
```

## Phase 2: Fix Route_Event Only

Route_Event is the entry point. Fix it first, verify it works, then proceed.

### Step 2.1: Identify the exact problematic nodes
The issue is in "Initialize Message Context" and "Initialize Reaction Context":
- They use `$input.first().json` which is NOT allowed in `runOnceForEachItem` mode
- They use `$('NodeName').item.json` which is NOT allowed

### Step 2.2: The fix
Change these nodes to NOT use `runOnceForEachItem` mode. Remove the `"mode": "runOnceForEachItem"` parameter (default is `runOnceForAllItems`).

Then adjust the code:
- Keep `$input.first().json` (allowed in default mode)
- Change `$('NodeName').item.json` to `$('NodeName').first().json`
- Change `return {json:...}` to `return [{json:...}]`

### Step 2.3: Create minimal fixed version locally
Edit `n8n-workflows/Route_Event.json` with ONLY the necessary fixes.

### Step 2.4: Deploy just Route_Event
```bash
# Get workflow ID
WF_ID=$(ssh DigitalOcean 'curl -s -H "X-N8N-API-KEY: $(grep N8N_API_KEY ~/.env | cut -d= -f2)" \
  "http://localhost:5678/api/v1/workflows" | jq -r ".data[] | select(.name==\"Route_Event\") | .id"')

# Upload fixed workflow
scp n8n-workflows/Route_Event.json DigitalOcean:/tmp/
ssh DigitalOcean "curl -X PUT -H 'Content-Type: application/json' \
  -H 'X-N8N-API-KEY: \$(grep N8N_API_KEY ~/.env | cut -d= -f2)' \
  -d @/tmp/Route_Event.json \
  'http://localhost:5678/api/v1/workflows/$WF_ID'"
```

### Step 2.5: Activate and test
```bash
# Activate
ssh DigitalOcean "curl -X POST -H 'X-N8N-API-KEY: \$(grep N8N_API_KEY ~/.env | cut -d= -f2)' \
  'http://localhost:5678/api/v1/workflows/$WF_ID/activate'"

# Watch logs
ssh DigitalOcean 'docker logs -f --since 1m n8n-docker-caddy-n8n-1 2>&1'
```

### Step 2.6: Send test message via Discord
Send a simple message like "test" and watch the logs.

### Step 2.7: Verify execution succeeded
```bash
ssh DigitalOcean 'docker exec postgres-db psql -U n8n_user -d n8n_chat_memory -c "
SELECT id, status, mode FROM execution_entity ORDER BY id DESC LIMIT 5;"'
```

## Phase 3: Fix Downstream Workflows (only if Phase 2 succeeds)

Once Route_Event works, fix these one at a time in order:
1. Route_Message (called by Route_Event for messages)
2. Multi_Capture (called by Route_Message for untagged messages)
3. Execute_Queries (utility, called by many)

Same process for each:
1. Export current from prod
2. Identify Code nodes with `runOnceForEachItem` + disallowed patterns
3. Fix locally
4. Deploy single workflow
5. Test
6. Proceed to next

## Success Criteria
- Route_Event webhook executions show `status: success`
- Messages sent to Discord create traces and projections in the database

## Rollback
If things get worse, the workflows were working before the n8n upgrade. The issue is the Code node behavior change. We could:
1. Downgrade n8n
2. Or continue fixing workflows one by one

## Notes
- Don't use deploy.sh - it does too much
- Don't use smoke tests - they're broken
- Don't batch changes - one workflow at a time
- Verify at each step before proceeding
