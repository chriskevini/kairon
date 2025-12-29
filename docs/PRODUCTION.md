# Kairon Production Operations Guide

Complete guide to production operations and remote server management.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Core Tools](#core-tools)
- [Environment Setup](#environment-setup)
- [Common Workflows](#common-workflows)
- [Debugging](#debugging)
- [Deployment](#deployment)
- [File Structure](#file-structure)

## Quick Reference

### Production Operations (Remote Server)
| Task | Command |
|------|---------|
| **System Status** |
| Check n8n + DB health | `./tools/kairon-ops.sh status` |
| Test API connectivity | `./tools/kairon-ops.sh test-api` |
| **Workflow Operations** |
| List all workflows | `./tools/kairon-ops.sh n8n-list` |
| Get workflow JSON | `./tools/kairon-ops.sh n8n-get <ID>` |
| Backup workflows | `./tools/kairon-ops.sh backup` |
| **Execution Monitoring** |
| List recent executions | `./scripts/workflows/inspect_execution.py --list --limit 10` |
| List failed executions | `./scripts/workflows/inspect_execution.py --failed --limit 5` |
| View execution details | `./scripts/workflows/inspect_execution.py <execution-id>` |
| **Database Operations** |
| Run SQL query | `./tools/kairon-ops.sh db-query "SQL"` |
| Interactive psql | `./tools/kairon-ops.sh db -i` |
| Backup database | `./tools/kairon-ops.sh db --backup` |
| **Testing** |
| Quick smoke test | `./tools/test-all-paths.sh --quick` |
| Full test suite | `./tools/test-all-paths.sh` |
| With DB verification | `./tools/test-all-paths.sh --verify-db` |
| **Deployment** |
| Deploy to production | `./scripts/simple-deploy.sh prod` |
| Deploy with tests | `./scripts/simple-deploy.sh prod` (includes validation and smoke tests) |

## Core Tools

### 1. kairon-ops.sh - Production Operations Hub

Central command for production server operations and remote management.

**Location:** `tools/kairon-ops.sh`

**Usage:**
```bash
./tools/kairon-ops.sh [--prod] <command> [args]
```

**Commands:**

#### System Status
```bash
# Full system check (n8n, database, connectivity)
./tools/kairon-ops.sh status

# Test n8n API only
./tools/kairon-ops.sh test-api
```

#### Workflow Management
```bash
# List all workflows with IDs
./tools/kairon-ops.sh n8n-list

# Get specific workflow JSON
./tools/kairon-ops.sh n8n-get F60v1kSn9JKWkZgZ

# Save workflow to file
./tools/kairon-ops.sh n8n-get F60v1kSn9JKWkZgZ > Route_Event_backup.json

# Backup all workflows
./tools/kairon-ops.sh backup
```

#### Database Operations
```bash
# Run query
./tools/kairon-ops.sh db-query "SELECT COUNT(*) FROM events"

# Interactive psql session
./tools/kairon-ops.sh db -i

# Run query from file
./tools/kairon-ops.sh db -f query.sql

# Backup database
./tools/kairon-ops.sh db --backup
```

### 2. inspect_execution.py - Execution Monitoring

Purpose-built tool for viewing n8n workflow execution status and details.

**Location:** `scripts/workflows/inspect_execution.py`

**Usage:**
```bash
# List recent executions
./scripts/workflows/inspect_execution.py --list --limit 10

# List only failed executions
./scripts/workflows/inspect_execution.py --failed --limit 5

# View detailed execution info (with formatted errors)
./scripts/workflows/inspect_execution.py <execution-id>

# View full execution including node outputs
./scripts/workflows/inspect_execution.py <execution-id> --full
```

**Examples:**
```bash
# Quick health check - see last 5 executions
./scripts/workflows/inspect_execution.py --list --limit 5

# After deployment - check for any failures
./scripts/workflows/inspect_execution.py --failed --limit 10

# Debug specific failure
./scripts/workflows/inspect_execution.py 13191
```

**Output Features:**
- Colored status indicators (green = success, red = error)
- Formatted execution timing and duration
- Detailed error messages with stack traces
- Node-level error identification

### 3. simple-deploy.sh - Deployment Pipeline

Simplified deployment with validation and direct n8n API deployment.

**See:** `docs/SIMPLIFIED_PIPELINE.md` for complete deployment documentation.

## Environment Setup

### Production Environment Setup

```bash
# 1. Verify prod is running
./tools/kairon-ops.sh status

# 2. Load credentials for shell work
source ./scripts/kairon-credentials.sh prod
```

## Common Workflows

### 1. Deploy to Production

```bash
# Full deployment with all tests
./scripts/simple-deploy.sh prod

# Check deployment status
./tools/kairon-ops.sh status
```

### 2. Monitor System Health

```bash
# Continuous monitoring
watch ./tools/kairon-ops.sh status

# Check recent activity
./tools/kairon-ops.sh db-query "
  SELECT event_type, COUNT(*) as count
  FROM events
  WHERE received_at > NOW() - INTERVAL '1 hour'
  GROUP BY event_type
"
```

### 3. Debug Production Issues

```bash
# 1. Check system status
./tools/kairon-ops.sh status

# 2. List workflows
./tools/kairon-ops.sh n8n-list

# 3. Get specific workflow
./tools/kairon-ops.sh n8n-get <workflow-id> > /tmp/workflow.json

# 4. Check recent events
./tools/kairon-ops.sh db-query "
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
"
```

## Debugging

For comprehensive debugging tools and techniques, see `DEBUG.md`. Here are quick production debug commands:

### Quick Debug Commands

```bash
# System overview
./tools/kairon-ops.sh status

# Check recent activity
./tools/kairon-ops.sh db-query "
  SELECT event_type, COUNT(*) as count,
         MAX(received_at) as latest
  FROM events
  WHERE received_at > NOW() - INTERVAL '1 hour'
  GROUP BY event_type
"

# Check for errors
./tools/kairon-ops.sh db-query "
  SELECT e.event_type, e.clean_text, t.error_message
  FROM events e
  JOIN traces t ON t.event_id = e.id
  WHERE t.error_message IS NOT NULL
  ORDER BY t.created_at DESC
  LIMIT 5
"

# Test database connectivity
./tools/kairon-ops.sh db-query "SELECT version()"

# List active workflows
./tools/kairon-ops.sh n8n-list
```

For detailed debugging workflows and advanced troubleshooting, see `DEBUG.md`.

#### Workflow not processing messages
```bash
# Check recent events
./tools/kairon-ops.sh db-query "
  SELECT event_type, COUNT(*) as count,
         MAX(received_at) as latest
  FROM events
  WHERE received_at > NOW() - INTERVAL '1 hour'
  GROUP BY event_type
"

# Check for failed traces
./tools/kairon-ops.sh db-query "
  SELECT e.event_type, e.clean_text, t.error_message
  FROM events e
  LEFT JOIN traces t ON t.event_id = e.id
  WHERE t.error_message IS NOT NULL
  ORDER BY e.received_at DESC
  LIMIT 5
"
```

#### Database performance issues
```bash
# Check active connections
./tools/kairon-ops.sh db-query "
  SELECT count(*) as active_connections
  FROM pg_stat_activity
  WHERE state = 'active'
"

# Check slow queries
./tools/kairon-ops.sh db-query "
  SELECT query, total_time/1000 as seconds
  FROM pg_stat_statements
  ORDER BY total_time DESC
  LIMIT 5
"
```

## Deployment

See `docs/DEPLOYMENT.md` for complete deployment pipeline documentation.

## File Structure

```
tools/
├── kairon-ops.sh           # Production operations hub
├── test-all-paths.sh       # Production testing suite
└── verify-system.sh        # System verification

scripts/
├── simple-deploy.sh       # Deployment pipeline (587 lines)
├── simple-test.sh         # Regression testing
├── kairon-credentials.sh # Credential management
└── workflows/             # Production deployment scripts

docs/
├── DEPLOYMENT.md          # Deployment pipeline docs
└── PRODUCTION.md        # This file
```

## Quick Tips

- **Always deploy via pipeline:** `./scripts/simple-deploy.sh prod` (never manual)
- **Monitor after deployment:** `./tools/kairon-ops.sh status`
- **Backup before major changes:** `./tools/kairon-ops.sh backup`
- **Check system health before debugging:** `./tools/kairon-ops.sh status`

---

**Last Updated:** 2025-12-26
**Focus:** Production operations and maintenance