# n8n API Compatibility Validation

This document describes the enhanced API compatibility validation system that prevents workflows from reaching production that have n8n processing issues.

## Problem Solved

Workflows could pass basic validation (JSON syntax, structure) but fail during n8n's internal processing, causing production issues like corrupted workflow data or "Could not find property option" errors.

## Solution: Enhanced API Validation

### Multi-Layer Validation System

#### Level 1: Fast Pre-commit Checks (Enhanced)
- **Location**: `.githooks/pre-commit`
- **What it checks**: JSON syntax, basic properties, n8n API connectivity
- **Speed**: < 5 seconds
- **Blocks**: Syntax errors, missing properties, API unavailability

#### Level 2: Comprehensive API Validation
- **Location**: `scripts/validation/n8n_workflow_validator.py`
- **What it checks**: n8n API validation endpoints, workflow processing compatibility
- **Speed**: < 30 seconds
- **Blocks**: n8n processing issues, API compatibility problems

## Validation Features

### ✅ Enhanced Property Validation
- Required node properties (parameters, type, typeVersion, position)
- Connection validity and structure
- Node type format validation
- Position coordinate validation

### ✅ API Compatibility Testing
- n8n API connectivity verification
- Official validation endpoint testing (if available)
- Workflow structure preservation checks
- Error handling and reporting

### ✅ Production Deployment Simulation
- Mimics the same API patterns used by `n8n-push-prod.sh`
- Tests workflow upload and processing
- Validates against production deployment requirements

## Usage

### Pre-commit (Automatic)
```bash
# Happens automatically when committing workflow files
git add n8n-workflows/*.json
git commit -m "feat: add new workflow"
# → Validates API compatibility automatically
```

### Manual API Testing
```bash
# Test specific workflow
python3 scripts/validation/n8n_workflow_validator.py n8n-workflows/MyWorkflow.json --verbose

# Test with custom n8n instance
python3 scripts/validation/n8n_workflow_validator.py workflow.json --api-url http://localhost:5679 --api-key my-key
```

### CI/CD Integration
```bash
# In deployment pipeline
for workflow in n8n-workflows/*.json; do
    python3 scripts/validation/n8n_workflow_validator.py "$workflow" || exit 1
done
```

## What Gets Tested

### ✅ Structural Validation
- JSON syntax and parsing
- Required node properties validation
- Connection integrity
- Workflow metadata completeness

### ✅ API Compatibility
- n8n API endpoint availability
- Workflow validation via n8n's internal validators
- Error response handling
- API authentication and connectivity

### ✅ Production Readiness
- Same validation patterns as deployment scripts
- Workflow processing compatibility
- Error condition handling

## Error Prevention

### Before Enhancement
```
Workflow Development → JSON Validation → ❌ Production API Processing Error
```

### After Enhancement
```
Workflow Development → JSON Validation → API Compatibility → ✅ Production Ready
```

## Dependencies

### Required
- Python 3.7+
- `requests` library

### Optional (for API testing)
- Access to n8n API instance
- Valid N8N_API_KEY environment variable

## Configuration

### Environment Variables
```bash
# n8n API connection
N8N_API_URL=http://localhost:5678
N8N_API_KEY=your-api-key-here
```

### Validation Modes
- **Offline**: Property validation only (no API required)
- **Online**: Full API compatibility testing
- **Auto**: Detects API availability and runs appropriate tests

## Implementation Details

### Validation Flow
1. **JSON Loading**: Parse and validate basic structure
2. **Property Validation**: Check required fields and connections
3. **API Connectivity**: Test n8n API availability
4. **Official Validation**: Use n8n's built-in validation (if available)
5. **Error Reporting**: Detailed feedback on issues found

### Error Classification
- **Critical**: Blocks commits (JSON syntax, missing required properties)
- **Error**: Prevents deployment (API compatibility issues)
- **Warning**: Allows but recommends fixes (API unavailability, minor issues)

## Future Enhancements

- Integration with n8n's workflow validation endpoints
- Docker-based n8n test instances for CI/CD
- Parallel validation of multiple workflows
- Performance and execution time validation
- Enhanced error reporting with suggested fixes