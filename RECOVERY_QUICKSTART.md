# Kairon Recovery - Quick Start Guide

**READ THIS FIRST:** This is a quick reference. Full details in `MASTER_RECOVERY_PLAN.md`

---

## Current Situation (As of 2025-12-24 03:15 UTC)

**Status:** 🔴 CRITICAL - Data not being persisted

### What's Broken
- ❌ Traces not being created (38 in 24h, should be ~240)
- ❌ Projections not being created
- ❌ n8n API not responding correctly
- ❌ Workflows have deprecated parameters
- ❌ Code nodes incompatible with n8n v2

### What's Working
- ✅ Discord relay forwarding messages
- ✅ Events being stored (241 in 24h)
- ✅ Containers running
- ✅ Database accessible
- ✅ Basic commands (::ping) work

---

## Recovery Phases - DO NOT SKIP ANY

### Phase 1: Build Tools (30-45 min) ⚠️ REQUIRED
Build diagnostic and deployment tools. **You cannot skip this!**

```bash
cd /home/chris/Work/kairon

# Create tools directory
mkdir -p tools state-reports backups runbooks

# Build tools (see Phase 1 in master plan)
# - kairon-ops.sh
# - verify-system.sh
# - deploy-workflow.sh
# - db-health.sh
# - validate-workflow.sh
```

**Why this is critical:** Previous agents failed because they used unreliable commands. These tools handle SSH issues, API keys, and validation automatically.

### Phase 2: Baseline (15-20 min)
Backup everything before making changes.

```bash
# Run verification
./tools/verify-system.sh > state-reports/pre-recovery-$(date +%Y%m%d-%H%M).json

# Backup workflows and database
./tools/kairon-ops.sh backup

# Create recovery branch
git checkout -b recovery/2025-12-24-master-plan
git add -A
git commit -m "snapshot: pre-recovery state"
git tag pre-recovery-$(date +%Y%m%d-%H%M)
```

### Phase 3: Fix Infrastructure (30-45 min)
Fix n8n API, error workflow references, credentials.

### Phase 4: Fix Execute_Queries (20-30 min) 🎯 CRITICAL PATH
This is THE bottleneck. Nothing works until this is fixed.

**Issues:**
- Uses `queryReplacement` (deprecated) instead of `values`
- May have Code node v2 issues

### Phase 5: Fix Route_Event (30-40 min)
The entry point - must work for anything to process.

### Phase 6: Fix Route_Message & Multi_Capture (40-60 min)
The processing pipeline.

### Phase 7: Fix Remaining Workflows (60-90 min)
All other workflows systematically.

### Phase 8: Verification (20-30 min)
Test everything, monitor for 1 hour.

### Phase 9: Documentation (30-40 min)
Commit, document, create runbooks.

---

## Critical Tools to Build First

### 1. kairon-ops.sh (Main Operations Tool)

**Location:** `tools/kairon-ops.sh`

**Template:**
```bash
#!/bin/bash
# Kairon Operations - Unified remote operations tool

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# SSH host from global config
SSH_HOST="DigitalOcean"

# Use ControlMaster for connection reuse
export SSH_OPTS="-o ControlMaster=auto -o ControlPath=~/.ssh/sockets/%r@%h-%p -o ControlPersist=600"

# Ensure socket directory exists
mkdir -p ~/.ssh/sockets

# Function: Get API key from server
get_api_key() {
    ssh $SSH_OPTS $SSH_HOST 'grep "^N8N_API_KEY=" ~/kairon/.env | cut -d= -f2'
}

# Function: Run SQL query on kairon database
db_query() {
    local query="$1"
    ssh $SSH_OPTS $SSH_HOST "docker exec postgres-db psql -U n8n_user -d kairon -c \"$query\""
}

# Function: List all workflows
n8n_list() {
    local api_key=$(get_api_key)
    ssh $SSH_OPTS $SSH_HOST "curl -s -H 'X-N8N-API-KEY: $api_key' 'http://localhost:5678/api/v1/workflows'" | \
        jq -r '.data[]? | "\(.name) - ID: \(.id) - Active: \(.active)"'
}

# Function: Get workflow by ID
n8n_get() {
    local workflow_id="$1"
    local api_key=$(get_api_key)
    ssh $SSH_OPTS $SSH_HOST "curl -s -H 'X-N8N-API-KEY: $api_key' 'http://localhost:5678/api/v1/workflows/$workflow_id'"
}

# Function: System status
status() {
    echo "=== Docker Containers ==="
    ssh $SSH_OPTS $SSH_HOST 'docker ps --format "table {{.Names}}\t{{.Status}}"'
    echo ""
    echo "=== Discord Relay ==="
    ssh $SSH_OPTS $SSH_HOST 'systemctl status kairon-relay.service --no-pager | head -10'
    echo ""
    echo "=== Database Health ==="
    db_query "SELECT 'Events (24h)' as metric, COUNT(*)::text as count FROM events WHERE received_at > NOW() - INTERVAL '24 hours'
              UNION ALL
              SELECT 'Traces (24h)', COUNT(*)::text FROM traces WHERE created_at > NOW() - INTERVAL '24 hours'
              UNION ALL
              SELECT 'Projections (24h)', COUNT(*)::text FROM projections WHERE created_at > NOW() - INTERVAL '24 hours';"
}

# Function: Backup workflows and database
backup() {
    local backup_dir="$PROJECT_ROOT/backups/$(date +%Y%m%d-%H%M)"
    mkdir -p "$backup_dir/workflows" "$backup_dir/state"
    
    echo "Creating backup in $backup_dir"
    
    # Get all workflow IDs
    local api_key=$(get_api_key)
    local workflow_ids=$(ssh $SSH_OPTS $SSH_HOST "curl -s -H 'X-N8N-API-KEY: $api_key' 'http://localhost:5678/api/v1/workflows'" | \
        jq -r '.data[]?.id')
    
    # Download each workflow
    for id in $workflow_ids; do
        local name=$(ssh $SSH_OPTS $SSH_HOST "curl -s -H 'X-N8N-API-KEY: $api_key' 'http://localhost:5678/api/v1/workflows/$id'" | \
            jq -r '.name')
        echo "Backing up $name ($id)..."
        n8n_get "$id" > "$backup_dir/workflows/${name}.json"
    done
    
    # Backup database
    echo "Backing up database..."
    ssh $SSH_OPTS $SSH_HOST "docker exec postgres-db pg_dump -U n8n_user kairon" > "$backup_dir/kairon.sql"
    
    echo "Backup complete: $backup_dir"
}

# Main command dispatcher
case "$1" in
    status) status ;;
    db-query) db_query "$2" ;;
    n8n-list) n8n_list ;;
    n8n-get) n8n_get "$2" ;;
    backup) backup ;;
    *) 
        echo "Kairon Operations Tool"
        echo ""
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  status              - Show system status"
        echo "  db-query <SQL>      - Run SQL query on kairon database"
        echo "  n8n-list            - List all workflows"
        echo "  n8n-get <ID>        - Get workflow JSON by ID"
        echo "  backup              - Backup all workflows and database"
        exit 1
        ;;
esac
```

**Make it executable:**
```bash
chmod +x tools/kairon-ops.sh
```

### 2. verify-system.sh (System Health Check)

**Location:** `tools/verify-system.sh`

```bash
#!/bin/bash
# System verification and health check

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_TOOL="$SCRIPT_DIR/kairon-ops.sh"

echo "{"
echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
echo "  \"status\": \"checking\","

# Docker containers
echo "  \"containers\": ["
$OPS_TOOL status | grep -A 10 "Docker Containers" | tail -n +2 | head -6 | while read line; do
    echo "    \"$line\","
done | sed '$ s/,$//'
echo "  ],"

# Database metrics
echo "  \"database\": {"
$OPS_TOOL db-query "
    SELECT json_build_object(
        'events_24h', (SELECT COUNT(*) FROM events WHERE received_at > NOW() - INTERVAL '24 hours'),
        'traces_24h', (SELECT COUNT(*) FROM traces WHERE created_at > NOW() - INTERVAL '24 hours'),
        'projections_24h', (SELECT COUNT(*) FROM projections WHERE created_at > NOW() - INTERVAL '24 hours'),
        'last_event', (SELECT MAX(received_at) FROM events),
        'last_trace', (SELECT MAX(created_at) FROM traces),
        'last_projection', (SELECT MAX(created_at) FROM projections)
    );" | grep '{' | head -1
echo "  },"

# Workflows
echo "  \"workflows\": ["
$OPS_TOOL n8n-list 2>/dev/null | while read line; do
    echo "    \"$line\","
done | sed '$ s/,$//'
echo "  ]"

echo "}"
```

**Make it executable:**
```bash
chmod +x tools/verify-system.sh
```

### 3. db-health.sh (Database Health Monitor)

**Location:** `tools/db-health.sh`

```bash
#!/bin/bash
# Database health monitoring

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_TOOL="$SCRIPT_DIR/kairon-ops.sh"

echo "=== Kairon Database Health Check ==="
echo "Time: $(date)"
echo ""

# Critical metrics
echo "--- Event Processing Pipeline ---"
$OPS_TOOL db-query "
    WITH metrics AS (
        SELECT
            (SELECT COUNT(*) FROM events WHERE received_at > NOW() - INTERVAL '1 hour') as events_1h,
            (SELECT COUNT(*) FROM traces WHERE created_at > NOW() - INTERVAL '1 hour') as traces_1h,
            (SELECT COUNT(*) FROM projections WHERE created_at > NOW() - INTERVAL '1 hour') as projections_1h,
            (SELECT COUNT(*) FROM events WHERE received_at > NOW() - INTERVAL '24 hours') as events_24h,
            (SELECT COUNT(*) FROM traces WHERE created_at > NOW() - INTERVAL '24 hours') as traces_24h,
            (SELECT COUNT(*) FROM projections WHERE created_at > NOW() - INTERVAL '24 hours') as projections_24h
    )
    SELECT 
        'Last Hour:' as period,
        events_1h as events,
        traces_1h as traces,
        projections_1h as projections,
        (events_1h - traces_1h) as events_without_traces
    FROM metrics
    UNION ALL
    SELECT
        'Last 24 Hours:',
        events_24h,
        traces_24h,
        projections_24h,
        (events_24h - traces_24h)
    FROM metrics;
"

echo ""
echo "--- Recent Activity ---"
$OPS_TOOL db-query "
    SELECT
        'Last Event:' as type,
        TO_CHAR(MAX(received_at), 'YYYY-MM-DD HH24:MI:SS UTC') as timestamp,
        EXTRACT(EPOCH FROM (NOW() - MAX(received_at)))::int || 's ago' as age
    FROM events
    UNION ALL
    SELECT
        'Last Trace:',
        TO_CHAR(MAX(created_at), 'YYYY-MM-DD HH24:MI:SS UTC'),
        EXTRACT(EPOCH FROM (NOW() - MAX(created_at)))::int || 's ago'
    FROM traces
    UNION ALL
    SELECT
        'Last Projection:',
        TO_CHAR(MAX(created_at), 'YYYY-MM-DD HH24:MI:SS UTC'),
        EXTRACT(EPOCH FROM (NOW() - MAX(created_at)))::int || 's ago'
    FROM projections;
"

echo ""
echo "--- Health Status ---"
events_without_traces=$($OPS_TOOL db-query "SELECT COUNT(*) FROM events e WHERE received_at > NOW() - INTERVAL '1 hour' AND NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id);" | grep -o '[0-9]*' | head -1)

if [ "$events_without_traces" -lt 5 ]; then
    echo "✅ HEALTHY - Event-to-trace pipeline working"
else
    echo "❌ DEGRADED - $events_without_traces events without traces in last hour"
fi
```

**Make it executable:**
```bash
chmod +x tools/db-health.sh
```

---

## Quick Status Check

Run this immediately to see current state:

```bash
cd /home/chris/Work/kairon

# Check if tools exist
if [ ! -f tools/kairon-ops.sh ]; then
    echo "⚠️  Tools not built yet. Start with Phase 1!"
else
    echo "✅ Tools found. Running health check..."
    ./tools/kairon-ops.sh status
    echo ""
    ./tools/db-health.sh
fi
```

---

## Emergency Contacts

- **Full Plan:** `MASTER_RECOVERY_PLAN.md`
- **Previous Issues:** `postmortem-*.md`
- **Server:** `ssh DigitalOcean` (164.92.84.170)
- **n8n:** https://n8n.chrisirineo.com

---

## DO NOT:
- ❌ Skip Phase 1 (building tools)
- ❌ Deploy multiple workflows at once
- ❌ Use raw SSH commands
- ❌ Assume webhook 200 = success
- ❌ Use `rdev n8n push` for deployment
- ❌ Make changes without backup

## DO:
- ✅ Follow phases in order
- ✅ Use the tools for everything
- ✅ Verify database after each test
- ✅ Backup before making changes
- ✅ Check db-health.sh frequently
- ✅ Read the full master plan

---

**Start with Phase 1. Build the tools. Do not skip this step.**

Good luck! 🚀
