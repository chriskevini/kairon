# n8n Workflow Testing Guide

This document describes the multi-layered testing approach for n8n workflows.

## Overview

Kairon uses a comprehensive testing strategy:

1. **Level 1: Fast Pre-commit Checks** - JSON syntax, basic properties
2. **Level 2: Structural Validation** - Node properties, ctx patterns, ExecuteWorkflow configuration
3. **Level 2b: Workflow Integrity** - Dead code detection, misconfigured nodes (NEW!)
4. **Level 3: Regression Testing** - Real DB validation against modified workflows

---

# Level 1: Fast Pre-commit Checks

- **Location**: `.githooks/pre-commit`
- **What it checks**: JSON syntax, basic properties, pinData (sensitive data)
- **Speed**: < 5 seconds
- **Blocks**: Syntax errors, missing properties

## Features

### JSON Syntax Validation
- Parse JSON and catch syntax errors
- Fast feedback during development

### Property Validation
- Required node properties (name, type, parameters)
- Basic structural integrity

### Sensitive Data Detection
- Detects `pinData` (test execution data with real IDs)
- Prevents committing sensitive credentials or test data

---

# Level 2: Structural Validation

- **Location**: `scripts/workflows/lint_workflows.py` + `scripts/validation/n8n_workflow_validator.py`
- **What it checks**: Node properties, ctx patterns, ExecuteWorkflow configuration
- **Speed**: < 30 seconds
- **Blocks**: Structural and configuration issues

## Features

### Property & Structure Validation
- Required node properties (parameters, type, typeVersion, position)
- Connection validity and structure
- Node type format validation
- Position coordinate validation

### ctx Pattern Enforcement
- Proper ctx initialization and usage
- Namespace consistency across workflows
- Event field requirements
- Node reference elimination

### ExecuteWorkflow Configuration
- Correct mode settings (mode='list' for workflow execution)
- Required cachedResult fields for Execute_Queries integration
- Workflow ID validation

---

# Level 2b: Workflow Integrity Validation (NEW!)

- **Location**: `scripts/validation/workflow_integrity.py`
- **What it checks**: Dead code, misconfigured nodes, broken references
- **Speed**: < 10 seconds
- **Blocks**: Dead code, missing workflow references, misconfigured triggers

## Background

This validator was created in response to **Issues #118-122** which identified multiple deployment pipeline issues:
- Dead code (nodes unreachable from triggers) causing confusion
- Misconfigured executeWorkflowTrigger nodes showing validation errors in n8n UI
- Missing workflow references not caught before production

## Features

### Dead Code Detection
Finds nodes that are unreachable from any trigger node using BFS graph traversal.

**Why this matters:**
- Dead code confuses developers looking at workflows
- Dead code wastes n8n UI resources
- Dead code often indicates broken refactoring or incomplete changes

**Example from Issue #122:**
```
Proactive_Pulse had 6 dead nodes:
- AddDiagnosticReaction
- CheckVerboseConfig
- IfVerbose?
- MimoV2Flash
- NemotronNano9b
- TriggerShowDetails
```

### Misconfigured Node Detection
- Empty `executeWorkflowTrigger` parameters (causes n8n UI validation errors)
- Execute Workflow nodes not using `mode='list'` (not portable between environments)
- Execute Workflow nodes referencing non-existent workflows
- Switch nodes with invalid `fallbackOutput` values
- Code nodes with invalid return patterns

### Broken Reference Detection
- Validates all Execute Workflow nodes reference existing workflows
- Catches typos and missing workflows before deployment

## Usage

### Pre-commit (Automatic)
```bash
# Happens automatically when committing workflow files
git add n8n-workflows/*.json
git commit -m "feat: update workflow"
# → Runs integrity validation automatically
```

### Manual Validation
```bash
# Validate all workflows
python3 scripts/validation/workflow_integrity.py

# Validate specific workflow
python3 scripts/validation/workflow_integrity.py n8n-workflows/Proactive_Pulse.json

# Auto-fix dead code (removes unreachable nodes)
python3 scripts/validation/workflow_integrity.py --fix

# Strict mode (fail on warnings too)
python3 scripts/validation/workflow_integrity.py --strict
```

### In Deployment Pipeline
```bash
# Automatically runs in Stage 1 validation
./scripts/deploy.sh
# → validate_workflow_integrity() runs before deployment
```

## Auto-Fix Feature

The `--fix` flag automatically removes dead code:

```bash
# Before fix: Proactive_Pulse has 6 dead nodes
python3 scripts/validation/workflow_integrity.py
# Proactive_Pulse: DEAD CODE: 6 node(s) unreachable from triggers

# Run fix
python3 scripts/validation/workflow_integrity.py --fix
# Fixed: Proactive_Pulse.json - Removed 6 dead nodes

# After fix: Proactive_Pulse passes
python3 scripts/validation/workflow_integrity.py
# Proactive_Pulse: PASS
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All checks passed |
| 1 | Errors found (blocks deployment) |
| 2 | Warnings only (deployment allowed, review recommended) |

---

# Level 3: Regression Testing (NEW!)

## Overview

The regression testing framework validates that modified workflows work correctly against production-like data. It replaces the broken `test-all-paths.sh` approach with a more maintainable and accurate testing strategy.

**Addresses:** [Issue #118](https://github.com/chriskevini/kairon/issues/118)

## Key Features

### Execution + DB Verification

The regression testing framework provides:

1. **Targeted Testing** - Only tests modified workflows (not all 45+)
2. **Prod DB Snapshot** - Optional: Copy production DB to dev for realistic data
3. **Execution Validation** - Check workflow execution status (success/failure)
4. **DB State Verification** - Validate database changes (events, projections created)
5. **CI/CD Integration** - Blocks deployments on test failures

### How It Works

1. **Identify Modified Workflows** - Use `git diff` to find changed workflows
2. **Setup Test DB** (optional) - Snapshot prod DB to dev environment
3. **Run Test Payloads** - Execute workflows with defined test cases
4. **Validate Results** - Check both execution status AND database state
5. **Auto-Cleanup** - Restore dev DB after tests

## Usage

### In Deployment Pipeline (Automatic)

```bash
# Runs automatically in Stage 2
./scripts/deploy.sh
# Stage 0: Unit tests
# Stage 1: Dev deployment
# Stage 2: Regression tests (modified workflows only)
# Stage 3: Prod deployment
```

### Manual Testing

```bash
# Test all workflows with test payloads
bash scripts/testing/regression_test.sh --all

# Test specific workflow
bash scripts/testing/regression_test.sh --workflow Multi_Capture

# Test modified workflows (default)
bash scripts/testing/regression_test.sh

# Skip prod DB snapshot (use existing dev data)
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
    "test_name": "Activity with !! tag",
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

### Required Fields

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

### Step 1: Identify Test Scenarios

For each workflow, consider:
- Main success paths
- Edge cases
- Error conditions

**Example for Multi_Capture:**
- Activity with `!!` tag
- Note with `..` tag
- Todo with `$$` tag
- Untagged message (LLM extraction)
- Alias tags with spaces

### Step 2: Find Webhook Data

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
# Check existing test payloads for patterns
ls n8n-workflows/tests/regression/
```

### Step 3: Determine Expected DB Changes

Run the workflow manually and check what was created:
```bash
# Uses DB_USER and DB_NAME from .env (defaults: n8n_user/kairon)
docker exec postgres-dev-local psql -U n8n_user -d kairon -c "
  SELECT projection_type, COUNT(*)
  FROM projections
  WHERE created_at > NOW() - INTERVAL '1 minute'
  GROUP BY projection_type;
"
```

### Step 4: Create Payload File

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

## Initial Coverage

**Multi_Capture** - 5 tests:
- ✅ Activity with `!!` tag
- ✅ Note with `..` tag
- ✅ Todo with `$$` tag
- ✅ Untagged message (LLM extraction)
- ✅ Activity alias with space

**Execute_Command** - 5 tests:
- ✅ Command: `::help`
- ✅ Command: `::recent`
- ✅ Command: `::stats`
- ✅ Command: `::set timezone`
- ✅ Command: `::ping`

**Route_Message** - 3 tests:
- ✅ Route message with activity tag
- ✅ Route untagged message
- ✅ Route command

## Advantages Over Old test-all-paths.sh

| Aspect | test-all-paths.sh (BROKEN) | Regression Tests (NEW) |
|---------|---------------------------|-----------------|
| **Tests all workflows** | ✅ Every time | ❌ Only modified |
| **Execution validation** | ❌ jq parsing bug | ✅ Working |
| **DB validation** | ❌ HTTP only | ✅ State verification |
| **Real data** | ❌ Mocks | ✅ Prod DB snapshot |
| **Maintenance** | ❌ Modify script | ✅ Add JSON files |
| **Speed** | ❌ ~5 min | ✅ ~1 min (targeted) |
| **Bug detection** | ⚠️ Basic | ✅ Comprehensive |

## Debugging Failed Tests

### View Execution in n8n UI
```bash
# Test will show execution ID in output
# View: http://localhost:5679/execution/<id>
```

### Check Database State
```bash
# Uses DB_USER and DB_NAME from .env (defaults: n8n_user/kairon)
# Check recent events
docker exec postgres-dev-local psql -U n8n_user -d kairon -c "
  SELECT * FROM events ORDER BY received_at DESC LIMIT 5;
"

# Check recent projections
docker exec postgres-dev-local psql -U n8n_user -d kairon -c "
  SELECT * FROM projections ORDER BY created_at DESC LIMIT 5;
"
```

### Re-run Single Test
```bash
bash scripts/testing/regression_test.sh \
  --workflow Multi_Capture \
  --verbose \
  --keep-db
```

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

### When Bugs Are Found
1. Add failing test case to regression payload
2. Fix bug
3. Test passes
4. Commit both fix and test

### When Workflows Are Modified
1. Create/update regression tests for modified workflow
2. Verify tests pass before deployment
3. Tests prevent future regressions

### Coverage Growth
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

**Migration Steps:**
1. ✅ Framework implemented (`scripts/testing/regression_test.sh`)
2. ✅ Deployment updated (`scripts/deploy.sh`)
3. ⏳ Create test payloads for critical workflows (partially done)
4. ⏳ Archive `test-all-paths.sh` once coverage is sufficient

## Detailed Documentation

For comprehensive documentation on regression testing:
- **Main Guide:** `scripts/testing/README.md`
  - Complete test payload creation guide
  - Coverage strategy checklist
  - Troubleshooting guide
  - FAQ

---

# Error Prevention

### Before Enhancement
```
Workflow Development → Basic JSON Validation → ❌ Production Issues
```

### After Enhancement
```
Workflow Development → Pre-commit Checks → Structural Validation
                                  ↓
                          Regression Tests (modified workflows)
                                  ↓
                          ✅ Issues Caught Before Production
```

---

# Dependencies

### Required
- Python 3.7+
- jq (for JSON parsing in regression tests)
- Docker (for dev environment)

### Optional
- Access to n8n API instance (for execution verification)
- Valid N8N_API_KEY environment variable
- SSH access to remote server (for prod DB snapshot)

---

# Related Tools

- `scripts/workflows/inspect_execution.py` - Execution inspection tool
- `scripts/testing/regression_test.sh` - Regression testing framework
- `scripts/deploy.sh` - Deployment pipeline with integrated testing
- `tools/kairon-ops.sh` - Operations and DB queries

---

# Future Enhancements

## Regression Testing
1. **Cross-workflow tests** - Test workflow chains, not just individual workflows
2. **Performance benchmarks** - Track workflow execution times
3. **Automated payload generation** - Suggest test cases based on workflow structure
4. **Visual test reports** - HTML reports with execution details

## Structural Validation
1. **n8n UI Compatibility Testing** - Browser automation to test workflow editor loading
2. **API Endpoint Integration** - Use n8n's internal validation APIs when available
3. **Parallel Validation** - Optimize validation speed for large workflow sets
4. **UI Error Prevention** - Catch "Could not find property option" errors before production
5. **Enhanced Error Reporting** - Auto-fix suggestions and detailed remediation steps
