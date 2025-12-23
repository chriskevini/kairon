# ctx Pattern Audit Report

**Date**: 2025-12-21  
**Auditor**: GitHub Copilot  
**Scope**: All n8n workflows in the repository

## Executive Summary

The ctx pattern is **generally well-adopted** across the codebase with 13 workflows using it consistently. However, there are opportunities to improve **shape consistency**, fix **critical errors**, and enhance **maintainability** through better documentation and tooling.

**Key Findings:**
- ✅ **Pattern Adoption**: 100% of workflows use the ctx pattern
- ⚠️ **Shape Consistency**: Moderate - 8 distinct namespaces with overlapping purposes
- ❌ **Critical Errors**: 4 errors preventing proper ctx flow
- ⚠️ **Warnings**: 16 warnings indicating potential issues

## Current State Analysis

### 1. ctx Namespace Inventory

The audit identified 8 distinct ctx namespaces across workflows:

| Namespace | Usage | Purpose | Consistency |
|-----------|-------|---------|-------------|
| `ctx.event` | Universal | Event metadata (event_id, channel_id, clean_text, tag) | ⚠️ Moderate |
| `ctx.llm` | High | LLM outputs (completion_text, confidence, duration_ms) | ✅ Good |
| `ctx.db` | Low | Database query results | ⚠️ Limited |
| `ctx.thread` | Specific | Thread-specific data (history, extractions) | ✅ Good |
| `ctx.command` | Specific | Command parsing (name, args) | ✅ Good |
| `ctx.validation` | Low | Validation results (valid, error_message) | ✅ Good |
| `ctx.projection` | Low | Projection data | ⚠️ Underused |
| `ctx.timing` | Low | Timing information | ⚠️ Underused |

### 2. ctx Shape Patterns

#### Pattern A: Event-Centric (Recommended)
```javascript
{
  ctx: {
    event: {
      event_id: "uuid",
      channel_id: "discord_id",
      clean_text: "message content",
      tag: "!! or .. or ++",
      trace_chain: ["uuid1", "uuid2"]
    },
    llm: {
      completion_text: "...",
      confidence: 0.95,
      duration_ms: 1234
    }
  }
}
```
**Used by**: Route_Event, Generate_Daily_Summary, Generate_Nudge, Multi_Capture

#### Pattern B: Mixed Flat + Nested (Anti-pattern)
```javascript
{
  ctx: {
    event_id: "uuid",           // ❌ Should be ctx.event.event_id
    clean_text: "...",          // ❌ Should be ctx.event.clean_text
    llm: {
      result: "category",
      confidence: 0.95
    }
  }
}
```
**Used by**: Capture_Projection (partially), some command handlers

#### Pattern C: Workflow-Specific Pollution
```javascript
{
  ctx: {
    event: {...},
    // ❌ Workflow-specific fields at root level
    emoji_count: 3,
    message_count: 5,
    summary_content: "...",
    has_extractions: true
  }
}
```
**Used by**: Capture_Thread, Save_Extraction

### 3. Critical Errors (Must Fix)

#### Error 1 & 2: Empty Merge Node Parameters
**Location**: 
- `Handle_Error.json` → "Merge Paths" node
- `Save_Extraction.json` → "After Promote" node

**Issue**: Merge nodes have empty parameters, missing required `mode` and `numberInputs`

**Impact**: Unreliable merging behavior, may drop ctx data

**Fix**:
```json
{
  "parameters": {
    "mode": "append",
    "numberInputs": 2
  }
}
```

#### Error 3 & 4: Node References Without ctx
**Location**: `Route_Event.json`
- "Store Message Event" node
- "Store Reaction Event" node

**Issue**: Uses `$('Parse Message').item.json.clean_text` instead of `$json.ctx.event.clean_text`

**Impact**: Breaks ctx pattern, creates tight coupling, violates documented best practices

**Current (Wrong)**:
```javascript
={{ $('Parse Message').item.json.clean_text }}
```

**Should Be**:
```javascript
={{ $json.ctx.event.clean_text }}
```

**Root Cause**: The Parse Message node doesn't properly initialize ctx. It should return:
```javascript
{
  ctx: {
    event: {
      clean_text: cleanText,
      tag: tag
    }
  }
}
```

### 4. Warning Issues (Should Fix)

#### Missing Merge Node Modes (3 instances)
- `Capture_Thread.json` → "Merge Thread Data"
- `Continue_Thread.json` → "Wait for Context"  
- `Generate_Daily_Summary.json` → "Merge All Query Results"

**Fix**: Add `"mode": "append"` to parameters

#### Missing Switch Fallback Outputs (2 instances)
- `Execute_Command.json` → "Switch Generate Type"
- `Route_Event.json` → "Route by Event Type"

**Impact**: Unmatched cases produce no output, causing silent failures

**Fix**: Add `"fallbackOutput": 3` or similar to options

#### Inconsistent ctx Initialization (3 instances)
- `Generate_Daily_Summary.json` → "Prepare Event Data" doesn't initialize ctx
- `Generate_Nudge.json` → "Prepare Event" doesn't initialize ctx
- Workflows that use Set nodes vs Code nodes inconsistently

#### Flat Data Access (4 instances)
- `Multi_Capture.json` → "Parse & Split" may access flat data
- `Generate_Daily_Summary.json` → "Parse LLM Response" uses prepareData.ctx
- Discord content fields accessing flat $json instead of $json.ctx

## Recommendations

### Priority 1: Fix Critical Errors (Immediate)

1. **Fix Merge nodes** in Handle_Error and Save_Extraction
2. **Fix node references** in Route_Event by ensuring Parse Message initializes ctx
3. **Verify fixes** with linter: `./scripts/workflows/lint_workflows.py`

### Priority 2: Standardize ctx Shape (Short-term)

Establish a canonical ctx shape based on Pattern A:

```javascript
{
  ctx: {
    // Core event data (always present)
    event: {
      event_id: string,
      event_type: "discord_message" | "discord_reaction",
      channel_id: string,
      message_id: string,
      clean_text: string,
      tag: string | null,
      trace_chain: string[],
      author_login: string,
      timestamp: string
    },
    
    // LLM outputs (when applicable)
    llm?: {
      completion_text: string,
      confidence: number,
      duration_ms: number,
      model?: string
    },
    
    // Database results (when applicable)
    db?: {
      trace_id?: string,
      projection_id?: string,
      user_record?: object
    },
    
    // Validation results (when applicable)
    validation?: {
      valid: boolean,
      error_message?: string
    },
    
    // Thread-specific (only in thread workflows)
    thread?: {
      thread_id: string,
      history: array,
      extractions: array
    },
    
    // Command-specific (only in Execute_Command)
    command?: {
      name: string,
      args: string[]
    }
  }
}
```

**Migration strategy:**
1. Update AGENTS.md with canonical shape
2. Create ctx_schema.json for validation
3. Update workflows one namespace at a time
4. Add linter rules to enforce shape

### Priority 3: Enhance Linter (Medium-term)

Add validation rules to `lint_workflows.py`:

1. **Namespace validation**: Ensure only approved namespaces used
2. **Shape validation**: Check ctx.event has required fields
3. **Initialization validation**: Verify first node after trigger initializes ctx.event
4. **Consistency checks**: Flag workflows that deviate from canonical shape
5. **Auto-fix capability**: Generate corrected ctx structures

Example new rules:
```python
def check_ctx_namespace_whitelist(node, result):
    """Ensure only approved ctx namespaces are used"""
    approved = ['event', 'llm', 'db', 'validation', 'thread', 'command']
    # Check code for ctx.* patterns
    # Flag any not in whitelist
    
def check_ctx_event_required_fields(node, result):
    """Verify ctx.event has required fields"""
    required = ['event_id', 'clean_text', 'trace_chain']
    # Check if initializing ctx.event
    # Verify all required fields present
```

### Priority 4: Documentation (Medium-term)

1. **Update AGENTS.md**: 
   - Document canonical ctx shape with full examples
   - Add anti-patterns section with real examples from audit
   - Create troubleshooting guide for common ctx issues

2. **Create ctx migration guide**:
   - Step-by-step process for updating workflows
   - Before/after examples for each namespace
   - Testing checklist

3. **Add inline documentation**:
   - Comment ctx shape at top of each workflow Code node
   - Document namespace purpose in comments

### Priority 5: Prevent Regressions (Long-term)

1. **Pre-commit enforcement**: Make linter blocking for errors (already done for syntax)
2. **CI/CD integration**: Add ctx validation to workflow push scripts
3. **Documentation generation**: Auto-generate ctx shape docs from actual workflows
4. **ctx visualization**: Tool to visualize ctx flow through workflow

## Metrics

### Before Audit
- ✅ Workflows using ctx: 13/13 (100%)
- ❌ Critical errors: 4
- ⚠️ Warnings: 16
- 📊 Shape consistency: ~60%

### After Implementation (Projected)
- ✅ Workflows using ctx: 13/13 (100%)
- ❌ Critical errors: 0
- ⚠️ Warnings: <5
- 📊 Shape consistency: >95%

## Action Items

### For Immediate Implementation
- [ ] Fix Merge Paths node in Handle_Error.json
- [ ] Fix After Promote node in Save_Extraction.json
- [ ] Fix Parse Message node in Route_Event.json to initialize ctx
- [ ] Update Store Message/Reaction Event nodes to use ctx
- [ ] Add merge mode to 3 workflows missing it
- [ ] Add fallback outputs to 2 Switch nodes

### For Follow-up PRs
- [ ] Document canonical ctx shape in AGENTS.md
- [ ] Create ctx_schema.json
- [ ] Add namespace validation to linter
- [ ] Add shape validation to linter
- [ ] Add auto-fix capability to linter
- [ ] Create ctx migration guide
- [ ] Migrate all workflows to canonical shape
- [ ] Add ctx shape comments to workflows

## Conclusion

The ctx pattern is a **strong foundation** for the Kairon project. With targeted fixes and standardization, it can become even more maintainable and robust. The critical errors should be fixed immediately, while the shape standardization can be done incrementally without disrupting functionality.

The current linter (`lint_workflows.py`) is excellent but can be enhanced to enforce the canonical shape and prevent regressions. Combined with better documentation, these improvements will significantly reduce cognitive load for future development.
