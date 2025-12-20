#!/bin/bash
# validate_workflows.sh - Validate all n8n workflow JSON files
#
# Usage: ./validate_workflows.sh [workflow_file.json]
#
# If no argument provided, validates all workflows in n8n-workflows/
# Returns exit code 0 if all valid, 1 if any invalid

set -e

WORKFLOW_DIR="n8n-workflows"
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

validate_json() {
    local file="$1"
    if python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $file"
        return 0
    else
        echo -e "${RED}✗${NC} $file"
        # Show the actual error
        python3 -c "import json; json.load(open('$file'))" 2>&1 | head -5
        return 1
    fi
}

has_errors=0

if [ -n "$1" ]; then
    # Validate specific file
    if [ -f "$1" ]; then
        validate_json "$1" || has_errors=1
    else
        echo -e "${RED}File not found: $1${NC}"
        exit 1
    fi
else
    # Validate all workflows
    echo "Validating n8n workflows..."
    echo ""
    
    for f in "$WORKFLOW_DIR"/*.json; do
        if [ -f "$f" ]; then
            validate_json "$f" || has_errors=1
        fi
    done
    
    echo ""
    if [ $has_errors -eq 0 ]; then
        echo -e "${GREEN}All workflows valid!${NC}"
    else
        echo -e "${RED}Some workflows have errors!${NC}"
        exit 1
    fi
fi

exit $has_errors
