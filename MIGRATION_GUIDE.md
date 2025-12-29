# Migration Guide: Simplified Deployment (Dec 2025)

## What Changed

The deployment system has been simplified to reduce complexity:

**Before (Confusing):**
- `docker-compose.dev.yml` (with transformations/mocks)
- `docker-compose.yml` (different setup)
- `deploy.sh` with local/dev/prod/all targets
- `transform_for_dev.py` (workflow transformations)
- Multiple push scripts with different logic

**After (Simplified):**
- `docker-compose.yml` (single full environment)
- `deploy.sh` (just `local` or `prod`)
- No transformations (use real workflows everywhere)
- `setup-local.sh` (automated local setup)

## Key Changes

### 1. Single Docker Compose File

**Old:** `docker-compose.dev.yml` (n8n + postgres only)
**New:** `docker-compose.yml` (n8n + postgres + discord-relay + embedding-service)

### 2. Deploy Script Simplified

**Old:**
```bash
./scripts/deploy.sh local    # Setup dev with transforms
./scripts/deploy.sh dev      # Deploy dev with transforms
./scripts/deploy.sh prod     # Deploy prod
./scripts/deploy.sh all      # Full pipeline
```

**New:**
```bash
./scripts/setup-local.sh     # One-command local setup (NEW)
./scripts/deploy.sh local    # Deploy to localhost
./scripts/deploy.sh prod     # Deploy to production
```

### 3. No Transformations

**Old:** Workflows transformed for local testing (mocks, webhook triggers)
**New:** Same workflows deployed everywhere (real APIs, real triggers)

### 4. Webhook Paths

**Old dev:** `/webhook/kairon-dev-test`
**Now:** `/webhook/kairon-local` (configurable via `WEBHOOK_PATH` in .env)

### 5. Authentication

**Old:** API keys for dev
**Now:** Session cookies for localhost, API keys only for prod

## Migration Steps

### If You Were Using Dev Setup

1. **Stop old containers:**
   ```bash
   docker-compose -f docker-compose.dev.yml down
   ```

2. **Set up new environment:**
   ```bash
   ./scripts/setup-local.sh
   ```

3. **Update webhook URLs:**
   - If using Discord webhook, update `N8N_WEBHOOK_URL` in `.env`
   - Old: `http://localhost:5679/webhook/kairon-dev-test`
   - New: `http://localhost:5679/webhook/kairon-local`

4. **Update documentation/scripts:**
   - Replace `docker-compose.dev.yml` with `docker-compose.yml`
   - Replace `deploy.sh dev` with `deploy.sh local`

### If You Were Testing with Transforms

**Before:** Workflows were mocked for fast testing
**Now:** Workflows use real APIs by default

**Benefits:**
- More accurate testing (same behavior as production)
- No need to maintain separate transformation logic
- Simpler deployment pipeline
- No "it works in dev but not prod" issues

**Trade-offs:**
- Requires API keys during development
- Slightly slower (real API calls)
- Needs internet connection

### If You Were Using NO_MOCKS Flag

**Old:** `NO_MOCKS=1 ./scripts/deploy.sh dev`
**New:** Not needed - real APIs are default

## What Was Deprecated/Removed

### Files Moved to `docs/archive/deprecated/`:

- `transform_for_dev.py` - Workflow transformation script
- `docker-compose.dev.yml` - Old dev compose file
- `setup-local-full.sh` - Temporary file (replaced by `setup-local.sh`)
- `FULL_LOCAL_SETUP.md` - Temporary documentation

### Scripts Renamed/Removed:

- ~~`deploy.sh dev`~~ → Use `deploy.sh local`
- ~~`deploy.sh local`~~ (old behavior) → Use `setup-local.sh` first, then `deploy.sh local`

### Environment Variables Removed:

- `N8N_DEV_ENCRYPTION_KEY` - Now uses default from docker-compose.yml
- `N8N_DEV_API_KEY` - Not needed for localhost (uses session cookies)
- `NO_MOCKS` - Not needed (real APIs default)

## Quick Reference

### Local Development

**Setup:**
```bash
./scripts/setup-local.sh
```

**Deploy after changes:**
```bash
./scripts/deploy.sh local
```

**Check logs:**
```bash
docker-compose logs -f n8n
```

### Production Deployment

**Deploy to server:**
```bash
./scripts/deploy.sh prod
```

## Environment Variables

### Required for Local Development:

```bash
# .env
DISCORD_BOT_TOKEN=your-bot-token
OPENROUTER_API_KEY=your-api-key
```

### Optional:

```bash
# Database
DB_USER=postgres
DB_PASSWORD=postgres
DB_NAME=kairon

# n8n
N8N_DEV_USER=admin
N8N_DEV_PASSWORD=Admin123!
WEBHOOK_PATH=kairon-local

# Discord webhook (if testing with Discord)
N8N_WEBHOOK_URL=https://xxxx.ngrok.io/webhook/kairon-local
```

### Required for Production:

```bash
N8N_API_KEY=your-prod-api-key
N8N_API_URL=http://localhost:5678
N8N_DEV_SSH_HOST=your-server
```

## Benefits of Simplification

1. **Single codebase** - Same workflows everywhere
2. **No surprises** - Local behavior matches production
3. **Easier onboarding** - Fewer concepts to learn
4. **Faster development** - No transformation step
5. **Better testing** - Real APIs during development
6. **Less maintenance** - One less transform script

## Common Issues

### "n8n not responding at localhost:5679"

**Solution:**
```bash
# Start containers
docker-compose up -d

# Wait for n8n to be ready
curl http://localhost:5679/
```

### "Discord bot not working"

**Solution:**
```bash
# Check discord-relay logs
docker-compose logs -f discord-relay

# Verify webhook URL is set
docker exec discord-relay-local env | grep N8N_WEBHOOK_URL

# If using tunnel, update .env and restart
docker-compose restart discord-relay
```

### "Webhook not triggering workflows"

**Solution:**
```bash
# Check webhook path in .env
echo $WEBHOOK_PATH

# Test webhook manually
curl -X POST http://localhost:5679/webhook/$WEBHOOK_PATH \
  -H "Content-Type: application/json" \
  -d '{"event_type":"message","content":"test"}'

# Check n8n UI for webhook path
# Go to http://localhost:5679 → Route_Event workflow → Webhook trigger
```

## Rollback Plan

If you need to use the old dev setup:

```bash
# Restore from archive
git checkout HEAD~1 docker-compose.dev.yml

# Start old setup
docker-compose -f docker-compose.dev.yml up -d

# Deploy with transforms
NO_MOCKS=1 ./scripts/deploy.sh dev
```

Note: Old setup may not work perfectly after schema changes.

## Questions?

See documentation:
- `docs/DEVELOPMENT.md` - Local development guide
- `docs/DEPLOYMENT.md` - Production deployment guide
- `AGENTS.md` - Agent guidelines

**Last Updated:** 2025-12-28
