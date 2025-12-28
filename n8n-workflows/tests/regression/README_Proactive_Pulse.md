# Proactive_Pulse Testing

## Testing Status

✅ **Unit Tests** - Fully automated (32 tests)  
✅ **Regression Tests** - Fully automated (3 tests)  
✅ **Structural Validation** - Fully automated

## Regression Test Support

The regression test framework now supports custom webhook paths for schedule-trigger workflows. Tests are defined in `Proactive_Pulse.json`:

```json
{
  "test_name": "Test description",
  "webhook_path": "kairon-dev-test/Every5Minutes",  // Custom path for transformed schedule trigger
  "webhook_data": {},
  "expected_db_changes": {
    "events_created": 1,
    "projections_created": 1,
    "projection_types": ["pulse"]
  }
}
```

**How it works:**
1. `transform_for_dev.py` converts Schedule Trigger → Webhook with path `kairon-dev-test/{node_name}`
2. Test JSON specifies `webhook_path` to match transformed path
3. `regression_test.sh` uses custom path instead of default `WEBHOOK_PATH`

## Test Coverage

### ✅ Level 1: Unit Tests (Fully Automated)
**Location:** `n8n-workflows/tests/test_Proactive_Pulse.py`

**Coverage:** 32 comprehensive tests
- Workflow structure and node configuration  
- Both entry points (schedule + execute workflow)
- Cron path logic (CheckNextPulse, ShouldRunPulse, SetDefaultNextPulse)
- Event and context initialization
- Execute_Queries integration
- Context summary building
- Semantic selection and RAG integration
- LLM integration and response parsing
- Database operations (traces, projections)
- Discord integration
- All workflow connections
- Error handling configuration

**Runs automatically:**
- Pre-commit: Workflow validation
- Pre-push: Full unit test suite (32 tests)

**Run manually:**
```bash
pytest n8n-workflows/tests/test_Proactive_Pulse.py -v
```

**Status:** ✅ All 32 tests passing

### ✅ Level 2: Automated Regression Tests
**Location:** `n8n-workflows/tests/regression/Proactive_Pulse.json`

**Coverage:** 3 automated test scenarios
- Basic proactive pulse with cron trigger
- Custom trigger reason parameter
- Execute Workflow Trigger path

**Runs automatically:**
- Pre-push: Full regression test suite

**Run manually:**
```bash
bash scripts/testing/regression_test.sh --workflow Proactive_Pulse --verbose
```

**Status:** ✅ Fully automated with custom webhook path support

### ✅ Level 3: Structural Validation (Fully Automated)
**Location:** `scripts/validation/workflow_integrity.py`

Validates:
- No dead code (all nodes reachable)
- Proper connections
- Valid node configurations
- Execute_Queries integration

**Runs automatically:**
- Pre-commit: Basic structure
- Pre-push: Full integrity check

**Run manually:**
```bash
python3 scripts/validation/workflow_integrity.py n8n-workflows/Proactive_Pulse.json
```

## Deployment Pipeline

```
git push
  ↓
Pre-push Hook
  ↓
├─ ✅ Stage 0: Unit tests (32 tests) ← PASSES
├─ ✅ Stage 1: Dev deployment ← PASSES
├─ ✅ Stage 2: Regression tests (3 tests) ← PASSES
└─ ✅ Stage 3: Production deployment ← PROCEEDS
```

## Manual Testing (Optional)

If you want to manually test the workflow:

```bash
# 1. Ensure dev environment is running
docker-compose -f docker-compose.dev.yml up -d

# 2. Invoke the transformed webhook (schedule trigger → webhook)
curl -X POST http://localhost:5679/webhook/kairon-dev-test/Every5Minutes \
  -H 'Content-Type: application/json' \
  -d '{}'

# 3. Check execution in n8n UI: http://localhost:5679/executions

# 4. Verify database changes
docker exec postgres-dev-local psql -U n8n_user -d kairon -c \
  "SELECT * FROM events WHERE event_type = 'system' ORDER BY received_at DESC LIMIT 1"
```

## Why This Approach is Safe

1. **Comprehensive Unit Tests** - 32 tests cover all critical paths
2. **Automated Regression Tests** - 3 tests validate end-to-end behavior
3. **Structural Validation** - Catches dead code and misconfigurations
4. **Transform Script** - Proven pattern used by other workflows
5. **Production Monitoring** - Can detect issues post-deployment

## Previous Deployments

- ✅ Initial deployment (commit d0d188a) - Successful
- ✅ Refactor with Execute_Queries pattern - Validated
- ✅ RAG and semantic selection added - Tested
- ✅ Unit test suite created (32 tests) - Passing
