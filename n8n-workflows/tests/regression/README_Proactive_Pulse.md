# Proactive_Pulse Testing

## Testing Approach

Proactive_Pulse uses **standard webhook-based regression testing**. The Schedule Trigger is automatically converted to a Webhook Trigger by `transform_for_dev.py` during testing.

## Entry Points

### Production
1. **Schedule Trigger** (`Every5Minutes`) - Cron execution every 5 minutes
2. **Execute Workflow Trigger** (`WhenCalledByAnotherWorkflow`) - Called by other workflows

### Testing (Automated Transformation)
- **Schedule Trigger → Webhook Trigger** - The `transform_for_dev.py` script automatically converts the schedule trigger to a webhook for regression testing
- **Path:** `kairon-dev-test/Every5Minutes`
- **Benefit:** Deterministic testing without waiting for cron schedule

## Test Coverage

### ✅ Level 1: Unit Tests (Automated)
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

**Run tests:**
```bash
pytest n8n-workflows/tests/test_Proactive_Pulse.py -v
```

**Status:** ✅ All 32 tests passing

### ✅ Level 2: Regression Tests (Automated)
**Location:** `n8n-workflows/tests/regression/Proactive_Pulse.json`

**Test Scenarios:**
1. **Schedule trigger transformed to webhook (default)** - Empty body, defaults to `trigger_reason: "cron"`
2. **Schedule trigger with explicit trigger_reason** - Override with `trigger_reason: "test"`
3. **Verify pulse message generation** - End-to-end LLM, RAG, semantic selection, Discord

**Run tests:**
```bash
# Test Proactive_Pulse specifically
bash scripts/testing/regression_test.sh --workflow Proactive_Pulse

# Or as part of deployment pipeline
./scripts/deploy.sh
```

Each test validates:
- 1 system event created (event_type='system')
- 1 pulse projection created (projection_type='pulse')
- Trace created with LLM data
- Discord message posted (mocked in dev)
- next_pulse config updated

### ✅ Level 3: Structural Validation (Automated)
**Location:** `scripts/validation/workflow_integrity.py`

Validates:
- No dead code (all nodes reachable)
- Proper connections
- Valid node configurations
- Execute_Queries integration

**Run validation:**
```bash
python3 scripts/validation/workflow_integrity.py n8n-workflows/Proactive_Pulse.json
```

## Deployment Validation Checklist

### Pre-Deployment
- [ ] Run unit tests: `pytest n8n-workflows/tests/test_Proactive_Pulse.py -v`
- [ ] Validate structure: `python3 scripts/validation/workflow_integrity.py n8n-workflows/Proactive_Pulse.json`
- [ ] Run regression tests: `bash scripts/testing/regression_test.sh --workflow Proactive_Pulse`

### Post-Deployment
- [ ] Monitor execution: `python3 scripts/workflows/inspect_execution.py --workflow Proactive_Pulse --limit 5`
- [ ] Check database: `./tools/kairon-ops.sh db-query "SELECT * FROM projections WHERE projection_type = 'pulse' ORDER BY created_at DESC LIMIT 5"`
- [ ] Verify Discord messages in #arcane-shell
- [ ] Check next_pulse config: `./tools/kairon-ops.sh db-query "SELECT * FROM config WHERE key = 'next_pulse'"`

### Ongoing Monitoring
- [ ] Check failed executions: `python3 scripts/workflows/inspect_execution.py --workflow Proactive_Pulse --failed`
- [ ] Monitor pulse frequency: Daily pulses based on next_pulse timing
- [ ] Track LLM performance in traces

## Architecture

### Transform Script Magic

The `transform_for_dev.py` script handles the conversion automatically:

```python
# Schedule Trigger → Webhook Trigger (ALWAYS - for testing)
if node_type == "n8n-nodes-base.scheduleTrigger":
    node["type"] = "n8n-nodes-base.webhook"
    node["parameters"] = {
        "httpMethod": "POST",
        "path": f"kairon-dev-test/{node.get('name', 'workflow')}",
        "responseMode": "onReceived",
    }
```

This means:
- **Production:** Schedule trigger runs every 5 minutes
- **Testing:** Webhook trigger can be invoked on-demand
- **No code changes needed:** Same workflow JSON works in both environments

### Entry Point Flow

```
Production:
  Every5Minutes (Schedule) → CheckNextPulse → ShouldRunPulse? → ...

Testing (Transformed):
  Every5Minutes (Webhook) → CheckNextPulse → ShouldRunPulse? → ...
                                                (always runs in tests)
```

## Key Features

1. **Idempotency** - Uses `scheduled:proactive:YYYY-MM-DDTHH:MM:${trigger_reason}` keys
2. **Advisory Lock** - Prevents concurrent executions via `pg_advisory_xact_lock`
3. **Semantic Selection** - Chooses relevant techniques via embedding service
4. **RAG** - Retrieves similar projections using pgvector
5. **Empty Message Handling** - Skips Discord posting if LLM generates empty message

## Benefits of This Approach

✅ **Standard Testing** - Uses the same regression framework as other workflows
✅ **No Manual Testing** - Fully automated
✅ **Deterministic** - No waiting for cron schedules
✅ **Fast** - Runs in seconds, not minutes
✅ **Production-Safe** - Transform only affects dev environment

## Previous Deployments

- ✅ Initial deployment (commit d0d188a) - Successful
- ✅ Refactor with Execute_Queries pattern - Validated
- ✅ RAG and semantic selection added - Tested
- ✅ Standard regression testing enabled - Current
