#!/bin/bash
# Git wrapper that prevents bypassing hooks
# This enforces that safety checks always run

# Check if user is trying to bypass hooks
if [[ "$*" == *"--no-verify"* ]] || [[ "$*" == *"-n"* ]]; then
    echo "❌ ERROR: Bypassing git hooks is not allowed"
    echo ""
    echo "Git hooks provide critical safety checks:"
    echo "  - Pre-commit: Validates workflow syntax and runs tests"
    echo "  - Pre-push: Runs full deployment pipeline"
    echo ""
    echo "If hooks are failing:"
    echo "  1. Fix the underlying issue causing the failure"
    echo "  2. Commit the fix"
    echo "  3. Try again"
    echo ""
    echo "If you believe this is a false positive, please:"
    echo "  1. Document the issue"
    echo "  2. Get team review/approval"
    echo "  3. Temporarily disable this wrapper (not recommended)"
    echo ""
    exit 1
fi

# Otherwise, run git normally
exec /usr/bin/git "$@"
