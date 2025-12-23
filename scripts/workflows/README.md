# N8N Workflow Deployment Guide

## Overview

Automated deployment pipeline for Kairon n8n workflows with dev→prod promotion and smoke testing.

**Features:**
- ✅ Deploy to dev, run tests, then promote to prod
- ✅ Automatic workflow ID remapping (portable across environments)
- ✅ Automatic credential linking
- ✅ Smoke tests before prod deployment
- ✅ Uses `mode: "list"` with `cachedResultName` for reliability

## Architecture

```
Dev:  localhost:5679 (n8n-dev container)
Prod: localhost:5678 → n8n.chrisirineo.com (n8n-docker-caddy-n8n-1)
```

## Setup

### 1. Dev N8N Instance

If dev n8n isn't running:

```bash
cd /root/kairon
./scripts/workflows/setup-dev-n8n.sh
```

Then:
1. Open http://localhost:5679
2. Create admin account
3. Create 4 credentials with **exact names**:
   - `Discord Bot account` (Discord Bot)
   - `OpenRouter account` (OpenRouter API)  
   - `GitHub account` (GitHub)
   - `Postgres account` (Postgres - DB: `kairon`)
4. Generate API key: Settings → API → Create API Key
5. Save as `N8N_DEV_API_KEY`

### 2. Production N8N Instance

Production is already running at https://n8n.chrisirineo.com

1. Open https://n8n.chrisirineo.com
2. Create same 4 credentials with exact names
3. Generate API key
4. Save as `N8N_PROD_API_KEY`

### 3. Environment Variables

```bash
# Add to ~/.bashrc or ~/.zshrc
export N8N_DEV_API_KEY="your-dev-api-key"
export N8N_PROD_API_KEY="your-prod-api-key"
```

## Deployment

### Full Pipeline (Dev → Prod)

```bash
cd /root/kairon
./scripts/deploy.sh
```

**Flow:**
1. Deploy to dev (localhost:5679)
2. Run smoke tests on dev
3. Deploy to prod (n8n.chrisirineo.com)

**Note:** `deploy.sh` automatically detects the environment:
- Local machine with `rdev`: Uses SSH tunneling
- Server or no `rdev`: Uses direct API access

### Dev Only

```bash
cd /root/kairon
./scripts/deploy.sh dev
```

### Prod Only (Not Recommended)

```bash
cd /root/kairon
./scripts/deploy.sh prod
```

## How It Works

### Deployment Passes

**Pass 1: Deploy Workflows**
- Fetches existing workflows
- Creates new or updates existing
- Builds workflow name → ID mapping

**Pass 2: Fix Workflow References**
- Finds all `executeWorkflow` nodes
- Uses `cachedResultName` to map workflow names to IDs
- Updates all sub-workflow references

**Pass 3: Fix Credentials** (dev only with DB access)
- Fetches credentials from database
- Links credentials by name to workflow nodes
- Ensures nodes have both name and ID

### Smoke Tests

**Test 1: Health Check**
- Verifies n8n is responding

**Test 2: Workflow Count**
- Confirms all workflows deployed

**Test 3: Critical Workflows**
- Verifies: Route_Event, Query_DB, Handle_Error

**Test 4: Reference Validation**
- Checks for unfixed placeholder IDs
- Ensures all workflow references are valid

## Workflow Reference Architecture

All workflows use **mode: "list"** for portability:

```json
{
  "type": "n8n-nodes-base.executeWorkflow",
  "parameters": {
    "workflowId": {
      "__rl": true,
      "mode": "list",
      "cachedResultName": "Query_DB",  // ← Workflow name (portable!)
      "value": "PLACEHOLDER_WILL_BE_FIXED_BY_DEPLOY"
    }
  }
}
```

**Benefits:**
- Workflow names map to correct IDs in any environment
- Self-documenting (see what workflow is called)
- No manual ID configuration needed
- Deployment script automatically fixes all references

## Troubleshooting

### Dev n8n not responding

```bash
docker logs n8n-dev --tail 50
docker restart n8n-dev
```

### "Found credential with no ID"

Credentials weren't created with exact names:

1. Delete existing credentials in n8n UI
2. Recreate with **exact names** (see Setup section)
3. Re-run deployment

### "Workflow does not exist"

Workflow references aren't fixed:

```bash
# Check source files use mode:list
grep -r '"mode": "id"' n8n-workflows/

# Should return nothing (all should be mode:list)
```

### Smoke tests fail

Check execution logs:
```bash
# Dev
docker exec postgres-db psql -U n8n_user -d n8n_dev -c \
  "SELECT * FROM execution_entity ORDER BY \"startedAt\" DESC LIMIT 5;"

# Prod  
docker exec postgres-db psql -U n8n_user -d n8n_chat_memory -c \
  "SELECT * FROM execution_entity ORDER BY \"startedAt\" DESC LIMIT 5;"
```

### Rollback prod

If prod deployment fails, workflows are already updated. To rollback:

```bash
# Option 1: Re-deploy previous version
git checkout <previous-commit>
cd /root/kairon
N8N_API_URL=http://localhost:5678 \
N8N_API_KEY="$N8N_PROD_API_KEY" \
./scripts/workflows/n8n-push-prod.sh

# Option 2: Restore from database backup
# (if you have one)
```

## Development Workflow

### Making Changes

1. Edit workflow files in `/root/kairon/n8n-workflows/`
2. Ensure executeWorkflow nodes use `mode: "list"` with `cachedResultName`
3. Test locally:
   ```bash
   ./scripts/deploy.sh dev
   ```
4. If dev tests pass, deploy to prod:
   ```bash
   ./scripts/deploy.sh prod
   ```
5. Commit changes

### Adding New Workflows

1. Export from n8n UI
2. Save to `/root/kairon/n8n-workflows/`
3. Convert any `mode: "id"` to `mode: "list"`:
   ```bash
   # Manual: edit JSON, change mode and add cachedResultName
   # Or re-select workflows in n8n UI using dropdown
   ```
4. Deploy to dev for testing

### Credentials Backup

Store credential values securely (never commit):

```bash
cat > ~/.n8n_credentials.env << 'EOF'
DISCORD_BOT_TOKEN="your-token"
OPENROUTER_API_KEY="your-key"
GITHUB_PAT="your-pat"
POSTGRES_HOST="postgres-db"
POSTGRES_PORT="5432"
POSTGRES_DB="kairon"
POSTGRES_USER="n8n_user"
POSTGRES_PASSWORD="password"
EOF

chmod 600 ~/.n8n_credentials.env
```

## Scripts

- `../deploy.sh` - Main deployment script (works locally and on server)
- `n8n-push-local.sh` - Push to local/dev n8n via direct API
- `n8n-push-prod.sh` - 3-pass deployment (workflow IDs, credentials, references)
- `setup-dev-n8n.sh` - Set up dev n8n instance
- `validate_workflows.sh` - Validate workflow JSON files
- `sanitize_workflows.sh` - Remove pinData from workflow exports

## Environment Variables

```bash
# Required (add to .env in project root)
N8N_DEV_API_KEY="dev-api-key"
N8N_API_KEY="prod-api-key"
REMOTE_HOST="DigitalOcean"              # SSH host for rdev
N8N_DEV_SSH_HOST="DigitalOcean"         # SSH host for dev tunneling

# Optional (defaults shown)
N8N_DEV_API_URL="http://localhost:5679"
N8N_API_URL="http://localhost:5678"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"
```

## Database Info

```
Dev DB:  n8n_dev (postgres-db container)
Prod DB: n8n_chat_memory (postgres-db container)
Kairon DB: kairon (separate, never touched by n8n)
```

## Support

**Check Status:**
```bash
docker ps | grep n8n
curl http://localhost:5679/healthz  # dev
curl http://localhost:5678/healthz  # prod
```

**Check Logs:**
```bash
docker logs n8n-dev --tail 50        # dev
docker logs n8n-docker-caddy-n8n-1 --tail 50  # prod
```

**Check Workflows:**
```bash
# Dev
curl -H "X-N8N-API-KEY: $N8N_DEV_API_KEY" http://localhost:5679/api/v1/workflows | jq '.data[].name'

# Prod
curl -H "X-N8N-API-KEY: $N8N_PROD_API_KEY" http://localhost:5678/api/v1/workflows | jq '.data[].name'
```
