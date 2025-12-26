# Kairon Tooling Improvement Plan

## Executive Summary

Based on the issues documented in `TOOLING_ISSUES_WORKAROUNDS.md` and analysis of the current tooling, this plan outlines improvements to reduce debugging overhead from ~2 hours to ~15 minutes per deployment cycle.

**Current Pain Points:**
- kairon-ops.sh only supports production (via rdev)
- Deployment script silently fails while reporting success
- No unified way to manage dev/prod environments
- Workflow ID mismatches cause confusion
- API credentials handling is error-prone
- Integration testing requires manual verification

**Goal:** Single, unified tooling that works transparently across dev/prod with clear feedback.

---

## Shared Tooling (Reusable Across Projects)

All generic utilities are now in `~/.local/share/remote-dev/`:

| File | Purpose | Functions |
|------|---------|-----------|
| `lib/json-helpers.sh` | jq wrappers | `json_array`, `json_get`, `json_find`, `json_map`, `json_filter`, `json_keys`, `json_to_csv`, etc. |
| `lib/credential-helper.sh` | Credential management | `init_credentials`, `api_get`, `api_call`, `api_ping`, `db_query`, `db_backup` |
| `lib/deploy-verify.sh` | Deployment verification | `verify_deployment`, `verify_workflows`, `quick_verify`, `verify_health`, `generate_report` |
| `templates/ops-wrapper.sh` | Project ops template | `--dev`/`--prod` flags, common commands, rdev integration |
| `test-suite.sh` | Test suite | Tests for all utilities |

**Installation:** The toolkit is already installed at `~/.local/share/remote-dev/`

**Documentation:** See `~/.local/share/remote-dev/README.md` for full API reference

---

## Kairon-Specific Improvements

### Phase 1: Update kairon-ops.sh (2-3 hours)

Replace current implementation with shared credential helper:

```bash
# At top of kairon-ops.sh
source ~/.local/share/remote-dev/lib/json-helpers.sh
source ~/.local/share/remote-dev/lib/credential-helper.sh

# Replace _init_environment with:
_init_environment() {
    local prefix
    case "$ENVIRONMENT" in
        dev|development) prefix="DEV" ;;
        prod|production) prefix="PROD" ;;
    esac
    
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        set -a
        source "$PROJECT_ROOT/.env"
        set +a
    fi
    
    # Use credential-helper to set all CRED_* vars
    init_credentials "$ENVIRONMENT"
    
    # Export for n8n operations
    export N8N_API_URL="$CRED_API_URL"
    export N8N_API_KEY="$CRED_API_KEY"
}
```

### Phase 2: Update deploy.sh (1-2 hours)

Add verification using shared deploy-verify.sh:

```bash
# At top
source ~/.local/share/remote-dev/lib/deploy-verify.sh

# After n8n-push-local.sh, call:
verify_workflows "$N8N_API_URL" "$N8N_API_KEY" "$TEMP_DIR"
```

### Phase 3: Create kairon-credentials.sh (1 hour)

Wrapper for project-specific env vars:

```bash
#!/bin/bash
# Kairon credential helper
source ~/.local/share/remote-dev/lib/credential-helper.sh

ENVIRONMENT="${1:-dev}"
init_credentials --api-url "${N8N_DEV_API_URL:-http://localhost:5679}" \
    --api-key "$N8N_DEV_API_KEY" \
    --db-container "${CONTAINER_DB:-postgres-dev}" \
    --db-name "${DB_NAME:-kairon_dev}" \
    "$ENVIRONMENT"

# Export for direct use
export N8N_API_URL="$CRED_API_URL"
export N8N_API_KEY="$CRED_API_KEY"
```

### Phase 4: Create workflow registry (2-3 hours)

```bash
# scripts/manage-workflow-registry.sh
source ~/.local/share/remote-dev/lib/credential-helper.sh

case "$1" in
    dev) init_credentials "dev" ;;
    prod) init_credentials "prod" ;;
esac

api_get "/api/v1/workflows?limit=100" | \
    jq -r --arg env "$1" '{($env): [.data[]? | {(.name): .id}] | add}' > \
    scripts/workflow-registry.json
```

### Phase 5: Update test-all-paths.sh (2 hours)

```bash
# Add DB verification using credential helper
source "$(dirname "$0")/../scripts/kairon-credentials.sh" dev

# Replace docker exec with:
db_query() {
    docker exec "$CRED_CONTAINER_DB" psql -U "$CRED_DB_USER" -d "$CRED_DB_NAME" -c "$1"
}
```

### Phase 6: Documentation (2-3 hours)

Update `docs/TOOLING.md` to reference shared toolkit and add examples.

---

## Implementation Order

| Phase | Priority | Effort | Reuses |
|-------|----------|--------|--------|
| Phase 1: Update kairon-ops.sh | HIGH | 2-3h | credential-helper.sh |
| Phase 2: Deployment Verification | HIGH | 1-2h | deploy-verify.sh |
| Phase 3: Credential Helper | HIGH | 1h | credential-helper.sh |
| Phase 4: ID Registry | MEDIUM | 2-3h | credential-helper.sh |
| Phase 5: Integration Tests | MEDIUM | 2h | credential-helper.sh |
| Phase 6: Documentation | HIGH | 2-3h | - |

**Total Estimated Effort:** 10-14 hours

---

## Testing

Run the test suite:
```bash
~/.local/share/remote-dev/test-suite.sh
```

---

## Files Modified/Created

| File | Action |
|------|--------|
| `~/.local/share/remote-dev/lib/json-helpers.sh` | Created (11KB, 40+ functions) |
| `~/.local/share/remote-dev/lib/credential-helper.sh` | Created (13KB, 20+ functions) |
| `~/.local/share/remote-dev/lib/deploy-verify.sh` | Created (13KB, 10+ functions) |
| `~/.local/share/remote-dev/templates/ops-wrapper.sh` | Created (15KB, template) |
| `~/.local/share/remote-dev/test-suite.sh` | Created (9KB, comprehensive tests) |
| `~/.local/share/remote-dev/README.md` | Created (6KB documentation) |
| `~/.local/share/remote-dev/CHANGELOG.md` | Created |

**All generic tooling is complete and tested.**

---

## Phase 1: Unified kairon-ops.sh with Dev Support (Priority: HIGH)

### 1.1 Add Environment Flag to kairon-ops.sh

**Problem:** kairon-ops.sh always connects to production via rdev, making it useless for local dev work.

**Solution:** Add `--dev` / `--prod` flags to all n8n and db commands. Uses the shared ops-wrapper pattern from `~/.local/share/remote-dev/templates/ops-wrapper.sh`.

**Changes to `tools/kairon-ops.sh`:**
```bash
# Source shared JSON helpers
source ~/.local/share/remote-dev/lib/json-helpers.sh

ENVIRONMENT="prod"  # default

# Parse --dev/--prod flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --dev) ENVIRONMENT="dev"; shift ;;
        --prod) ENVIRONMENT="prod"; shift ;;
        *) break ;;
    esac
done

# Initialize credentials (uses shared credential-helper.sh)
case "$ENVIRONMENT" in
    dev)
        export CRED_API_URL="${N8N_DEV_API_URL:-http://localhost:5679}"
        export CRED_API_KEY="$N8N_DEV_API_KEY"
        export CRED_CONTAINER_DB="${CONTAINER_DB_DEV:-postgres-dev}"
        export CRED_DB_NAME="${DB_NAME_DEV:-kairon_dev}"
        ;;
    prod)
        export CRED_API_URL="${N8N_API_URL:-http://localhost:5678}"
        export CRED_API_KEY="$N8N_API_KEY"
        export CRED_CONTAINER_DB="${CONTAINER_DB:-postgres-db}"
        export CRED_DB_NAME="${DB_NAME:-kairon}"
        ;;
esac
```

**New Commands:**
- `./tools/kairon-ops.sh --dev status` - Local dev status
- `./tools/kairon-ops.sh --dev n8n-list` - List dev workflows
- `./tools/kairon-ops.sh --dev n8n-get <ID>` - Get dev workflow
- `./tools/kairon-ops.sh --dev db-query "SELECT..."` - Query dev DB

**Backward Compatibility:** `--prod` or no flag = current behavior

**Estimated Effort:** 2-3 hours (leverages shared infrastructure)
**Files Modified:** `tools/kairon-ops.sh`
**Tests Added:** None (manual verification)

---

## Phase 2: Robust Deployment Verification (Priority: HIGH)

### 2.1 Add Deployment Verification to deploy.sh

**Problem:** `deploy.sh dev` reports "✅ PASSED" even when workflows aren't updated.

**Solution:** Verify actual workflow state after deployment using the shared deploy-verify.sh.

**Changes to `scripts/deploy.sh`:**
```bash
# Source shared deployment verification
source ~/.local/share/remote-dev/lib/deploy-verify.sh

# Replace verification section with:
verify_deployment() {
    local api_url="${N8N_DEV_API_URL:-http://localhost:5679}"
    local api_key="$N8N_DEV_API_KEY"
    local source_dir="$TEMP_DIR"
    
    verify_deployment "dev" "$source_dir" "$api_url" "$api_key"
    return $?
}
```

**Additional Logging:** Capture and display the actual workflow IDs created/updated:
```
Pushing workflows to http://localhost:5679
   Source: /tmp/tmp.abc123

   Found 12 accessible workflows
   Updated: Route_Event (id: F60v1kSn9JKWkZgZ)
   Updated: Execute_Command (id: abc123)
   Created: New_Workflow (id: xyz789)

Push complete: 1 created, 11 updated, 0 failed
```

**Estimated Effort:** 1-2 hours (leveraging shared deploy-verify.sh)
**Files Modified:** `scripts/deploy.sh`
**Tests Added:** Manual verification of deployment output

---

## Phase 3: Workflow ID Mapping System (Priority: MEDIUM)

### 3.1 Persistent Workflow ID Registry

**Problem:** Local workflow IDs differ from deployed IDs, causing confusion about which workflow is being updated.

**Solution:** Maintain a local registry that maps local workflow names to their deployed IDs for each environment.

**Create `scripts/workflow-registry.json`:**
```json
{
  "dev": {
    "Route_Event": "F60v1kSn9JKWkZgZ",
    "Execute_Command": "abc123def456",
    "Capture_Projection": "xyz789abc123"
  },
  "prod": {
    "Route_Event": "prod-id-1",
    "Execute_Command": "prod-id-2",
    "Capture_Projection": "prod-id-3"
  }
}
```

**Create `scripts/manage-workflow-registry.sh`:**
```bash
#!/bin/bash
# Sync workflow IDs from deployed environments to local registry

ENVIRONMENT="${1:-dev}"
REGISTRY_FILE="$(dirname "$0")/workflow-registry.json"

# Source credential helper for API access
source ~/.local/share/remote-dev/lib/credential-helper.sh

case "$ENVIRONMENT" in
    dev)
        init_credentials "dev"
        ;;
    prod)
        init_credentials "prod"
        ;;
    *)
        echo "Usage: $0 [dev|prod]"
        exit 1
        ;;
esac

# Fetch all workflows and update registry
api_get "/api/v1/workflows?limit=100" | \
    jq -r --arg env "$ENVIRONMENT" '
        {($env): [.data[]? | {(.name): .id}] | add // {}}
    ' > /tmp/registry_update.json

# Merge with existing registry (preserving other environment)
if [ -f "$REGISTRY_FILE" ]; then
    jq -s '.[0] * .[1]' "$REGISTRY_FILE" /tmp/registry_update.json > "$REGISTRY_FILE.tmp"
    mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"
else
    cp /tmp/registry_update.json "$REGISTRY_FILE"
fi

echo "Updated $ENVIRONMENT workflow registry"
```

**Update `n8n-push-local.sh`** to use registry:
```bash
# Before processing, load registry
if [ -f "$SCRIPT_DIR/workflow-registry.json" ]; then
    REGISTRY=$(cat "$SCRIPT_DIR/workflow-registry.json")
    DEV_REGISTRY=$(echo "$REGISTRY" | jq -r ".${ENVIRONMENT:-dev} // {}")
else
    DEV_REGISTRY="{}"
fi

# When updating workflow, also update registry
if [ -n "$existing_id" ]; then
    # Update workflow...
    
    # Update local registry
    REGISTRY=$(cat "$SCRIPT_DIR/workflow-registry.json" 2>/dev/null || echo "{}")
    NEW_REGISTRY=$(echo "$REGISTRY" | jq --arg env "${ENVIRONMENT:-dev}" \
        --arg name "$name" --arg id "$existing_id" '
        .[$env][$name] = $id
    ')
    echo "$NEW_REGISTRY" > "$SCRIPT_DIR/workflow-registry.json"
fi
```

**Usage:**
```bash
# Sync IDs from dev after deployment
./scripts/manage-workflow-registry.sh dev

# View current registry
cat scripts/workflow-registry.json
```

**Estimated Effort:** 2-3 hours
**Files Created:** `scripts/manage-workflow-registry.sh`
**Files Modified:** `scripts/workflows/n8n-push-local.sh`

---

## Phase 4: API Credential Helper (Priority: HIGH)

### 4.1 Unified Credential Management

**Problem:** Users must manually extract and export API keys, leading to errors.

**Solution:** Use the shared credential-helper.sh from the remote-dev toolkit.

**Create `scripts/kairon-credentials.sh`:**
```bash
#!/bin/bash
# Kairon credential helper - wraps remote-dev credential-helper.sh
# Source this file: source ./scripts/kairon-credentials.sh [dev|prod]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source remote-dev credential helper
source ~/.local/share/remote-dev/lib/credential-helper.sh

ENVIRONMENT="${1:-dev}"

# Initialize with project-specific env var names
init_credentials \
    --api-url "${N8N_DEV_API_URL:-http://localhost:5679}" \
    --api-key "$N8N_DEV_API_KEY" \
    --db-container "${CONTAINER_DB_DEV:-postgres-dev}" \
    --db-name "${DB_NAME_DEV:-kairon_dev}" \
    "$ENVIRONMENT"

# Export additional Kairon-specific variables
export KAIRON_ENV="$CRED_ENV"
export N8N_API_URL="$CRED_API_URL"
export N8N_API_KEY="$CRED_API_KEY"
```

**Usage:**
```bash
# In shell sessions
source ./scripts/kairon-credentials.sh dev
echo $N8N_API_KEY  # Now set correctly

# In scripts
source ./scripts/kairon-credentials.sh prod
curl -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_API_URL/api/v1/workflows"
```

**Estimated Effort:** 1 hour (wrapper around shared library)
**Files Created:** `scripts/kairon-credentials.sh`

---

## Phase 5: Enhanced Integration Testing (Priority: MEDIUM)

### 5.1 Add Database Verification to test-all-paths.sh

**Problem:** test-all-paths.sh verifies messages are sent but doesn't confirm they were processed.

**Solution:** Add automatic database verification using the shared credential helper.

**Changes to `tools/test-all-paths.sh`:**

```bash
# Source shared helpers
source "$SCRIPT_DIR/../scripts/kairon-credentials.sh" "$([ "$DEV_MODE" = true ] && echo "dev" || echo "prod")"

verify_database_processing() {
    local test_count="$TOTAL_TESTS"
    local timeout="${1:-30}"  # seconds
    
    echo ""
    echo "=== Database Verification ==="
    echo "Waiting for async processing (${timeout}s timeout)..."
    
    # Wait for processing with periodic checks
    local elapsed=0
    local processed=0
    
    while [ $elapsed -lt $timeout ]; do
        processed=$(db_query "
            SELECT COUNT(*) FROM events 
            WHERE (idempotency_key LIKE 'test-msg-%' OR payload->>'discord_message_id' LIKE 'test-msg-%')
            AND received_at > NOW() - INTERVAL '10 minutes'
        " 2>/dev/null | grep -oP '\d+' | head -1 || echo "0")
        
        if [ "$processed" -gt 0 ]; then
            break
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    echo ""
    
    if [ "${processed:-0}" -eq 0 ]; then
        echo "  ⚠️  No test events found in database (n8n may be down)"
        return 1
    fi
    
    echo "  ✅ Found $processed / $test_count test events in database"
    
    # Additional verification: check for traces (processed by workflows)
    local traced
    traced=$(db_query "
        SELECT COUNT(*) FROM traces t
        JOIN events e ON e.id = t.event_id
        WHERE (e.idempotency_key LIKE 'test-msg-%' OR e.payload->>'discord_message_id' LIKE 'test-msg-%')
        AND e.received_at > NOW() - INTERVAL '10 minutes'
    " 2>/dev/null | grep -oP '\d+' | head -1 || echo "0")
    
    echo "  ✅ $traced events processed by workflows (have traces)"
    
    if [ "$traced" -lt "$processed" ]; then
        echo "  ⚠️  Some events not fully processed"
        return 1
    fi
    
    return 0
}
```

**Estimated Effort:** 2 hours
**Files Modified:** `tools/test-all-paths.sh`

---

## Phase 6: Documentation Overhaul (Priority: HIGH)

### 6.1 Create Tooling Documentation

**Create `docs/TOOLING.md`:**
```markdown
# Kairon Development Tooling Guide

## Quick Reference

| Task | Dev Command | Prod Command |
|------|-------------|--------------|
| Check status | `./tools/kairon-ops.sh --dev status` | `./tools/kairon-ops.sh status` |
| List workflows | `./tools/kairon-ops.sh --dev n8n-list` | `./tools/kairon-ops.sh n8n-list` |
| Get workflow | `./tools/kairon-ops.sh --dev n8n-get <ID>` | `./tools/kairon-ops.sh n8n-get <ID>` |
| Query DB | `./tools/kairon-ops.sh --dev db-query "SQL"` | `./tools/kairon-ops.sh db-query "SQL"` |
| Run tests | `./tools/test-all-paths.sh --dev` | `./tools/test-all-paths.sh` |
| Deploy | `./scripts/deploy.sh dev` | `./scripts/deploy.sh prod` |

## Environment Setup

### For Dev Work
```bash
# Source credentials for dev environment
source ./scripts/kairon-credentials.sh dev

# Start dev n8n (on server)
ssh $N8N_DEV_SSH_HOST "cd /opt/n8n-docker-caddy && docker-compose -f docker-compose.dev.yml up -d"

# Tunnel to dev (if working locally)
./scripts/deploy.sh dev  # Opens tunnel automatically
```

### For Prod Operations
```bash
# Source credentials for prod
source ./scripts/kairon-credentials.sh prod

# All kairon-ops.sh commands work without --dev flag
./tools/kairon-ops.sh status
./tools/kairon-ops.sh db-query "SELECT ..."
```

## Common Workflows

### Deploy Changes to Dev
```bash
# 1. Make changes to n8n-workflows/*.json

# 2. Deploy
./scripts/deploy.sh dev

# 3. Verify
./tools/test-all-paths.sh --dev --verify-db

# 4. Check status
./tools/kairon-ops.sh --dev status
```

### Deploy Changes to Prod
```bash
# 1. Verify in dev first
./scripts/deploy.sh dev && ./tools/test-all-paths.sh --dev

# 2. Deploy to prod
./scripts/deploy.sh prod

# 3. Verify
./tools/kairon-ops.sh test-api
```

### Debug Workflow Issues
```bash
# Get workflow JSON
./tools/kairon-ops.sh --dev n8n-get <workflow-id> > /tmp/workflow.json

# Check database
./tools/kairon-ops.sh --dev db-query "SELECT * FROM events ORDER BY received_at DESC LIMIT 10"

# Check logs
./tools/kairon-ops.sh --dev db-query "SELECT * FROM traces LIMIT 10"
```

## Troubleshooting

### "API key not set"
```bash
# Verify .env has correct keys
grep N8N_DEV_API_KEY .env
grep N8N_API_KEY .env

# Source credentials
source ./scripts/kairon-credentials.sh dev
```

### "Workflow not found"
```bash
# List workflows to get correct ID
./tools/kairon-ops.sh --dev n8n-list

# Check workflow registry
cat scripts/workflow-registry.json
```

### Deployment reports success but changes not visible
```bash
# Verify actual deployment
./tools/kairon-ops.sh --dev n8n-get <workflow-id> | jq '.nodes | length'

# Compare with local
jq '.nodes | length' n8n-workflows/<workflow>.json
```

## File Structure

```
kairon/
├── tools/
│   ├── kairon-ops.sh      # Main ops tool (supports --dev/--prod)
│   ├── test-all-paths.sh  # Integration tests (--dev for local)
│   └── ...
├── scripts/
│   ├── deploy.sh          # Deployment (dev/prod/all)
│   ├── kairon-credentials.sh  # Credential helper
│   ├── manage-workflow-registry.sh  # ID mapping
│   └── workflows/
│       ├── n8n-push-local.sh  # Push to local n8n
│       └── n8n-push-prod.sh   # Push to prod n8n
├── n8n-workflows/         # Source workflows
├── n8n-workflows-dev/     # Dev-only workflows
└── docs/
    └── TOOLING.md        # This file
```
```

**Estimated Effort:** 3-4 hours
**Files Created:** `docs/TOOLING.md`

---

## Phase 7: JSON Parsing Utilities (Priority: LOW)

### 7.1 Create JSON Helper Functions

**Problem:** JSON parsing is error-prone across different tools.

**Solution:** Create a shared library of JSON parsing functions.

**Create `scripts/lib/json-helpers.sh`:**
```bash
#!/bin/bash
# Shared JSON parsing utilities for Kairon tooling

# Parse n8n workflow response, extract just the workflow data
json_workflows() {
    jq '.data? // []'
}

# Extract workflow by name
json_workflow_by_name() {
    local name="$1"
    jq -r --arg name "$name" '.data[]? | select(.name == $name) // empty'
}

# Check if jq parsed successfully
json_success() {
    jq -e '.id' > /dev/null 2>&1
}

# Pretty print with error handling
json_pretty() {
    jq '.' 2>/dev/null || cat
}

# Extract node names from workflow
json_node_names() {
    jq -r '.nodes[]?.name? // empty' | sort -u
}

# Extract webhook URLs from workflow
json_webhooks() {
    jq -r '.nodes[]?.settings?.webhookUrl? // empty' | grep -v '^null$' | sort -u
}
```

**Usage in other scripts:**
```bash
source "$SCRIPT_DIR/lib/json-helpers.sh"

# Get workflows
response=$(curl -H "X-N8N-API-KEY: $API_KEY" "$URL/workflows")
echo "$response" | json_workflows | json_pretty

# Find specific workflow
workflow=$(echo "$response" | json_workflow_by_name "Route_Event")
```

**Estimated Effort:** 1-2 hours
**Files Created:** `scripts/lib/json-helpers.sh`

---

## Implementation Order

| Phase | Priority | Effort | Reuses |
|-------|----------|--------|--------|
| Phase 1: Unified kairon-ops.sh | HIGH | 2-3h | ops-wrapper.sh |
| Phase 4: Credential Helper | HIGH | 1h | credential-helper.sh |
| Phase 2: Deployment Verification | HIGH | 1-2h | deploy-verify.sh |
| Phase 6: Documentation | HIGH | 2-3h | - |
| Phase 3: ID Registry | MEDIUM | 2-3h | credential-helper.sh |
| Phase 5: Integration Tests | MEDIUM | 2h | credential-helper.sh |

**Total Estimated Effort:** 10-14 hours (vs 17-26 without shared tooling)

## Shared Tooling Credits

| Shared Library | Used By |
|----------------|---------|
| `json-helpers.sh` | All phases with jq operations |
| `credential-helper.sh` | Phases 1, 3, 4, 5 |
| `deploy-verify.sh` | Phase 2 |
| `ops-wrapper.sh` | Template for Phase 1 |

See `~/.local/share/remote-dev/README.md` for full documentation on the shared toolkit.
