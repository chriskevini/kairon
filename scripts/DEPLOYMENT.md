# n8n Workflow Deployment Architecture

## Overview

This document explains the deployment tooling for n8n workflows and clarifies the role of each script.

## The Problem We Solved

n8n workflows can reference other workflows by ID, but these IDs differ between environments (dev/prod). Additionally, credential IDs must be mapped correctly. A naive deployment would break these references.

## Architecture

### 1. `scripts/deploy.sh` - Main Entry Point ⭐

**Purpose:** Orchestrate the complete deployment pipeline

**Usage:**
```bash
./scripts/deploy.sh           # Full pipeline: dev → test → prod
./scripts/deploy.sh dev       # Deploy to dev only + run smoke tests  
./scripts/deploy.sh prod      # Deploy to prod only (no tests)
```

**What it does:**
- **Dev deployment:** 2-pass with `transform_for_dev.py` to transform prod workflows for dev
- **Smoke tests:** Runs automated tests in dev environment
- **Prod deployment:** Syncs files to server and runs `n8n-push-prod.sh` remotely

**When to use:** This is your main deployment tool for CI/CD and manual deployments.

---

### 2. `scripts/workflows/n8n-push-prod.sh` - The Ultimate Deployer 🚀

**Purpose:** Sophisticated 3-pass deployment with automatic ID remapping

**Passes:**
1. **Sanitization:** Removes pinData and credential IDs from workflows
2. **Initial deployment:** Creates/updates workflows via n8n API
3. **Workflow ID fixing:** Resolves workflow references using `cachedResultName`
4. **Credential ID fixing:** Queries database to link credentials by name

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
               ├─── DEV ───────────────────────────────────────┐
               │    1. Transform workflows (transform_for_dev.py)
               │    2. Push to dev n8n (2-pass)                │
               │    3. Fix workflow ID refs                    │
               │    4. Run smoke tests                         │
               │                                               │
               └─── PROD ─────────────────────────────────────┤
                    1. Sync files to server                   │
                    2. SSH to server and run:                 │
                       ↓                                       │
        ┌──────────────────────────────────────┐             │
        │  n8n-push-prod.sh (ON SERVER)        │             │
        │  ↓                                    │             │
        │  1. Sanitize workflows               │             │
        │  2. Initial deployment               │             │
        │  3. Fix workflow ID references       │             │
        │  4. Fix credential ID references     │             │
        │     (via docker exec postgres-db)    │             │
        └──────────────────────────────────────┘             │
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
| Manual dev deployment | `scripts/deploy.sh dev` |
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
3. **`n8n-push-prod.sh` is the sophisticated 3-pass deployer** - runs automatically via deploy.sh
4. **Sanitization is automatic** - no need to run manually

**For human developers:**

1. **Use `scripts/deploy.sh`** for all real deployments
2. **Use `rdev n8n pull`** to sync workflows from n8n to local
3. **Use `rdev n8n list/exec`** to inspect execution logs
4. **Avoid `rdev n8n push`** unless you're sure workflows don't reference each other

The deployment architecture is now clear and unified!
