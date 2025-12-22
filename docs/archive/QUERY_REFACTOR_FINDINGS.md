# Analysis: Postgres Query Node Refactor

## Current State & Issues
Across the Kairon codebase, Postgres nodes are used extensively to interact with the immutable event log and projections. However, because n8n's native nodes overwrite the `$json` object, every query currently requires a manual "context restoration" pattern:

1.  **Postgres Node:** Executes query, outputting rows as separate items.
2.  **Merge Node:** Usually set to "Wait for all inputs" or "Append" mode to collect rows.
3.  **Code Node:** Manually pulls the original `ctx` from the trigger node and attaches the DB results.

### Observed Inconsistencies
- **Merge Modes:** Some workflows use `combineByPosition` with 3+ inputs (e.g., `Start_Thread.json`), while others use `append` with a single input.
- **Context Shape:** Database results are sometimes placed in `ctx.db.thread_history`, `ctx.db.results`, or flattened into the root of `ctx`.
- **Boilerplate:** Approx. 3-4 nodes are repeated per query to maintain the `ctx` pattern.

## Implemented Solution: `Query_DB` Wrapper

A reusable sub-workflow (`Query_DB.json`) standardizes database interactions.

### Interface (Input)
The sub-workflow expects a standard `ctx` with query details:
```javascript
{
  ctx: {
    event: { ... },
    db_query: {
      sql: "SELECT * FROM projections WHERE ...",
      params: ["param1", "param2"]
    }
  }
}
```

### Interface (Output)
Returns `ctx` with results in standardized location:
```javascript
{
  ctx: {
    event: { ... },
    db: {
      results: [...],  // Array of row objects
      count: 5         // Number of rows returned
    }
  }
}
```

### Implementation
The wrapper contains:
- **Execute Workflow Trigger** - Receives ctx with db_query
- **Prepare Query** - Validates input, stores original ctx
- **Execute Query** - Postgres node using dynamic SQL/params
- **Merge Results** - Combines original ctx with query results
- **Finalize Context** - Restores ctx with results in `ctx.db`

## Linter Enforcement
The `scripts/workflows/lint_workflows.py` script enforces this:
- **Rule:** Warns on any `n8n-nodes-base.postgres` node found in any workflow except `Query_DB`.
- **Exemption:** Query_DB itself is allowed to use Postgres directly.

## Benefits
- **Safety:** Guaranteed `ctx` preservation across the entire system.
- **Maintenance:** Centralized database connection and error handling.
- **Clarity:** Parent workflows become significantly cleaner, replacing 3+ nodes with a single "Execute Workflow" node.
- **Agent Efficiency:** Clear contract - always use Query_DB, always get `ctx.db.results` back.

## When to Use Query_DB

**Good candidates:**
- Single SELECT queries that need ctx preserved
- Sequential queries where you build up context
- Reusable query patterns across workflows

**Keep inline Postgres for:**
- Parallel queries from a single trigger (Query_DB would force sequential execution)
- Simple config lookups with no parameters
- INSERT/UPDATE/DELETE operations tightly coupled with workflow logic
- Queries where the result feeds directly into the next node's parameters

## Migration Path
Existing workflows using direct Postgres SELECT nodes will show warnings. Migrate incrementally:
1. Identify SELECT queries that would benefit from standardization
2. Replace Postgres + Merge + ctx-restore pattern with Query_DB call
3. Update code to read from `ctx.db.results` instead of custom locations
4. Keep parallel query patterns inline when performance matters
