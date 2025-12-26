# Issue #73: Eliminate Node References from Workflows

## Status: In Progress (Technical Debt)

Pre-commit validation now **blocks new violations** while existing workflows 
are incrementally refactored.

## Blocking Errors (8 total)

### Execute_Command.json (5 errors)
- [ ] `ValidateGet`: 2 node references → Refactor to use ctx or Merge nodes
- [ ] `ValidateSet`: 2 node references → Refactor to use ctx or Merge nodes
- [ ] `ValidateDelete`: 2 node references → Refactor to use ctx or Merge nodes
- [ ] `ValidateRecent`: 2 node references → Refactor to use ctx or Merge nodes
- [ ] `ValidateGenerate`: 2 node references → Refactor to use ctx or Merge nodes

### Capture_Thread.json (2 errors)
- [ ] `PrepareTraceData`: 2 node references → Refactor to use Merge pattern
- [ ] `BuildUpdateSummaryQuery`: 2 node references → Use ctx.db namespace

### Handle_Correction.json (1 error)
- [ ] `CheckReExtract`: 2 node references → Refactor validation logic

## Non-Blocking Warnings (21 total)

Workflows with single node references that should be refactored to use 
dedicated wrapper nodes:

### Execute_Command.json (10 warnings)
- [ ] HandlePing, HandleHelp, FormatGetResponse, FormatSetResponse, etc.
  → Move ctx restoration to dedicated wrapper nodes before logic nodes

### Other Workflows (11 warnings)
- [ ] Capture_Projection.json: ParseClassification
- [ ] Capture_Thread.json: ParseExtractions  
- [ ] Generate_Nudge.json: CheckSkip
- [ ] Handle_Error.json: FormatErrorMessage
- [ ] Start_Thread.json: SetLlmResponse
- [ ] Multi_Capture.json: ParseResponse, SplitCaptures, CollectResults
- [ ] Route_Reaction.json: DetermineRoute

## Refactoring Strategy

1. **Execute_Command.json** (15 issues): Most violations concentrated here
   - Pattern: Validation nodes access both trigger data and previous node data
   - Solution: Add Merge nodes or use ctx.validation namespace

2. **Incremental Approach**: Fix during regular workflow maintenance
   - When modifying a workflow, address warnings in changed areas
   - No dedicated refactoring sprint required

3. **Monitoring**: Pre-commit hook prevents regression

## Success Criteria

- [ ] All 8 blocking errors resolved (Execute_Command, Capture_Thread, Handle_Correction)
- [ ] Warnings reduced to < 10 through opportunistic refactoring
- [ ] New workflows pass with 0 errors, 0 warnings
