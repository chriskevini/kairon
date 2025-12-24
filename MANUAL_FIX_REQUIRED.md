# Manual Fix Required - Execute_Command

**Date:** 2025-12-24  
**Status:** 🟡 FIX IDENTIFIED - NEEDS MANUAL DEPLOYMENT  
**Workflow:** Execute_Command  
**Node:** QueryRecentEvents

---

## Issue Found

The Execute_Command workflow has a Postgres node (`QueryRecentEvents`) still using the deprecated `queryReplacement` parameter instead of `values`.

**Impact:** The `::recent` command may fail when querying recent events.

---

## The Fix

### Current (Broken)
```json
{
  "parameters": {
    "options": {
      "queryReplacement": "={{ $json.ctx.validation.normalized_type }},={{ $json.ctx.validation.normalized_limit }}"
    }
  }
}
```

### Fixed (Correct)
```json
{
  "parameters": {
    "options": {
      "values": "={{ [$json.ctx.validation.normalized_type, $json.ctx.validation.normalized_limit] }}"
    }
  }
}
```

**Key Changes:**
1. `queryReplacement` → `values`
2. Comma-separated string → Array format with `[ ]`

---

## Manual Deployment Steps

Since automated deployment isn't working, manually update via n8n UI:

### Option 1: Via n8n UI (Recommended)

1. **Open Execute_Command workflow in n8n:**
   - Navigate to https://n8n.chrisirineo.com
   - Open workflow: `Execute_Command` (ID: ZwuxCuNFykFxgD3e)

2. **Find QueryRecentEvents node:**
   - Look for the node named "QueryRecentEvents"
   - It's in the `::recent` command path

3. **Update the node parameters:**
   - Click on the node
   - Go to "Options" tab
   - Find "Query Replacement" field
   - Change to: `={{ [$json.ctx.validation.normalized_type, $json.ctx.validation.normalized_limit] }}`
   - Note: This will automatically change the parameter name from `queryReplacement` to `values`

4. **Save and Activate:**
   - Click "Save" button
   - Ensure workflow is Active

### Option 2: Via File Upload (If available in n8n)

1. Go to n8n workflows page
2. Select Execute_Command
3. Use "Import/Replace" function
4. Upload: `n8n-workflows/Execute_Command.json` from local repo
5. Save and activate

---

## Testing Required

After deploying the fix, test ALL command paths to ensure nothing broke:

### Test Commands

Send these messages to the Discord relay webhook or via Discord:

```bash
# Test 1: Get config value
::get llm_model

# Test 2: Set config value  
::set test_key test_value

# Test 3: Recent events (THIS IS THE FIXED PATH)
::recent

# Test 4: Recent activities
::recent activities 10

# Test 5: Recent notes
::recent notes 5

# Test 6: Stats command
::stats

# Test 7: Help command
::help

# Test 8: Modules list
::modules

# Test 9: User status
::status
```

### Expected Results

All commands should:
- ✅ Return HTTP 200
- ✅ Process without errors in n8n execution log
- ✅ Return appropriate Discord message response

### How to Test via Webhook

```bash
# Template for testing
curl -X POST "https://n8n.chrisirineo.com/webhook/asoiaf92746087" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message",
    "guild_id": "754207117157859388",
    "channel_id": "1450406231146496132",
    "message_id": "test-'$(date +%s)'",
    "author": {
      "login": "test_user",
      "id": "123456",
      "display_name": "Test User"
    },
    "content": "::recent",
    "clean_text": "::recent",
    "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'"
  }'

# Test ::recent with type filter
curl -X POST "https://n8n.chrisirineo.com/webhook/asoiaf92746087" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message",
    "guild_id": "754207117157859388",
    "channel_id": "1450406231146496132",
    "message_id": "test-'$(date +%s)'",
    "author": {
      "login": "test_user",
      "id": "123456",
      "display_name": "Test User"
    },
    "content": "::recent activities 5",
    "clean_text": "::recent activities 5",
    "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'"
  }'
```

---

## Verification

After testing, verify the fix worked:

```bash
# Check n8n execution logs
ssh DigitalOcean 'docker logs n8n-docker-caddy-n8n-1 --tail 100 | grep -i "queryReplacement\|error"'

# Check database for successful command executions
cd ~/Work/kairon
./tools/kairon-ops.sh db-query "
  SELECT 
    event_type,
    payload->>'content' as command,
    received_at
  FROM events 
  WHERE event_type = 'discord_message'
    AND payload->>'content' LIKE '::recent%'
    AND received_at > NOW() - INTERVAL '1 hour'
  ORDER BY received_at DESC
  LIMIT 5;
"
```

---

## Other Postgres Nodes to Check

While fixing Execute_Command, I verified these nodes are already correct (no queryReplacement):

- ✅ QueryGetConfig
- ✅ QuerySetConfig
- ✅ QueryStats
- ✅ QueryUserStatus
- ✅ VoidProjections
- ✅ QueryListModules
- ✅ QueryViewModule
- ✅ QueryToggleModule
- ✅ QueryUpdateModule

**Only QueryRecentEvents needs fixing.**

---

## Why This Wasn't Caught Earlier

1. **Execute_Queries was the priority** - We fixed that first since it's used by 15+ workflows
2. **Commands weren't fully tested** - We verified projections/traces but didn't test all command paths
3. **Production sync pulled current state** - The queryReplacement was already in production

This is why comprehensive testing of ALL paths is critical before declaring victory.

---

## Status

- [x] Issue identified
- [x] Fix implemented locally
- [x] Committed to git (commit: 9d500ba)
- [ ] **Deployed to production** ← YOU NEED TO DO THIS
- [ ] **Tested all command paths** ← AND THIS

---

## Next Steps

1. **Deploy the fix** using Option 1 or 2 above
2. **Test all commands** using the test commands list
3. **Verify in execution logs** that no errors appear
4. **Update this document** to mark deployment complete
5. **Continue with remaining workflow verification**

---

**Remember:** Don't celebrate until ALL paths are tested! 🎯
