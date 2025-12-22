# Postmortem: Handle_Error Infinite Loop Cascade

**Date:** 2025-12-22  
**Duration:** ~4 hours (07:00 - 11:37 UTC-8)  
**Severity:** Critical  
**Affected Executions:** ~7,000 - 13,847 (approximately 6,800+ failed executions)

## Summary

A bug introduced during the Query_DB migration caused the `Handle_Error` workflow to fail immediately when invoked. Since `Handle_Error` is registered as the error handler for other workflows, each failure triggered another `Handle_Error` execution, creating an infinite error cascade that eventually overwhelmed the server and caused SSH to become unresponsive.

## Root Cause

The bug was introduced in commit `e55bea8` ("refactor: migrate remaining workflows to Query_DB/Write_DB wrappers") on 2025-12-22 at 03:24:42.

### The Bug

In `Handle_Error.json`, the "Filter Duplicate Errors" node was updated to prepare queries for the Query_DB sub-workflow:

```javascript
// BUGGY CODE - outputs db_queries at root level
return [{
  json: {
    error_data: errorData,
    db_queries: [{           // ❌ Should be ctx.db_queries
      key: 'recent_event',
      sql: `SELECT ...`
    }]
  }
}];
```

However, the `Query_DB` workflow expects queries under `ctx.db_queries`:

```javascript
// Query_DB validation (line 5 of Initialize Loop)
if (!ctx?.db_queries || !Array.isArray(ctx.db_queries) || ctx.db_queries.length === 0) {
  throw new Error('Query_DB requires ctx.db_queries array with at least one query');
}
```

### The Cascade

1. Any workflow error triggered `Handle_Error`
2. `Handle_Error` called `Query_DB` with incorrect data shape
3. `Query_DB` threw an error: "Query_DB requires ctx.db_queries array with at least one query"
4. This error triggered `Handle_Error` again (recursive)
5. Each iteration spawned more error handlers
6. Server resources exhausted, SSH daemon stopped responding

## Timeline

| Time (PST) | Event |
|------------|-------|
| 03:24 | Commit `e55bea8` pushed with buggy Handle_Error migration |
| ~03:30 | Workflows deployed to n8n via `rdev n8n push` |
| ~07:00 | First user activity triggers a workflow error |
| 07:00-11:35 | Error cascade begins, ~6,800 Handle_Error executions |
| 11:35 | Server becomes unresponsive (SSH connection refused) |
| 11:37 | Execution 13847 shows "crashed" status after 1.3 minute hang |
| 11:48 | Server recovered after ~13 minutes of downtime |

## Impact

- **~6,800 failed executions** clogging the execution history
- **Server instability** - SSH became unresponsive
- **No error notifications** - Handle_Error's failure meant no Discord alerts were sent
- **Potential data loss** - Unknown number of user messages may not have been processed

## Root Cause Analysis

### Why did this happen?

1. **Inconsistent ctx patterns**: Handle_Error is a special workflow triggered by the error system, not a sub-workflow called with proper ctx. It receives raw error data, not the standard `{ctx: {...}}` shape.

2. **Insufficient testing**: The migration was applied uniformly without testing Handle_Error's unique trigger context.

3. **No circuit breaker**: The error handler has no protection against recursive failures.

4. **Lint gap**: The workflow linter (`lint_workflows.py`) checks for ctx patterns but doesn't validate that error trigger workflows handle the different input shape.

### Contributing Factors

- Late-night refactoring (03:24 AM commit)
- Large batch migration (9 workflows in one commit)
- Handle_Error's unique status as an error-triggered workflow wasn't considered

## The Fix

The Handle_Error workflow needs to wrap its output in proper ctx structure:

```javascript
// FIXED CODE
return [{
  json: {
    ctx: {
      error_data: errorData,
      db_queries: [{
        key: 'recent_event',
        sql: `SELECT ...`
      }]
    }
  }
}];
```

## Mitigation Recommendations

### Immediate (P0)

1. **Fix Handle_Error.json** - Wrap db_queries under ctx namespace
2. **Add circuit breaker** - Prevent Handle_Error from triggering itself:
   ```javascript
   // At top of Filter Duplicate Errors
   const workflow = errorData.workflow?.name;
   if (workflow === 'Handle_Error' || workflow === 'Query_DB' || workflow === 'Write_DB') {
     return []; // Don't recurse on infrastructure workflow errors
   }
   ```

### Short-term (P1)

3. **Enhance lint_workflows.py** - Add validation that:
   - Error trigger workflows properly wrap output in ctx
   - All Execute Workflow nodes receive ctx-wrapped input
   
4. **Add integration tests** - Test Handle_Error with simulated error payloads

5. **Add execution rate monitoring** - Alert when Handle_Error executes >10 times in 5 minutes

### Long-term (P2)

6. **Document special workflow patterns** - Add AGENTS.md section on error trigger workflows and their unique input shapes

7. **Consider separate error handler** - A minimal, hardened error handler that:
   - Has no sub-workflow dependencies (no Query_DB/Write_DB)
   - Cannot fail in ways that trigger itself
   - Uses direct Postgres node with continueOnFail: true

8. **Add graceful degradation** - If Query_DB fails in Handle_Error, still send a basic error notification without the recent event context

## Lessons Learned

1. **Error handlers are critical infrastructure** - They require extra scrutiny and testing
2. **Batch migrations are risky** - Consider smaller, incremental changes
3. **Test in context** - Error-triggered workflows have different inputs than sub-workflows
4. **Circuit breakers prevent cascades** - Always add recursion protection to error handlers

## Action Items

| Priority | Item | Owner | Status |
|----------|------|-------|--------|
| P0 | Fix ctx wrapping in Handle_Error | - | TODO |
| P0 | Add circuit breaker for recursive errors | - | TODO |
| P1 | Enhance linter for error trigger workflows | - | TODO |
| P1 | Add Handle_Error integration test | - | TODO |
| P2 | Document error trigger pattern in AGENTS.md | - | TODO |
| P2 | Consider minimal fallback error handler | - | TODO |
