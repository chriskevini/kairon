#!/bin/bash
# db-query.sh - Run SQL queries against remote database
#
# Usage:
#   ./scripts/db/db-query.sh "SELECT COUNT(*) FROM notes"
#   ./scripts/db/db-query.sh -f query.sql
#   ./scripts/db/db-query.sh -i                    # Interactive psql session
#
# Prerequisites:
#   - SSH access configured
#   - .env file in repo root

set -euo pipefail

# --- COMMON SETUP ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
kairon_init "$SCRIPT_DIR"
kairon_setup_ssh
kairon_require_vars REMOTE_HOST CONTAINER_DB DB_USER DB_NAME

# --- 4. PARSE ARGUMENTS ---
show_help() {
    echo "Usage: $0 [OPTIONS] [QUERY]"
    echo ""
    echo "Options:"
    echo "  -i          Interactive psql session"
    echo "  -f FILE     Run SQL from file"
    echo "  -h          Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 \"SELECT COUNT(*) FROM notes\""
    echo "  $0 -f db/check_migration_status.sql"
    echo "  $0 -i"
}

INTERACTIVE=false
SQL_FILE=""
QUERY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -i)
            INTERACTIVE=true
            shift
            ;;
        -f)
            SQL_FILE="${2:-}"
            if [ -z "$SQL_FILE" ]; then
                echo "❌ Error: -f requires a filename"
                exit 1
            fi
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            QUERY="$1"
            shift
            ;;
    esac
done

# --- 5. EXECUTION ---
if [ "$INTERACTIVE" = true ]; then
    echo "🔗 Connecting to $DB_NAME on $REMOTE_HOST..."
    ssh -t "$REMOTE_HOST" "docker exec -it $CONTAINER_DB psql -U $DB_USER -d $DB_NAME"
elif [ -n "$SQL_FILE" ]; then
    if [ ! -f "$SQL_FILE" ]; then
        # Try relative to repo root
        if [ -f "$REPO_ROOT/$SQL_FILE" ]; then
            SQL_FILE="$REPO_ROOT/$SQL_FILE"
        else
            echo "❌ SQL file not found: $SQL_FILE"
            exit 1
        fi
    fi
    cat "$SQL_FILE" | ssh "$REMOTE_HOST" "docker exec -i $CONTAINER_DB psql -U $DB_USER -d $DB_NAME"
elif [ -n "$QUERY" ]; then
    ssh "$REMOTE_HOST" "docker exec -i $CONTAINER_DB psql -U $DB_USER -d $DB_NAME -c \"$QUERY\""
else
    show_help
    exit 1
fi
