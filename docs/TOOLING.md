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

## Credential Helper

```bash
# Load credentials for dev
source ./scripts/kairon-credentials.sh dev

# Load credentials for prod
source ./scripts/kairon-credentials.sh prod

# Now use direct curl commands
curl -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_API_URL/api/v1/workflows"
```

## Common Workflows

### Deploy Changes to Dev
```bash
# 1. Make changes to n8n-workflows/*.json

# 2. Deploy (includes verification)
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
