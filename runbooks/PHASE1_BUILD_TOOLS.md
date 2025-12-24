# Phase 1: Build Recovery Tools - Subagent Instructions

**Objective:** Build the diagnostic and deployment tools required for the Kairon recovery

**Estimated Time:** 30-45 minutes

**Prerequisites:** None - this is the first phase and cannot be skipped

---

## Context

You are working on the Kairon recovery project. Multiple previous agents failed because they used unreliable commands, had SSH issues, wrong API keys, etc. This phase builds robust tools that eliminate these problems.

**Important Files:**
- Main plan: `/home/chris/Work/kairon/MASTER_RECOVERY_PLAN.md`  
- Quick ref: `/home/chris/Work/kairon/RECOVERY_QUICKSTART.md`
- Project guidelines: `/home/chris/Work/kairon/AGENTS.md`

**Current State:**
- Events: 241 in 24h ✅
- Traces: 38 in 24h ❌ (should be ~150-200)  
- Projections: varies (1 trace can create multiple projections)
- Gap: ~200 events without traces

---

## Tool 1: kairon-ops.sh (Main Operations) - ✅ DONE

This tool is already created at `/home/chris/Work/kairon/tools/kairon-ops.sh`

**Test it:**
```bash
cd /home/chris/Work/kairon
./tools/kairon-ops.sh status
./tools/kairon-ops.sh help
```

**Note:** The n8n API may return 401 errors - this is a known issue we'll fix in Phase 3.

---

## Tool 2: verify-system.sh (System Health Check)

Create `/home/chris/Work/kairon/tools/verify-system.sh`

**Purpose:** Comprehensive system health check with JSON output

**Requirements:**
- Check all Docker containers
- Check Discord relay service  
- Check database metrics (events, traces, projections in last 24h)
- Check data pipeline health (events without traces)
- Output as JSON for automation
- Save report to `state-reports/YYYY-MM-DD-HHmm.json`

**Template provided in MASTER_RECOVERY_PLAN.md Phase 1, Tool 2**

**Implementation Steps:**
1. Read the template from MASTER_RECOVERY_PLAN.md
2. Create the file using the Write tool
3. Make it executable with `chmod +x`
4. Test: `./tools/verify-system.sh`
5. Verify it creates a report in `state-reports/`

---

## Tool 3: db-health.sh (Database Health Monitor)

Create `/home/chris/Work/kairon/tools/db-health.sh`

**Purpose:** Monitor the health of data flow through the system

**Requirements:**
- Show event processing pipeline metrics (1h and 24h)
- Show recent activity (last event, trace, projection with timestamps)
- Calculate events without traces
- Health status: ✅ HEALTHY if < 5 events without traces, ❌ DEGRADED otherwise
- Support `--watch` flag for continuous monitoring (optional)

**Template provided in MASTER_RECOVERY_PLAN.md Phase 1, Tool 3**

**Implementation Steps:**
1. Read the template from MASTER_RECOVERY_PLAN.md
2. Create the file using the Write tool
3. Make it executable with `chmod +x`
4. Test: `./tools/db-health.sh`
5. Verify it shows health status correctly

---

## Tool 4: validate-workflow.sh (Workflow Validator)

Create `/home/chris/Work/kairon/tools/validate-workflow.sh`

**Purpose:** Validate workflow JSON for known issues before deployment

**Requirements:**
- Check JSON syntax validity (use `jq`)
- Check for deprecated parameters (`queryReplacement` in Postgres nodes)
- Check for Code node issues (`runOnceForEachItem` + forbidden patterns)
- Check for missing required nodes (Webhook trigger, etc.)
- Return exit code 0 for valid, 1 for invalid

**Checks to implement:**
```bash
# 1. JSON syntax
jq empty "$workflow_file" 2>/dev/null || error "Invalid JSON"

# 2. Deprecated queryReplacement
if jq -e '.nodes[] | select(.type=="n8n-nodes-base.postgres") | .parameters.options.queryReplacement' "$workflow_file" >/dev/null 2>&1; then
    error "Found deprecated queryReplacement (use 'values' instead)"
fi

# 3. Code node runOnceForEachItem issues
# Check for code nodes with mode:"runOnceForEachItem" AND using $input.first()/$input.last()/$input.all()
```

**Implementation Steps:**
1. Create the script with checks listed above
2. Make it executable
3. Test on known-bad workflow: `./tools/validate-workflow.sh n8n-workflows/Execute_Queries.json`
4. Should report queryReplacement issue
5. Verify exit codes work correctly

---

## Tool 5: deploy-workflow.sh (Safe Deployment)

Create `/home/chris/Work/kairon/tools/deploy-workflow.sh`

**Purpose:** Safe single-workflow deployment with rollback capability

**Requirements:**
- Validate workflow before upload (use validate-workflow.sh)
- Backup current workflow version
- Sanitize workflow (remove pinData, clean credential refs)
- Upload via n8n API
- Verify deployment success
- Can rollback on failure

**Key features:**
```bash
# Usage patterns:
./tools/deploy-workflow.sh Route_Event.json              # Interactive
./tools/deploy-workflow.sh Route_Event.json --force      # Skip confirmation
./tools/deploy-workflow.sh --rollback Route_Event        # Restore backup
```

**Implementation Steps:**
1. Start with validation check
2. Use kairon-ops.sh for n8n API access
3. Create backup before deploying
4. Use jq to sanitize: `jq '{name, nodes, connections, settings}' workflow.json`
5. Deploy via API
6. Verify with API GET request
7. Store backup with timestamp

---

## Completion Checklist

When done, verify all tools work:

```bash
cd /home/chris/Work/kairon

# Tool 1 - kairon-ops.sh
./tools/kairon-ops.sh status          # Should show system status
./tools/kairon-ops.sh db-query "SELECT 1;"  # Should return 1

# Tool 2 - verify-system.sh
./tools/verify-system.sh              # Should create JSON report
ls -l state-reports/*.json            # Should see new file

# Tool 3 - db-health.sh
./tools/db-health.sh                  # Should show health metrics
# Should show either ✅ HEALTHY or ❌ DEGRADED

# Tool 4 - validate-workflow.sh
./tools/validate-workflow.sh n8n-workflows/Execute_Queries.json
# Should report issues (if any)

# Tool 5 - deploy-workflow.sh
./tools/deploy-workflow.sh --help     # Should show usage
```

---

## Success Criteria

- [ ] All 5 tools created and executable
- [ ] kairon-ops.sh can run status and db-query
- [ ] verify-system.sh creates JSON reports
- [ ] db-health.sh shows health status
- [ ] validate-workflow.sh can detect issues
- [ ] deploy-workflow.sh has backup/restore capability
- [ ] All tools use kairon-ops.sh (don't call rdev directly)

---

## Common Issues

**Issue: Permission denied**
```bash
chmod +x tools/*.sh
```

**Issue: rdev not found**
- rdev should be at `~/.local/bin/rdev`
- Check PATH includes `~/.local/bin`

**Issue: n8n API returns 401**
- This is expected! We'll fix in Phase 3
- For now, just ensure the tool tries to connect

**Issue: SSH connection issues**
- rdev handles this with ControlMaster
- Should work automatically

---

## Next Phase

Once all tools are built and tested, proceed to:
**Phase 2: Establish Baseline & Backup**

DO NOT proceed until all tools are working!

---

## Questions?

Refer to:
- `/home/chris/Work/kairon/MASTER_RECOVERY_PLAN.md` - Complete plan
- `/home/chris/Work/kairon/RECOVERY_QUICKSTART.md` - Quick reference
- Global AGENTS.md - Tool usage guidelines
