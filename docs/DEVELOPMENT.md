# Kairon Local Development Guide

Complete guide to local development with Docker containers.

## Table of Contents

- [Quick Start](#quick-start)
- [Quick Reference](#quick-reference)
- [Core Tools](#core-tools)
- [Environment Setup](#environment-setup)
- [Common Workflows](#common-workflows)
- [Debugging](#debugging)
- [Advanced Usage](#advanced-usage)
- [File Structure](#file-structure)

## Quick Start

**Set up local development environment:**

```bash
# Start containers
docker-compose up -d

# Deploy workflows
bash scripts/simple-deploy.sh dev

# Run tests
bash scripts/simple-test.sh
```

This will:
1. Start Docker containers (n8n + PostgreSQL)
2. Deploy workflows to n8n via API
3. Run webhook-based tests with database validation

## Quick Reference

### Local Development Commands

| Task | Command |
|------|---------|
| **Start containers** | `docker-compose up -d` |
| **Stop containers** | `docker-compose down` |
| **Deploy workflows** | `bash scripts/simple-deploy.sh dev` |
| **Run tests** | `bash scripts/simple-test.sh` |
| **Manual Steps** |
| Start containers | `docker-compose up -d` |
| Stop containers | `docker-compose down` |
| View logs | `docker-compose logs -f n8n` |
| **Database** |
| Interactive psql | `docker exec -it postgres-dev-local psql -U postgres -d kairon_dev` |
| Run SQL query | `docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c "SELECT * FROM events LIMIT 5"` |
| **Testing** |
| Test webhook | `curl -X POST http://localhost:5679/webhook/$WEBHOOK_PATH -H "Content-Type: application/json" -d '{"event_type": "message", "content": "!! test", "guild_id": "test", "channel_id": "test", "message_id": "test123", "author": {"login": "test"}}'` |

### Authentication

Local n8n uses API key authentication:
- **Web UI:** http://localhost:5679 (auto-login on first visit)
- **REST API:** Requires `N8N_DEV_API_KEY` from `.env`
- **Owner Account:** Auto-created on first run (admin@example.com)
- **Environment:** Set `N8N_DEV_API_KEY` in `.env` for automated deployments

## Core Tools

### 1. docker-compose.yml - Local Environment

Docker Compose configuration for local n8n and PostgreSQL development.

**Location:** `docker-compose.yml`

**Services:**
- **n8n:** n8n instance on port 5679
- **postgres:** PostgreSQL on port 5433

**Usage:**
```bash
# Start containers
docker-compose up -d

# Stop containers
docker-compose down

# View logs
docker-compose logs -f n8n

# Access n8n UI
open http://localhost:5679
```

### 2. simple-deploy.sh - Workflow Deployment

Deploys workflows directly to n8n via API with validation.

**Location:** `scripts/simple-deploy.sh`

**Features:**
- JSON syntax validation
- Workflow name uniqueness check
- Direct API deployment (no transformations needed)
- Smoke test verification

**Usage:**
```bash
# Deploy to dev
bash scripts/simple-deploy.sh dev

# Deploy to prod
bash scripts/simple-deploy.sh prod

# Validate only (no deployment)
bash scripts/simple-deploy.sh validate
```

### 3. simple-test.sh - Webhook Testing

Tests workflows via webhook endpoints with database validation.

**Location:** `scripts/simple-test.sh`

**Features:**
- Send test payloads to webhook endpoints
- Validate database changes (events, projections)
- Test coverage tracking

**Usage:**
```bash
# Test all workflows
bash scripts/simple-test.sh

# Test specific workflow
bash scripts/simple-test.sh Route_Message
```

---

## Environment Setup

### Prerequisites

- Docker and Docker Compose installed
- n8n API key in `.env` (`N8N_DEV_API_KEY`)

### Quick Setup (Recommended)

```bash
# 1. Start containers
docker-compose up -d

# 2. Initialize database (if needed)
docker exec -i postgres-dev-local psql -U n8n_user -d kairon < db/schema.sql

# 3. Deploy workflows
bash scripts/simple-deploy.sh dev

# 4. Run tests
bash scripts/simple-test.sh
```

### What Gets Validated

The deployment process runs comprehensive validation:

1. **JSON syntax:** Valid workflow files
2. **Workflow name uniqueness:** Prevents duplicate names
3. **Environment variable syntax:** Check for correct `={{ $env.VAR }}` usage
4. **Database connectivity:** Verify workflow execution creates records

### Environment Variables

For local development, these variables are optional (docker-compose.yml provides defaults):

- `DB_USER` - Database user (default: postgres)
- `DB_NAME` - Database name (default: kairon_dev)
- `WEBHOOK_PATH` - Webhook path for Route_Event (from .env, used for both dev and prod)
- `N8N_DEV_ENCRYPTION_KEY` - n8n encryption key (default: dev-local-encryption-key-32chars)
- `NO_MOCKS` - Set to "1" to use real APIs instead of mocks (requires API keys)

### Authentication

Local n8n instance uses API key authentication:

- **Web UI:** http://localhost:5679 (auto-created owner account on first run)
- **REST API:** Requires `N8N_DEV_API_KEY` from `.env` file
- **Owner Account:** `admin@example.com` (created automatically)
- **Configuration:** Set API keys in `.env`:
  ```
  N8N_DEV_API_KEY=your-dev-api-key-here
  N8N_API_KEY=your-prod-api-key-here
  ```

**Note:** The old deployment system used session cookie authentication. The new pipeline uses API keys which are more reliable for automated deployments.

### Single Codebase Approach

> ✅ **NEW:** Workflows use environment variables (`={{ $env.VAR }}`) for environment-specific configuration.
>
> The simplified deployment pipeline (`simple-deploy.sh`) uses a single codebase approach - no transformations needed.
>
> **→ See [SIMPLIFIED_PIPELINE.md](SIMPLIFIED_PIPELINE.md) for details.

The same workflow files work in both dev and prod:
- **Webhook Paths:** Uses `WEBHOOK_PATH` from `.env` file
- **Discord Channels:** Uses `DISCORD_CHANNEL_*` environment variables
- **Database Connection:** Handled by n8n credentials (same credential name across environments)

### Database Operations

```bash
# Run SQL query
docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c "SELECT * FROM events LIMIT 5"

# Interactive session
docker exec -it postgres-dev-local psql -U postgres -d kairon_dev

# Run query from file
docker exec -i postgres-dev-local psql -U postgres -d kairon_dev < query.sql
```

### Cleanup

```bash
# Stop containers (keeps data)
docker-compose down

# Remove containers and volumes manually (WARNING: deletes all data)
docker-compose down -v
```

---

## Common Workflows

### 1. Initial Setup

```bash
# Start containers
docker-compose up -d

# Initialize database
docker exec -i postgres-dev-local psql -U n8n_user -d kairon < db/schema.sql

# Deploy workflows
bash scripts/simple-deploy.sh dev

# Run tests
bash scripts/simple-test.sh
```

### 2. Test a New Feature

```bash
# 1. Edit your workflow file in n8n-workflows/

# 2. Deploy
bash scripts/simple-deploy.sh dev

# 3. Run tests
bash scripts/simple-test.sh

# 4. Check results in database
docker exec -i postgres-dev-local psql -U n8n_user -d kairon -c \
  "SELECT * FROM projections ORDER BY created_at DESC LIMIT 3"
```

### 3. Test Specific Workflow

```bash
# Test only Route_Message workflow
bash scripts/simple-test.sh Route_Message
```

### 4. Debug Workflow Issues

```bash
# 1. Check container logs
docker-compose logs -f n8n

# 2. Test webhook manually
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! debug", "guild_id": "test", "channel_id": "test", "message_id": "debug-123", "author": {"login": "test"}, "timestamp": "'$(date -Iseconds)'"}'

# 3. Inspect database state
docker exec -it postgres psql -U postgres -d kairon_dev
```

### 5. Run Tests Only

```bash
# Run all tests without deployment
pytest n8n-workflows/tests/ -v

# Run specific test
pytest n8n-workflows/tests/test_tag_parsing.py -v
```

## Debugging

For comprehensive debugging tools and techniques, see `DEBUG.md`. Here are quick local development debug commands:

### Quick Debug Commands

```bash
# Check container status
docker-compose ps

# View n8n logs
docker-compose logs -f n8n

# Check database connectivity
docker exec -i postgres psql -U postgres -d kairon_dev -c "SELECT COUNT(*) FROM events"

# List active workflows
curl -s http://localhost:5679/api/v1/workflows | jq '.data[] | select(.active == true) | {name, id}'

# Test webhook manually
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! debug", "guild_id": "test", "channel_id": "test", "message_id": "debug-123", "author": {"login": "test"}, "timestamp": "'$(date -Iseconds)'"}'
```

For detailed debugging workflows, see `DEBUG.md`.

## Advanced Usage

### Deploy to Production

```bash
# Deploy to production (validates, deploys, smokes tests)
bash scripts/simple-deploy.sh prod

# Deploy to dev environment
bash scripts/simple-deploy.sh dev
```

**Production Deployment includes:**
1. JSON syntax validation
2. Workflow deployment to production n8n
3. Smoke test verification
4. All workflows accessible via API

### Custom Database Configuration

```bash
# Use custom database settings
export DB_USER=myuser
export DB_NAME=mykairon

# Restart containers with new config
docker-compose down
docker-compose up -d
```

### Workflow Development Tips

- **Test incrementally:** Deploy and test single workflows as you develop
- **Use environment variables:** Configure behavior via `={{ $env.VAR }}` in workflows
- **Monitor logs:** `docker logs -f n8n-dev-local` shows n8n processing in real-time
- **Database persistence:** Data persists between container restarts (use `down -v` to reset)
- **Iterative development:** Just run `bash scripts/simple-deploy.sh dev` after editing workflow files

### Cleanup

```bash
# Stop containers (keeps data)
docker-compose down

# Remove containers and volumes (deletes all data)
docker-compose down -v
```

## File Structure

```
docker-compose.yml            # Local environment definition
n8n-workflows/               # Source workflows
scripts/
├── simple-deploy.sh         # Deployment script
└── simple-test.sh           # Testing script
n8n-workflows/tests/
└── payloads/               # Test payloads for each workflow
```

## Quick Tips

### Recommended Workflow
1. **Start containers:** `docker-compose up -d`
2. **Edit:** Modify workflow files in n8n-workflows/
3. **Deploy:** `bash scripts/simple-deploy.sh dev`
4. **Test:** `bash scripts/simple-test.sh`
5. **Debug:** Check logs with `docker logs -f n8n`
6. **Verify:** Query database or check n8n UI at http://localhost:5679

### Useful Commands
- **Start containers:** `docker-compose up -d`
- **Stop containers:** `docker-compose down`
- **Deploy:** `bash scripts/simple-deploy.sh dev`
- **Test:** `bash scripts/simple-test.sh`
- **Check database:** `docker exec -i postgres-dev-local psql -U n8n_user -d kairon -c "SELECT * FROM events LIMIT 10"`
- **View logs:** `docker logs -f n8n-dev-local`

---

**Last Updated:** 2025-12-29
**Focus:** Simplified deployment pipeline (simple-deploy.sh + simple-test.sh)