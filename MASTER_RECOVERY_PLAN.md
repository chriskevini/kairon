# Kairon Master Recovery Plan - Foolproof Edition

**Date:** 2025-12-24  
**Status:** CRITICAL - Production Partially Down  
**Author:** Master Recovery Analysis

## Executive Summary

The Kairon system experienced cascading failures following a PostgreSQL database migration to add pgvector support. While the system appears to be working (webhooks return 200, events are stored), **data is not being fully persisted** - traces and projections are not being created. Multiple agents have attempted fixes but created more confusion.

**Key Finding:** This is NOT a single failure - it's a compound failure with multiple root causes that must be addressed systematically.

---

## Current State Assessment

### What's Working ✅
- Discord relay service is running and forwarding messages
- n8n containers are running (prod and dev)
- PostgreSQL database is running with correct schema
- Events are being stored in the `events` table
- Webhooks return HTTP 200
- Basic commands like `::ping` work (they don't use Execute_Queries)
- SSH access via ControlMaster works reliably

### What's Broken ❌
- **Traces are not being created** (last trace: 22 hours ago)
- **Projections are not being created** (last projection: 22 hours ago)
- **n8n API returns 405/null** (authentication or routing issue)
- **n8n logs show telemetry errors** ("Could not find property option")
- **Workflows reference non-existent error workflow** (JOXLqn9TTznBdo7Q)
- **Workflows have corrupted parameters** (queryReplacement vs values)
- **11 commits ahead of origin** but local changes not fully deployed

### Critical Metrics
```
Events (24h):     241 ✅
Traces (24h):     38  ❌ (should be ~240)
Last event:       2025-12-24 03:00 UTC (12 min ago)
Last trace:       2025-12-24 02:39 UTC (33 min ago)
Gap:              203 events without traces
```

---

## Root Cause Analysis

### Primary Causes

1. **Database Migration Side Effects (Dec 22)**
   - PostgreSQL container recreated with pgvector image
   - n8n credential IDs became invalid
   - Workflow references were broken
   - Manual credential recreation created new IDs

2. **n8n Code Node v2 Breaking Changes**
   - n8n updated Code nodes to strict v2 mode
   - `runOnceForEachItem` mode now forbids:
     - `$input.first()`, `$input.last()`, `$input.all()`
     - `$('NodeName').item.json`
     - Returning objects (must return arrays)
   - Multiple workflows have incompatible code

3. **Postgres Node Parameter Deprecation**
   - Old parameter: `queryReplacement`
   - New parameter: `values`
   - Execute_Queries uses old parameter (silent failure)

4. **Workflow Reference Corruption**
   - Error workflow ID `JOXLqn9TTznBdo7Q` doesn't exist
   - Sub-workflow references may be incorrect
   - Credential IDs may be mismatched

5. **Deployment State Confusion**
   - Local repository has uncommitted changes
   - 11 commits not pushed to origin
   - Production state doesn't match local state
   - Multiple agents applied partial fixes

### Secondary Issues

- SSH rate limiting (mitigated by ControlMaster)
- n8n API key confusion (documented but agents use wrong paths)
- Missing `.env` on server in expected location
- Multiple postmortems with conflicting information

---

## The Foolproof Recovery Strategy

### Philosophy: Build From Ground Up

Instead of fixing broken workflows, we'll:
1. **Build robust diagnostic tools first**
2. **Verify and document the actual state**
3. **Create a clean baseline**
4. **Deploy incrementally with verification**
5. **Document every step for future reference**

### Phase 1: Build Diagnostic & Deployment Tools (30-45 min)

Before attempting ANY fixes, we need reliable tools that won't fail due to SSH issues, wrong API keys, or environment problems.

#### Tool 1: Unified Remote Helper (`kairon-ops.sh`)

Create a single, bulletproof operations script that handles ALL remote operations with proper error handling.

**Location:** `/home/chris/Work/kairon/tools/kairon-ops.sh`

**Features:**
- Uses SSH ControlMaster automatically
- Sources correct `.env` from server
- Validates API keys before use
- Provides clear error messages
- Handles all common operations

**Commands:**
```bash
./tools/kairon-ops.sh status           # Complete system status
./tools/kairon-ops.sh db-query "SQL"   # Run SQL query
./tools/kairon-ops.sh n8n-list         # List all workflows with IDs
./tools/kairon-ops.sh n8n-get <ID>     # Get workflow JSON
./tools/kairon-ops.sh n8n-deploy <file> <ID>  # Deploy single workflow
./tools/kairon-ops.sh verify           # Run full system verification
./tools/kairon-ops.sh backup           # Backup current state
```

#### Tool 2: State Verification Script (`verify-system.sh`)

Checks ALL critical components and creates a baseline report.

**Location:** `/home/chris/Work/kairon/tools/verify-system.sh`

**Checks:**
- Docker containers status
- Discord relay service status
- n8n API accessibility
- Database connectivity
- Workflow list and active status
- Credential status
- Recent execution statistics
- Event/trace/projection counts

**Output:** JSON report saved to `state-reports/YYYY-MM-DD-HHmm.json`

#### Tool 3: Workflow Deployment Pipeline (`deploy-workflow.sh`)

Safe, single-workflow deployment with rollback capability.

**Location:** `/home/chris/Work/kairon/tools/deploy-workflow.sh`

**Features:**
- Validates JSON before upload
- Backs up current workflow version
- Sanitizes workflow (removes pinData, etc.)
- Fixes common issues automatically
- Verifies deployment success
- Can rollback on failure

**Usage:**
```bash
./tools/deploy-workflow.sh Route_Event.json   # Interactive mode
./tools/deploy-workflow.sh Route_Event.json --force  # Skip confirmation
./tools/deploy-workflow.sh --rollback Route_Event    # Restore backup
```

#### Tool 4: Database Health Check (`db-health.sh`)

Monitors the health of data flow through the system.

**Location:** `/home/chris/Work/kairon/tools/db-health.sh`

**Checks:**
- Events without traces (data loss indicator)
- Traces without projections
- Orphaned data
- Recent activity statistics
- Database table sizes

**Usage:**
```bash
./tools/db-health.sh              # Full report
./tools/db-health.sh --watch      # Continuous monitoring
./tools/db-health.sh --json       # JSON output for automation
```

#### Tool 5: n8n Workflow Validator (`validate-workflow.sh`)

Validates workflow JSON for known issues before deployment.

**Location:** `/home/chris/Work/kairon/tools/validate-workflow.sh`

**Checks:**
- JSON syntax validity
- Deprecated parameters (queryReplacement)
- Code node mode issues (runOnceForEachItem + forbidden patterns)
- Missing required nodes
- Workflow reference validity
- Credential reference format

**Usage:**
```bash
./tools/validate-workflow.sh n8n-workflows/Execute_Queries.json
./tools/validate-workflow.sh n8n-workflows/*.json  # Validate all
```

---

### Phase 2: Establish Baseline & Backup (15-20 min)

Before making ANY changes, document and backup the current state.

#### Step 2.1: Create State Snapshot
```bash
cd /home/chris/Work/kairon
./tools/verify-system.sh > state-reports/pre-recovery-$(date +%Y%m%d-%H%M).json
```

#### Step 2.2: Backup All Workflows from Production
```bash
# Pull current production state
./tools/kairon-ops.sh backup

# This creates:
# - backups/workflows/YYYYMMDD-HHmm/*.json (all workflow JSONs)
# - backups/state/YYYYMMDD-HHmm/state.json (system state)
# - backups/db/YYYYMMDD-HHmm/kairon.sql (database dump)
```

#### Step 2.3: Document Current Workflow IDs
```bash
./tools/kairon-ops.sh n8n-list > state-reports/workflow-ids.txt

# Expected output format:
# Route_Event - ID: xxxxx - Active: true
# Execute_Queries - ID: yyyyy - Active: true
# ...
```

#### Step 2.4: Git State Management
```bash
# Create recovery branch for our work
git checkout -b recovery/2025-12-24-master-plan

# Commit current uncommitted changes as snapshot
git add -A
git commit -m "snapshot: pre-recovery state with partial fixes"

# Tag the current state
git tag pre-recovery-$(date +%Y%m%d-%H%M)
```

---

### Phase 3: Fix Core Infrastructure (30-45 min)

Fix the foundational issues that prevent proper operation.

#### Step 3.1: Fix n8n API Access

**Problem:** n8n API returns 405 or null responses.

**Investigation:**
```bash
# Test direct API call
./tools/kairon-ops.sh test-api

# If fails, check:
# 1. n8n logs for API errors
# 2. API key validity
# 3. n8n service health
```

**Possible fixes:**
- Restart n8n if API is unresponsive
- Regenerate API key if invalid
- Check n8n environment variables

#### Step 3.2: Remove Invalid Error Workflow References

**Problem:** Workflows reference non-existent error workflow `JOXLqn9TTznBdo7Q`.

**Fix:**
```bash
# Find correct error workflow ID
./tools/kairon-ops.sh n8n-list | grep "Handle_Error"

# Update all workflows referencing old ID
# (automated in deployment tool)
```

#### Step 3.3: Fix Credential References

**Problem:** Workflows may reference wrong credential IDs after database migration.

**Investigation:**
```bash
# Get current credential IDs from production
./tools/kairon-ops.sh db-query "SELECT id, name, type FROM credentials_entity WHERE type='postgres';" --n8n-db

# Expected: One credential named "Kairon Postgres" or similar
```

**Fix:** Deployment tool will automatically map credentials by name.

---

### Phase 4: Fix Execute_Queries (The Critical Path) (20-30 min)

Execute_Queries is the bottleneck - if this doesn't work, nothing works.

#### Step 4.1: Validate Local Execute_Queries.json
```bash
./tools/validate-workflow.sh n8n-workflows/Execute_Queries.json

# Should check:
# - Uses "values" not "queryReplacement"
# - Code nodes compatible with v2
# - No deprecated patterns
```

#### Step 4.2: Apply Required Fixes

**Known issues in Execute_Queries:**
1. Postgres nodes use `queryReplacement` (deprecated)
2. Code nodes may use `runOnceForEachItem` incorrectly

**Fixes:**
```bash
# Automated fix script
./tools/fix-execute-queries.sh

# Manual verification
cat n8n-workflows/Execute_Queries.json | jq '.nodes[] | select(.type=="n8n-nodes-base.postgres") | .parameters.options'
# Should show "values": [...] not "queryReplacement"
```

#### Step 4.3: Deploy Execute_Queries
```bash
# Get current workflow ID
EXEC_QUERIES_ID=$(./tools/kairon-ops.sh n8n-list | grep "Execute_Queries" | awk -F'ID: ' '{print $2}' | awk '{print $1}')

# Deploy with backup
./tools/deploy-workflow.sh n8n-workflows/Execute_Queries.json --id $EXEC_QUERIES_ID

# Verify deployment
./tools/kairon-ops.sh n8n-get $EXEC_QUERIES_ID | jq '.nodes[] | select(.type=="n8n-nodes-base.postgres") | .parameters.options'
```

#### Step 4.4: Test Execute_Queries Directly

**Create test execution:**
```bash
# Send test webhook that will trigger Execute_Queries
curl -X POST "https://n8n.chrisirineo.com/webhook/asoiaf92746087" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message",
    "guild_id": "test",
    "channel_id": "test",
    "message_id": "exec-test-'$(date +%s)'",
    "author": {"login": "test", "id": "test", "display_name": "Test"},
    "content": "testing execute queries",
    "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'"
  }'

# Wait 10 seconds, then check for new trace
./tools/kairon-ops.sh db-query "SELECT COUNT(*) FROM traces WHERE created_at > NOW() - INTERVAL '1 minute';"

# Expected: count > 0
```

---

### Phase 5: Fix Route_Event (30-40 min)

Route_Event is the entry point - it must work correctly for anything to process.

#### Step 5.1: Identify Code Node Issues

**Known issues:**
- InitializeMessageContext uses deprecated patterns
- InitializeReactionContext uses deprecated patterns

**Check current state:**
```bash
./tools/validate-workflow.sh n8n-workflows/Route_Event.json
```

#### Step 5.2: Fix Code Nodes

**Pattern to fix:**
```javascript
// BEFORE (broken in runOnceForEachItem)
const data = $input.first().json;
return { json: { ctx: { ... } } };

// AFTER (works in runOnceForAllItems)
const data = $input.first().json;
return [{ json: { ctx: { ... } } }];
```

**Apply fixes:**
```bash
./tools/fix-route-event.sh

# Verify changes
git diff n8n-workflows/Route_Event.json
```

#### Step 5.3: Deploy Route_Event
```bash
ROUTE_EVENT_ID=$(./tools/kairon-ops.sh n8n-list | grep "Route_Event" | awk -F'ID: ' '{print $2}' | awk '{print $1}')

./tools/deploy-workflow.sh n8n-workflows/Route_Event.json --id $ROUTE_EVENT_ID
```

#### Step 5.4: Test Route_Event

**Test message processing:**
```bash
# Send test message
curl -X POST "https://n8n.chrisirineo.com/webhook/asoiaf92746087" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message",
    "guild_id": "test",
    "channel_id": "test", 
    "message_id": "route-test-'$(date +%s)'",
    "author": {"login": "test", "id": "test", "display_name": "Test"},
    "content": "::ping",
    "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'"
  }'

# Check event was stored
./tools/kairon-ops.sh db-query "SELECT * FROM events WHERE idempotency_key LIKE 'route-test-%' ORDER BY received_at DESC LIMIT 1;"

# Expected: 1 row with the test message
```

---

### Phase 6: Fix Route_Message & Multi_Capture (40-60 min)

These handle the actual message processing and LLM extraction.

#### Step 6.1: Fix Route_Message
```bash
# Validate
./tools/validate-workflow.sh n8n-workflows/Route_Message.json

# Fix issues
./tools/fix-route-message.sh

# Deploy
ROUTE_MESSAGE_ID=$(./tools/kairon-ops.sh n8n-list | grep "Route_Message" | awk -F'ID: ' '{print $2}' | awk '{print $1}')
./tools/deploy-workflow.sh n8n-workflows/Route_Message.json --id $ROUTE_MESSAGE_ID
```

#### Step 6.2: Fix Multi_Capture

**Known issues:**
- Multiple Code nodes use runOnceForEachItem incorrectly
- ParseResponse, CollectResults, etc.

```bash
# Validate
./tools/validate-workflow.sh n8n-workflows/Multi_Capture.json

# Fix issues
./tools/fix-multi-capture.sh

# Deploy
MULTI_CAPTURE_ID=$(./tools/kairon-ops.sh n8n-list | grep "Multi_Capture" | awk -F'ID: ' '{print $2}' | awk '{print $1}')
./tools/deploy-workflow.sh n8n-workflows/Multi_Capture.json --id $MULTI_CAPTURE_ID
```

#### Step 6.3: End-to-End Test

**Send untagged message that requires LLM processing:**
```bash
curl -X POST "https://n8n.chrisirineo.com/webhook/asoiaf92746087" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message",
    "guild_id": "test",
    "channel_id": "test",
    "message_id": "e2e-test-'$(date +%s)'",
    "author": {"login": "test", "id": "test", "display_name": "Test"},
    "content": "I spent 2 hours coding today, made good progress on the authentication system",
    "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'"
  }'

# Wait 30 seconds for LLM processing

# Check for trace
./tools/kairon-ops.sh db-query "SELECT * FROM traces WHERE created_at > NOW() - INTERVAL '1 minute' ORDER BY created_at DESC LIMIT 1;"

# Check for projection
./tools/kairon-ops.sh db-query "SELECT * FROM projections WHERE created_at > NOW() - INTERVAL '1 minute' ORDER BY created_at DESC LIMIT 1;"

# Expected: Both should return rows
```

---

### Phase 7: Fix Remaining Workflows (60-90 min)

Once the core path works, fix the remaining workflows systematically.

#### Priority Order:
1. **Execute_Command** - For command handling
2. **Capture_Projection** - For storing projections
3. **Handle_Error** - For error handling
4. **Start_Thread** - For thread creation
5. **Continue_Thread** - For thread replies
6. **Generate_Nudge** - For periodic nudges
7. **Generate_Daily_Summary** - For daily summaries
8. All others

#### Process for Each:
```bash
# 1. Validate
./tools/validate-workflow.sh n8n-workflows/<WorkflowName>.json

# 2. Fix if needed
./tools/fix-workflow.sh <WorkflowName>

# 3. Deploy
WORKFLOW_ID=$(./tools/kairon-ops.sh n8n-list | grep "<WorkflowName>" | awk -F'ID: ' '{print $2}' | awk '{print $1}')
./tools/deploy-workflow.sh n8n-workflows/<WorkflowName>.json --id $WORKFLOW_ID

# 4. Test specific functionality
# (workflow-specific test)

# 5. Monitor
./tools/db-health.sh --watch
```

---

### Phase 8: Verification & Monitoring (20-30 min)

#### Step 8.1: Full System Test
```bash
# Run comprehensive test suite
./tools/run-full-tests.sh

# Tests:
# - Message processing (tagged and untagged)
# - Command execution
# - Thread creation and continuation
# - Error handling
# - Cron jobs (nudge, summary)
# - Database integrity
```

#### Step 8.2: Monitor for 1 Hour
```bash
# Start monitoring
./tools/db-health.sh --watch

# Watch for:
# - Events without traces (should be 0)
# - Traces without projections (should be 0)
# - New traces being created
# - New projections being created
```

#### Step 8.3: Generate Post-Recovery Report
```bash
./tools/verify-system.sh > state-reports/post-recovery-$(date +%Y%m%d-%H%M).json

# Compare with pre-recovery state
./tools/compare-states.sh \
  state-reports/pre-recovery-*.json \
  state-reports/post-recovery-*.json
```

---

### Phase 9: Documentation & Hardening (30-40 min)

#### Step 9.1: Commit All Changes
```bash
# Review all changes
git status
git diff

# Commit workflow fixes
git add n8n-workflows/
git commit -m "fix: resolve n8n v2 compatibility issues in all workflows

- Replace queryReplacement with values in Postgres nodes
- Fix Code node runOnceForEachItem compatibility issues
- Remove invalid error workflow references
- Update credential references"

# Commit new tools
git add tools/
git commit -m "feat: add comprehensive diagnostic and deployment tools

Tools:
- kairon-ops.sh: Unified remote operations
- verify-system.sh: System health verification
- deploy-workflow.sh: Safe single-workflow deployment
- db-health.sh: Database health monitoring
- validate-workflow.sh: Pre-deployment validation
- fix-*.sh: Automated workflow fixes"

# Commit documentation
git add MASTER_RECOVERY_PLAN.md
git commit -m "docs: add master recovery plan and postmortem analysis"
```

#### Step 9.2: Update Main Documentation
```bash
# Update README with tool references
# Update AGENTS.md with new procedures
# Archive old recovery plans
mv CURRENT_PLAN_PLEASE_READ.md docs/archive/recovery-plan-v1.md
mv RECOVERY_PLAN.md docs/archive/recovery-plan-v2.md
```

#### Step 9.3: Create Runbook for Future Issues
```bash
# Create runbooks/
mkdir -p runbooks

# Add specific runbooks:
- runbooks/workflow-deployment.md
- runbooks/database-migration.md
- runbooks/emergency-recovery.md
- runbooks/monitoring.md
```

#### Step 9.4: Set Up Automated Monitoring

**Create systemd service for monitoring:**
```bash
# On server
cat > /etc/systemd/system/kairon-health-monitor.service <<'EOF'
[Unit]
Description=Kairon Health Monitor
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/kairon
ExecStart=/root/kairon/tools/db-health.sh --watch --alert
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable kairon-health-monitor
sudo systemctl start kairon-health-monitor
```

#### Step 9.5: Add Pre-commit Hooks

**Update `.githooks/pre-commit`:**
```bash
#!/bin/bash
# Validate all workflow files before commit

echo "Validating workflow files..."

for workflow in n8n-workflows/*.json; do
  if [[ -f "$workflow" ]]; then
    echo "Checking $workflow..."
    if ! ./tools/validate-workflow.sh "$workflow"; then
      echo "❌ Validation failed for $workflow"
      echo "Run './tools/fix-workflow.sh' to auto-fix common issues"
      exit 1
    fi
  fi
done

echo "✅ All workflows valid"
```

---

## Success Criteria

The recovery is successful when ALL of the following are true:

### Critical Metrics (Must All Pass)
- [ ] All events that should create traces have traces (gap < 5)
- [ ] All traces that should create projections have projections (gap < 5)
- [ ] Note: Ratio is NOT 1:1:1 - One trace can spawn multiple projections
- [ ] Webhook returns 200 AND data is persisted
- [ ] n8n API returns valid responses
- [ ] All core workflows show "Active: true"
- [ ] No errors in n8n logs for 1 hour

### Functional Tests (Must All Pass)
- [ ] `::ping` returns response
- [ ] `::recent` shows recent activities
- [ ] Untagged message creates activity/note/todo
- [ ] `!!` tagged message creates activity
- [ ] `++` creates thread
- [ ] Thread reply works
- [ ] Nudge cron executes successfully
- [ ] Summary cron executes successfully

### Infrastructure Health (Must All Pass)
- [ ] All Docker containers running
- [ ] Discord relay service active
- [ ] SSH access works reliably
- [ ] Database queries execute quickly (<100ms)
- [ ] n8n UI accessible
- [ ] No credential errors

### Code Quality (Must All Pass)
- [ ] All workflows validated by validate-workflow.sh
- [ ] No deprecated parameters in workflows
- [ ] No Code node compatibility issues
- [ ] All workflow references valid
- [ ] Git history clean and pushed to origin

---

## Rollback Procedures

If recovery fails or makes things worse:

### Immediate Rollback (< 5 minutes)
```bash
# Restore workflows from backup
./tools/kairon-ops.sh restore-workflows backups/workflows/YYYYMMDD-HHmm/

# Restart n8n
./tools/kairon-ops.sh restart-n8n

# Verify baseline restored
./tools/verify-system.sh
```

### Git Rollback
```bash
# Return to pre-recovery state
git reset --hard pre-recovery-YYYYMMDD-HHmm

# Re-deploy known working state
./tools/deploy-all-workflows.sh --from-git
```

### Nuclear Option - Full System Restore
```bash
# Restore database from backup
./tools/kairon-ops.sh restore-db backups/db/YYYYMMDD-HHmm/kairon.sql

# Restore workflows from backup
./tools/kairon-ops.sh restore-workflows backups/workflows/YYYYMMDD-HHmm/

# Restart all services
./tools/kairon-ops.sh restart-all

# Wait for system stabilization (5 minutes)
sleep 300

# Verify restoration
./tools/verify-system.sh
```

---

## Common Pitfalls & How to Avoid Them

### Pitfall 1: SSH Rate Limiting
**Symptom:** "Too many authentication failures"  
**Solution:** Use kairon-ops.sh which manages ControlMaster automatically  
**Prevention:** Always use the tools, never raw SSH commands

### Pitfall 2: Wrong API Key
**Symptom:** 401 or 405 responses from n8n API  
**Solution:** kairon-ops.sh sources correct key from server  
**Prevention:** Never hardcode API keys, always use the tools

### Pitfall 3: Workflow ID Confusion
**Symptom:** Deploying workflow creates duplicate instead of updating  
**Solution:** Always query for current ID before deploying  
**Prevention:** Use deploy-workflow.sh which handles IDs automatically

### Pitfall 4: Partial Deployment
**Symptom:** Some workflows fixed, others still broken  
**Solution:** Deploy Execute_Queries first, then test before proceeding  
**Prevention:** Follow phase order strictly, verify each step

### Pitfall 5: Credential Reference Issues
**Symptom:** Workflows fail silently with no errors  
**Solution:** Verify credentials exist and match by name  
**Prevention:** Use deployment tool which auto-maps credentials

### Pitfall 6: Code Node Mode Confusion
**Symptom:** Workflow shows success but data not saved  
**Solution:** Remove runOnceForEachItem mode or fix code patterns  
**Prevention:** Use validate-workflow.sh before every deployment

### Pitfall 7: Testing with Wrong Data
**Symptom:** Tests pass but real messages fail  
**Solution:** Test with real Discord data shape and content  
**Prevention:** Use test templates in tools/test-payloads/

### Pitfall 8: Not Checking Database
**Symptom:** Assuming success because webhook returns 200  
**Solution:** Always verify traces and projections in database  
**Prevention:** Use db-health.sh after every test

---

## Tools Reference

### Quick Command Reference

```bash
# System Status
./tools/kairon-ops.sh status
./tools/verify-system.sh
./tools/db-health.sh

# Workflow Operations
./tools/kairon-ops.sh n8n-list
./tools/validate-workflow.sh <file>
./tools/deploy-workflow.sh <file>

# Database Operations
./tools/kairon-ops.sh db-query "SQL"
./tools/db-health.sh --watch

# Backup & Restore
./tools/kairon-ops.sh backup
./tools/kairon-ops.sh restore-workflows <dir>

# Testing
./tools/run-full-tests.sh
./tools/send-test-message.sh <type>

# Monitoring
./tools/db-health.sh --watch
tail -f logs/kairon-health.log
```

### Tool Locations

```
/home/chris/Work/kairon/
├── tools/
│   ├── kairon-ops.sh           # Main operations script
│   ├── verify-system.sh         # System verification
│   ├── deploy-workflow.sh       # Safe workflow deployment
│   ├── db-health.sh             # Database health monitoring
│   ├── validate-workflow.sh     # Workflow validation
│   ├── fix-workflow.sh          # Auto-fix common issues
│   ├── fix-execute-queries.sh   # Fix Execute_Queries
│   ├── fix-route-event.sh       # Fix Route_Event
│   ├── fix-route-message.sh     # Fix Route_Message
│   ├── fix-multi-capture.sh     # Fix Multi_Capture
│   ├── run-full-tests.sh        # Comprehensive testing
│   ├── send-test-message.sh     # Send test messages
│   └── compare-states.sh        # Compare system states
├── state-reports/              # System state snapshots
├── backups/                    # Workflow and DB backups
└── runbooks/                   # Operational procedures
```

---

## Timeline Estimate

| Phase | Duration | Can Start | Blocking |
|-------|----------|-----------|----------|
| Phase 1: Build Tools | 30-45 min | Immediately | None |
| Phase 2: Baseline | 15-20 min | After Phase 1 | Phase 1 |
| Phase 3: Fix Infrastructure | 30-45 min | After Phase 2 | Phase 2 |
| Phase 4: Fix Execute_Queries | 20-30 min | After Phase 3 | Phase 3 |
| Phase 5: Fix Route_Event | 30-40 min | After Phase 4 | Phase 4 |
| Phase 6: Fix Route_Message/Multi_Capture | 40-60 min | After Phase 5 | Phase 5 |
| Phase 7: Fix Remaining | 60-90 min | After Phase 6 | Phase 6 |
| Phase 8: Verification | 20-30 min | After Phase 7 | Phase 7 |
| Phase 9: Documentation | 30-40 min | After Phase 8 | Phase 8 |

**Total Estimated Time:** 4-6 hours

**Critical Path:** Phase 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8  
**Parallelizable:** Phase 9 can be done async

---

## Contact & Resources

### Key Files
- This Plan: `/home/chris/Work/kairon/MASTER_RECOVERY_PLAN.md`
- Previous Postmortems: `/home/chris/Work/kairon/postmortem-*.md`
- Deployment Docs: `/home/chris/Work/kairon/scripts/DEPLOYMENT.md`
- Onboarding: `/home/chris/Work/kairon/docs/ONBOARDING-N8N-FIX.md`

### Server Details
- **SSH Alias:** `DigitalOcean`
- **IP:** `164.92.84.170`
- **Kairon Path:** `/root/kairon/`
- **n8n URL:** `https://n8n.chrisirineo.com`
- **Webhook:** `https://n8n.chrisirineo.com/webhook/asoiaf92746087`

### Database Details
- **Container:** `postgres-db`
- **Kairon DB:** `kairon`
- **User:** `n8n_user`
- **n8n DB:** `n8n_chat_memory` (for n8n internal data)

---

## Next Steps

1. **Read this entire document** to understand the full plan
2. **Start with Phase 1** - build the tools (cannot skip this!)
3. **Follow phases in order** - do not skip ahead
4. **Verify each step** before moving to the next
5. **Document any deviations** from the plan
6. **Ask for clarification** if anything is unclear

**Remember:** This is a marathon, not a sprint. Taking time to build proper tools and verify each step will result in a more reliable and maintainable system.

---

**Last Updated:** 2025-12-24 03:15 UTC  
**Version:** 1.0 - Master Recovery Plan  
**Status:** Ready for execution
