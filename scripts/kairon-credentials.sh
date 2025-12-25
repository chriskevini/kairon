#!/bin/bash
# Kairon credential helper - wraps remote-dev credential-helper.sh
# Source this file: source ./scripts/kairon-credentials.sh [dev|prod]
#
# This provides a unified interface for accessing credentials across dev/prod
# environments, using the shared remote-dev toolkit.
#
# Usage:
#   source ./scripts/kairon-credentials.sh dev
#   echo $CRED_API_KEY
#   api_get "/api/v1/workflows"
#   db_query "SELECT COUNT(*) FROM events"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source remote-dev credential helper
if [ -f ~/.local/share/remote-dev/lib/credential-helper.sh ]; then
    source ~/.local/share/remote-dev/lib/credential-helper.sh
else
    echo "Error: remote-dev toolkit not found" >&2
    echo "Expected: ~/.local/share/remote-dev/lib/credential-helper.sh" >&2
    return 1
fi

# Load project .env
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo "Warning: $PROJECT_ROOT/.env not found" >&2
fi

ENVIRONMENT="${1:-dev}"

# Initialize credentials based on environment
case "$ENVIRONMENT" in
    dev|development)
        if [ -z "${N8N_DEV_API_KEY:-}" ]; then
            echo "Error: N8N_DEV_API_KEY not set in .env" >&2
            return 1
        fi
        
        init_credentials \
            --api-url "${N8N_DEV_API_URL:-http://localhost:5679}" \
            --api-key "$N8N_DEV_API_KEY" \
            --db-container "${CONTAINER_DB_DEV:-postgres-dev}" \
            --db-name "${DB_NAME_DEV:-kairon_dev}" \
            --db-user "${DB_USER_DEV:-n8n_user}" \
            "dev"
        ;;
    
    prod|production)
        if [ -z "${N8N_API_KEY:-}" ]; then
            echo "Error: N8N_API_KEY not set in .env" >&2
            return 1
        fi
        
        init_credentials \
            --api-url "${N8N_API_URL:-http://localhost:5678}" \
            --api-key "$N8N_API_KEY" \
            --db-container "${CONTAINER_DB:-postgres-db}" \
            --db-name "${DB_NAME:-kairon}" \
            --db-user "${DB_USER:-n8n_user}" \
            "prod"
        ;;
    
    *)
        echo "Error: Invalid environment '$ENVIRONMENT'. Use 'dev' or 'prod'" >&2
        return 1
        ;;
esac

# Export additional Kairon-specific variables for compatibility
export KAIRON_ENV="$CRED_ENV"
export N8N_API_URL="$CRED_API_URL"
export N8N_API_KEY="$CRED_API_KEY"

# Success message
if [ "${VERBOSE:-false}" = "true" ]; then
    echo "✓ Credentials loaded for $ENVIRONMENT environment" >&2
    echo "  API URL: $CRED_API_URL" >&2
    echo "  DB: $CRED_DB_NAME@$CRED_CONTAINER_DB" >&2
fi
