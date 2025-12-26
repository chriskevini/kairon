# Phase 4: API Credential Helper

## Overview

This phase implements a unified credential management system that wraps the shared `remote-dev` toolkit, providing consistent access to n8n API and database credentials across dev and prod environments.

## Files Created/Modified

- **scripts/kairon-credentials.sh** (already exists) - Wrapper script that loads credentials for dev or prod environments

## Usage

### In Shell Sessions

```bash
# Load dev credentials
source ./scripts/kairon-credentials.sh dev

# Access credentials
echo $N8N_API_URL      # http://localhost:5679
echo $N8N_API_KEY      # Your dev API key
echo $CRED_CONTAINER_DB # postgres-dev
echo $CRED_DB_NAME      # kairon_dev

# Load prod credentials  
source ./scripts/kairon-credentials.sh prod

# Access prod credentials
echo $N8N_API_URL      # http://localhost:5678  
echo $N8N_API_KEY      # Your prod API key
```

### In Scripts

```bash
#!/bin/bash
# Example script using credentials

source ./scripts/kairon-credentials.sh dev

# Use api_get helper from credential-helper.sh
api_get "/api/v1/workflows" | jq '.data[] | {name, id}'

# Use db_query helper
db_query "SELECT COUNT(*) FROM events WHERE received_at > NOW() - INTERVAL '1 hour'"
```

## Environment Variables Required

Update your `.env` file with these variables (see `.env.example` for full list):

### Dev Environment
```bash
N8N_DEV_API_KEY=your-dev-api-key
N8N_DEV_API_URL=http://localhost:5679
CONTAINER_DB_DEV=postgres-dev
DB_NAME_DEV=kairon_dev
DB_USER_DEV=n8n_user
```

### Prod Environment  
```bash
N8N_API_KEY=your-prod-api-key
N8N_API_URL=http://localhost:5678
CONTAINER_DB=postgres-db
DB_NAME=kairon
DB_USER=n8n_user
```

## Helper Functions Available

Once credentials are loaded, these functions from `credential-helper.sh` are available:

- `api_get <path>` - GET request to n8n API
- `api_call <method> <path> [data]` - Generic API call
- `db_query <sql>` - Run SQL query against database
- `db_backup [output_file]` - Backup database

See `~/.local/share/remote-dev/lib/credential-helper.sh` for full API.

## Benefits

1. **Consistency** - Same interface for dev and prod
2. **Safety** - Validates credentials exist before use
3. **Convenience** - No manual credential extraction needed
4. **Integration** - Works with existing tools (kairon-ops.sh, deploy.sh)

## Testing

```bash
# Test dev credentials load
source ./scripts/kairon-credentials.sh dev
test -n "$N8N_API_KEY" && echo "✅ Dev credentials loaded"

# Test prod credentials load
source ./scripts/kairon-credentials.sh prod  
test -n "$N8N_API_KEY" && echo "✅ Prod credentials loaded"
```

## Next Phases

This credential helper will be used by:
- Phase 1: kairon-ops.sh (for --dev/--prod support)
- Phase 3: Workflow ID registry (for syncing IDs)
- Phase 5: Integration tests (for database verification)
