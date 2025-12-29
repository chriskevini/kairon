# Regression Testing Framework

Replaces the broken `test-all-paths.sh` with focused testing of modified workflows against production-like data.

## Concept

1. **Snapshot prod DB to dev** - Copy real production data
2. **Identify modified workflows** - Only test what changed
3. **Run test payloads** - Execute workflows with defined inputs
4. **Validate execution + DB** - Check both status and database state
5. **Auto-cleanup** - Restore dev DB after tests

## Usage

### In deployment pipeline (automatic)

```bash
./scripts/deploy.sh
# Stage 0: Unit tests
# Stage 1: Dev deployment
# Stage 2: Regression tests (only modified workflows)
# Stage 3: Prod deployment
```

### Manual testing

```bash
# Test all workflows with test payloads
bash scripts/testing/regression_test.sh --all

# Test specific workflow
bash scripts/testing/regression_test.sh --workflow Multi_Capture

# Test modified workflows (default behavior)
bash scripts/testing/regression_test.sh

# Skip DB snapshot (use existing dev data)
bash scripts/testing/regression_test.sh --no-db-snapshot

# Keep DB after tests (for debugging)
bash scripts/testing/regression_test.sh --keep-db

# Verbose output
bash scripts/testing/regression_test.sh --verbose
```

## Test Payload Format

Create test payloads in `n8n-workflows/tests/regression/<WorkflowName>.json`:

```json
[
  {
    "test_name": "Human-readable description",
    "webhook_data": {
      "event_type": "message",
      "content": "!! debugging issues",
      "guild_id": "754207117157859388",
      "channel_id": "1453335033665556654",
      "message_id": "test-unique-id",
      "author": {
        "login": "test-user",
        "id": "123456789",
        "display_name": "Test User"
      },
      "timestamp": "2025-12-27T10:00:00Z"
    },
    "expected_db_changes": {
      "events_created": 1,
      "projections_created": 1,
      "projection_types": ["activity"]
    }
  }
]
```

### Payload Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `test_name` | string | ✅ | Human-readable test description |
| `webhook_data` | object | ✅ | Discord webhook payload (same structure as real messages) |
| `expected_db_changes` | object | ✅ | Database validation criteria |

### expected_db_changes Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `events_created` | integer | ✅ | Expected number of events to be created |
| `projections_created` | integer | ✅ | Expected number of projections to be created |
| `projection_types` | array | ❌ | Expected projection types (e.g., `["activity", "note"]`) |

## Creating Test Payloads

### Step 1: Identify test scenarios

For each workflow, consider:
- Main success paths
- Edge cases
- Error conditions

### Step 2: Find webhook data

Option A: **Copy from actual Discord message** (recommended)
```bash
# Query database for recent message
./tools/kairon-ops.sh db-query "
  SELECT payload->>'content', payload
  FROM events
  WHERE payload->>'tag' = '\$\$'
  LIMIT 1;
"
```

Option B: **Use existing tests** as reference
```bash
grep -A 20 "Cmd: help" tools/test-all-paths.sh
```

### Step 3: Determine expected DB changes

Run the workflow manually and check what was created:
```bash
# Uses DB_USER and DB_NAME from .env (defaults: n8n_user/kairon)
docker exec postgres-local psql -U n8n_user -d kairon -c "
  SELECT projection_type, COUNT(*)
  FROM projections
  WHERE created_at > NOW() - INTERVAL '1 minute'
  GROUP BY projection_type;
"
```

### Step 4: Create payload file

```bash
mkdir -p n8n-workflows/tests/regression
cat > n8n-workflows/tests/regression/MyWorkflow.json <<'EOF'
[
  {
    "test_name": "Test scenario 1",
    "webhook_data": { ... },
    "expected_db_changes": { ... }
  }
]
EOF
```

## Coverage Strategy

### Phase 1: Critical workflows (done)
- ✅ Multi_Capture
- ✅ Execute_Command
- ✅ Route_Message

### Phase 2: High-impact workflows (next)
- Save_Thread
- Continue_Thread
- Start_Thread
- Handle_Correction

### Phase 3: Remaining workflows
- Handle_Todo_Status
- Capture_Projection
- Generate_Daily_Summary
- Proactive_Pulse
- etc.

## Workflow Coverage Checklist

Track test coverage per workflow:

**Multi_Capture**
- ✅ Activity with !! tag
- ✅ Note with .. tag
- ✅ Todo with $$ tag
- ✅ Untagged message (LLM extraction)
- ✅ Activity alias with space

**Execute_Command**
- ✅ Command: ::help
- ✅ Command: ::recent
- ✅ Command: ::stats
- ✅ Command: ::set timezone
- ✅ Command: ::ping

**Route_Message**
- ✅ Route message with activity tag
- ✅ Route untagged message
- ✅ Route command

## Debugging Failed Tests

### View execution in n8n UI
```bash
# Test will show execution ID in output
# View: http://localhost:5679/execution/<id>
```

### Check database state
```bash
docker exec postgres-local psql -U postgres -d kairon -c "
  SELECT * FROM events ORDER BY received_at DESC LIMIT 5;
"

docker exec postgres-local psql -U postgres -d kairon -c "
  SELECT * FROM projections ORDER BY created_at DESC LIMIT 5;
"
```

### Re-run single test with verbose output
```bash
bash scripts/testing/regression_test.sh \
  --workflow Multi_Capture \
  --verbose \
  --keep-db
```

## Advantages Over test-all-paths.sh

| Aspect | test-all-paths.sh | Regression Tests |
|---------|-------------------|-----------------|
| **Tests all workflows** | ✅ Every time | ❌ Only modified |
| **DB validation** | ❌ HTTP only | ✅ State verification |
| **Real data** | ❌ Mocks | ✅ Prod DB snapshot |
| **Maintenance** | ❌ Modify script | ✅ Add JSON files |
| **Speed** | ❌ ~5 min | ✅ ~1 min (targeted) |
| **Bug detection** | ⚠️ Basic | ✅ Comprehensive |

## Integration with deploy.sh

Regression tests are integrated as Stage 2 in `scripts/deploy.sh`:

```bash
# Stage 2: Regression tests
echo "  Stage 2: Regression tests with prod DB snapshot..."
if ! bash "$REPO_ROOT/scripts/testing/regression_test.sh" --no-db-snapshot; then
    echo "❌ FAILED (regression tests)"
    return 1
fi
echo "  ✅ PASSED (regression tests)"
```

Note: `--no-db-snapshot` is used by default in deploy.sh to:
- Avoid slow DB restore on every deploy
- Rely on dev DB having reasonable test data
- Can be overridden with manual testing

## Environment Variables

Required in `.env`:
```bash
# For dev testing
N8N_DEV_API_URL=http://localhost:5679
WEBHOOK_PATH=asoiaf3947  # Dev webhook path (prod: asoiaf92746087)
N8N_DEV_SSH_HOST=DigitalOcean  # Optional: for remote prod DB access

# For prod DB snapshot (optional)
CONTAINER_DB=postgres-db
DB_USER=n8n_user
DB_NAME=kairon
```

## Continuous Improvement

### When bugs are found
1. Add failing test case to regression payload
2. Fix bug
3. Test passes
4. Commit both fix and test

### When workflows are modified
1. Create/update regression tests for modified workflow
2. Verify tests pass before deployment
3. Tests prevent future regressions

### Coverage growth
- Start with critical workflows
- Add tests as workflows are modified
- Build comprehensive coverage over time

## FAQ

**Q: What if no workflows are modified?**  
A: Regression tests skip (exit 0). Unit tests and dev deploy still run.

**Q: What about cross-workflow bugs?**  
A: Include downstream workflows in test payloads. Phase 1 focuses on single-workflow regressions.

**Q: How long does testing take?**  
A: Typical deployment (1-2 workflows modified): ~60 seconds total.

**Q: Can I use prod DB snapshot?**  
A: Yes, remove `--no-db-snapshot` flag. Takes ~30 seconds extra for DB restore.

**Q: What if test payload doesn't exist for modified workflow?**  
A: Test is skipped with warning. No deployment failure.

## Migration from test-all-paths.sh

The old `test-all-paths.sh` has been retired due to:
- Broken jq parsing (issue #118)
- Unmaintainable structure
- No DB validation
- Slow execution

Regression testing replaces it with a maintainable, working approach.
