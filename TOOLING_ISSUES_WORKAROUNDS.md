# Kairon Development Tooling

## Overview
This document describes the current development tooling for Kairon, including local testing setup and historical issues/workarounds.

## Local Development Setup

Kairon now supports local development testing with Docker containers for n8n and PostgreSQL.

### Prerequisites
- Docker and Docker Compose installed
- Python 3.8+ for transformation scripts

### Quick Start

1. **Start local dev environment:**
   ```bash
   docker-compose -f docker-compose.dev.yml up -d
   ```

2. **Set up database:**
   ```bash
   # Load schema
   docker exec -i postgres-dev-local psql -U n8n_user -d kairon < db/schema.sql

   # Or for custom DB_USER/DB_NAME from .env:
   source .env
   docker exec -i postgres-dev-local psql -U $DB_USER -d $DB_NAME < db/schema.sql
   ```

3. **Transform workflows for dev:**
   ```bash
   # Create transformed workflows with mocks
   mkdir -p n8n-workflows-transformed
   for wf in n8n-workflows/*.json; do
     cat "$wf" | python scripts/transform_for_dev.py > "n8n-workflows-transformed/$(basename "$wf")"
   done

   # For real API testing (no mocks):
   NO_MOCKS=1 cat workflow.json | python scripts/transform_for_dev.py
   ```

4. **Push workflows to local n8n:**
   ```bash
   # Note: Local n8n runs without API key authentication
   curl -X POST http://localhost:5679/api/v1/workflows \
     -H "Content-Type: application/json" \
     -d "$(jq '{name, nodes, connections, settings}' n8n-workflows-transformed/Route_Event.json)"
   ```

5. **Test webhooks:**
   ```bash
   # Send test message
   curl -X POST http://localhost:5679/webhook/kairon-dev-test \
     -H "Content-Type: application/json" \
     -d '{"event_type": "message", "content": "$$ buy milk", ...}'
   ```

### Services

- **n8n:** http://localhost:5679 (no auth for dev)
- **PostgreSQL:** localhost:5433, user: n8n_user, db: kairon

### Workflow Transformation

The `transform_for_dev.py` script modifies workflows for local testing:
- Converts Schedule Triggers to Webhook Triggers
- Mocks Discord/LLM nodes with Code nodes
- Remaps Execute Workflow nodes for dev IDs
- Preserves webhook paths for testing

## Historical Issues & Workarounds

This section details problems encountered during development and their resolutions.

## Problem 1: kairon-ops.sh Targets Production, Not Dev (RESOLVED)

### Issue Description
The `kairon-ops.sh` tool is designed for remote production server operations using `rdev`. Local development testing was not available at the time.

### Resolution
Local development testing is now available via `docker-compose.dev.yml`. Use local containers for dev testing instead of remote connections.

### Current Usage
```bash
# Production operations (remote server)
./tools/kairon-ops.sh --prod status

# Development operations (local containers)
docker-compose -f docker-compose.dev.yml up -d
curl "http://localhost:5679/api/v1/workflows"
```

### Root Cause
`kairon-ops.sh` uses `rdev exec` to run commands on remote servers, connecting to production n8n instances. The tool is not designed for local dev environment operations.

### Workaround
Use direct API calls to the dev instance:
```bash
# Correct way for dev environment
export N8N_API_KEY="$(grep N8N_DEV_API_KEY .env | cut -d'=' -f2)"
curl -H "X-N8N-API-KEY: $N8N_API_KEY" "http://localhost:5679/api/v1/workflows"
```

## Problem 2: Deployment Script Silent Failures

### Issue Description
The deployment script (`./scripts/deploy.sh dev`) reported "✅ PASSED" but failed to update the dev workflow with new validation nodes.

### Evidence
```bash
STAGE 1: Deploy to DEV... ✅ PASSED
# But validation nodes were missing from deployed workflow
```

### Root Cause
The deployment script creates new workflows in dev instead of updating existing ones due to workflow ID remapping issues. The script uses `WORKFLOW_ID_REMAP='{}'` for dev (no remapping), but the workflow matching logic failed.

### Workaround
Manually update existing dev workflows via API:
```bash
# Find the correct workflow ID in dev
curl -H "X-N8N-API-KEY: $N8N_API_KEY" "http://localhost:5679/api/v1/workflows" | jq '.data[] | select(.name == "Route_Event (with webhook)") | .id'

# Update with local changes
jq '{name, nodes, connections, settings}' Route_Event.json | \
curl -X PUT -H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json" \
     -d @- "http://localhost:5679/api/v1/workflows/{workflow_id}"
```

## Problem 3: API Authentication & Endpoint Confusion

### Issue Description
Multiple authentication and endpoint issues when trying to access n8n APIs.

### Evidence
```bash
# Wrong API key source
curl -H "X-N8N-API-KEY: $N8N_API_KEY" # Used prod key for dev instance

# Wrong endpoint
curl "http://localhost:5679/api/v1/executions" # Missing authentication header

# Environment variable issues
echo $N8N_API_KEY # Empty because not exported properly
```

### Root Cause
- Mixed usage of production vs dev API keys
- Environment variables not properly exported in shell sessions
- Inconsistent API endpoint usage

### Workaround
Explicitly export and verify API keys:
```bash
# Extract and export the correct key
export N8N_API_KEY="$(grep N8N_DEV_API_KEY .env | cut -d'=' -f2)"

# Verify key is set
echo "Key starts with: $(echo $N8N_API_KEY | cut -c1-20)..."

# Use consistent curl commands
curl -H "X-N8N-API-KEY: $N8N_API_KEY" \
     "http://localhost:5679/api/v1/workflows"
```

## Problem 4: Workflow ID Mismatches

### Issue Description
Local workflow (`IdpHzWCchShvArHM`) had different ID than deployed dev version (`F60v1kSn9JKWkZgZ`), causing confusion about which workflow was being updated.

### Evidence
```bash
# Local workflow ID
jq '.id' n8n-workflows/Route_Event.json
# "IdpHzWCchShvArHM"

# Dev workflow ID
curl "http://localhost:5679/api/v1/workflows" | jq '.data[] | select(.name | contains("Route_Event")) | .id'
# "F60v1kSn9JKWkZgZ"
```

### Root Cause
Deployment script creates new workflow instances in dev environment instead of updating existing ones. This is likely due to n8n's internal versioning or the deployment process.

### Workaround
Always verify the actual deployed workflow ID before operations:
```bash
# Find workflows by name pattern
curl -H "X-N8N-API-KEY: $N8N_API_KEY" \
     "http://localhost:5679/api/v1/workflows" | \
jq '.data[] | select(.name | contains("Route_Event")) | "\(.id) \(.name) \(.active)"'
```

## Problem 5: JSON Parsing Issues

### Issue Description
Various tools failed to parse n8n workflow JSON due to formatting issues.

### Evidence
```bash
# jq parsing failed
./tools/kairon-ops.sh n8n-get IdpHzWCchShvArHM | jq .
# parse error: Invalid numeric literal at line 1, column 2

# Python JSON parsing failed
python3 -c "import json; json.load(open('workflow.json'))"
# json.decoder.JSONDecodeError: Expecting value
```

### Root Cause
- Tool output includes extra formatting/header text
- JSON responses may have unexpected structure
- Some commands return error messages instead of JSON

### Workaround
Use intermediate files and robust parsing:
```bash
# Save to file first, then parse
curl -s "http://localhost:5679/api/v1/workflows" > /tmp/workflows.json
jq '.data[] | .name' /tmp/workflows.json

# Use grep for simple extractions
curl -s "http://localhost:5679/api/v1/workflows" | grep '"name"' | head -5

# Robust error handling
curl -s "http://localhost:5679/api/v1/workflows" | \
python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(f'Found {len(data.get(\"data\", []))} workflows')
except:
    print('JSON parsing failed')
"
```

## Problem 6: Database Query Authentication

### Issue Description
`kairon-ops.sh db-query` worked for database access, but direct queries through other tools failed.

### Evidence
```bash
# This worked (uses rdev)
./tools/kairon-ops.sh db-query "SELECT COUNT(*) FROM events"

# This failed (direct connection)
psql -h localhost -U postgres -d kairon -c "SELECT COUNT(*) FROM events"
# Authentication failed
```

### Root Cause
Database authentication is configured differently for remote vs local access. `rdev` handles the remote server connection properly.

### Workaround
Use the kairon-ops.sh tool for all database operations:
```bash
# Correct way
./tools/kairon-ops.sh db-query "SELECT * FROM events LIMIT 5"

# Avoid direct database connections
# psql -h localhost ... # Don't use this
```

## Problem 7: Lack of Integration Testing

### Issue Description
No automated way to test end-to-end workflow execution with real Discord messages.

### Evidence
```bash
# Could check static workflow structure
pytest n8n-workflows/tests/test_Route_Event.py # ✅ PASSED

# Could check database state
./tools/kairon-ops.sh db-query "SELECT COUNT(*) FROM events" # ✅ Worked

# Could NOT test actual workflow execution with webhooks
# No automated integration test for Discord → n8n → Database flow
```

### Root Cause
Testing infrastructure doesn't include Discord webhook simulation or end-to-end workflow execution testing.

### Workaround
Manual verification through database inspection:
```bash
# Check if messages are processed correctly
./tools/kairon-ops.sh db-query "
SELECT e.payload->>'content' as content,
       CASE WHEN t.id IS NOT NULL THEN 'PROCESSED' ELSE 'BLOCKED' END as status
FROM events e
LEFT JOIN traces t ON e.id = t.event_id
WHERE e.event_type = 'discord_message'
ORDER BY e.received_at DESC LIMIT 10
"
```

## Problem 8: Missing Tool Documentation

### Issue Description
Lack of clear documentation about which tools work with which environments.

### Evidence
- `kairon-ops.sh` README doesn't specify it's for production only
- No clear distinction between dev and prod tooling
- Environment-specific API keys and endpoints not well documented

### Workaround
Documented environment-specific usage patterns:
```bash
# For PRODUCTION operations (remote server)
./tools/kairon-ops.sh status          # ✅ Works
./tools/kairon-ops.sh n8n-get <ID>    # ✅ Works
./tools/kairon-ops.sh db-query <SQL>  # ✅ Works

# For DEV operations (local machine)
export N8N_API_KEY="$(grep N8N_DEV_API_KEY .env | cut -d'=' -f2)"
curl -H "X-N8N-API-KEY: $N8N_API_KEY" "http://localhost:5679/api/v1/..."  # ✅ Works
```

## Summary

The tooling issues have been largely resolved with the introduction of local development testing. Key improvements:

1. **Local dev environment** with Docker containers
2. **Workflow transformation** for mock testing
3. **Direct API access** for local n8n instance
4. **Database setup** scripts for local testing

## Current Best Practices

1. **Use local containers** for development testing
2. **Transform workflows** with `transform_for_dev.py` for mocks
3. **Push via API** to local n8n instance
4. **Test webhooks** directly against local instance
5. **Use kairon-ops.sh** only for production operations
6. **Verify database** state through local connections

## Future Improvements

1. **Automated local testing** pipeline
2. **Integration tests** for webhook flows
3. **UI for workflow management** in dev
4. **Database seeding** for consistent test data

## Impact Assessment

These tooling issues caused significant debugging overhead:
- **Time spent**: ~2 hours on tooling problems vs 30 minutes on actual code fixes
- **Risk**: Deployed broken validation logic to dev environment
- **Reliability**: Reduced confidence in deployment process

The validation logic itself was correct from the start - the issues were entirely with the deployment and verification tooling.</content>
<parameter name="filePath">TOOLING_ISSUES_WORKAROUNDS.md