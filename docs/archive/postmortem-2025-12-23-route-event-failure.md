# Postmortem: Route_Event Workflow Failure (2025-12-23)

## Problem Summary

**Status:** Production DOWN - Discord messages not being processed  
**Started:** 2025-12-23 ~22:00 UTC  
**Duration:** 25+ minutes and ongoing  

Route_Event workflow fails on ALL Discord message webhooks. Cron jobs succeed but user messages fail.

## Symptoms

- Discord relay sends messages → n8n returns 200 OR 404
- n8n executions show ERROR status
- No events stored in database since 22:15 UTC
- Last successful Discord message: 22:00 UTC (execution 631)
- Cron executions (nudge/summary) work fine
- Error in logs: "Could not find error workflow JOXLqn9TTznBdo7Q"
- Error in logs: "Could not find property option" (telemetry error)

## Root Cause

**Database was rebuilt** for pgvector migration, which corrupted:
1. n8n workflow definitions (old workflow IDs, wrong parameters)
2. Credential references (wrong credential IDs)
3. Workflow cross-references (wrong error workflow IDs)

Additionally: **ALL git history had corrupted Postgres nodes** using invalid `queryReplacement` parameter instead of `values` array.

## What We Tried

### Attempt 1: Fix Node Name Standardization (FAILED)
- **Commits:** 23d514f, 6786c6f
- **Action:** Standardized node names to PascalCase, restored error checks
- **Result:** Error: "there is no parameter $11" - parameter mapping broken

### Attempt 2: Fix Execute_Queries Pattern (FAILED)
- **Commits:** d9353c5, 1b67850
- **Action:** Added `ctx` parameter and `waitForSubWorkflow: true` to Execute_Queries calls
- **Result:** Still failing - Execute_Queries pattern not working

### Attempt 3: Direct Postgres Node (FAILED)
- **Commit:** 35a2ddf
- **Action:** Bypassed Execute_Queries, used direct Postgres node
- **Result:** Parameter $11 error persisted

### Attempt 4: Git Rollbacks (FAILED - tried 7 different commits)
- **4db2c6d** (Dec 23) - Failed: snake_case names, tests failed
- **b34d16b** (Dec 22) - Failed: No ctx passed to Execute_Queries
- **2792510** (Dec 21) - Failed: "Could not find property option"
- **e92b605** (Dec 21) - Failed: Same error
- **81f06f9** (Dec 20) - Failed: Same error
- **6a33f4d** (Dec 20) - Failed: Same error (oldest in git)
- All versions had `queryReplacement` corruption

### Attempt 5: Delete & Recreate Workflow (PARTIAL SUCCESS)
- **Commit:** 4036023, 3d70e89, 9a3c166
- **Action:** Deleted old workflow (sLFhq6fPcHWZCYmu), redeployed as new (IdpHzWCchShvArHM)
- **Result:** 
  - Workflow created but NOT ACTIVE
  - After manual activation: Crons work, webhooks fail
  - Error persists: "Could not find property option"

### Attempt 6: Fix Postgres Node Parameters (CURRENT)
- **Commit:** b7e40b8
- **Action:** Replaced invalid `options.queryReplacement` with proper `values` array
- **Result:** Deployed, crons work (668 SUCCESS), webhooks STILL FAIL (670-672 ERROR)

## Current Workflow State

- **Workflow ID:** IdpHzWCchShvArHM (new, created 22:19 UTC)
- **Active:** Yes
- **Webhook Path:** `/webhook/asoiaf92746087` (correct)
- **Cron Jobs:** ✅ Working (executions 665, 668, 669 all success)
- **Discord Messages:** ❌ Failing (executions 666, 667, 670-672 all error)
- **Error Workflow ID:** JOXLqn9TTznBdo7Q (dev ID, wrong - should be NOJ7FqVhVLqw0n8D)

## Database State

```sql
-- Events table has pgvector migration (023) applied
-- timezone column exists (migration 019)
-- Last discord_message event: 22:00:38 UTC
-- No new events since 22:15 UTC despite multiple webhook calls
```

## Discord Relay State

```
22:22:00 - ✗ n8n webhook returned 404
22:22:25 - ✓ Sent message to n8n (status 200)
22:25:xx - Multiple 200 responses but workflow errors
```

Relay is working, sending to correct webhook, getting 200s, but workflows fail internally.

## Key Files

- Workflow JSON: `n8n-workflows/Route_Event.json`
- Relay service: `kairon-relay.service` (active, working)
- Database: PostgreSQL with pgvector
- n8n Version: 1.123.5

## Outstanding Issues

1. **Error workflow ID not updating** - Deployment script doesn't remove old errorWorkflow setting
2. **"Could not find property option"** - Still present, telemetry error during workflow save
3. **Webhook executions fail** - Error details not accessible via API
4. **All git history corrupted** - `queryReplacement` in all commits, no clean baseline

## Commits Made (in order)

1. 23d514f - Standardize node names
2. 6786c6f - Restore error checks
3. d9353c5 - Add ctx to Execute_Queries
4. 1b67850 - Pass ctx and wait
5. 35a2ddf - Direct Postgres instead of Execute_Queries
6. 4361db2 - Reference BuildMessageEventQuery explicitly
7. 2a36171 - Rollback to b34d16b
8. 66bf3b9 - Rollback to d9353c5
9. 39a8a7e - Remove errorWorkflow ID
10. 4036023 - Rollback to 2792510
11. 3d70e89 - Rollback to e92b605
12. 9a3c166 - Rollback to 81f06f9
13. b7e40b8 - Fix queryReplacement → values (CURRENT)

## Recommendations

1. **Immediate:** Check n8n execution data in database directly (execution_data table)
2. **Short-term:** Extract working workflow from dev/backup if available
3. **Medium-term:** Rebuild ALL workflows from scratch after database rebuild
4. **Long-term:** Add workflow validation to deployment script to catch parameter issues
