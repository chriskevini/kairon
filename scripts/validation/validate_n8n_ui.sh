#!/bin/bash
# n8n UI Compatibility Validator
# Validates workflows can be loaded in n8n UI before production deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR"/.. && pwd)"

# Find workflow files that changed
if [ -n "$1" ]; then
    # Specific file
    WORKFLOW_FILES="$1"
else
    # All workflow files (for testing)
    WORKFLOW_FILES="$(find "$REPO_ROOT"/n8n-workflows -name "*.json" | head -5)"
fi

echo "🔍 Validating n8n UI compatibility for workflows..."
echo ""

FAILED=0
for workflow in $WORKFLOW_FILES; do
    echo "Validating: $(basename "$workflow")"

    # Run property validation
    if python3 "$SCRIPT_DIR"/validation/n8n_workflow_validator.py "$workflow" >/dev/null 2>&1; then
        echo "  ✅ Property validation passed"
    else
        echo "  ❌ Property validation failed"
        FAILED=1
    fi

    # Try API validation if credentials available
    if [ -n "$N8N_API_KEY" ] && [ -n "$N8N_API_URL" ]; then
        if python3 "$SCRIPT_DIR"/validation/n8n_workflow_validator.py "$workflow" --api-url "$N8N_API_URL" --api-key "$N8N_API_KEY" >/dev/null 2>&1; then
            echo "  ✅ API validation passed"
        else
            echo "  ❌ API validation failed"
            FAILED=1
        fi
    else
        echo "  ⚠️  API validation skipped (no credentials)"
    fi

    echo ""
done

if [ $FAILED -eq 1 ]; then
    echo "❌ Some workflows failed UI compatibility validation"
    echo "These workflows may not load properly in n8n UI"
    exit 1
else
    echo "✅ All workflows passed UI compatibility validation"
fi
