# Phase 5: Enhanced Integration Testing

## Overview

This phase enhances the integration testing capabilities of `test-all-paths.sh` by adding comprehensive database verification that confirms messages aren't just sent, but actually processed by workflows.

## Problem Solved

**Before:** test-all-paths.sh only verified that HTTP requests succeeded (200 OK responses). It couldn't tell if:
- Events were actually stored in the database
- Workflows processed the events
- Data extraction (projections) occurred

**After:** Complete end-to-end verification with:
- Event storage confirmation
- Workflow processing traces
- Data projection creation
- Detailed failure diagnostics

## Changes Made

### Enhanced Database Verification

**File:** `tools/test-all-paths.sh`

**New `verify_database_processing()` function:**
- Polls database for up to 30 seconds waiting for async processing
- Checks multiple stages of the pipeline:
  1. **Events stored** - Confirms webhook reached n8n and created event records
  2. **Traces created** - Confirms workflows ran and created LLM traces
  3. **Projections created** - Confirms data was extracted and structured

- Clear, color-coded output showing what passed/failed
- Helpful diagnostics when things fail

## Usage

### Basic Testing (No DB Verification)

```bash
# Quick test - just verify webhooks respond
./tools/test-all-paths.sh --quick

# Full test suite
./tools/test-all-paths.sh
```

### With Database Verification

```bash
# Test and verify database processing (dev environment)
./tools/test-all-paths.sh --dev --verify-db

# Test and verify database processing (prod environment)
./tools/test-all-paths.sh --verify-db
```

### Example Output

```
=== Database Verification ===
Waiting for async processing (30s timeout)...

  ✓ Found 15 / 15 test events in database
  ✓ 15 events processed by workflows (have traces)
  ✓ 12 events created projections

  ✓ All test events successfully processed
```

### Failure Example

```
=== Database Verification ===
Waiting for async processing (30s timeout)...

  ✗ No test events found in database
     Tip: n8n may be down or webhook not reachable
```

## Verification Stages

### Stage 1: Event Storage
Checks if events were received and stored:
```sql
SELECT COUNT(*) FROM events 
WHERE (idempotency_key LIKE 'test-msg-%' OR payload->>'discord_message_id' LIKE 'test-msg-%')
AND received_at > NOW() - INTERVAL '5 minutes'
```

### Stage 2: Workflow Processing (Traces)
Checks if workflows ran and created LLM traces:
```sql
SELECT COUNT(DISTINCT t.event_id) FROM traces t 
JOIN events e ON e.id = t.event_id
WHERE (e.idempotency_key LIKE 'test-msg-%' OR e.payload->>'discord_message_id' LIKE 'test-msg-%')
AND e.received_at > NOW() - INTERVAL '5 minutes'
```

### Stage 3: Data Extraction (Projections)
Checks if data was extracted into structured projections:
```sql
SELECT COUNT(DISTINCT p.trace_id) FROM projections p 
JOIN traces t ON t.id = p.trace_id 
JOIN events e ON e.id = t.event_id
WHERE (e.idempotency_key LIKE 'test-msg-%' OR e.payload->>'discord_message_id' LIKE 'test-msg-%')
AND e.received_at > NOW() - INTERVAL '5 minutes'
```

## Integration with Other Tools

### In CI/CD Pipeline

```bash
#!/bin/bash
# Deploy and verify

# Deploy to dev
./scripts/deploy.sh dev

# Run integration tests with DB verification
./tools/test-all-paths.sh --dev --verify-db || {
    echo "Integration tests failed!"
    exit 1
}

# Deploy to prod only if tests pass
./scripts/deploy.sh prod
```

### Manual Testing Workflow

```bash
# 1. Make changes to workflows
vim n8n-workflows/Route_Event.json

# 2. Deploy to dev
./scripts/deploy.sh dev

# 3. Test with DB verification
./tools/test-all-paths.sh --dev --verify-db

# 4. Check specific events if needed
./tools/kairon-ops.sh --dev db-query "
  SELECT event_type, clean_text, received_at 
  FROM events 
  WHERE idempotency_key LIKE 'test-msg-%' 
  ORDER BY received_at DESC 
  LIMIT 10
"

# 5. Deploy to prod when confident
./scripts/deploy.sh prod
```

## Dependencies

- Requires Phase 1 (kairon-ops.sh with --dev support)
- Requires Phase 4 (kairon-credentials.sh for database access)
- Uses `rdev db` for dev environment
- Uses `kairon-ops.sh db-query` for prod environment

## Benefits

1. **Confidence** - Know for certain that workflows are processing correctly
2. **Fast Debugging** - Immediately see where the pipeline breaks
3. **Regression Prevention** - Catch processing failures before they reach prod
4. **Complete Coverage** - Verify full event lifecycle, not just HTTP success
5. **Async-Aware** - Properly waits for async processing to complete

## Testing

```bash
# Test basic verification (requires dev n8n running)
./tools/test-all-paths.sh --dev --verify-db --quick

# Test full suite with verification
./tools/test-all-paths.sh --dev --verify-db

# Test failure handling (with n8n stopped)
docker stop n8n-dev
./tools/test-all-paths.sh --dev --verify-db  # Should show clear error
docker start n8n-dev
```

## Troubleshooting

### "No test events found in database"

**Possible causes:**
1. n8n not running: `./tools/kairon-ops.sh --dev status`
2. Webhook URL wrong: Check `WEBHOOK` in script or `.env`
3. Database not accessible: Test with `rdev db "SELECT COUNT(*) FROM events"`

### "No workflow traces found"

**Possible causes:**
1. Workflows not processing events correctly
2. Check n8n executions: Visit n8n UI → Executions tab
3. Check for workflow errors: `./tools/kairon-ops.sh --dev n8n-list`

### "Some events not fully processed"

**Possible causes:**
1. Some workflows may have failed
2. Async processing still ongoing (rare - timeout is 30s)
3. Check specific events: Query events and traces tables directly

## Future Enhancements

Potential additions for future phases:
- Execution status checking via n8n API
- Automatic error log collection on failure
- Performance metrics (processing time)
- Detailed per-workflow verification
- Integration with monitoring/alerting systems
