#!/bin/bash
# validate_workflows.sh - Validate all n8n workflow JSON files
#
# Usage: ./scripts/workflows/validate_workflows.sh [workflow_file.json]
#
# If no argument provided, validates all workflows in n8n-workflows/
# Returns exit code 0 if all valid, 1 if any invalid

set -euo pipefail

# Find repo root (works when called from any directory)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"
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

if [ -n "${1:-}" ]; then
    # Validate specific file
    if [ -f "$1" ]; then
        validate_json "$1" || has_errors=1
        # Run structural validation
        echo ""
        echo "Running structural validation..."
        if ! python3 "$REPO_ROOT/scripts/workflows/inspect_workflow.py" "$1" --validate >/dev/null 2>&1; then
            echo -e "${RED}✗$1${NC} - Structural validation failed"
            has_errors=1
        else
            echo -e "${GREEN}✓${NC} $1 - Structural validation passed"
        fi
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
            # Run structural validation
            echo ""
            echo "Running structural validation for $f..."
            if ! python3 "$REPO_ROOT/scripts/workflows/inspect_workflow.py" "$f" --validate >/dev/null 2>&1; then
                echo -e "${RED}✗$f${NC} - Structural validation failed"
                has_errors=1
            else
                echo -e "${GREEN}✓${NC} $f - Structural validation passed"
            fi
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
