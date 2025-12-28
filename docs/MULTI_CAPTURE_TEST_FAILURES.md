# Multi_Capture Regression Test Failures - Investigation Report

**Date**: 2025-12-27  
**Branch**: `fix/multi-capture-test-failures`  
**Status**: Root cause identified, fix documented

## Summary

Investigated 2 failing regression tests in Multi_Capture workflow (3/5 tests passing). Root cause identified as dev environment having outdated workflow version from before validator fix.

## Test Results

### ✅ Passing Tests (3/5)
1. **Test 1**: Activity with `!!` tag - PASS
2. **Test 2**: Note with `..` tag - PASS  
3. **Test 5**: Activity alias with space - PASS

### ❌ Failing Tests (2/5)

#### Test 3: "Todo with $$ tag" - 0 projections created (expected 1)

**Root Cause**: Dev n8n has outdated Capture_Projection workflow

**Evidence**:
- Source file: `TodoClassifier` type = `@n8n/n8n-nodes-langchain.chainLlm` ✅
- Dev n8n: `TodoClassifier` type = `n8n-nodes-base.code` ❌

**Timeline**:
1. Commit 65631dc: Validator incorrectly removed LLM model nodes
2. Commit 9501546: Restored workflows from git (source files fixed)
3. Production deployed today with fixed workflows ✅
4. **Dev never redeployed with fixed workflows** ❌

**Impact**:
- Tagged messages (`!!`, `..`) work because they use simple tag parsing
- `$$` (todo) fails because Capture_Projection's TodoClassifier is broken
- No LLM traces created for todo classification
- No projection inserted into database

**Fix Required**:
1. Resolve dev n8n authentication issues (login fails with all credentials)
2. Redeploy Capture_Projection to dev with correct TodoClassifier node
3. Rerun regression tests to verify

#### Test 4: "Untagged message (LLM extraction)" - creates note instead of activity

**Message**: `"I should remember this idea about the new feature"`  
**Expected**: activity  
**Actual**: note

**Analysis**:
This may be a test expectation issue rather than a bug. The message could reasonably be classified as either:
- **Note** (something to remember) ← LLM chose this
- **Activity** (thinking about/planning a feature)

The LLM interpretation seems valid. The test expectation may need adjustment.

**Recommendation**: Review test expectation. If "remembering an idea" should be activity, update LLM prompt to clarify.

## Verification Steps

### Verify Production Has Correct Workflow

Production was successfully deployed today (2025-12-27) with commit 9501546, which includes the fixed Capture_Projection workflow.

To verify TodoClassifier in production:
```bash
# Via SSH tunnel to production
./tools/kairon-ops.sh n8n-get Capture_Projection | \
  jq '.nodes[] | select(.name == "TodoClassifier") | {name, type}'
```

Expected output:
```json
{
  "name": "TodoClassifier",
  "type": "@n8n/n8n-nodes-langchain.chainLlm"
}
```

### Fix Dev Environment

Current blocker: Dev n8n authentication fails with all known credentials.

Attempted fixes:
- User reset: `docker exec n8n-dev-local n8n user-management:reset` (failed)
- Cookie refresh: Login API returns 401 with correct credentials
- Multiple credential combinations tried from .env

**Next Steps**:
1. Debug why n8n dev authentication is broken
   - Check n8n database user table
   - Try recreating dev containers from scratch
   - Verify n8n version compatibility with auth API
   
2. Once authenticated, redeploy workflows:
   ```bash
   bash scripts/deploy.sh local
   ```

3. Verify TodoClassifier fixed:
   ```bash
   curl -b /tmp/n8n-dev-session.txt "http://localhost:5679/rest/workflows" | \
     jq '.data[] | select(.name == "Capture_Projection") | .id' | \
     xargs -I {} curl -b /tmp/n8n-dev-session.txt \
       "http://localhost:5679/rest/workflows/{}" | \
     jq '.data.nodes[] | select(.name == "TodoClassifier") | {name, type}'
   ```

4. Rerun regression tests:
   ```bash
   bash scripts/testing/regression_test.sh \
     --workflow Multi_Capture \
     --no-db-snapshot \
     --verbose
   ```

## Files Investigated

- `n8n-workflows/Multi_Capture.json` - LLM extraction workflow (working)
- `n8n-workflows/Route_Message.json` - Tag routing (working)
- `n8n-workflows/Route_Event.json` - Tag parsing (working)
- `n8n-workflows/Capture_Projection.json` - Projection storage (broken in dev)
- `n8n-workflows/tests/regression/Multi_Capture.json` - Test definitions

## Key Learnings

1. **Regression tests work correctly** - They found real issues with outdated workflows
2. **Dev-prod parity is critical** - Dev should always match production state
3. **Deployment verification needed** - Need automated checks that workflows deployed successfully
4. **Authentication fragility** - Need more robust dev environment setup

## Recommendations

### Immediate
1. Fix dev n8n authentication
2. Redeploy fixed workflows to dev
3. Rerun and pass regression tests

### Short-term  
1. Add deployment verification step that checks critical node types
2. Implement dev-prod parity check before running regression tests
3. Document dev environment reset procedure

### Long-term
1. Consider using same database for dev/test to avoid drift
2. Add automated daily dev environment health checks
3. Improve error messages when workflows have mismatched node types
