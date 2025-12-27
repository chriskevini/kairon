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

**One command to set up everything:**

```bash
./scripts/deploy.sh local
```

This will:
1. Start Docker containers (n8n + PostgreSQL)
2. Initialize database schema
3. Transform workflows for local testing
4. Deploy workflows to n8n
5. Run comprehensive tests (structural + functional + unit tests)

## Quick Reference

### Local Development Commands

| Task | Command |
|------|---------|
| **Complete Setup** | `./scripts/deploy.sh local` |
| **Reset Environment** | `./scripts/reset-local-dev.sh` |
| **Deploy Only** | `./scripts/deploy.sh dev` |
| **Manual Steps** |
| Start containers | `docker-compose -f docker-compose.dev.yml up -d` |
| Stop containers | `docker-compose -f docker-compose.dev.yml down` |
| View logs | `docker-compose -f docker-compose.dev.yml logs -f n8n-dev` |
| **Database** |
| Interactive psql | `docker exec -it postgres-dev-local psql -U postgres -d kairon_dev` |
| Run SQL query | `docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c "SELECT * FROM events LIMIT 5"` |
| **Testing** |
| Test webhook | `curl -X POST http://localhost:5679/webhook/$WEBHOOK_PATH -H "Content-Type: application/json" -d '{"event_type": "message", "content": "!! test", "guild_id": "test", "channel_id": "test", "message_id": "test123", "author": {"login": "test"}}'` |

### Authentication

Local n8n uses automated session-based authentication:
- **Web UI:** http://localhost:5679 (auto-login on first visit)
- **REST API:** Session cookie authentication (automatically configured)
- **Owner Account:** Auto-created on first run (admin@example.com / Admin123!)
- **Deployment scripts:** Automatically login and use session cookies for API calls
- **No manual setup required:** Everything is handled by `./scripts/deploy.sh local`

## Core Tools

### 1. docker-compose.dev.yml - Local Environment

Docker Compose configuration for local n8n and PostgreSQL development.

**Location:** `docker-compose.dev.yml`

**Services:**
- **n8n-dev-local:** n8n instance on port 5679 (authentication disabled)
- **postgres-dev-local:** PostgreSQL on port 5433

**Usage:**
```bash
# Start containers
docker-compose -f docker-compose.dev.yml up -d

# Stop containers
docker-compose -f docker-compose.dev.yml down

# View logs
docker-compose -f docker-compose.dev.yml logs -f n8n-dev

# Access n8n UI
open http://localhost:5679
```

### 2. transform_for_dev.py - Workflow Transformation

Transforms workflows for local development with mock APIs.

**Location:** `scripts/transform_for_dev.py`

**Features:**
- Converts Schedule Triggers to Webhook Triggers
- Mocks Discord and LLM nodes with Code nodes
- Preserves webhook paths for testing

**Usage:**
```bash
# Transform single workflow
cat n8n-workflows/Route_Event.json | python scripts/transform_for_dev.py > transformed.json

# Transform all workflows
mkdir -p n8n-workflows-transformed
for wf in n8n-workflows/*.json; do
  if ! cat "$wf" | python scripts/transform_for_dev.py > "n8n-workflows-transformed/$(basename "$wf")" 2>/dev/null; then
    echo "Warning: Failed to transform $(basename "$wf")"
  fi
done

# Use real APIs instead of mocks
NO_MOCKS=1 cat workflow.json | python scripts/transform_for_dev.py
```

### 3. n8n-push-local.sh - Local Workflow Deployment

Pushes transformed workflows to local n8n instance.

**Location:** `scripts/workflows/n8n-push-local.sh`

**Usage:**
```bash
N8N_API_URL=http://localhost:5679 N8N_API_KEY="" WORKFLOW_DIR=n8n-workflows-transformed ./scripts/workflows/n8n-push-local.sh
```

---

## Environment Setup

### Prerequisites

- Docker and Docker Compose installed
- Python 3.8+ for transformation scripts
- pytest for running tests

### Quick Setup (Recommended)

```bash
# One command does everything
./scripts/deploy.sh local
```

### Manual Setup Workflow (Alternative)

If you need more control over the process:

1. **Start containers:**
   ```bash
   docker-compose -f docker-compose.dev.yml up -d
   sleep 10  # Wait for services to start
   ```

2. **Initialize database:**
   ```bash
   # Load schema
   docker exec -i postgres-dev-local psql -U postgres -d kairon_dev < db/schema.sql
   ```

3. **Deploy workflows:**
   ```bash
   ./scripts/deploy.sh dev
   ```

### What Gets Validated

The deployment process runs comprehensive validation:

1. **Structural validation:** JSON format, node connections, no orphans
2. **Workflow name uniqueness:** Prevents mode:list reference conflicts  
3. **Portable references:** Ensures Execute Workflow nodes use mode:list
4. **Unit tests:** Python test suite for workflow logic
5. **Functional tests:** Mock and real API tests via webhooks

### Environment Variables

For local development, these variables are optional (docker-compose.dev.yml provides defaults):

- `DB_USER` - Database user (default: postgres)
- `DB_NAME` - Database name (default: kairon_dev)
- `WEBHOOK_PATH` - Webhook path for Route_Event (from .env, used for both dev and prod)
- `N8N_DEV_ENCRYPTION_KEY` - n8n encryption key (default: dev-local-encryption-key-32chars)
- `NO_MOCKS` - Set to "1" to use real APIs instead of mocks (requires API keys)

### Authentication

Local n8n instance uses automated session-based authentication:

- **Web UI:** http://localhost:5679 (auto-created owner account on first run)
- **REST API:** Session cookie authentication (automatically configured by deploy script)
- **Owner Account:** `admin@example.com` / `Admin123!` (created automatically)
- **Deployment scripts:** Automatically login and use session cookies for API calls
- **No manual setup required:** Everything is handled by `./scripts/deploy.sh local`

The deploy script automatically:
1. Detects if n8n needs owner account setup
2. Creates owner account via `/rest/owner/setup` API
3. Logs in and saves session cookie to `/tmp/n8n-dev-session-*.txt`
4. Exports cookie path for deployment scripts to use

### Workflow Transformation Details

The `transform_for_dev.py` script modifies workflows for local testing:

- **Schedule → Webhook:** Converts Schedule Triggers to Webhook Triggers for manual testing
- **Discord Mocking:** Replaces Discord nodes with Code nodes that return fake API responses
- **LLM Mocking:** Replaces LLM nodes with Code nodes that return predictable responses
- **Webhook Paths:** Uses `WEBHOOK_PATH` from `.env` file (same as production)

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
docker-compose -f docker-compose.dev.yml down

# Full reset - removes all containers, volumes, and n8n data
./scripts/reset-local-dev.sh

# Reset but keep database data
./scripts/reset-local-dev.sh --keep-db

# Remove containers and volumes manually (WARNING: deletes all data)
docker-compose -f docker-compose.dev.yml down -v
```

---

## Common Workflows

### 1. Initial Setup

```bash
# Complete setup from scratch
./scripts/deploy.sh local
```

### 2. Test a New Feature

```bash
# 1. Edit your workflow file in n8n-workflows/

# 2. Deploy and test
./scripts/deploy.sh dev

# 3. Check results in database
docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c \
  "SELECT * FROM projections ORDER BY created_at DESC LIMIT 3"
```

### 3. Test with Real APIs

```bash
# Deploy with real Discord/LLM APIs (requires API keys in environment)
export NO_MOCKS=1
export DISCORD_BOT_TOKEN="your-token"
export OPENROUTER_API_KEY="your-key"

./scripts/deploy.sh dev
```

### 4. Debug Workflow Issues

```bash
# 1. Check container logs
docker-compose -f docker-compose.dev.yml logs -f n8n-dev

# 2. Test webhook manually
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! debug", "guild_id": "test", "channel_id": "test", "message_id": "debug-123", "author": {"login": "test"}, "timestamp": "'$(date -Iseconds)'"}'

# 3. Inspect database state
docker exec -it postgres-dev-local psql -U postgres -d kairon_dev
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
docker-compose -f docker-compose.dev.yml ps

# View n8n logs
docker-compose -f docker-compose.dev.yml logs -f n8n-dev

# Check database connectivity
docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c "SELECT COUNT(*) FROM events"

# List active workflows
curl -s http://localhost:5679/api/v1/workflows | jq '.data[] | select(.active == true) | {name, id}'

# Test webhook manually
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! debug", "guild_id": "test", "channel_id": "test", "message_id": "debug-123", "author": {"login": "test"}, "timestamp": "'$(date -Iseconds)'"}'
```

For detailed debugging workflows, see `DEBUG.md`.

## Advanced Usage

### Using Real APIs (No Mocks)

By default, `deploy.sh local` uses mocked Discord and LLM responses for fast, offline testing. To test with real APIs:

```bash
# Export API credentials
export DISCORD_BOT_TOKEN="your-token"
export OPENROUTER_API_KEY="your-key"
export NO_MOCKS=1

# Deploy with real APIs
./scripts/deploy.sh dev
```

Note: The deployment script runs tests twice - once with mocks, once with real APIs.

### Custom Database Configuration

```bash
# Use custom database settings
export DB_USER=myuser
export DB_NAME=mykairon

# Restart containers with new config
docker-compose -f docker-compose.dev.yml down
docker-compose -f docker-compose.dev.yml up -d
```

### Workflow Development Tips

- **Test incrementally:** Deploy and test single workflows as you develop
- **Use descriptive webhook paths:** Edit `transform_for_dev.py` to change webhook paths for clarity
- **Monitor logs:** `docker-compose logs -f` shows n8n processing in real-time
- **Database persistence:** Data persists between container restarts (use `down -v` to reset)
- **Iterative development:** Just run `./scripts/deploy.sh dev` after editing workflow files

### Cleanup

```bash
# Stop containers (keeps data)
docker-compose -f docker-compose.dev.yml down

# Remove containers and volumes (deletes all data)
docker-compose -f docker-compose.dev.yml down -v
```

## File Structure

```
docker-compose.dev.yml       # Local environment definition
n8n-workflows/               # Source workflows
n8n-workflows-transformed/   # Transformed workflows for testing
scripts/
├── transform_for_dev.py     # Workflow transformation
└── workflows/
    └── n8n-push-local.sh    # Local deployment script
```

## Quick Tips

### Recommended Workflow
1. **Start:** `./scripts/deploy.sh local` (one command setup)
2. **Edit:** Modify workflow files in n8n-workflows/
3. **Test:** `./scripts/deploy.sh dev` (deploy + test)
4. **Debug:** Check logs with `docker-compose logs -f n8n-dev`
5. **Verify:** Query database or check n8n UI at http://localhost:5679

### Useful Commands
- **Complete setup:** `./scripts/deploy.sh local`
- **Deploy only:** `./scripts/deploy.sh dev`
- **Run tests:** `pytest n8n-workflows/tests/ -v`
- **Check database:** `docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c "SELECT * FROM events LIMIT 10"`
- **View logs:** `docker-compose -f docker-compose.dev.yml logs -f n8n-dev`
- **Clean start:** `./scripts/reset-local-dev.sh && ./scripts/deploy.sh local`

---

**Last Updated:** 2025-12-27
**Focus:** One-command local development setup with comprehensive testing