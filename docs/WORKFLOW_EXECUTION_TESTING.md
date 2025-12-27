# Workflow Execution Testing (Part 1)

## Overview

This document describes the workflow execution verification feature added to address [Issue #110](https://github.com/user/kairon/issues/110).

The testing system now supports verifying that n8n workflows execute successfully, not just that webhooks return HTTP 200. This catches internal workflow errors like missing node parameters.

## What's New

### Execution Verification

The `test-all-paths.sh` script now includes:

1. **Execution Status Polling** - Queries n8n API to check workflow execution status
2. **Error Detection** - Extracts and reports workflow execution errors
3. **Timeout Handling** - Fails tests if workflows don't complete within timeout
4. **Detailed Reporting** - Shows which node failed and the error message

### How It Works

When `--verify-executions` is enabled:

1. Test sends webhook request to n8n
2. Records timestamp before sending
3. Polls n8n API for recent executions matching timestamp + workflow name
4. Monitors execution until completion (success/error) or timeout
5. Reports results with detailed error messages if failures occur

## Usage

### Basic Usage

```bash
# Run tests with execution verification (requires API access)
./tools/test-all-paths.sh --dev --verify-executions

# Quick test with execution verification
./tools/test-all-paths.sh --dev --quick --verify-executions

# Verbose output
./tools/test-all-paths.sh --dev --verify-executions --verbose
```

### Authentication Setup

Execution verification requires n8n API access. Two methods are supported:

#### Method 1: API Key (Recommended)

1. Generate an API key in n8n UI (Settings → API)
2. Add to `.env`:
   ```bash
   N8N_DEV_API_KEY=your-api-key-here
   ```

#### Method 2: Session Cookie (Fallback)

1. Run deployment to generate session cookie:
   ```bash
   ./scripts/deploy.sh dev
   ```
2. Cookie is stored at `/tmp/n8n-dev-session.txt`

**Note:** If authentication fails, the script will show a warning and continue with basic HTTP tests only.

### CI/CD Integration (Future - Part 2)

```bash
# In deploy.sh (planned for Part 2)
run_functional_tests() {
    ./tools/test-all-paths.sh --dev --verify-executions
    
    if [ $? -ne 0 ]; then
        echo "Functional tests failed - blocking deployment"
        exit 1
    fi
}
```

## Implementation Details

### New Functions

- `n8n_api_call()` - Authenticated API requests to n8n
- `get_recent_executions()` - Fetch recent workflow executions
- `get_execution()` - Get detailed execution data
- `verify_execution()` - Poll and verify execution status

### API Endpoints Used

- `GET /api/v1/executions?limit=N` - List recent executions
- `GET /api/v1/executions/{id}?includeData=true` - Get execution details

### Execution Matching

Executions are matched by:
1. **Workflow name** - "Route_Event" (main entry workflow)
2. **Timestamp** - Must start after webhook was sent
3. **Recency** - Gets most recent matching execution

### Timeout Behavior

- **Default timeout:** 30 seconds per test
- **Configurable:** Can be adjusted in `verify_execution()` function
- **On timeout:** Test fails and reports last known status

## Limitations (Part 1)

This is Part 1 of the implementation. Current limitations:

1. **Authentication:** Requires manual API key setup (not automated)
2. **Not in CI/CD:** Not yet integrated into deployment pipeline (Part 2)
3. **Dev only:** Currently only works with local dev environment
4. **Route_Event only:** Only verifies main workflow, not downstream workflows

## What's Next (Part 2)

The next PR will add:

1. **Database verification enhancement** - Check execution status via traces table
2. **CI/CD integration** - Block deployments on execution failures
3. **Production support** - Execution verification for production tests
4. **Better error reporting** - Link to n8n UI for failed executions

## Testing This Feature

```bash
# 1. Ensure dev environment is running
docker-compose -f docker-compose.dev.yml up -d

# 2. Setup API authentication
# Add N8N_DEV_API_KEY to .env OR run:
./scripts/deploy.sh dev

# 3. Run tests with execution verification
./tools/test-all-paths.sh --dev --quick --verify-executions --verbose

# 4. Verify it catches errors by introducing a bug in a workflow
```

## Troubleshooting

### "Cannot access n8n API" warning

**Cause:** Authentication failed or API not accessible

**Solutions:**
1. Check `N8N_DEV_API_KEY` in `.env`
2. Regenerate session cookie: `./scripts/deploy.sh dev`
3. Verify n8n is running: `docker ps | grep n8n-dev`
4. Check n8n API is enabled: `docker exec n8n-dev-local env | grep N8N_API_ENABLED`

### "No execution found for workflow" warning

**Cause:** Workflow execution not found or completed before polling started

**Solutions:**
1. Normal for some test cases (async workflows, edge cases)
2. Not a test failure - just informational
3. Can be ignored unless many tests show this

### Execution timeouts

**Cause:** Workflow taking longer than 30 seconds

**Solutions:**
1. Check n8n logs: `docker logs n8n-dev-local`
2. Verify workflow isn't stuck: Check n8n UI
3. Increase timeout in `verify_execution()` if needed

## References

- **Issue #110:** [Workflow Changes Must Pass Functional Execution Tests](https://github.com/user/kairon/issues/110)
- **PR #112:** [Enable dev→test→prod deployment pipeline](https://github.com/user/kairon/pull/112)
- **Related:** `scripts/workflows/inspect_execution.py` - Execution inspection tool
