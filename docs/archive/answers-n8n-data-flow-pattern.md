>>> Gemini 3 Pro <<<

This approach leverages modern n8n capabilities and software engineering principles to solve the data context problem without the flaws of the options you listed.

### The Recommendation: The "Context Object" Pattern

Based on your constraints (maintainability, explicit dependencies, refactor-safety), the best practice for production-grade n8n workflows is a hybrid approach I call the **Context Object Pattern**.

This pattern treats the workflow execution like a functional pipeline where a single, evolving `context` object is deliberately curated, rather than relying on accidental accumulation or brittle references.

---

### The Pattern Implementation

Instead of letting `$json` be overwritten blindly or accumulating random junk, you enforce a structure where every major output is keyed into a specific property.

#### 1. Initialize the Context (Early in the Flow)
Right after your Trigger, use an **Edit Fields** (Set) node called `InitContext`.
It maps the trigger data into a dedicated object key.

**Output:**
```json
{
  "ctx": {
    "trigger": {
      "event_id": "123",
      "channel_id": "C-999"
    }
  }
}
```

#### 2. The "Carry-Forward" Technique (Middle Nodes)
For intermediate nodes (DB, LLM, HTTP), you must carry the `ctx` forward.

**The "Paired" Pattern:**
When you configure a node (e.g., a Postgres node), you often lose the input JSON. To fix this *without* brittle backward references, change the **node output setting** (if available) or simply follow the node immediately with an **Edit Fields (Set)** node.

**The Standard Configuration for Set/Edit Fields Nodes:**
For a node named `SaveDBResult`:
1.  **Mode:** "Assignment" (Keep existing fields? YES, if following a pass-through node. NO, if rebuilding).
2.  **Logic:**
    *   Input: `$('InitContext').item.json.ctx` (Use the *anchor* node, not the immediate previous node, for the base).
    *   New Field: `ctx.db_result` = `$json.id` (The output of the immediate predecessor).

**Better yet: The Code Node Wrapper (Refined)**
Since you mentioned `Code` nodes are acceptable, this is the cleanest implementation. Instead of Option D (node explosion), you use **one** logic style inside your code nodes.

Input to Code Node: The previous step's output.
Code:
```javascript
// Access the evolving context from a standard "Anchor" node or the input if passed through
const globalCtx = $('InitContext').item.json.ctx; 

// Perform logic or grab previous step data
const stepResult = items[0].json;

// Return the merged structure
return {
  json: {
    ctx: {
      ...globalCtx,
      llm_response: stepResult.text
    }
  }
}
```

#### 3. The "Pinned Anchor" Strategy (Crucial for Refactoring)
This is the "secret sauce" for scalability.

Designate specific nodes as **Data Anchors**.
*   **Trigger**
*   **InitContext** (A Set node that standardizes the input)
*   **Checkpoints** (If the flow is huge, have a Set node halfway through named `Checkpoint_Data` that consolidates everything up to that point).

All subsequent nodes reference `$('InitContext').item.json.ctx` or `$('Checkpoint_Data').item.json.ctx`.

**Why this works:**
You are referencing a *specific, intentional architectural collection point*, not the random node immediately preceding the current one. If you rename the "LLM Call" node, your downstream nodes don't break because they weren't referencing `$('LLM Call')`—they were referencing the Context.

---

### Why This Wins

1.  **Refactoring Safety:** You can move, delete, or rename the processing nodes (DB, LLM) freely. As long as the `InitContext` node remains named the same (which it should, it's infrastructure), references hold.
2.  **Explicit Dependencies:** Looking at the final node, you see `{{ $('InitContext').item.json.ctx.channel_id }}`. It is immediately obvious this is global context data, not local computation.
3.  **No Name Collisions:** Because you nest under `ctx.trigger`, `ctx.db1`, `ctx.llm`, `id` never collides with `id`.
4.  **AI Agent Friendly:** AI agents understand object namespacing perfectly. Telling an agent "The channel ID is in `ctx.trigger.channel_id`" is much more reliable than "It's in the node that ran 4 steps ago."

### Comparison to Other Tools

*   **Pipedream:** Uses a similar logic with the `steps` object (e.g., `steps.trigger.event.body`). This pattern mimics that by creating a `ctx` object that persists.
*   **Zapier:** Uses strict linear dependency (Output of A -> Input of B). This is why Zapier gets messy for complex logic.
*   **Make (Integromat):** Allows random access to any module. It suffers from the same "renaming breaks mappings" issue as n8n's default method.

### Concrete Example (The Solution)

**Workflow Structure:**

1.  **Webhook**
2.  **Edit Fields (Set)** -> Name: `Ref_Context`
    *   *Config:* Create `ctx` object.
    *   *Fields:* `ctx.trigger = $json`
3.  **Postgres** (Query DB)
4.  **Code** (Process Logic) -> Name: `Update_Ctx_DB`
    *   *Logic:* Take `$json` (DB result) and merge into `$('Ref_Context').item.json.ctx`.
    *   *Output:* Returns the FULL updated `ctx` object.
5.  **HTTP Request** (Call LLM) -> *Input:* Uses `ctx.trigger.message` from previous node.
6.  **Code** (Process Logic) -> Name: `Update_Ctx_LLM`
    *   *Logic:* Take `$json` (LLM result) and merge into existing input `ctx`.
7.  **Send Slack**
    *   *Input:* `channel` = `$json.ctx.trigger.channel_id`, `text` = `$json.ctx.llm.text`

**By explicitly passing the `ctx` object as the PRIMARY output of your "Logic/Transition" nodes, the final node just looks at its input.**

### Final Recommendation

Use **The "Ref_Context" Anchor Pattern**.

1.  Create a **Set** node early named `Ref_Context`.
2.  Structure your data into a `ctx` object inside that node.
3.  For simple flows, reference `$('Ref_Context').item.json.ctx...` directly in later nodes.
4.  For complex flows, pass the `ctx` object through as the payload, appending new data to it in `Code` or `Set` nodes following significant actions.

This strikes the perfect balance between the rigidity of "Pass Everything" and the brittleness of "Node References."

>>> Claude Opus 4.5 <<<

# Recommended Pattern: Structured Context Accumulation

After analyzing the tradeoffs, I recommend **Option B with disciplined namespacing** as the canonical pattern. Here's the firm recommendation with strong arguments.

---

## The Pattern: Namespaced Context Object

Every workflow maintains a `ctx` (context) object that accumulates data under namespaced keys.

### Core Rules

1. **Every Code node spreads `$json` and adds its output under a unique namespace**
2. **Namespaces match the semantic purpose, not the node name**
3. **Native nodes (Postgres, HTTP) get wrapped with a 1-line Code node**

### Implementation

```javascript
// Pattern for Code nodes
return {
  ...$json,
  ctx: {
    ...$json.ctx,
    dbUser: { id, name, created_at }  // Namespaced under semantic key
  }
};
```

```javascript
// Wrapper pattern for native nodes (Postgres, HTTP, etc.)
// Place immediately after the native node
const result = $('Postgres Query').item.json;
return {
  ...$json,
  ctx: {
    ...$json.ctx,
    userRecord: result
  }
};
```

### Your Example Workflow Becomes:

```
Trigger → Wrap Trigger → Query DB → Wrap DB → Call LLM → Wrap LLM → Query DB → Wrap DB → Send Response
```

Data shape at each stage:

```javascript
// After Wrap Trigger
{
  ctx: {
    event: { event_id, message, channel_id, user_id }
  }
}

// After Wrap DB (first query)
{
  ctx: {
    event: { event_id, message, channel_id, user_id },
    user: { id, name, created_at }
  }
}

// After Wrap LLM
{
  ctx: {
    event: { event_id, message, channel_id, user_id },
    user: { id, name, created_at },
    llmResponse: { text, tokens_used }
  }
}

// After Wrap DB (second query)
{
  ctx: {
    event: { event_id, message, channel_id, user_id },
    user: { id, name, created_at },
    llmResponse: { text, tokens_used },
    insertResult: { inserted_id }
  }
}

// Send Response accesses:
// $json.ctx.event.channel_id
// $json.ctx.llmResponse.text
```

---

## Why This Pattern Wins

### Argument 1: Refactoring Safety

| Scenario | Node Reference (`$('Trigger')`) | Namespaced Context |
|----------|--------------------------------|-------------------|
| Rename node | ❌ Breaks all references | ✅ No change needed |
| Move node | ❌ May break if order matters | ✅ Context follows data |
| Delete node | ❌ Runtime errors | ✅ Clear what's missing |
| Duplicate workflow | ❌ Must verify all names | ✅ Works immediately |

**The namespace is semantic (`ctx.event`), not positional (`$('Slack Trigger 2')`).**

### Argument 2: Explicit Data Dependencies

```javascript
// Bad: Hidden dependency on node name
const channel = $('Slack Trigger').item.json.channel_id;

// Good: Explicit dependency on context shape
const channel = $json.ctx.event.channel_id;
```

Any node can inspect `$json.ctx` to see exactly what data is available. This is critical for AI agents that need to understand data flow.

### Argument 3: Controlled Object Growth

The `ctx` object grows, but **namespacing prevents collisions and makes staleness visible**:

```javascript
// Without namespacing (Option B as typically done)
{ id, name, result, data, response, id, ... }  // Which 'id'? Which 'result'?

// With namespacing
{
  ctx: {
    user: { id, name },
    order: { id, total },
    llm: { response, tokens }
  }
}
```

You can also **prune aggressively** at key points:

```javascript
// At a natural boundary, extract only what's needed going forward
return {
  ctx: {
    event: $json.ctx.event,  // Keep
    finalResponse: $json.ctx.llm.response  // Keep
    // Drop user, order, etc.
  }
};
```

### Argument 4: Wrapper Overhead is Acceptable

Yes, this doubles nodes for native operations. But:

| Concern | Reality |
|---------|---------|
| Visual clutter | Group wrapper + native node in n8n's visual grouping |
| Boilerplate | 3 lines of code, highly consistent |
| Performance | Negligible—n8n bottleneck is never JS execution |
| Maintenance | Wrappers are trivial to update |

**The alternative (node references everywhere) creates invisible dependencies that are far worse for maintenance.**

### Argument 5: Works With AI Agents

AI agents can follow a simple rule:

> "Every native node must be followed by a Code node that merges output into `$json.ctx` under a semantic namespace."

This is checkable, enforceable, and requires no understanding of the specific workflow structure.

---

## Comparison With Other Tools

| Tool | Data Flow Model | n8n Equivalent |
|------|-----------------|----------------|
| **Zapier** | Each step has named output, accessible as `Step 3: Field` | Node references (Option A) |
| **Make (Integromat)** | Bundle carries all data, modules add to it | Pass-through (Option B) |
| **Pipedream** | `steps` object accumulates all outputs by step name | Hybrid A+B |
| **Temporal/Prefect** | Explicit parameter passing between activities | Not applicable |

Make's model (accumulating bundle) is closest to what works well at scale. Zapier's model (step references) becomes unwieldy past 10 steps.

---

## Addressing Your Concerns

### "Object bloat with 30+ fields"

Namespace isolation prevents this from becoming unmanageable:

```javascript
ctx: {
  slack: { ... },      // 5 fields
  db: { ... },         // 8 fields  
  llm: { ... },        // 3 fields
  validation: { ... }  // 4 fields
}
// 20 fields, but organized into 4 logical groups
```

### "Name collisions"

Impossible with namespacing. `ctx.sourceUser.id` vs `ctx.targetUser.id` are unambiguous.

### "Memory overhead"

n8n workflows process items sequentially. Even 100KB per item is trivial. This is not a real concern unless you're passing binary data (which you shouldn't put in context anyway).

### "Hard to know if data is current"

Namespacing makes this explicit. If you see `ctx.validation`, you know it came from the validation step. If you need fresh data, query again and update the namespace.

---

## Implementation Checklist

### For New Workflows

1. **First node after trigger**: Initialize context
   ```javascript
   return { ctx: { event: $json } };
   ```

2. **After every native node**: Wrap with context merge
   ```javascript
   return {
     ...$json,
     ctx: { ...$json.ctx, semanticName: $('Native Node').item.json }
   };
   ```

3. **For Code nodes that do work**: Add output to context inline
   ```javascript
   const result = doSomething($json.ctx.event);
   return {
     ...$json,
     ctx: { ...$json.ctx, processed: result }
   };
   ```

4. **At major boundaries**: Prune context to only needed fields

### For Existing Workflows

Migrate incrementally:
1. Add `ctx` wrapper to trigger
2. Convert one node reference at a time to context access
3. Add wrapper nodes as you touch each native node

---

## Template Code

### Context Initializer (after trigger)

```javascript
// Name: Initialize Context
return {
  ctx: {
    event: $json
  }
};
```

### Native Node Wrapper

```javascript
// Name: Wrap [Node Name]
// Place immediately after: [Native Node Name]
return {
  ...$json,
  ctx: {
    ...$json.ctx,
    SEMANTIC_NAME: $('NATIVE_NODE_NAME').item.json
  }
};
```

### Context Pruner (at boundaries)

```javascript
// Name: Prune Context
return {
  ctx: {
    // Only keep what's needed downstream
    event: $json.ctx.event,
    result: $json.ctx.finalStep.output
  }
};
```

---

## Final Verdict

**Use Option B (pass-through) with strict namespacing under a `ctx` object.**

This pattern:
- ✅ Survives node renames and moves
- ✅ Minimal boilerplate (3-line wrappers)
- ✅ Explicit, inspectable data dependencies
- ✅ Scales to 30+ nodes without confusion
- ✅ AI-agent friendly (simple, consistent rule)
- ✅ Works with n8n's visual editor (group wrappers with their native nodes)

The node-explosion concern is real but acceptable. **The maintenance cost of node references at scale is far higher than the visual cost of wrapper nodes.**

>>> Devstral 2 2512 <<<

# Recommended Data Flow Pattern for n8n Workflows

## The Solution: **Context Object Pattern**

After analyzing all options and considering your constraints, I recommend the **Context Object Pattern** as the most maintainable solution for your n8n workflows.

### Core Concept

Maintain a single `context` object that flows through your entire workflow, with each node explicitly declaring its inputs and outputs.

```javascript
// Initial context structure
{
  context: {
    inputs: {
      trigger: { event_id, message, channel_id, user_id },
      // other inputs will be added here
    },
    outputs: {
      // outputs will be added here
    },
    metadata: {
      workflow_id: "abc123",
      started_at: "2023-01-01T00:00:00Z"
    }
  }
}
```

## Implementation Details

### 1. Initialize Context (First Node)

```javascript
// In your trigger node or first Code node
return {
  context: {
    inputs: {
      trigger: {
        event_id: $json.event_id,
        message: $json.message,
        channel_id: $json.channel_id,
        user_id: $json.user_id
      }
    },
    outputs: {},
    metadata: {
      workflow_id: $workflow.id,
      started_at: new Date().toISOString()
    }
  }
};
```

### 2. Standard Node Pattern

For each subsequent node, use this template:

```javascript
// 1. Extract what you need from context
const { channel_id } = $json.context.inputs.trigger;
const { user_data } = $json.context.outputs.query_db_1 || {};

// 2. Do your operation
const result = await queryDatabase(user_data);

// 3. Return updated context
return {
  context: {
    ...$json.context, // Preserve all existing context
    outputs: {
      ...$json.context.outputs,
      query_db_2: { // Explicit output name
        inserted_id: result.id,
        timestamp: new Date().toISOString()
      }
    }
  },
  // Optionally include direct output for next node
  inserted_id: result.id
};
```

### 3. Final Node Access

```javascript
// In your final node
const { channel_id } = $json.context.inputs.trigger;
const { text } = $json.context.outputs.call_llm;

return {
  response: {
    channel: channel_id,
    message: text,
    metadata: $json.context.metadata
  }
};
```

## Why This Pattern Wins

### 1. Maintainability
- **Explicit dependencies**: Each node declares exactly what it needs
- **No brittle references**: No node name strings scattered through code
- **Easy refactoring**: Move/rename nodes without breaking references

### 2. Scalability
- **Flat structure**: Doesn't grow exponentially with workflow size
- **Selective access**: Nodes only take what they need
- **Clear provenance**: Always know where data came from

### 3. Debugging
- **Complete history**: Entire data flow preserved in context
- **Isolation**: Easy to see what each node contributed
- **Metadata tracking**: Built-in workflow tracking

### 4. AI-Friendly
- **Structured data**: Predictable format for AI agents
- **Self-documenting**: Clear input/output declarations
- **Pattern consistency**: Same approach in every workflow

## Comparison to Other Options

| Approach               | Maintainability | Scalability | Refactoring | Explicitness | AI-Friendly |
|------------------------|-----------------|-------------|-------------|--------------|-------------|
| Context Object Pattern | ⭐⭐⭐⭐⭐         | ⭐⭐⭐⭐⭐     | ⭐⭐⭐⭐⭐     | ⭐⭐⭐⭐⭐      | ⭐⭐⭐⭐⭐     |
| Node Name References   | ⭐               | ⭐⭐         | ⭐           | ⭐⭐⭐         | ⭐⭐          |
| Pass Everything        | ⭐⭐             | ⭐           | ⭐⭐         | ⭐            | ⭐⭐          |
| Merge Nodes            | ⭐⭐⭐            | ⭐⭐⭐        | ⭐⭐⭐        | ⭐⭐⭐         | ⭐⭐⭐         |
| Code Node Wrappers     | ⭐⭐⭐            | ⭐⭐         | ⭐⭐⭐        | ⭐⭐⭐         | ⭐⭐⭐         |

## Implementation Tips

1. **Create a Context Helper Node**:
   ```javascript
   // Reusable function to update context
   function updateContext($json, outputName, newData) {
     return {
       context: {
         ...$json.context,
         outputs: {
           ...$json.context.outputs,
           [outputName]: {
             ...newData,
             _timestamp: new Date().toISOString()
           }
         }
       },
       ...newData // Optionally spread for direct access
     };
   }
   ```

2. **Use Consistent Naming**:
   - Inputs: `trigger`, `query_db_1`, `call_llm`
   - Outputs: Same as node purpose with `_out` suffix

3. **Add Validation**:
   ```javascript
   // In critical nodes
   if (!$json.context?.inputs?.trigger?.channel_id) {
     throw new Error("Missing required context: trigger.channel_id");
   }
   ```

4. **Document Your Pattern**:
   ```markdown
   # Workflow Data Flow Rules

   1. All data flows through `context` object
   2. Inputs are in `context.inputs.{node_name}`
   3. Outputs go to `context.outputs.{node_name}`
   4. Each node declares its dependencies at the top
   5. Never modify context inputs - only add outputs
   ```

## Migration Strategy

1. **Start with new workflows**: Implement pattern in all new workflows
2. **Gradual refactoring**: When modifying existing workflows, convert to pattern
3. **Create templates**: Save workflow snippets with pattern implemented
4. **Document decisions**: Explain why this pattern was chosen in your docs

## Alternative Consideration: n8n Variables

While n8n does have workflow variables (`$workflow`), they're not suitable for this use case because:
- Limited to simple key-value pairs
- No structure or nesting
- Harder to manage in complex workflows
- Less explicit about data flow

The Context Object Pattern provides all the benefits of variables with proper structure and maintainability.

## Conclusion

The **Context Object Pattern** provides the best balance of maintainability, scalability, and explicitness for your n8n workflows. It addresses all your concerns while working well with both human developers and AI agents. Standardize on this pattern across all workflows for long-term success.

>>> GPT 5.2 Pro <<<

### Firm recommendation: **“Context rail + checkpoint merges” (a.k.a. an explicit context envelope carried on a dedicated branch and merged back at well-defined points)**

If you want something that is **rename/move-safe**, **explicit about dependencies**, uses **built-in nodes**, and doesn’t require wrapping *every* node in Code, the most maintainable standard in n8n is:

- Keep a **single, compact context object** (e.g. `ctx`) that represents “state so far”.
- Keep it alive by running it down a **separate “context rail”** (a branch that never goes through overwriting nodes).
- Whenever an overwriting node produces new data you want to keep, **merge the result back into the context rail at a checkpoint** (using a `Merge` node), then immediately **normalize/store** it into `ctx.<namespace>` with a `Set` node (and drop any temporary top-level fields).

This avoids brittle node-name references *and* avoids “pass everything through every node”.

---

## Why this is the best fit for your constraints

### What it optimizes for
- **Refactor safety (rename/move nodes):** downstream nodes read from `$json.ctx...`, not `$('Some Node Name')...`.
- **Explicit dependencies:** the only “global” contract is the `ctx` schema (which you control). Checkpoints show exactly where state is updated.
- **Low boilerplate vs wrappers:** you add merges **only at checkpoints** (places where you truly need to retain outputs), not after every node.
- **Visual clarity in n8n:** you literally see two rails: “state” and “work”, and you see where they rejoin.

### The hard truth this pattern respects
In n8n, if a node overwrites output and **does not include input fields**, then **you cannot keep prior data without either**:
- referencing earlier nodes by name, **or**
- passing/merging data forward via the graph.

So the “context rail” is the cleanest graph-native way to do it.

---

## The pattern (standardize this)

### 1) Create a context envelope immediately after the trigger
Use a `Set` node (or `Code`, but `Set` is fine) to create a stable structure like:

- `ctx`: durable state you want to retain
- `work`: optional scratch space for the next operation (kept small)

Example output shape:
```json
{
  "ctx": {
    "event": { "event_id": "...", "message": "...", "channel_id": "...", "user_id": "..." }
  },
  "work": {}
}
```

### 2) Run overwrite-y nodes on a **work rail**
Branch from the `ctx:init` node:

- **Rail A (context rail):** just carries `{ ctx, work }` forward untouched
- **Rail B (work rail):** runs Postgres / HTTP / LLM nodes that overwrite

### 3) At each checkpoint, `Merge` the rails
Use a `Merge` node in **“Merge By Position”** mode (safe for single-item flows).  
If you may have multiple items, use **“Merge By Key”** with something stable like `ctx.event.event_id`.

### 4) Immediately normalize into `ctx.<namespace>` with a `Set` node
After the merge, use `Set` to store the work output under a namespaced key and remove temporary top-level fields if desired.

---

## Your example rewritten with this standard

Original:
```
Trigger → Query DB → Call LLM → Query DB → Send Response
```

Recommended layout (conceptually two rails + checkpoints):

1. **Trigger**
2. **Set: `ctx:init`** → creates `{ ctx: { event: ... }, work: {} }`

### Checkpoint 1: Query DB (read user)
- Work rail: **Postgres: `db:getUser`** (input from `ctx:init`) → outputs `{ id, name, created_at }`
- Context rail: passes through `ctx:init` unchanged
- **Merge: `cp:user`** (ctx rail + db output)
- **Set: `ctx:storeUser`**
  - Set `ctx.user = { id, name, created_at }`
  - Optionally remove `id/name/created_at` from top-level

### Checkpoint 2: Call LLM
- Work rail: **Set: `work:prompt`** (build prompt from `$json.ctx.event.message` and `$json.ctx.user...`)
- Work rail: **LLM: `llm:reply`** → outputs `{ text, tokens_used }`
- Context rail: passes through from after `ctx:storeUser`
- **Merge: `cp:llm`**
- **Set: `ctx:storeLlm`**
  - Set `ctx.llm = { text, tokens_used }`

### Checkpoint 3: Insert DB record
- Work rail: **Postgres: `db:insertMessage`** (use `$json.ctx.llm.text`, `$json.ctx.event.user_id`, etc.)
- Context rail: passes through with `ctx.event`, `ctx.user`, `ctx.llm`
- **Merge: `cp:insert`**
- **Set: `ctx:storeInsert`**
  - Set `ctx.db.inserted_id = $json.inserted_id`

### Final
- **Send Response**
  - Reads from `$json.ctx.event.channel_id` and `$json.ctx.llm.text`

**Key property:** the final node never needs `$('Trigger')...` or `$('LLM')...` references.

---

## Answers to your specific questions

### 1) Is there an established best practice in the n8n community?
In practice there are two common approaches:
- **Node references** (`$node["X"].json...`) for quick builds (but brittle at scale).
- **A state/envelope carried forward** (often with `Merge` checkpoints or selective merging) for maintainable builds.

For your constraints (refactor-friendly, 10–30 nodes, long-term maintenance), the **context envelope + checkpoint merges** approach is the most robust graph-native pattern.

### 2) How do production n8n workflows handle this at scale (20+ nodes)?
Typically by doing **one of**:
- **A small “state object”** (like `ctx`) that becomes the workflow’s contract, updated at checkpoints.
- **Sub-workflows** (`Execute Workflow`) to keep each workflow small, with explicit input/output contracts (still often using a `ctx` envelope at the boundaries).
- Avoiding “everything everywhere” payloads; instead, **namespacing**: `ctx.event`, `ctx.user`, `ctx.llm`, `ctx.db`.

### 3) Is there a built-in n8n feature we’re missing (workflow variables/context)?
There is no universal, per-execution “context object” that all nodes automatically preserve. You basically have:
- **Pass it along in the item JSON**, or
- **Reference earlier nodes by name**, or
- Use persistence primitives (e.g., static data / datastore) which are **not** appropriate as an execution-scoped context store.

So you’re not missing a magic feature—this is a real architectural constraint of the data model.

### 4) What patterns do similar tools use?
- **Pipedream:** encourages `steps.<name>...` references (similar brittleness, but step names are treated like API).
- **Zapier:** “bundle” style mapping; earlier step outputs remain addressable by step, i.e., explicit references.
- **Make:** mapping between module outputs; earlier module data remains accessible via UI mapping tokens (again, step/module addressing).

Those tools largely lean on **step addressing**. In n8n, that corresponds to node-name references—your Option A—which you correctly identified as brittle for refactoring. The **context rail** pattern is n8n’s best equivalent to a real “execution context”.

---

## Standard to document for AI agents (the “contract”)

Adopt these rules:

1. **Every workflow item must have `ctx` at the top level.**
2. **Only `ctx` is durable.** Anything else is work output and can be discarded.
3. **All durable fields are namespaced:**  
   `ctx.event`, `ctx.user`, `ctx.llm`, `ctx.db`, `ctx.http`, etc.
4. **Any node that overwrites output must run on the work rail and be merged at a checkpoint** if its result is needed later.
5. **Final/send nodes read only from `ctx`.** Never from `$node[...]` unless there is an exceptional reason.

---

If you tell me whether your workflows are **single-item** (one trigger event → one execution item) or **multi-item/batched**, I can give you the exact `Merge` configuration to standardize (by position vs by key) and a concrete node-by-node template you can clone for new workflows.
