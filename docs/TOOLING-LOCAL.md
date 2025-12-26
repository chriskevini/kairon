# Kairon Local Development Guide

Complete guide to local development with Docker containers.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Core Tools](#core-tools)
- [Environment Setup](#environment-setup)
- [Common Workflows](#common-workflows)
- [Debugging](#debugging)
- [Advanced Usage](#advanced-usage)
- [File Structure](#file-structure)

## Quick Reference

### Local Development (Docker Containers)
| Task | Command |
|------|---------|
| **Setup** |
| Start local containers | `docker-compose -f docker-compose.dev.yml up -d` |
| Load database schema | `docker exec -i postgres-dev-local psql -U postgres -d kairon_dev < db/schema.sql` |
| Transform workflows | `mkdir -p n8n-workflows-transformed && for wf in n8n-workflows/*.json; do cat "$wf" \| python scripts/transform_for_dev.py > "n8n-workflows-transformed/$(basename "$wf")"; done` |
| Push workflows | `N8N_API_URL=http://localhost:5679 N8N_API_KEY="" WORKFLOW_DIR=n8n-workflows-transformed ./scripts/workflows/n8n-push-local.sh` |
| Test webhook | `curl -X POST http://localhost:5679/webhook/kairon-dev-test -H "Content-Type: application/json" -d '{"event_type": "message", "content": "!! test", "guild_id": "test", "channel_id": "test", "message_id": "test123", "author": {"login": "test"}}'` |
| **Database** |
| Run SQL query | `docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c "SELECT * FROM events LIMIT 5"` |
| Interactive psql | `docker exec -it postgres-dev-local psql -U postgres -d kairon_dev` |

## Core Tools

### 1. docker-compose.dev.yml - Local Environment

Docker Compose configuration for local n8n and PostgreSQL development.

**Location:** `docker-compose.dev.yml`

**Services:**
- **n8n-dev-local:** n8n instance on port 5679 (no authentication)
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

### Complete Setup Workflow

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

3. **Transform workflows:**
   ```bash
   # Create transformed workflows with mocks
   mkdir -p n8n-workflows-transformed
   for wf in n8n-workflows/*.json; do
     if ! cat "$wf" | python scripts/transform_for_dev.py > "n8n-workflows-transformed/$(basename "$wf")" 2>/dev/null; then
       echo "Warning: Failed to transform $(basename "$wf")"
     fi
   done
   ```

4. **Deploy workflows:**
   ```bash
   N8N_API_URL=http://localhost:5679 N8N_API_KEY="" WORKFLOW_DIR=n8n-workflows-transformed ./scripts/workflows/n8n-push-local.sh
   ```

5. **Test functionality:**
   ```bash
   # Send test message
   curl -X POST http://localhost:5679/webhook/kairon-dev-test \
     -H "Content-Type: application/json" \
     -d '{
       "event_type": "message",
       "guild_id": "test-guild",
       "channel_id": "test-channel",
       "message_id": "test123",
       "author": {"login": "testuser", "id": "12345", "display_name": "Test User"},
       "content": "$$ buy milk",
       "timestamp": "2025-12-26T12:00:00Z"
     }'
   ```

6. **Verify results:**
   ```bash
   # Check database
   docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c "SELECT COUNT(*) FROM events;"

   # View n8n UI
   open http://localhost:5679
   ```

### Environment Variables

For local development, these variables are optional (docker-compose.dev.yml provides defaults):

- `DB_USER` - Database user (default: postgres)
- `DB_NAME` - Database name (default: kairon_dev)
- `N8N_DEV_ENCRYPTION_KEY` - n8n encryption key (default: dev-local-encryption-key-32chars)
- `NO_MOCKS` - Set to "1" to use real APIs instead of mocks

### Workflow Transformation Details

The `transform_for_dev.py` script modifies workflows for local testing:

- **Schedule → Webhook:** Converts Schedule Triggers to Webhook Triggers for manual testing
- **Discord Mocking:** Replaces Discord nodes with Code nodes that return fake API responses
- **LLM Mocking:** Replaces LLM nodes with Code nodes that return predictable responses
- **Webhook Paths:** Preserves webhook paths for testing (e.g., `kairon-dev-test`)

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
# Stop containers
docker-compose -f docker-compose.dev.yml down

# Remove containers and volumes (WARNING: deletes all data)
docker-compose -f docker-compose.dev.yml down -v
```

---

## Common Workflows

### 1. Test a New Feature

```bash
# 1. Start local environment
docker-compose -f docker-compose.dev.yml up -d

# 2. Transform and deploy your updated workflow
cat n8n-workflows/My_New_Workflow.json | python scripts/transform_for_dev.py > n8n-workflows-transformed/My_New_Workflow.json
N8N_API_URL=http://localhost:5679 N8N_API_KEY="" WORKFLOW_DIR=n8n-workflows-transformed ./scripts/workflows/n8n-push-local.sh

# 3. Test with sample data
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! test my feature", ...}'

# 4. Check results
docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c "SELECT * FROM projections ORDER BY created_at DESC LIMIT 3"
```

### 2. Debug Workflow Issues

```bash
# 1. Check container logs
docker-compose -f docker-compose.dev.yml logs -f n8n-dev

# 2. Test webhook manually
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! debug", ...}'

# 3. Inspect database state
docker exec -it postgres-dev-local psql -U postgres -d kairon_dev
```

### 3. Performance Testing

```bash
# 1. Load test with multiple messages
for i in {1..10}; do
  curl -X POST http://localhost:5679/webhook/kairon-dev-test \
    -H "Content-Type: application/json" \
    -d "{\"event_type\": \"message\", \"content\": \"!! test $i\", \"message_id\": \"test-$i\", ...}" &
done

# 2. Monitor processing
watch "docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c 'SELECT COUNT(*) FROM events;'"
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

```bash
# Transform without mocks
NO_MOCKS=1 cat n8n-workflows/Route_Event.json | python scripts/transform_for_dev.py > real-api-workflow.json

# You'll need real API keys in environment variables
export DISCORD_BOT_TOKEN="your-token"
export OPENROUTER_API_KEY="your-key"
```

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

- **Test incrementally:** Push single workflows, not all at once
- **Use descriptive webhook paths:** Change `kairon-dev-test` to `test-my-feature` for clarity
- **Monitor logs:** `docker-compose logs -f` shows n8n processing in real-time
- **Database persistence:** Data persists between container restarts (use `down -v` to reset)

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

### Local Development
- **Start local environment:** `docker-compose -f docker-compose.dev.yml up -d`
- **Test webhooks directly:** `curl -X POST http://localhost:5679/webhook/kairon-dev-test ...`
- **Check local database:** `docker exec -i postgres-dev-local psql -U postgres -d kairon_dev -c "SELECT * FROM events"`
- **Transform workflows for testing:** `cat workflow.json | python scripts/transform_for_dev.py`
- **Monitor logs:** `docker-compose logs -f n8n-dev`

---

**Last Updated:** 2025-12-26
**Focus:** Local development and testing