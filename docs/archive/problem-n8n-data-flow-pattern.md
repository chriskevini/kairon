# Problem: Data Flow Pattern in n8n Workflows

## The Core Problem

In n8n workflows, **each node overwrites `$json` with its own output**. This creates a fundamental challenge: how do you maintain access to data from earlier nodes without creating brittle, unmaintainable workflows?

### Example Scenario

```
Trigger → Query DB → Call LLM → Query DB → Send Response
```

At each step:
1. **Trigger** outputs: `{ event_id, message, channel_id, user_id }`
2. **Query DB** outputs: `{ id, name, created_at }` ← Original event data is LOST
3. **Call LLM** outputs: `{ text, tokens_used }` ← DB result is LOST
4. **Query DB** outputs: `{ inserted_id }` ← LLM result is LOST
5. **Send Response** needs: `channel_id` (from step 1), `text` (from step 3)

The final node cannot access earlier data through `$json` because it was overwritten.

## Current Solutions (All Have Drawbacks)

### Option A: Node Name References

Access previous nodes explicitly: `$('Trigger').item.json.channel_id`

**Problems:**
- Brittle: Renaming a node breaks all references to it
- Verbose: Long expressions scattered throughout workflow
- Hard to refactor: Moving nodes requires updating many references
- No autocomplete: Easy to typo node names

### Option B: Pass Everything Through

Every node spreads input and adds its output: `return { ...$json, new_field }`

**Problems:**
- Object bloat: Accumulates 30+ fields over a complex workflow
- Name collisions: Multiple nodes might use `result` or `id`
- Stale data: Hard to know if a field is current or from 10 nodes ago
- Memory overhead: Large objects passed through every node
- Tight coupling: Every node implicitly depends on accumulated shape

### Option C: Merge Nodes

Use n8n's Merge node to combine data from multiple branches.

**Problems:**
- Adds complexity: Extra nodes just for data management
- Timing issues: Must wait for all branches
- Not always applicable: Linear flows don't have branches to merge

### Option D: Code Node Wrappers

Wrap every database/HTTP node with a Code node that merges results.

**Problems:**
- Node explosion: 2x nodes for every operation
- Boilerplate: Repetitive merge logic everywhere
- Visual clutter: Hard to see actual workflow logic

## The Question

**What is the recommended pattern for maintaining data context across n8n workflows?**

Specifically:
1. Is there an established best practice in the n8n community?
2. How do production n8n workflows handle this at scale (20+ nodes)?
3. Is there a built-in n8n feature we're missing (e.g., workflow variables, context object)?
4. What patterns do similar tools (Zapier, Make, Pipedream) use?

## Constraints

- Workflows have 10-30 nodes
- Mix of Code nodes, Postgres nodes, HTTP nodes, LLM nodes
- Need to minimize maintenance burden when refactoring
- Must be understandable by AI coding agents working on the codebase

## Desired Outcome

A firm recommendation with strong arguments for ONE pattern to standardize across all workflows. The pattern should:

1. Be maintainable as workflows grow
2. Not require excessive boilerplate
3. Allow easy refactoring (rename/move nodes)
4. Be explicit about data dependencies
5. Work well with n8n's visual editor

## Context

- n8n version: Latest (self-hosted)
- Workflow complexity: Medium-high (routing, LLM calls, multiple DB operations)
- Team size: Solo developer + AI agents
- Primary concern: Long-term maintainability over short-term convenience
