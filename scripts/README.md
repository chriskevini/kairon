# Kairon Deployment Scripts

## Quick Start: Use the Simplified Pipeline

**For new deployments and development, use:**

- `simple-deploy.sh` - Deploy workflows (264 lines, replaces 1031-line deploy.sh)
- `simple-test.sh` - Test workflows (193 lines, replaces 340-line regression_test.sh)

See [../docs/SIMPLIFIED_PIPELINE.md](../docs/SIMPLIFIED_PIPELINE.md) for complete documentation.

### Usage

```bash
# Deploy to dev and test
./scripts/simple-deploy.sh dev

# Run tests
./scripts/simple-test.sh

# Deploy to production
./scripts/simple-deploy.sh prod

# Full pipeline (dev → test → prod)
./scripts/simple-deploy.sh all
```

## Legacy Scripts (Deprecated)

The following scripts represent the old complex deployment system and are **deprecated**:

### Deployment
- `deploy.sh` - Complex 1031-line deployment orchestrator (DEPRECATED)
- `workflows/n8n-push-prod.sh` - 4-pass deployment with ID remapping (DEPRECATED)
- `workflows/n8n-push-local.sh` - Local dev deployment (DEPRECATED)
- `transform_for_dev.py` - Workflow transformation for dev (DEPRECATED)

### Testing
- `testing/regression_test.sh` - Complex 340-line test framework (DEPRECATED)
- `testing/mock_discord_nodes.py` - Node mocking system (DEPRECATED)
- `workflows/unit_test_framework.py` - Structural validation (DEPRECATED)

### Why Deprecated?

The legacy system had **2,371 lines of deployment code** with:
- Complex workflow transformations
- Dual codebase management
- Multi-stage deployment
- Complex test orchestration
- Many failure modes

The new simplified system has **457 lines** (83% reduction) with:
- Single codebase
- Direct deployment
- Simple testing
- Fewer failure modes

## Migration Path

If you're using the old system:

1. **Stop using:** `./scripts/deploy.sh`
2. **Start using:** `./scripts/simple-deploy.sh`

Workflows already use environment variables, so no code changes needed!

## Script Directory Structure

```
scripts/
├── README.md                           # This file
├── simple-deploy.sh                    # ⭐ NEW: Simple deployment
├── simple-test.sh                      # ⭐ NEW: Simple testing
├── deploy.sh                           # DEPRECATED: Complex deployment
├── transform_for_dev.py                # DEPRECATED: Workflow transformation
├── workflows/
│   ├── n8n-push-prod.sh               # DEPRECATED: 4-pass deployment
│   ├── n8n-push-local.sh              # DEPRECATED: Local deployment
│   ├── validate_workflows.sh           # Still used: JSON validation
│   └── inspect_execution.py            # Still used: Execution inspection
├── testing/
│   ├── regression_test.sh             # DEPRECATED: Complex test framework
│   ├── mock_discord_nodes.py          # DEPRECATED: Node mocking
│   └── test_mode_list_references.py   # Still used: Mode list validation
└── validation/
    └── workflow_integrity.py           # Still used: Dead code detection
```

## What's Still Used?

Some utility scripts remain useful:

- `workflows/inspect_execution.py` - Inspect n8n execution logs
- `workflows/validate_workflows.sh` - JSON syntax validation
- `testing/test_mode_list_references.py` - Verify portable workflow references
- `validation/workflow_integrity.py` - Dead code detection

These are called by the simplified pipeline or used for debugging.

## Questions?

See [../docs/SIMPLIFIED_PIPELINE.md](../docs/SIMPLIFIED_PIPELINE.md) for:
- Complete usage guide
- Migration instructions
- Troubleshooting
- Comparison with legacy system
