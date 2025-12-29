#!/bin/bash
# Simple deployment pipeline for n8n workflows
#
# This replaces the complex 2,536-line deployment system with a simple, robust approach:
# - Single codebase (no transformations)
# - Direct workflow testing
# - Automatic environment setup
# - Cleanup of orphan containers
#
# Usage:
#   ./scripts/simple-deploy.sh [dev|prod|all|validate]
#
# Environment Variables (.env):
#   N8N_API_URL          - Production n8n URL
#   N8N_API_KEY           - Production n8n API key
#   N8N_DEV_API_URL      - Dev/Staging n8n URL (default: http://localhost:5679)
#   N8N_DEV_API_KEY       - Dev/Staging n8n API key
#   DB_NAME               - Database name (default: kairon_dev)
#   DB_USER               - Database user (default: n8n_user)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"

# Configuration - MUST come before loading environment
TARGET="${1:-all}"

# Load environment variables
# Try environment-specific file first, then fall back to default .env
if [ -f "$REPO_ROOT/.env.$TARGET" ]; then
    set -a
    source "$REPO_ROOT/.env.$TARGET"
    set +a
elif [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
else
    log_error "No environment file found"
    echo "Create one of:"
    echo "  .env.dev        # For local development"
    echo "  .env.prod       # For production deployment"
    echo "  .env            # Default (production)"
    exit 1
fi
# Variables loaded from .env.$TARGET or .env
# Support CI/CD override variables
N8N_API_URL="${N8N_DEV_API_URL:-${N8N_API_URL:-http://localhost:5678}}"
N8N_API_KEY="${N8N_DEV_API_KEY:-${N8N_API_KEY:-}}"
DB_NAME="${DB_NAME:-kairon_dev}"
DB_USER="${DB_USER:-n8n_user}"

# Safety check: Don't allow production mode if overrides are set for dev
# Skip for validate mode since it doesn't deploy
if [ "$TARGET" != "validate" ] && [ "$TARGET" = "dev" ] || [ "$TARGET" = "all" ]; then
    if [ -n "${N8N_DEV_API_KEY:-}" ] && [ -n "${N8N_DEV_API_URL:-}" ]; then
        # Overrides are set, so we're not using base production file
        # This is safe - environment file specifies dev credentials
        :
    elif [[ "$N8N_API_URL" =~ prod|production|5678 ]]; then
        log_error "Production URL detected in dev mode!"
        log_error "Are you using .env instead of .env.dev?"
        log_error "For dev, create: cp .env.example .env.dev"
        log_error "Then add: N8N_API_URL=http://localhost:5679"
        log_error "Then add: N8N_API_KEY=your-dev-key"
        exit 1
    fi
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_info() {
    echo -e "${YELLOW}→ $1${NC}"
}

log_section() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

# Cleanup orphan containers and volumes
cleanup_environment() {
    log_info "Cleaning up environment..."

    # Remove orphan containers for this project
    cd "$REPO_ROOT"

    # Remove old containers that might conflict
    for old_container in n8n-dev-local postgres-dev-local postgres-dev-local n8n postgres; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${old_container}$"; then
            log_info "Removing old container: $old_container"
            docker rm -f "$old_container" 2>/dev/null || true
        fi
    done

    # Remove orphan containers (not in current compose file)
    if docker-compose ps -q 2>/dev/null | grep -q "Found orphan"; then
        log_info "Removing orphan containers..."
        docker-compose down --remove-orphans 2>/dev/null || true
    fi
}

# Start Docker environment
start_containers() {
    log_info "Starting Docker environment..."

    cd "$REPO_ROOT"

    # Stop and remove old containers
    cleanup_environment

    # Start fresh containers
    docker-compose up -d

    # Wait for database to be ready
    log_info "Waiting for database to be ready..."
    local max_wait=30
    local waited=0

    while [ $waited -lt $max_wait ]; do
        if docker exec kairon-postgres pg_isready -U "${DB_USER}" 2>/dev/null; then
            log_success "Database is ready"
            break
        fi

        sleep 1
        waited=$((waited + 1))
        echo -n "."
    done

    if [ $waited -ge $max_wait ]; then
        log_error "Database did not become ready within ${max_wait}s"
        return 1
    fi

    # Create database if it doesn't exist
    log_info "Checking database..."
    if ! docker exec kairon-postgres psql -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1" 2>/dev/null; then
        log_info "Creating database: ${DB_NAME}"
        docker exec kairon-postgres psql -U "${DB_USER}" -d postgres -c "CREATE DATABASE ${DB_NAME};"
    fi

    # Wait for n8n to be ready
    log_info "Waiting for n8n to be ready..."
    waited=0

    while [ $waited -lt $max_wait ]; do
        if curl -sf http://localhost:5679/healthz > /dev/null 2>&1 || \
           curl -sf http://localhost:5679 > /dev/null 2>&1; then
            log_success "n8n is ready"
            break
        fi

        sleep 1
        waited=$((waited + 1))
        echo -n "."
    done

    if [ $waited -ge $max_wait ]; then
        log_error "n8n did not become ready within ${max_wait}s"
        return 1
    fi

    return 0
}

# Retry wrapper for curl commands (handles transient network issues)
retry_curl() {
    local max_attempts=3
    local attempt=1
    local delay=2

    while [ $attempt -le $max_attempts ]; do
        if curl "$@"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            echo -e "${YELLOW}Retry $attempt/$max_attempts in ${delay}s...${NC}" >&2
            sleep $delay
        fi

        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done

    return 1
}

# Validate JSON syntax
validate_json() {
    log_info "Validating workflow JSON syntax..."

    local errors=0
    for workflow in "$WORKFLOW_DIR"/*.json; do
        [ -f "$workflow" ] || continue

        if ! jq empty "$workflow" 2>/dev/null; then
            log_error "Invalid JSON: $(basename "$workflow")"
            errors=$((errors + 1))
        fi
    done

    if [ $errors -gt 0 ]; then
        log_error "Found $errors JSON syntax errors"
        return 1
    fi

    log_success "JSON validation passed"
    return 0
}

# Check for duplicate workflow names
check_duplicates() {
    log_info "Checking for duplicate workflow names..."

    local duplicates
    duplicates=$(jq -r '.name' "$WORKFLOW_DIR"/*.json 2>/dev/null | sort | uniq -d)

    if [ -n "$duplicates" ]; then
        log_error "Duplicate workflow names found:"
        echo "$duplicates"
        return 1
    fi

    log_success "No duplicate names found"
    return 0
}

# Check n8n first-time setup
check_n8n_setup() {
    local api_url="$1"
    local api_key="$2"

    # Try to connect without auth first
    if curl -sf "$api_url/api/v1/workflows?limit=1" > /dev/null 2>&1; then
        # n8n is running but doesn't require auth (first-time setup)
        log_error "n8n needs initial setup"
        echo ""
        echo "First-time setup required:"
        echo "1. Open $api_url in your browser"
        echo "2. Create an admin account"
        echo "3. Go to Settings → API"
        echo "4. Generate an API key"
        echo "5. Add API key to environment file:"
        echo ""
        if [[ "$api_url" == *"localhost"* ]]; then
            echo "   Create .env.dev:"
            echo "     N8N_API_KEY=your-generated-api-key-here"
            echo ""
            echo "   Then run: ./scripts/simple-deploy.sh dev"
        else
            echo "   Create .env.prod:"
            echo "     N8N_API_KEY=your-generated-api-key-here"
            echo ""
            echo "   Then run: ./scripts/simple-deploy.sh prod"
        fi
        echo ""
        return 1
    fi

    return 0
}

# Deploy workflows to n8n
deploy_workflows() {
    local api_url="$1"
    local api_key="$2"

    # Check first-time setup
    check_n8n_setup "$api_url" "$api_key" || return 1

    log_info "Deploying workflows to $api_url..."

    # Get existing workflows
    local existing_workflows
    existing_workflows=$(retry_curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=100" | jq -r '.data[] | "\(.name)|\(.id)"')

    # Deploy each workflow
    local deployed=0
    local updated=0
    local errors=0

    for workflow in "$WORKFLOW_DIR"/*.json; do
        [ -f "$workflow" ] || continue

        local wf_name
        wf_name=$(jq -r '.name' "$workflow")

        # Check if workflow exists
        local existing_id
        existing_id=$(echo "$existing_workflows" | grep "^${wf_name}|" | cut -d'|' -f2 || echo "")

        # Prepare workflow payload (remove id, pinData, versionId)
        local payload
        payload=$(jq 'del(.id, .pinData, .versionId)' "$workflow")

        if [ -n "$existing_id" ]; then
            # Update existing workflow
            if retry_curl -s -f -X PUT \
                -H "X-N8N-API-KEY: $api_key" \
                -H "Content-Type: application/json" \
                -d "$payload" \
                "$api_url/api/v1/workflows/$existing_id" > /dev/null 2>&1; then
                updated=$((updated + 1))
                echo "  Updated: $wf_name"
            else
                log_error "Failed to update: $wf_name"
                errors=$((errors + 1))
            fi
        else
            # Create new workflow
            if retry_curl -s -f -X POST \
                -H "X-N8N-API-KEY: $api_key" \
                -H "Content-Type: application/json" \
                -d "$payload" \
                "$api_url/api/v1/workflows" > /dev/null 2>&1; then
                deployed=$((deployed + 1))
                echo "  Created: $wf_name"
            else
                log_error "Failed to create: $wf_name"
                errors=$((errors + 1))
            fi
        fi
    done

    echo ""
    if [ $errors -eq 0 ]; then
        log_success "Deployment complete: $deployed created, $updated updated"
        return 0
    else
        log_error "Deployment failed: $errors errors"
        return 1
    fi
}

# Smoke test deployed workflows
smoke_test() {
    local api_url="$1"
    local api_key="$2"

    log_info "Running smoke test..."

    # Verify workflows are accessible
    local count
    count=$(retry_curl -s -H "X-N8N-API-KEY: $api_key" "$api_url/api/v1/workflows?limit=1" | jq '.data | length')

    if [ "$count" -ge 1 ]; then
        log_success "Smoke test passed ($count workflows accessible)"
        return 0
    else
        log_error "Smoke test failed (no workflows accessible)"
        return 1
    fi
}

# Run basic tests
run_tests() {
    log_info "Running basic workflow tests..."

    # Test 1: Validate all workflows can be parsed
    validate_json || return 1

    # Test 2: Check for duplicate workflow names
    check_duplicates || return 1

    log_success "All tests passed"
    return 0
}

# Main execution
main() {
    log_section "Simple n8n Workflow Deployment"

    cd "$REPO_ROOT"

    case "$TARGET" in
        validate)
            # Validation only - no deployment
            run_tests
            ;;

        dev)
            # Deploy to LOCAL development environment
            # Start local containers if not running
            if ! docker ps --format '{{.Names}}' | grep -q "^kairon-n8n$"; then
                start_containers || exit 1
            else
                # Ensure database exists even if containers are running
                if ! docker exec kairon-postgres psql -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1" 2>/dev/null; then
                    log_info "Creating database: ${DB_NAME}"
                    docker exec kairon-postgres psql -U "${DB_USER}" -d postgres -c "CREATE DATABASE ${DB_NAME};" 2>/dev/null || true
                fi
            fi

            # Variables already loaded from .env.$TARGET or .env
            run_tests || exit 1
            deploy_workflows "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            smoke_test "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            ;;

        prod)
            # Deploy to PRODUCTION environment
            export N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
            export N8N_API_KEY="${N8N_API_KEY}"

            run_tests || exit 1
            deploy_workflows "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            smoke_test "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            ;;

        all)
            # Deploy to LOCAL development, then production
            # Stage 1: Local dev
            log_section "Stage 1: Deploy to Local Development"

            if ! docker ps --format '{{.Names}}' | grep -q "^kairon-n8n$"; then
                start_containers || exit 1
            else
                # Ensure database exists even if containers are running
                if ! docker exec kairon-postgres psql -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1" 2>/dev/null; then
                    log_info "Creating database: ${DB_NAME}"
                    docker exec kairon-postgres psql -U "${DB_USER}" -d postgres -c "CREATE DATABASE ${DB_NAME};" 2>/dev/null || true
                fi
            fi

            # Variables already loaded from .env.$TARGET or .env
            run_tests || exit 1
            deploy_workflows "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            smoke_test "$N8N_API_URL" "$N8N_API_KEY" || exit 1

            # Stage 2: Production
            log_section "Stage 2: Deploy to Production"

            run_tests || exit 1
            deploy_workflows "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            smoke_test "$N8N_API_URL" "$N8N_API_KEY" || exit 1
            ;;

        *)
            echo "Usage: $0 [validate|dev|prod|all]"
            echo ""
            echo "Commands:"
            echo "  validate - Validate workflows only (no deployment)"
            echo "  dev      - Deploy to LOCAL development (auto-starts containers + creates database)"
            echo "  prod     - Deploy to PRODUCTION via API (remote server)"
            echo "  all      - Deploy to local dev, then production (default)"
            echo ""
            echo "Environment Configuration:"
            echo "  Copy .env.example to environment file:"
            echo "    cp .env.example .env.dev        # For local development"
            echo "    cp .env.example .env.prod       # For production deployment"
            echo ""
            echo "  Then run: ./scripts/simple-deploy.sh <target>"
            echo ""
            echo "Targets:"
            echo "  dev  - Load .env.dev (or .env if .env.dev doesn't exist)"
            echo "  prod - Load .env.prod (or .env if .env.prod doesn't exist)"
            echo "  all  - Use .env.dev for Stage 1, .env.prod for Stage 2"
            echo ""
            echo "For CI/CD: Set N8N_DEV_API_URL and N8N_DEV_API_KEY in secrets"
            echo "  Then: ./scripts/simple-deploy.sh dev"
            exit 1
            ;;
    esac

    log_section "Deployment Complete!"
}

main
