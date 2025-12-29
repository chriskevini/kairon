# n8n Workflow Deployment Architecture

> ⚠️ **DEPRECATED:** This document describes the complex legacy deployment system (2,536 lines).
> 
> **→ See [SIMPLIFIED_PIPELINE.md](SIMPLIFIED_PIPELINE.md) for the new recommended approach (587 lines, 76.9% reduction).**
>
> The legacy system is kept for reference but should not be used for new deployments.

## Overview

This document explains the legacy deployment tooling for n8n workflows and clarifies the role of each script.

## The Problem We Solved

n8n workflows can reference other workflows by ID, but these IDs differ between environments (dev/prod). Additionally, credential IDs must be mapped correctly. A naive deployment would break these references.

## Architecture

### 1. `scripts/deploy.sh` - Main Entry Point ⭐

**Purpose:** Orchestrate the complete deployment pipeline with automated testing and rollback

**Usage:**
```bash
./scripts/deploy.sh           # Full pipeline: unit tests → dev → functional tests → prod
./scripts/deploy.sh dev       # Deploy to dev only + run functional tests
./scripts/deploy.sh prod      # Deploy to prod only (not recommended - skip tests)
```

**What it does:**
- **Stage 0: Unit Tests** - Structural validation and Python unit tests
- **Stage 1: Dev deployment** - Transform workflows with `transform_for_dev.py` and push to dev n8n
- **Stage 2: Regression Tests** - Test modified workflows with prod DB snapshot
  - Identifies modified workflows (git diff)
  - Optionally snapshots prod DB to dev
  - Runs test payloads against dev environment
  - Validates both execution status AND database state
  - Only tests what changed (fast)
- **Stage 3: Prod deployment** - Sync files to server, run `n8n-push-prod.sh` remotely with automated rollback on failure
- **Deep smoke tests** - End-to-end verification after production deployment

**Safety features:**
- **Automated rollback** - Production deployment automatically rolls back on any failure
- **Proactive backups** - Database and workflow backups created before production deployment
- **Enhanced validation** - Workflow name uniqueness, mode:list usage validation

**When to use:** This is your main deployment tool for CI/CD and manual deployments.

---

### 2. `scripts/workflows/n8n-push-prod.sh` - The Ultimate Deployer 🚀

**Purpose:** Sophisticated 4-pass deployment with automatic ID remapping and rollback

**Passes:**
1. **Sanitization:** Removes pinData and credential IDs from workflows
2. **Initial deployment:** Creates/updates workflows via n8n API
3. **Workflow ID fixing:** Resolves workflow references using `cachedResultName`
4. **Credential ID fixing:** Queries database to link credentials by name
5. **Deep smoke testing:** End-to-end verification of production deployment

**IMPORTANT:** Must run ON THE SERVER because it uses `docker exec postgres-db` to query credentials.

**Usage:**
```bash
# On the server:
N8N_API_URL=http://localhost:5678 \
N8N_API_KEY=xxx \
WORKFLOW_DIR=/opt/kairon/n8n-workflows \
  ./scripts/workflows/n8n-push-prod.sh
```

**When to use:** Called automatically by `deploy.sh prod`. Use directly only when debugging prod deployment issues on the server.

---

### 3. `rdev n8n` - Manual Operations Tool (Human Use Only) ⚡

**Purpose:** Manual inspection and quick operations for human developers

**Available commands:**
```bash
rdev n8n pull              # Pull workflows from n8n to local
rdev n8n pull --all        # Pull ALL workflows
rdev n8n list              # List recent executions
rdev n8n exec 12345        # Inspect execution by ID
```

**IMPORTANT:**
- `rdev n8n push` exists but **agents should NEVER use it**
- It does NOT fix workflow IDs or credential IDs
- Only for human developers doing quick manual testing

**When to use (humans only):**
- Pulling workflows from n8n to local
- Inspecting execution logs
- Quick workflow updates when you know they don't reference each other

**When NOT to use:**
- **NEVER for CI/CD or production deployments** (use `deploy.sh` instead)
- **NEVER when workflows reference each other** (IDs won't be fixed)

---

### 4. `scripts/workflows/sanitize_workflows.sh` - Cleanup Helper

**Purpose:** Remove sensitive/environment-specific data from workflow files

**What it does:**
- Removes `pinData` (test execution data with real IDs)
- Removes credential IDs (forces deployment to look them up by name)

**When to use:**
- **No longer needed!** Now automatically called by `n8n-push-prod.sh`
- Only run manually if you need to clean workflows before committing to git

---

## Deployment Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  scripts/deploy.sh  (MAIN ENTRY POINT)                      │
└──────────────┬──────────────────────────────────────────────┘
               │
               ├─── STAGE 0: UNIT TESTS ──────────────────────┐
               │    - Structural validation                    │
               │    - Python unit tests                        │
               │                                              │
               ├─── STAGE 1: DEV DEPLOY ──────────────────────┐
               │    1. Transform workflows (transform_for_dev.py)
               │    2. Push to dev n8n                         │
               │    3. Fix workflow ID refs                    │
               │                                              │
               ├─── STAGE 1b: REDEPLOY (OPTIONAL) ────────────┐
               │    - Redeploy with real APIs for testing      │
               │                                              │
               ├─── STAGE 2: FUNCTIONAL TESTS ────────────────┐
               │    2a. Mock tests (fast)                      │
               │    2b. Real API tests (comprehensive)        │
               │    2d. Python tag parsing tests               │
               │                                              │
               └─── STAGE 3: PROD DEPLOY ─────────────────────┤
                    1. Create backup                           │
                    2. Sync files to server                    │
                    3. SSH to server and run:                  │
                       ↓                                        │
        ┌──────────────────────────────────────┐              │
        │  n8n-push-prod.sh (ON SERVER)        │              │
        │  ↓                                    │              │
        │  1. Sanitize workflows               │              │
        │  2. Initial deployment               │              │
        │  3. Fix workflow ID references       │              │
        │  4. Fix credential ID references     │              │
        │  5. Deep smoke tests                 │              │
        │                                       │              │
        │  ❌ FAILURE DETECTED? ───────────────►│              │
        │     ↓                                 │              │
        │  AUTOMATIC ROLLBACK                   │              │
        └──────────────────────────────────────┘              │
                                                              │
┌──────────────────────────────────────────────────────────────┤
│  rdev n8n (MANUAL INSPECTION ONLY - HUMAN USE)              │
│  - Pull workflows from n8n to local                          │
│  - Inspect execution logs                                    │
│  - NOT for deployments                                       │
└─────────────────────────────────────────────────────────────┘
```

## Decision Matrix

| Scenario | Use This Tool |
|----------|---------------|
| CI/CD deployment | `scripts/deploy.sh` |
| Manual prod deployment | `scripts/deploy.sh prod` |
| Manual dev deployment + testing | `scripts/deploy.sh dev` |
| Pulling workflows from n8n | `rdev n8n pull` or `rdev n8n pull --all` |
| Inspecting execution logs | `rdev n8n list` and `rdev n8n exec <id>` |
| Debugging prod deployment on server | `n8n-push-prod.sh` (directly on server) |

## Common Issues

### Issue: "Workflow references are broken after deployment"

**Cause:** Used `rdev n8n push` instead of `deploy.sh` for production

**Solution:** Always use `scripts/deploy.sh prod` for production deployments. It properly fixes workflow ID references.

---

### Issue: "Credentials not working after deployment"

**Cause:** Credential IDs weren't mapped correctly

**Solution:** `n8n-push-prod.sh` handles this automatically in Pass 3. Make sure you're using it via `deploy.sh prod`.

---

### Issue: "Can I use `rdev n8n push` for deployments?"

**Answer:** No. `rdev n8n push` is for human developers doing quick manual operations only.

**Reason:** It doesn't fix workflow ID references or credential IDs. Workflows that reference each other will break.

**Solution:** Always use `scripts/deploy.sh` for any actual deployments. It handles all the ID mapping automatically.

---

### Issue: "Deployment failed and system rolled back automatically"

**Cause:** Production deployment or smoke tests failed

**Solution:** Check the deployment logs for the specific error. The system automatically creates backups and rolls back to the previous working state. Fix the issue and redeploy.

---

### Issue: "Python unit tests are failing"

**Cause:** Tests were migrated from n8n workflow format to Python pytest

**Solution:** Update your test expectations. The new Python tests provide better error messages and are more maintainable than workflow-based tests.

## Environment Variables

**Required in `.env`:**

```bash
# For dev deployment
N8N_DEV_API_KEY=xxx
N8N_DEV_API_URL=http://localhost:5679  # optional, defaults to this
N8N_DEV_SSH_HOST=DigitalOcean          # SSH alias from ~/.ssh/config

# For prod deployment
N8N_API_KEY=xxx
N8N_API_URL=http://localhost:5678      # optional, defaults to this

# For rdev
REMOTE_HOST=DigitalOcean
WORKFLOW_DIR=n8n-workflows             # optional, defaults to this
```

## Summary

**For agents:**

1. **Always use `scripts/deploy.sh`** as your deployment tool
2. **Never use `rdev n8n push`** - it's for human manual operations only
3. **`n8n-push-prod.sh` is the sophisticated 4-pass deployer** - runs automatically via deploy.sh
4. **Sanitization is automatic** - no need to run manually
5. **Automated rollback protects production** - deployments are fail-safe

**For human developers:**

1. **Use `scripts/deploy.sh`** for all real deployments
2. **Use `rdev n8n pull`** to sync workflows from n8n to local
3. **Use `rdev n8n list/exec`** to inspect execution logs
4. **Avoid `rdev n8n push`** unless you're sure workflows don't reference each other
5. **Trust the automated rollback** - production issues are automatically resolved

The deployment architecture is now production-hardened with comprehensive testing and automatic recovery!</content>
<parameter name="filePath">docs/DEPLOYMENT.md