# Kairon Development Tooling Guide

Complete guide to Kairon's development and operations tools.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Core Tools](#core-tools)
- [Environment Setup](#environment-setup)
- [Common Workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)
- [Advanced Usage](#advanced-usage)
- [File Structure](#file-structure)

## Quick Reference

| Task | Dev Command | Prod Command |
|------|-------------|--------------|
| **System Status** |
| Check n8n + DB health | `./tools/kairon-ops.sh --dev status` | `./tools/kairon-ops.sh status` |
| Test API connectivity | `./tools/kairon-ops.sh --dev test-api` | `./tools/kairon-ops.sh test-api` |
| **Workflow Operations** |
| List all workflows | `./tools/kairon-ops.sh --dev n8n-list` | `./tools/kairon-ops.sh n8n-list` |
| Get workflow JSON | `./tools/kairon-ops.sh --dev n8n-get <ID>` | `./tools/kairon-ops.sh n8n-get <ID>` |
| Backup workflows | `./tools/kairon-ops.sh --dev backup` | `./tools/kairon-ops.sh backup` |
| **Database Operations** |
| Run SQL query | `./tools/kairon-ops.sh --dev db-query "SQL"` | `./tools/kairon-ops.sh db-query "SQL"` |
| Interactive psql | `./tools/kairon-ops.sh --dev db -i` | `./tools/kairon-ops.sh db -i` |
| Backup database | `./tools/kairon-ops.sh --dev db --backup` | `./tools/kairon-ops.sh db --backup` |
| **Testing** |
| Quick smoke test | `./tools/test-all-paths.sh --dev --quick` | `./tools/test-all-paths.sh --quick` |
| Full test suite | `./tools/test-all-paths.sh --dev` | `./tools/test-all-paths.sh` |
| With DB verification | `./tools/test-all-paths.sh --dev --verify-db` | `./tools/test-all-paths.sh --verify-db` |
| **Deployment** |
| Deploy to environment | `./scripts/deploy.sh dev` | `./scripts/deploy.sh prod` |
| Deploy with tests | `./scripts/deploy.sh dev` (automatic) | `./scripts/deploy.sh` (all stages) |

## Core Tools

### 1. kairon-ops.sh - Operations Hub

Central command for all development and production operations.

**Location:** `tools/kairon-ops.sh`

**Usage:**
```bash
./tools/kairon-ops.sh [--dev|--prod] <command> [args]
```

**Environment Flags:**
- `--dev` - Use development environment (localhost:5679, postgres-dev)
- `--prod` - Use production environment (default, remote server)

**Commands:**

#### System Status
```bash
# Full system check (n8n, database, connectivity)
./tools/kairon-ops.sh --dev status

# Test n8n API only
./tools/kairon-ops.sh --dev test-api
```

#### Workflow Management
```bash
# List all workflows with IDs
./tools/kairon-ops.sh --dev n8n-list

# Get specific workflow JSON
./tools/kairon-ops.sh --dev n8n-get F60v1kSn9JKWkZgZ

# Save workflow to file
./tools/kairon-ops.sh --dev n8n-get F60v1kSn9JKWkZgZ > Route_Event_backup.json

# Backup all workflows
./tools/kairon-ops.sh --dev backup
```

#### Database Operations
```bash
# Run query
./tools/kairon-ops.sh --dev db-query "SELECT COUNT(*) FROM events"

# Interactive psql session
./tools/kairon-ops.sh --dev db -i

# Run query from file
./tools/kairon-ops.sh --dev db -f query.sql

# Backup database
./tools/kairon-ops.sh --dev db --backup
```

---

### 2. deploy.sh - Deployment Pipeline

Comprehensive deployment with validation, transformation, and verification.

**Location:** `scripts/deploy.sh`

**Usage:**
```bash
./scripts/deploy.sh [dev|prod|all]
```

**Stages:**

**STAGE 0: Unit Tests**
- Structural validation (nodes, connections, triggers)
- Functional tests (logic, patterns, data flow)
- Passes: Continue | Fails: Abort deployment

**STAGE 1: Deploy to DEV**
- Transform workflows for dev environment
- Validate workflow names are unique
- Validate mode:list usage (portability check)
- Push to dev n8n instance
- Verify deployment success

**STAGE 2: Smoke Tests** (dev only)
- Run Smoke_Test workflow in dev n8n
- Verify all core paths work
- Passes: Continue | Fails: Abort prod deployment

**STAGE 3: Deploy to PROD** (if 'prod' or 'all')
- Same validation as dev
- Push to production n8n
- Verify deployment

**Examples:**
```bash
# Dev only (includes smoke tests)
./scripts/deploy.sh dev

# Prod only (use with caution)
./scripts/deploy.sh prod

# Full pipeline (dev → test → prod)
./scripts/deploy.sh all
```

---

### 3. test-all-paths.sh - Integration Testing

Comprehensive test suite covering all system paths.

**Location:** `tools/test-all-paths.sh`

**Usage:**
```bash
./tools/test-all-paths.sh [options]
```

**Options:**
- `--dev` - Test dev environment (localhost:5679)
- `--quick` - Quick test (~10 tests instead of ~45)
- `--verify-db` - Verify database processing (Phase 5)
- `--quiet` - Minimal output (default)
- `--verbose` - Show all test details

**Test Coverage:**
- ✓ Command paths (::help, ::get, ::set, etc.)
- ✓ Tag shortcuts (act/!! note/.. chat/++ etc.)
- ✓ Message extraction (activities, notes, todos)
- ✓ Reactions (👍 👎 ❌)
- ✓ Thread operations (start, continue, save)
- ✓ Database processing verification (--verify-db)

**Examples:**
```bash
# Quick dev test
./tools/test-all-paths.sh --dev --quick

# Full test with database verification
./tools/test-all-paths.sh --dev --verify-db

# Production smoke test
./tools/test-all-paths.sh --quick
```

**Database Verification** (--verify-db):
1. Events stored in database
2. Workflows created traces (LLM ran)
3. Projections created (data extracted)

**Arbitrary Payload Testing:**

Send custom payloads directly to test specific scenarios:

```bash
# Send custom message to dev environment
curl -X POST "http://localhost:5679/webhook/kairon-dev-test" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message",
    "guild_id": "123456789",
    "channel_id": "987654321",
    "message_id": "custom-msg-123",
    "author": {
      "login": "test-user",
      "id": "12345",
      "display_name": "Test User"
    },
    "content": "!!Your custom test activity",
    "timestamp": "2025-12-26T00:00:00.000Z",
    "thread_id": null
  }'

# Send reaction payload
curl -X POST "http://localhost:5679/webhook/kairon-dev-test" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "reaction",
    "guild_id": "123456789",
    "channel_id": "987654321",
    "message_id": "custom-msg-123",
    "user_id": "12345",
    "emoji": "1️⃣",
    "action": "add",
    "timestamp": "2025-12-26T00:00:00.000Z"
  }'

# Test with custom webhook URL
./tools/test-all-paths.sh --webhook "https://your-custom-webhook.com/endpoint"
```

**Payload Format:**
- `event_type`: "message" or "reaction"
- `guild_id`, `channel_id`, `message_id`: Discord identifiers
- `content`: Message text (messages only)
- `author`: User info (messages) or `user_id` (reactions)
- `timestamp`: ISO format
- `thread_id`: null or thread ID

---

### 4. kairon-credentials.sh - Credential Management

Unified credential loading for dev/prod environments.

**Location:** `scripts/kairon-credentials.sh`

**Usage:**
```bash
source ./scripts/kairon-credentials.sh [dev|prod]
```

**Variables Set:**
- `N8N_API_URL` - n8n API endpoint
- `N8N_API_KEY` - n8n API key
- `CRED_*` - Full set of credentials from remote-dev toolkit
- `CONTAINER_DB` - Database container name
- `DB_NAME` - Database name
- `DB_USER` - Database user

**Helper Functions Available:**
- `api_get <path>` - GET request to n8n API
- `api_call <method> <path> [data]` - Generic API call
- `db_query <sql>` - Run SQL query
- `db_backup [output]` - Backup database

**Examples:**
```bash
# Load dev credentials
source ./scripts/kairon-credentials.sh dev

# Use credentials
echo $N8N_API_KEY
curl -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_API_URL/api/v1/workflows"

# Use helper functions
api_get "/api/v1/workflows" | jq '.data[] | {name, id}'
db_query "SELECT COUNT(*) FROM events WHERE received_at > NOW() - INTERVAL '1 hour'"
```

---

## Environment Setup

### Prerequisites

1. **Required in .env:**
   ```bash
   # Dev environment
   N8N_DEV_API_KEY=<dev-api-key>
   N8N_DEV_API_URL=http://localhost:5679
   CONTAINER_DB_DEV=postgres-dev
   DB_NAME_DEV=kairon_dev
   
   # Prod environment
   N8N_API_KEY=<prod-api-key>
   N8N_API_URL=http://localhost:5678
   CONTAINER_DB=postgres-db
   DB_NAME=kairon
   REMOTE_HOST=Oracle  # SSH alias for remote server
   ```

2. **Remote-dev toolkit:**
   - Already installed at `~/.local/share/remote-dev/`
   - Provides credential management, db access, JSON helpers
   - See `~/.local/share/remote-dev/README.md`

3. **SSH configuration:**
   - SSH alias configured in `~/.ssh/config`
   - ControlMaster enabled for multiplexing
   - Used by `rdev` and `kairon-ops.sh`

### Development Environment Setup

```bash
# 1. Ensure dev n8n is running on server
ssh Oracle "cd /opt/n8n-docker-caddy && docker-compose -f docker-compose.dev.yml up -d"

# 2. Verify connectivity
./tools/kairon-ops.sh --dev status

# 3. Load credentials for shell work
source ./scripts/kairon-credentials.sh dev
```

### Production Environment Setup

```bash
# 1. Verify prod is running
./tools/kairon-ops.sh status

# 2. Load credentials
source ./scripts/kairon-credentials.sh prod

# 3. Check health
./tools/kairon-ops.sh test-api
```

---

## Common Workflows

### 1. Develop & Test New Feature

```bash
# 1. Make changes to workflow files
vim n8n-workflows/Route_Message.json

# 2. Deploy to dev
./scripts/deploy.sh dev
# ✅ STAGE 0: Unit Tests... PASSED
# ✅ STAGE 1: Deploy to DEV... PASSED
# ✅ STAGE 2: Smoke Tests... PASSED

# 3. Test manually via Discord
# Send test messages to dev Discord channel

# 4. Run integration tests
./tools/test-all-paths.sh --dev --verify-db
# ✓ All tests passed (45/45)
# ✓ Database verification passed

# 5. Check specific workflow execution
./tools/kairon-ops.sh --dev n8n-list | grep Route_Message
# Route_Message: F60v1kSn9JKWkZgZ (Active)

# 6. Inspect database
./tools/kairon-ops.sh --dev db-query "
  SELECT event_type, clean_text, received_at 
  FROM events 
  ORDER BY received_at DESC 
  LIMIT 10
"
```

### 2. Deploy to Production

```bash
# 1. Ensure dev tests pass
./scripts/deploy.sh dev

# 2. Deploy full pipeline (dev → test → prod)
./scripts/deploy.sh all

# OR deploy prod directly (if dev already verified)
./scripts/deploy.sh prod

# 3. Verify production
./tools/kairon-ops.sh test-api
./tools/test-all-paths.sh --quick

# 4. Monitor for issues
./tools/kairon-ops.sh db-query "
  SELECT COUNT(*), event_type 
  FROM events 
  WHERE received_at > NOW() - INTERVAL '1 hour'
  GROUP BY event_type
"
```

### 3. Debug Workflow Issues

```bash
# 1. Check system status
./tools/kairon-ops.sh --dev status

# 2. List workflows
./tools/kairon-ops.sh --dev n8n-list

# 3. Get specific workflow
./tools/kairon-ops.sh --dev n8n-get <workflow-id> > /tmp/workflow.json

# 4. Check recent events
./tools/kairon-ops.sh --dev db-query "
  SELECT 
    e.event_type,
    e.clean_text,
    e.received_at,
    COUNT(t.id) as trace_count
  FROM events e
  LEFT JOIN traces t ON t.event_id = e.id
  WHERE e.received_at > NOW() - INTERVAL '1 hour'
  GROUP BY e.id
  ORDER BY e.received_at DESC
  LIMIT 20
"

# 5. Check for errors in traces
./tools/kairon-ops.sh --dev db-query "
  SELECT 
    t.created_at,
    t.completion_text,
    e.clean_text as original_message
  FROM traces t
  JOIN events e ON e.id = t.event_id
  WHERE t.created_at > NOW() - INTERVAL '1 hour'
  AND t.completion_text LIKE '%error%'
  ORDER BY t.created_at DESC
"

# 6. Check workflow health via n8n UI
# Visit https://n8n.chrisirineo.com → Executions tab
```

### 4. Database Maintenance

```bash
# Interactive session
./tools/kairon-ops.sh --dev db -i
# postgres=# \dt
# postgres=# SELECT * FROM events LIMIT 5;
# postgres=# \q

# Backup database
./tools/kairon-ops.sh --dev db --backup

# Run migration
./tools/kairon-ops.sh --dev db -f db/migrations/025_new_feature.sql

# Check migration status
./tools/kairon-ops.sh --dev db -f scripts/db/check_migration_status.sql
```

### 5. Workflow Backup & Restore

```bash
# Backup all workflows
./tools/kairon-ops.sh --dev backup
# Saved to: backups/deploy-YYYYMMDD-HHMM/workflows/

# Backup specific workflow
./tools/kairon-ops.sh --dev n8n-get <id> > backup.json

# Compare versions
diff <(./tools/kairon-ops.sh --dev n8n-get <id>) n8n-workflows/Route_Event.json

# Restore from backup (via deployment)
cp backups/deploy-*/workflows/Route_Event.json n8n-workflows/
./scripts/deploy.sh dev
```

---

## Troubleshooting

### System Health Issues

#### "n8n not responding"
```bash
# Check if n8n is running
ssh Oracle "docker ps | grep n8n"

# Check logs
ssh Oracle "docker logs n8n-dev --tail 100"

# Restart n8n
ssh Oracle "cd /opt/n8n-docker-caddy && docker-compose -f docker-compose.dev.yml restart n8n"
```

#### "Database connection failed"
```bash
# Check postgres is running
ssh Oracle "docker ps | grep postgres"

# Test direct connection
rdev db "SELECT 1"

# Check credentials
source ./scripts/kairon-credentials.sh dev
echo $CONTAINER_DB $DB_NAME
```

### Credential Issues

#### "API key not set"
```bash
# Verify .env file
grep N8N_DEV_API_KEY .env
grep N8N_API_KEY .env

# Regenerate API key in n8n UI
# Settings → API → Create new API key

# Update .env and reload
source ./scripts/kairon-credentials.sh dev
```

#### "Credential helper not found"
```bash
# Check remote-dev toolkit
ls -la ~/.local/share/remote-dev/lib/credential-helper.sh

# Reinstall if needed
# (Contact maintainer for installation instructions)
```

### Deployment Issues

#### "Workflow names not unique"
```bash
# Find duplicates
jq -r '.name' n8n-workflows/*.json | sort | uniq -d

# Rename duplicate
# Edit workflow JSON, change "name" field

# Retry deployment
./scripts/deploy.sh dev
```

#### "mode:id found (should use mode:list)"
```bash
# Find workflows using mode:id
./scripts/testing/test_mode_list_references.py n8n-workflows/

# Convert to mode:list
# Edit Execute Workflow nodes:
#   "mode": "list",
#   "cachedResultName": "Target_Workflow_Name",
#   "value": "..."  # Will be resolved from name

# Verify
./scripts/testing/test_mode_list_references.py n8n-workflows/
# ✅ All workflows use portable mode:list references
```

#### "Deployment succeeds but changes not visible"
```bash
# Get deployed workflow
./tools/kairon-ops.sh --dev n8n-get <id> > deployed.json

# Compare with local
diff deployed.json n8n-workflows/My_Workflow.json

# Check workflow was actually updated
./tools/kairon-ops.sh --dev n8n-list | grep "My_Workflow"

# Force re-deploy
./scripts/deploy.sh dev
```

### Test Failures

#### "No test events found in database"
```bash
# Check n8n is processing webhooks
./tools/kairon-ops.sh --dev status

# Check webhook URL is correct
grep WEBHOOK tools/test-all-paths.sh
grep N8N_WEBHOOK_URL .env

# Test webhook manually
curl -X POST "$N8N_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"test": "data"}'
```

#### "Some events not fully processed"
```bash
# Check for workflow errors
./tools/kairon-ops.sh --dev db-query "
  SELECT 
    e.event_type,
    COUNT(t.id) as trace_count,
    COUNT(p.id) as projection_count
  FROM events e
  LEFT JOIN traces t ON t.event_id = e.id
  LEFT JOIN projections p ON p.trace_id = t.id
  WHERE e.received_at > NOW() - INTERVAL '1 hour'
  GROUP BY e.event_type
"

# Check n8n execution history
# Visit n8n UI → Executions → Filter by "error"
```

---

## Advanced Usage

### Custom Scripts Using Credentials

```bash
#!/bin/bash
# custom-report.sh - Example custom script

source ./scripts/kairon-credentials.sh prod

# Use db_query helper
echo "Events in last 24 hours:"
db_query "
  SELECT DATE_TRUNC('hour', received_at) as hour, 
         COUNT(*) as count
  FROM events
  WHERE received_at > NOW() - INTERVAL '24 hours'
  GROUP BY hour
  ORDER BY hour DESC
"

# Use api_get helper
echo ""
echo "Active workflows:"
api_get "/api/v1/workflows?active=true" | jq -r '.data[] | .name'
```

### Workflow Validation

```bash
# Validate all workflows
./scripts/workflows/validate_workflows.sh

# Lint specific workflow
./scripts/workflows/lint_workflows.py n8n-workflows/Route_Event.json

# Check for structural issues
python3 ./scripts/workflows/unit_test_framework.py --all
```

### Database Queries

```bash
# Recent activity by type
./tools/kairon-ops.sh --dev db-query "
  SELECT 
    event_type,
    COUNT(*) as count,
    MAX(received_at) as last_seen
  FROM events
  WHERE received_at > NOW() - INTERVAL '24 hours'
  GROUP BY event_type
  ORDER BY count DESC
"

# Trace success rate
./tools/kairon-ops.sh --dev db-query "
  SELECT 
    COUNT(*) as total_events,
    COUNT(t.id) as traced_events,
    ROUND(100.0 * COUNT(t.id) / NULLIF(COUNT(*), 0), 2) as success_rate
  FROM events e
  LEFT JOIN traces t ON t.event_id = e.id
  WHERE e.received_at > NOW() - INTERVAL '1 hour'
"

# Top message senders
./tools/kairon-ops.sh --dev db-query "
  SELECT 
    payload->>'author_login' as user,
    COUNT(*) as message_count
  FROM events
  WHERE event_type = 'discord_message'
  AND received_at > NOW() - INTERVAL '7 days'
  GROUP BY payload->>'author_login'
  ORDER BY message_count DESC
  LIMIT 10
"
```

---

## File Structure

```
kairon/
├── tools/
│   ├── kairon-ops.sh              # Main operations tool (Phase 1)
│   ├── test-all-paths.sh          # Integration tests (Phase 5)
│   ├── db-health.sh               # Database health checker
│   ├── deploy-workflow.sh         # Single workflow deployment
│   └── verify-system.sh           # Full system verification
│
├── scripts/
│   ├── deploy.sh                  # Multi-stage deployment (Phase 2)
│   ├── kairon-credentials.sh      # Credential management (Phase 4)
│   │
│   ├── db/
│   │   ├── check_migration_status.sql
│   │   ├── check_duplicates.sql
│   │   └── backfill_embeddings.py
│   │
│   ├── testing/
│   │   ├── test_mode_list_references.py
│   │   └── run-n8n-ui-tests.sh
│   │
│   └── workflows/
│       ├── n8n-push-local.sh     # Dev deployment helper
│       ├── n8n-push-prod.sh      # Prod deployment helper
│       ├── lint_workflows.py     # Workflow linter
│       ├── validate_workflows.sh # Structural validation
│       └── unit_test_framework.py # Unit test runner
│
├── n8n-workflows/                 # Source workflows (22 files)
├── n8n-workflows-dev/             # Dev-only workflows
│
├── docs/
│   ├── TOOLING.md                 # This file (Phase 6)
│   ├── phase4-credential-helper.md
│   ├── phase5-enhanced-testing.md
│   ├── AGENTS.md                  # Agent guidelines & patterns
│   └── archive/                   # Historical documentation
│
├── db/
│   ├── schema.sql                 # Database schema (reference)
│   ├── migrations/                # Versioned migrations
│   └── seeds/                     # Initial data
│
└── .env.example                   # Environment template
```

---

## Related Documentation

- **[AGENTS.md](AGENTS.md)** - Agent guidelines, ctx pattern, n8n best practices
- **[phase4-credential-helper.md](phase4-credential-helper.md)** - Credential management details
- **[phase5-enhanced-testing.md](phase5-enhanced-testing.md)** - Database verification details
- **[scripts/workflows/README.md](../scripts/workflows/README.md)** - Workflow deployment internals
- **[Remote-dev toolkit](~/.local/share/remote-dev/README.md)** - Shared utility library

---

## Quick Tips

- **Always test in dev first:** `./scripts/deploy.sh dev`
- **Use --verify-db for confidence:** `./tools/test-all-paths.sh --dev --verify-db`
- **Source credentials for direct API/DB access:** `source ./scripts/kairon-credentials.sh dev`
- **Check system health before debugging:** `./tools/kairon-ops.sh --dev status`
- **Backup before major changes:** `./tools/kairon-ops.sh --dev backup`

---

**Last Updated:** 2025-12-25  
**Tooling Version:** Phase 6 Complete  
**Phases Implemented:** 1 (kairon-ops), 2 (deploy), 4 (credentials), 5 (testing), 6 (docs)  
**Phase 3 Status:** Obsolete (mode:list solved workflow ID tracking)
