# Simple Workflow Testing

Webhook-based testing for n8n workflows with database validation.

## Overview

The simplified testing framework validates workflows by:
1. **Send webhook payloads** to trigger workflows
2. **Validate database changes** (events, projections created)
3. **Test coverage tracking** via JSON payloads

## Usage

### Basic usage

```bash
# Test all workflows
bash scripts/simple-test.sh

# Test specific workflow
bash scripts/simple-test.sh Route_Message
```

### Before testing

Ensure:
1. n8n dev container is running: `docker ps | grep n8n-dev-local`
2. Workflows are deployed: `bash scripts/simple-deploy.sh dev`
3. Database is accessible: `docker exec postgres-dev-local psql -U n8n_user -d kairon -c "SELECT COUNT(*) FROM events"`

## Test Payload Format

Create test payloads in `n8n-workflows/tests/payloads/<WorkflowName>.json`:

```json
{
  "description": "Test Route_Message with activity tag",
  "webhook_data": {
    "event_type": "message",
    "content": "!! testing simplified deployment pipeline",
    "guild_id": "754207117157859388",
    "channel_id": "1453335033665556654",
    "message_id": "test-simple-deploy-001",
    "author": {
      "login": "test-user",
      "id": "123456789",
      "display_name": "Test User"
    },
    "timestamp": "2025-12-29T00:00:00Z"
  },
  "expected_db_changes": {
    "events_created": 1,
    "projections_created": 1
  }
}
```

### Payload Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | ✅ | Human-readable test description |
| `webhook_data` | object | ✅ | Discord webhook payload (same structure as real messages) |
| `expected_db_changes` | object | ✅ | Database validation criteria |

### expected_db_changes Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `events_created` | integer | ✅ | Expected number of events to be created |
| `projections_created` | integer | ✅ | Expected number of projections to be created |

## Coverage Strategy

### Phase 1: Critical workflows
- ✅ Route_Message

### Phase 2: High-impact workflows (next)
- Multi_Capture
- Execute_Command
- Save_Thread
- Continue_Thread
- Start_Thread

### Phase 3: Remaining workflows
- Handle_Correction
- Handle_Todo_Status
- Capture_Projection
- Generate_Daily_Summary
- Proactive_Pulse
- etc.

## Debugging Failed Tests

### Check database state
```bash
# Check recent events
docker exec postgres-dev-local psql -U n8n_user -d kairon -c "
  SELECT * FROM events ORDER BY received_at DESC LIMIT 5;
"

# Check recent projections
docker exec postgres-dev-local psql -U n8n_user -d kairon -c "
  SELECT * FROM projections ORDER BY created_at DESC LIMIT 5;
"
```

### Check n8n logs
```bash
docker logs -f n8n-dev-local
```

### Test webhook manually
```bash
curl -X POST http://localhost:5679/webhook/asoiaf3947 \
  -H "Content-Type: application/json" \
  -d '{"event_type":"message","content":"test","guild_id":"123","channel_id":"456","message_id":"789","author":{"login":"test"}}'
```

## Integration with deploy.sh

```bash
# Deploy then test (manual workflow)
bash scripts/simple-deploy.sh dev
bash scripts/simple-test.sh
```

## Comparison with Old Framework

| Aspect | Old Framework (regression_test.sh) | New Framework (simple-test.sh) |
|---------|-----------------------------------|------------------------------|
| **Lines of code** | 577 | 193 |
| **Complexity** | High (prod DB snapshots, complex setup) | Low (webhook + DB validation) |
| **Setup** | Required prod DB access | Works with local dev DB |
| **Maintenance** | Complex bash scripts | Simple JSON payloads |
| **Speed** | ~60s (with DB snapshot) | ~30s (no snapshot) |
| **Test payload format** | JSON array | Single JSON object |

## Creating Test Payloads

### Step 1: Identify test scenarios

For each workflow, consider:
- Main success paths
- Edge cases
- Error conditions

### Step 2: Find webhook data

Option A: **Copy from actual Discord message**
```bash
docker exec postgres-dev-local psql -U n8n_user -d kairon -c "
  SELECT payload->>'content', payload
  FROM events
  WHERE payload->>'tag' = '!!'
  LIMIT 1;
"
```

Option B: **Use existing test payloads** as reference
```bash
cat n8n-workflows/tests/payloads/Route_Message.json
```

### Step 3: Determine expected DB changes

Run the workflow manually and check what was created:
```bash
docker exec postgres-dev-local psql -U n8n_user -d kairon -c "
  SELECT projection_type, COUNT(*)
  FROM projections
  WHERE created_at > NOW() - INTERVAL '1 minute'
  GROUP BY projection_type;
"
```

### Step 4: Create payload file

```bash
mkdir -p n8n-workflows/tests/payloads
cat > n8n-workflows/tests/payloads/MyWorkflow.json <<'EOF'
{
  "description": "Test scenario 1",
  "webhook_data": { ... },
  "expected_db_changes": { ... }
}
EOF
```

## Continuous Improvement

### When bugs are found
1. Add failing test case to test payload
2. Fix bug
3. Test passes
4. Commit both fix and test

### When workflows are modified
1. Create/update test payload for modified workflow
2. Verify tests pass before deployment
3. Tests prevent future regressions

### Coverage growth
- Start with critical workflows
- Add tests as workflows are modified
- Build comprehensive coverage over time
