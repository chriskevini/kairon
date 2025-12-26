# n8n Workflow Validation System

This document describes the comprehensive workflow validation system that prevents common issues and structural problems in n8n workflows.

## Problem Solved

Workflows could pass basic validation but contain structural issues that cause runtime problems, including:
- Missing required properties
- Incorrect node configurations
- ctx pattern violations
- ExecuteWorkflow misconfigurations

## Solution: Multi-Layer Validation

### Level 1: Fast Pre-commit Checks
- **Location**: `.githooks/pre-commit`
- **What it checks**: JSON syntax, basic properties
- **Speed**: < 5 seconds
- **Blocks**: Syntax errors, missing properties

### Level 2: Comprehensive Structural Validation
- **Location**: `scripts/workflows/lint_workflows.py` + `scripts/validation/n8n_workflow_validator.py`
- **What it checks**: Node properties, ctx patterns, ExecuteWorkflow configuration
- **Speed**: < 30 seconds
- **Blocks**: Structural and configuration issues

## Validation Features

### ✅ Property & Structure Validation
- Required node properties (parameters, type, typeVersion, position)
- Connection validity and structure
- Node type format validation
- Position coordinate validation

### ✅ ctx Pattern Enforcement
- Proper ctx initialization and usage
- Namespace consistency across workflows
- Event field requirements
- Node reference elimination

### ✅ ExecuteWorkflow Configuration
- Correct mode settings (mode='list' for workflow execution)
- Required cachedResult fields for Execute_Queries integration
- Workflow ID validation

### ⚠️ Known Limitations
- **Does NOT catch n8n UI compatibility issues** that cause "Could not find property option" errors
- **Does NOT validate against n8n's internal processing engine**
- **Cannot prevent human implementation errors** in ExecuteWorkflow integration
- Requires additional testing (smoke tests, staging deployment) for full UI compatibility assurance

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

### ✅ Code Quality & Patterns
- ctx pattern compliance (prevents data loss)
- Node reference elimination (reduces coupling)
- Switch node fallback requirements
- Merge node configuration validation

### ✅ Workflow Integration
- ExecuteWorkflow node configuration
- Postgres query ctx usage
- Discord node parameter validation
- Set node ctx preservation

## Error Prevention

### Before Enhancement
```
Workflow Development → Basic JSON Validation → ❌ Production Issues (missing properties, ctx violations, ExecuteWorkflow errors)
```

### After Enhancement
```
Workflow Development → Structural Validation → Pattern Enforcement → ✅ Structural Issues Prevented
                                                            ↓
                                                 ⚠️ UI Compatibility Requires Additional Testing
```

## Dependencies

### Required
- Python 3.7+

### Optional
- Access to n8n API instance (for future API-based validation)
- Valid N8N_API_KEY environment variable

## Configuration

### Environment Variables
```bash
# n8n API connection
N8N_API_URL=http://localhost:5678
N8N_API_KEY=your-api-key-here
```

### Validation Modes
- **Offline**: Property and pattern validation (no external dependencies)
- **Future**: API-based validation (planned enhancement)

## Implementation Details

### Validation Flow
1. **JSON Loading**: Parse and validate basic structure
2. **Property Validation**: Check required fields and connections
3. **Pattern Validation**: Enforce ctx patterns and best practices
4. **Configuration Validation**: Check ExecuteWorkflow and node-specific settings
5. **Error Reporting**: Detailed feedback on issues found

### Error Classification
- **Critical**: Blocks commits (JSON syntax, missing required properties)
- **Error**: Prevents deployment (pattern violations, configuration errors)
- **Warning**: Allows but recommends fixes (best practice violations)

### Original Incident Context
This validation system was developed in response to a production incident where Show_Projection_Details workflow failed with "Could not find property option" error. The root cause was human error in ExecuteWorkflow configuration during refactoring. While this system prevents many issues, it does not catch all n8n UI compatibility problems.

## Future Enhancements

- **n8n UI Compatibility Testing**: Browser automation to test workflow editor loading
- **API Endpoint Integration**: Use n8n's internal validation APIs when available
- **Docker Test Instances**: Automated n8n environment testing for CI/CD
- **Parallel Validation**: Optimize validation speed for large workflow sets
- **UI Error Prevention**: Catch "Could not find property option" errors before production
- **Enhanced Error Reporting**: Auto-fix suggestions and detailed remediation steps