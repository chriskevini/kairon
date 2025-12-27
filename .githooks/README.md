# Git Hook Safeguards

## Overview

This project uses git hooks to ensure code quality and prevent untested code from reaching production. Bypassing these hooks is dangerous and can lead to production issues.

## Safeguard: Git Wrapper

To prevent accidental bypass of hooks, you can use the git wrapper:

### Setup (Optional but Recommended)

```bash
# Create alias in your shell profile (~/.bashrc, ~/.zshrc, etc.)
alias git='/home/chris/Work/kairon/.githooks/git-wrapper.sh'

# Or set up globally for this project
cd /home/chris/Work/kairon
git config alias.safe '!bash .githooks/git-wrapper.sh'
```

### What It Does

The git wrapper prevents:
- `git commit --no-verify` (bypassing pre-commit hooks)
- `git push --no-verify` (bypassing pre-push hooks)
- `git push -n` (short form of --no-verify)

### Why This Matters

**Real Example:** In PR #107, the pre-push hook was bypassed using `--no-verify`, which allowed:
- Untested code to merge to main
- Production deployment to be skipped
- Multiple rounds of fixes to be needed
- Risk of production issues

## Hook Responsibilities

### Pre-commit Hook
- Validates workflow JSON syntax
- Runs structural tests
- Checks ctx pattern compliance
- Prevents committing sensitive data

### Pre-push Hook
- Runs full deployment pipeline
- Deploys to DEV environment
- Runs smoke tests
- Validates migration files
- Blocks push if any stage fails

## If Hooks Fail

### ❌ **DON'T:**
- Use `--no-verify` to bypass
- Assume the hook is wrong
- Push anyway and "fix it later"

### ✅ **DO:**
- Read the error message carefully
- Fix the underlying issue
- Commit the fix
- Let the hook run again
- Ask for help if stuck

## Emergency Bypass (Last Resort)

If you absolutely must bypass hooks (e.g., infrastructure is broken):

1. **Document the reason** in a comment or commit message
2. **Get team review/approval** (if working with a team)
3. **Create an issue** to track fixing the bypassed checks
4. **Test manually** before deploying to production
5. **Fix the hook** as soon as possible

### How to Bypass (Use Sparingly)

```bash
# Temporarily use real git (not wrapper)
/usr/bin/git push --no-verify

# Or disable wrapper temporarily
unalias git  # If using alias method
```

## Hook Debugging

### Pre-commit Hook Issues

```bash
# Run hook manually
.githooks/pre-commit

# Check workflow validation
./scripts/workflows/validate_workflows.sh
```

### Pre-push Hook Issues

```bash
# Run hook manually (dry-run)
.githooks/pre-push

# Run specific stages
./scripts/deploy.sh local   # Stage 0-2 only
./scripts/deploy.sh dev     # Stage 0-2 only  
./scripts/deploy.sh prod    # Stage 3 only (dangerous!)
```

## Maintenance

If hooks become obsolete or need updates:
1. Update the hook files in `.githooks/`
2. Document changes in this file
3. Test thoroughly before committing
4. Consider backward compatibility

## History

- **2025-12-27**: Added git-wrapper.sh to prevent hook bypass after PR #107 incident
- **2025-12-24**: Added pre-push hook with full deployment pipeline (PR #106)
