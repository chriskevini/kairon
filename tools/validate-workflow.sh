#!/bin/bash
# Workflow validator for Kairon project

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow_file="$1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}WARNING: $1${NC}" >&2
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

if [ -z "$workflow_file" ]; then
    echo "Usage: $0 <workflow_file.json>"
    exit 1
fi

if [ ! -f "$workflow_file" ]; then
    error "File not found: $workflow_file"
fi

echo "Validating $(basename "$workflow_file")..."

# 1. JSON syntax
jq empty "$workflow_file" 2>/dev/null || error "Invalid JSON syntax"

# 2. Deprecated queryReplacement in Postgres nodes
if jq -e '.nodes[] | select(.type=="n8n-nodes-base.postgres") | .parameters.options.queryReplacement' "$workflow_file" >/dev/null 2>&1; then
    error "Found deprecated 'queryReplacement' in Postgres node. Use 'values' instead."
fi

# 3. Code node runOnceForEachItem issues
# Check for code nodes with mode:"runOnceForEachItem" AND using $input.first()/$input.last()/$input.all()
# These are incompatible with n8n v2 strict mode
bad_code_nodes=$(jq -r '.nodes[] | select(.type=="n8n-nodes-base.code" and .parameters.jsCode != null) | select(.parameters.jsCode | contains("$input.first") or contains("$input.last") or contains("$input.all")) | .name' "$workflow_file")

if [ ! -z "$bad_code_nodes" ]; then
    # Only error if mode is runOnceForEachItem
    for node_name in $bad_code_nodes; do
        mode=$(jq -r ".nodes[] | select(.name==\"$node_name\") | .parameters.mode" "$workflow_file")
        if [ "$mode" == "runOnceForEachItem" ] || [ "$mode" == "null" ] || [ -z "$mode" ]; then
             # Default mode is often runOnceForEachItem if not specified in some versions, 
             # but in v2 we should check carefully. 
             warn "Code node '$node_name' uses \$input.first/last/all which might fail in n8n v2 if mode is runOnceForEachItem."
        fi
    done
fi

# 4. Check for invalid error workflow ID
if jq -e '.settings.errorWorkflow == "JOXLqn9TTznBdo7Q"' "$workflow_file" >/dev/null 2>&1; then
    error "Workflow references non-existent error workflow ID 'JOXLqn9TTznBdo7Q'"
fi

success "Workflow validation passed"
exit 0
