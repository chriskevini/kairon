# n8n Workflow Validation System

This document describes the comprehensive workflow validation system that prevents common issues and structural problems in n8n workflows.

## Problem Solved

Workflows could pass basic validation but contain structural issues that cause runtime problems, including:
- Missing required properties
- Incorrect node configurations
- ctx pattern violations
- ExecuteWorkflow misconfigurations

## Solution: Multi-Layer Validation

### Level 1: Fast Pre-commit Checks
- **Location**: `.githooks/pre-commit`
- **What it checks**: JSON syntax, basic properties
- **Speed**: < 5 seconds
- **Blocks**: Syntax errors, missing properties

### Level 2: Comprehensive Structural Validation
- **Location**: `scripts/workflows/lint_workflows.py` + `scripts/validation/n8n_workflow_validator.py`
- **What it checks**: Node properties, ctx patterns, ExecuteWorkflow configuration
- **Speed**: < 30 seconds
- **Blocks**: Structural and configuration issues

## Validation Features

### ✅ Property & Structure Validation
- Required node properties (parameters, type, typeVersion, position)
- Connection validity and structure
- Node type format validation
- Position coordinate validation

### ✅ ctx Pattern Enforcement
- Proper ctx initialization and usage
- Namespace consistency across workflows
- Event field requirements
- Node reference elimination

### ✅ ExecuteWorkflow Configuration
- Correct mode settings (mode='list' for workflow execution)
- Required cachedResult fields for Execute_Queries integration
- Workflow ID validation

### ⚠️ Known Limitations
- **Does NOT catch n8n UI compatibility issues** that cause "Could not find property option" errors
- **Does NOT validate against n8n's internal processing engine**
- **Cannot prevent human implementation errors** in ExecuteWorkflow integration
- Requires additional testing (smoke tests, staging deployment) for full UI compatibility assurance

## Usage

### Pre-commit (Automatic)
```bash
# Happens automatically when committing workflow files
git add n8n-workflows/*.json
git commit -m "feat: add new workflow"
# → Validates API compatibility automatically
```

### Manual API Testing
```bash
# Test specific workflow
python3 scripts/validation/n8n_workflow_validator.py n8n-workflows/MyWorkflow.json --verbose

# Test with custom n8n instance
python3 scripts/validation/n8n_workflow_validator.py workflow.json --api-url http://localhost:5679 --api-key my-key
```

### CI/CD Integration
```bash
# In deployment pipeline
for workflow in n8n-workflows/*.json; do
    python3 scripts/validation/n8n_workflow_validator.py "$workflow" || exit 1
done
```

## What Gets Tested

### ✅ Structural Validation
- JSON syntax and parsing
- Required node properties validation
- Connection integrity
- Workflow metadata completeness

### ✅ Code Quality & Patterns
- ctx pattern compliance (prevents data loss)
- Node reference elimination (reduces coupling)
- Switch node fallback requirements
- Merge node configuration validation

### ✅ Workflow Integration
- ExecuteWorkflow node configuration
- Postgres query ctx usage
- Discord node parameter validation
- Set node ctx preservation

## Error Prevention

### Before Enhancement
```
Workflow Development → Basic JSON Validation → ❌ Production Issues (missing properties, ctx violations, ExecuteWorkflow errors)
```

### After Enhancement
```
Workflow Development → Structural Validation → Pattern Enforcement → ✅ Structural Issues Prevented
                                                            ↓
                                                 ⚠️ UI Compatibility Requires Additional Testing
```

## Dependencies

### Required
- Python 3.7+

### Optional
- Access to n8n API instance (for future API-based validation)
- Valid N8N_API_KEY environment variable

## Configuration

### Environment Variables
```bash
# n8n API connection
N8N_API_URL=http://localhost:5678
N8N_API_KEY=your-api-key-here
```

### Validation Modes
- **Offline**: Property and pattern validation (no external dependencies)
- **Future**: API-based validation (planned enhancement)

## Implementation Details

### Validation Flow
1. **JSON Loading**: Parse and validate basic structure
2. **Property Validation**: Check required fields and connections
3. **Pattern Validation**: Enforce ctx patterns and best practices
4. **Configuration Validation**: Check ExecuteWorkflow and node-specific settings
5. **Error Reporting**: Detailed feedback on issues found

### Error Classification
- **Critical**: Blocks commits (JSON syntax, missing required properties)
- **Error**: Prevents deployment (pattern violations, configuration errors)
- **Warning**: Allows but recommends fixes (best practice violations)

### Original Incident Context
This validation system was developed in response to a production incident where Show_Projection_Details workflow failed with "Could not find property option" error. The root cause was human error in ExecuteWorkflow configuration during refactoring. While this system prevents many issues, it does not catch all n8n UI compatibility problems.

## Future Enhancements

- **n8n UI Compatibility Testing**: Browser automation to test workflow editor loading
- **API Endpoint Integration**: Use n8n's internal validation APIs when available
- **Docker Test Instances**: Automated n8n environment testing for CI/CD
- **Parallel Validation**: Optimize validation speed for large workflow sets
- **UI Error Prevention**: Catch "Could not find property option" errors before production
- **Enhanced Error Reporting**: Auto-fix suggestions and detailed remediation steps

---

# Workflow Execution Testing

## Overview

The workflow execution testing system verifies that n8n workflows execute successfully in real environments, not just that webhooks return HTTP 200. This catches runtime errors like missing node parameters, API failures, and logic bugs that static validation cannot detect.

**Addresses:** [Issue #110](https://github.com/user/kairon/issues/110)

## Key Features

### Execution Verification

The `test-all-paths.sh` script provides:

1. **Execution Status Polling** - Queries n8n API to check workflow execution status
2. **Error Detection** - Extracts and reports workflow execution errors with n8n UI links
3. **Timeout Handling** - Fails tests if workflows don't complete within timeout
4. **CI/CD Integration** - Blocks deployments on execution failures

### How It Works

When `--verify-executions` is enabled:

1. Test sends webhook request to n8n
2. Records timestamp before sending
3. Polls n8n API for recent executions matching timestamp + workflow name
4. Monitors execution until completion (success/error) or timeout
5. Reports results with detailed error messages and n8n UI links if failures occur

## Usage

### Basic Commands

```bash
# Dev environment - Run tests with execution verification
./tools/test-all-paths.sh --dev --verify-executions

# Production environment - Run tests with execution verification
./tools/test-all-paths.sh --prod --verify-executions

# Quick test with execution verification
./tools/test-all-paths.sh --dev --quick --verify-executions

# Verbose output (shows n8n UI links for successful executions)
./tools/test-all-paths.sh --dev --verify-executions --verbose
```

### Authentication Setup

Execution verification requires n8n API access. Setup varies by environment:

#### Dev Environment

**Method 1: API Key (Recommended)**

1. Generate an API key in n8n UI (Settings → API)
2. Add to `.env`:
   ```bash
   N8N_DEV_API_KEY=your-api-key-here
   ```

**Method 2: Session Cookie (Fallback)**

1. Run deployment to generate session cookie:
   ```bash
   ./scripts/deploy.sh dev
   ```
2. Cookie is stored at `/tmp/n8n-dev-session.txt`

#### Production Environment

**API Key Required**

1. Generate production API key in n8n UI
2. Add to `.env`:
   ```bash
   N8N_API_URL=https://n8n.yourdomain.com
   N8N_API_KEY=your-prod-api-key-here
   ```

**Note:** If authentication fails, the script shows a warning and continues with basic HTTP tests only.

### CI/CD Integration

Execution verification is integrated into the deployment pipeline (`scripts/deploy.sh`):

```bash
# Automatically enabled in deployment pipeline
./scripts/deploy.sh dev    # Runs tests with --verify-executions
./scripts/deploy.sh all    # Full pipeline with execution verification

# Manual testing
./tools/test-all-paths.sh --dev --verify-executions
```

**Deployment Stages:**
1. **Stage 2a:** Mock tests with execution verification
2. **Stage 2b:** Real API tests with execution verification

If execution verification fails, deployment is blocked before reaching production.

## Implementation Details

### Core Functions

- `n8n_api_call()` - Authenticated API requests to n8n
- `get_recent_executions()` - Fetch recent workflow executions
- `get_execution()` - Get detailed execution data
- `verify_execution()` - Poll and verify execution status

### API Endpoints Used

- `GET /rest/executions?limit=N` - List recent executions
- `GET /rest/executions/{id}?includeData=true` - Get execution details

### Execution Matching

Executions are matched by:
1. **Workflow name** - "Route_Event" (main entry workflow)
2. **Timestamp** - Must start after webhook was sent
3. **Recency** - Gets most recent matching execution

### Timeout Behavior

- **Default timeout:** 30 seconds per test
- **Configurable:** Can be adjusted in `verify_execution()` function
- **On timeout:** Test fails and reports last known status

### Enhanced Error Reporting

Failed executions display:
- Execution ID
- Failed node name
- Error message
- Direct link to execution in n8n UI (format: `http://localhost:5679/execution/<id>`)

Example error output:
```
✗ Test: Activity extraction: Execution failed (ID: abc123)
    Error in node: LLM Agent
    Message: API rate limit exceeded
    View in n8n: http://localhost:5679/execution/abc123
```

## Prerequisites

Before using execution verification:

1. **jq installed** - Required for JSON parsing
   ```bash
   # Ubuntu/Debian
   sudo apt-get install jq
   
   # macOS
   brew install jq
   
   # Verify installation
   jq --version
   ```

2. **Docker environment running** (for dev)
   ```bash
   docker-compose -f docker-compose.dev.yml up -d
   ```

3. **n8n API authentication** (see Authentication Setup above)

## Testing Example

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

## Current Limitations

1. **Authentication:** Requires manual API key setup in `.env`
2. **Route_Event only:** Only verifies main workflow, not downstream workflows
3. **No database correlation:** Execution IDs not yet linked to traces table (requires workflow changes)

## Future Enhancements (Execution Testing)

1. **Database correlation** - Link execution IDs to traces table for better tracking (requires workflow modifications)
2. **Downstream workflow verification** - Verify not just Route_Event but all triggered workflows
3. **Execution performance metrics** - Track and report workflow execution times

## Related Tools

- `scripts/workflows/inspect_execution.py` - Execution inspection tool
- `tools/test-all-paths.sh` - Comprehensive path testing script
- `scripts/deploy.sh` - Deployment pipeline with integrated testing