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
./scripts/setup-local.sh
```

This will:
1. Build and start all Docker containers (n8n + PostgreSQL + Discord relay + Embedding service)
2. Initialize database schema
3. Set up n8n owner account
4. Deploy workflows to n8n
5. Run comprehensive tests (structural + unit tests)

## Quick Reference

### Local Development Commands

| Task | Command |
|------|---------|
| **Complete Setup** | `./scripts/setup-local.sh` |
| **Deploy Only** | `./scripts/deploy.sh local` |
| **Deploy to Prod** | `./scripts/deploy.sh prod` |
| **Manual Steps** |
| Start containers | `docker-compose up -d` |
| Stop containers | `docker-compose down` |
| View logs | `docker-compose logs -f n8n` |
| **Database** |
| Interactive psql | `docker exec -it postgres-local psql -U postgres -d kairon` |
| Run SQL query | `docker exec -i postgres-local psql -U postgres -d kairon -c "SELECT * FROM events LIMIT 5"` |
| **Testing** |
| Test webhook | `curl -X POST http://localhost:5679/webhook/$WEBHOOK_PATH -H "Content-Type: application/json" -d '{"event_type": "message", "content": "!! test", "guild_id": "test", "channel_id": "test", "message_id": "test123", "author": {"login": "test"}}'` |

### Authentication

Local n8n uses automated session-based authentication:
- **Web UI:** http://localhost:5679
- **Owner Account:** Auto-created on first run (admin@example.com / Admin123!)
- **Credentials:** Set via `N8N_DEV_USER` and `N8N_DEV_PASSWORD` in `.env`
- **No API key needed** for localhost (uses session cookies)

## Core Tools

### 1. docker-compose.yml - Full Local Environment

Docker Compose configuration for complete local development environment.

**Location:** `docker-compose.yml`

**Services:**
- **n8n-local:** n8n instance on port 5679
- **postgres-local:** PostgreSQL on port 5432
- **discord-relay-local:** Discord bot (connects to your server)
- **embedding-service-local:** Embedding API on port 8000

**Usage:**
```bash
# Start all containers
docker-compose up -d

# Stop containers
docker-compose down

# View logs
docker-compose logs -f n8n

# Access n8n UI
open http://localhost:5679
```

### 2. n8n-push-local.sh - Local Workflow Deployment

Pushes workflows to local n8n instance.

**Location:** `scripts/workflows/n8n-push-local.sh`

**Usage:**
```bash
# Automatically called by deploy.sh local
# Manual usage:
N8N_API_URL=http://localhost:5679 N8N_DEV_COOKIE_FILE=/tmp/n8n-cookie.txt \
  ./scripts/workflows/n8n-push-local.sh
```

### 3. deploy.sh - Deployment Script

Main deployment script for both local and production environments.

**Location:** `scripts/deploy.sh`

**Usage:**
```bash
# Deploy to localhost
./scripts/deploy.sh local

# Deploy to production server
./scripts/deploy.sh prod
```

---

## Environment Setup

### Prerequisites

- Docker and Docker Compose installed
- Python 3.8+ for validation scripts
- pytest for running tests

### Quick Setup (Recommended)

```bash
# One command does everything
./scripts/setup-local.sh
```

### Manual Setup Workflow (Alternative)

If you need more control over the process:

1. **Start containers:**
    ```bash
    docker-compose up -d
    sleep 10  # Wait for services to start
    ```

2. **Initialize database:**
    ```bash
    # Load schema
    docker exec -i postgres-local psql -U postgres -d kairon < db/schema.sql
    ```

3. **Deploy workflows:**
    ```bash
    ./scripts/deploy.sh local
    ```

### What Gets Validated

The deployment process runs comprehensive validation:

1. **Structural validation:** JSON format, node connections, no orphans
2. **Workflow name uniqueness:** Prevents mode:list reference conflicts  
3. **Portable references:** Ensures Execute Workflow nodes use mode:list
4. **Workflow integrity:** Dead code detection, misconfigured nodes
5. **Unit tests:** Python test suite for workflow logic

### Environment Variables

For local development, configure these in `.env`:

**Required for full functionality:**
- `DISCORD_BOT_TOKEN` - Discord bot token (for discord-relay service)
- `OPENROUTER_API_KEY` - LLM API key (for workflow LLM nodes)

**Optional:**
- `DB_USER` - Database user (default: postgres)
- `DB_PASSWORD` - Database password (default: postgres)
- `DB_NAME` - Database name (default: kairon)
- `WEBHOOK_PATH` - Webhook path for Route_Event (default: kairon-local)
- `N8N_DEV_USER` - n8n owner username (default: admin)
- `N8N_DEV_PASSWORD` - n8n owner password (default: Admin123!)
- `N8N_ENCRYPTION_KEY` - n8n encryption key (default: local-encryption-key-32chars-123456)

**For Discord integration (webhook from Discord to n8n):**
- `N8N_WEBHOOK_URL` - Public URL to n8n webhook (use ngrok/cloudflared tunnel)
  Example: `https://xxxx.ngrok.io/webhook/kairon-local`

### Authentication

Local n8n instance uses automated session-based authentication:

- **Web UI:** http://localhost:5679
- **Owner Account:** Auto-created on first setup run
- **Credentials:** Set via `N8N_DEV_USER` and `N8N_DEV_PASSWORD` in `.env`
- **Deployment scripts:** Automatically login and use session cookies for API calls
- **No manual setup required:** Everything is handled by `./scripts/setup-local.sh`

### Database Operations

```bash
# Run SQL query
docker exec -i postgres-local psql -U postgres -d kairon -c "SELECT * FROM events LIMIT 5"

# Interactive session
docker exec -it postgres-local psql -U postgres -d kairon

# Run query from file
docker exec -i postgres-local psql -U postgres -d kairon < query.sql
```

### Cleanup

```bash
# Stop containers and clean up temporary files
./scripts/teardown-local.sh

# Remove everything (including database data)
./scripts/teardown-local.sh
docker-compose down -v
```

---

## Common Workflows

### 1. Initial Setup

```bash
# Complete setup from scratch
./scripts/setup-local.sh
```

### 2. Test a New Feature

```bash
# 1. Edit your workflow file in n8n-workflows/

# 2. Deploy and test
./scripts/deploy.sh local

# 3. Check results in database
docker exec -i postgres-local psql -U postgres -d kairon -c \
  "SELECT * FROM projections ORDER BY created_at DESC LIMIT 3"
```

### 3. Test with Real APIs

With the simplified setup, all workflows use real APIs by default:

```bash
# Ensure API keys are in .env:
# - DISCORD_BOT_TOKEN
# - OPENROUTER_API_KEY

# Deploy - workflows will use real APIs
./scripts/deploy.sh local
```

### 4. Debug Workflow Issues

```bash
# 1. Check container logs
docker-compose logs -f n8n-dev

# 2. Test webhook manually
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! debug", "guild_id": "test", "channel_id": "test", "message_id": "debug-123", "author": {"login": "test"}, "timestamp": "'$(date -Iseconds)'"}'

# 3. Inspect database state
docker exec -it postgres-local psql -U postgres -d kairon
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
docker exec -i postgres-local psql -U postgres -d kairon -c "SELECT COUNT(*) FROM events"

# List active workflows
curl -s http://localhost:5679/api/v1/workflows | jq '.data[] | select(.active == true) | {name, id}'

# Test webhook manually
curl -X POST http://localhost:5679/webhook/kairon-local \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! debug", "guild_id": "test", "channel_id": "test", "message_id": "debug-123", "author": {"login": "test"}, "timestamp": "'$(date -Iseconds)'"}'
```

For detailed debugging workflows, see `DEBUG.md`.

## Advanced Usage

### Using Webhook Tunnels (for Discord Integration)

To receive Discord events locally, you need to expose localhost to the internet:

```bash
# Option 1: Using ngrok
ngrok http 5679
# Copy the https://xxxx.ngrok.io URL

# Option 2: Using cloudflared
cloudflared tunnel --url http://localhost:5679
# Copy the https://xxxx.trycloudflare.com URL

# Update .env with your tunnel URL
N8N_WEBHOOK_URL=https://xxxx.ngrok.io/webhook/kairon-local

# Restart discord-relay to pick up new webhook URL
docker-compose restart discord-relay
```

### Custom Database Configuration

```bash
# Update .env with custom settings
DB_USER=myuser
DB_PASSWORD=mypassword
DB_NAME=mykairon

# Restart containers with new config
docker-compose down
docker-compose up -d
```

### Workflow Development Tips

- **Test incrementally:** Deploy after editing workflow files
- **Monitor logs:** `docker-compose logs -f n8n` shows processing in real-time
- **Database persistence:** Data persists between container restarts (use `down -v` to reset)
- **Discord testing:** Set up webhook tunnel to test with real Discord messages
- **Iterative development:** Just run `./scripts/deploy.sh local` after editing workflow files

### Cleanup

```bash
# Stop containers (keeps data)
docker-compose down

# Remove containers and volumes (deletes all data)
docker-compose down -v
```

## File Structure

```
docker-compose.yml              # Full local environment
n8n-workflows/                  # Source workflows
scripts/
├── setup-local.sh              # Automated local setup
├── deploy.sh                  # Local and production deployment
└── workflows/
    └── n8n-push-local.sh      # Local deployment script
```

## Quick Tips

### Recommended Workflow
1. **Start:** `./scripts/setup-local.sh` (one command setup)
2. **Edit:** Modify workflow files in n8n-workflows/
3. **Test:** `./scripts/deploy.sh local` (deploy)
4. **Debug:** Check logs with `docker-compose logs -f n8n`
5. **Verify:** Query database or check n8n UI at http://localhost:5679

### Useful Commands
- **Complete setup:** `./scripts/setup-local.sh`
- **Deploy locally:** `./scripts/deploy.sh local`
- **Deploy to prod:** `./scripts/deploy.sh prod`
- **Check database:** `docker exec -i postgres-local psql -U postgres -d kairon -c "SELECT * FROM events LIMIT 10"`
- **View logs:** `docker-compose logs -f [service-name]`
- **Clean start:** `docker-compose down -v && ./scripts/setup-local.sh`

---

**Last Updated:** 2025-12-28
**Focus:** Simplified single-environment deployment