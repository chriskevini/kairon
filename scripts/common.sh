#!/bin/bash
# common.sh - Shared functions and setup for Kairon scripts
#
# Usage: source this file from other scripts
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../common.sh"  # or appropriate relative path
#
# Provides:
#   - kairon_init: Initialize REPO_ROOT and load .env
#   - kairon_require_vars: Validate required environment variables
#   - kairon_setup_ssh: Source SSH connection reuse setup
#   - REPO_ROOT: Path to repository root (set by kairon_init)

# Resolve repository root from any script location
# Usage: Call kairon_init after setting SCRIPT_DIR in your script
kairon_init() {
    local script_dir="${1:-$SCRIPT_DIR}"
    
    # Find repo root by looking for .env or .git
    local dir="$script_dir"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/.env" ] || [ -d "$dir/.git" ]; then
            REPO_ROOT="$dir"
            break
        fi
        dir="$(dirname "$dir")"
    done
    
    if [ -z "${REPO_ROOT:-}" ]; then
        echo "Error: Could not find repository root (no .env or .git found)"
        exit 1
    fi
    
    export REPO_ROOT
    
    # Load .env file safely (handles values with spaces and special characters)
    local env_file="$REPO_ROOT/.env"
    if [ -f "$env_file" ]; then
        # Read line by line to properly handle values with spaces
        while IFS='=' read -r key value; do
            # Skip empty lines and comments
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            # Remove leading/trailing whitespace from key
            key=$(echo "$key" | xargs)
            # Remove surrounding quotes from value if present
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            # Export the variable
            export "$key=$value"
        done < "$env_file"
    else
        echo "Error: .env file not found at $env_file"
        exit 1
    fi
}

# Validate that required environment variables are set
# Usage: kairon_require_vars REMOTE_HOST DB_USER DB_NAME
kairon_require_vars() {
    local missing=()
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: Missing required environment variables:"
        for var in "${missing[@]}"; do
            echo "  - $var"
        done
        echo ""
        echo "Please set these in your .env file"
        exit 1
    fi
}

# Setup SSH connection reuse (if ssh-setup.sh exists)
# Usage: kairon_setup_ssh
kairon_setup_ssh() {
    local ssh_setup="${REPO_ROOT:-}/scripts/ssh-setup.sh"
    if [ -f "$ssh_setup" ]; then
        # shellcheck disable=SC1090
        source "$ssh_setup" 2>/dev/null || true
    fi
}
