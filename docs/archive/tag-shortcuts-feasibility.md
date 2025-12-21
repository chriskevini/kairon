# Tag Shortcuts: Feasibility Analysis

## Current State: Projection Types & Categories

### Projection Types (5 types)
```javascript
projection_type: 'activity' | 'note' | 'todo' | 'thread_extraction' | 'assistant_message'
```

### Categories within Projections (JSONB, not enums)

**Activity categories (7 types):**
- work
- leisure
- study
- health
- sleep
- relationships
- admin

**Note categories (2 types):**
- `fact` - External knowledge (birthdays, preferences, facts about people)
- `reflection` - Internal knowledge (insights, decisions, observations)

**Key Design:** There is NO separate `fact` or `reflection` projection type. Both are `projection_type: 'note'` with different categories stored in JSONB:
```javascript
// Fact note
{
  projection_type: 'note',
  data: {
    category: 'fact',
    text: 'Chris birthday is March 15',
    timestamp: '...'
  }
}

// Reflection note
{
  projection_type: 'note',
  data: {
    category: 'reflection',
    text: 'realized error handling needs improvement',
    timestamp: '...'
  }
}
```

---

## Current Tag System: "Hard Override"

### Behavior
```javascript
!!  → Skip multi-extraction → Extract ONLY activity
..  → Skip multi-extraction → Extract ONLY note
++  → Skip extraction entirely → Start thread
::  → Skip extraction entirely → Execute command
(no tag) → Run multi-extraction → Extract activity + note + todo
```

### Why "Hard Override" is Accurate
- Tags completely bypass multi-extraction step in trace chain
- They force a specific projection type without LLM classification
- No ambiguity: `!!` will NEVER create a note, only activity

---

## Proposed Rebrand: "Shortcuts"

### Conceptual Shift

**Before (Hard Override):**
> "Tags override the AI and force a specific action"
> *Implies: AI is the default, tags are exceptions*

**After (Shortcuts):**
> "Tags are shortcuts that skip classification steps"
> *Implies: Tags are power-user features, not workarounds*

### Why "Shortcuts" is Better

**1. User-Centric Framing**
- "Hard override" sounds like you're fighting the system
- "Shortcuts" sounds like efficiency and control
- Better aligns with power-user mental model

**2. Accurate Description**
- Tags literally skip trace chain steps (multi-extraction)
- They're shortcut keys for common actions
- Similar to keyboard shortcuts in apps

**3. Extensibility**
- "Shortcuts" suggests configurability
- Opens door to custom shortcuts in future
- Fits with potential user-defined tags

### Naming Comparison

| Current | Proposed | Notes |
|---------|----------|-------|
| Tag as Hard Override | Tag Shortcuts | More user-friendly |
| Tag detection (deterministic) | Shortcut detection | Same implementation |
| Tags skip multi-extraction | Shortcuts skip classification | Same behavior |

---

## Feasibility Analysis: Configurable Shortcuts

### Proposal: User-Defined Shortcuts

**Concept:**
Allow users to create custom shortcuts beyond `!!`, `..`, `++`, `::`

**Example Use Cases:**
```javascript
// User defines custom shortcuts
$$ → Extract ONLY fact note (skip category classification)
%% → Extract activity + note (skip todo extraction)
@@ → Mention/reference (new projection type)
## → Goal/milestone (todo with is_goal=true)
```

### Implementation Options

#### Option 1: Hardcoded Registry (Current + Extensions)

**Approach:** Add more hardcoded shortcuts to TRACE_STEP_REGISTRY

```javascript
// In n8n workflow
const SHORTCUT_REGISTRY = {
  '!!': {
    label: 'Activity shortcut',
    skips: ['multi_extraction'],
    executes: ['activity_extraction']
  },
  '..': {
    label: 'Note shortcut',
    skips: ['multi_extraction'],
    executes: ['note_extraction']
  },
  '++': {
    label: 'Thread shortcut',
    skips: ['multi_extraction', 'activity_extraction', 'note_extraction'],
    executes: ['thread_start']
  },
  '::': {
    label: 'Command shortcut',
    skips: ['multi_extraction'],
    executes: ['command_handler']
  },
  // NEW: User-defined shortcuts
  '$$': {
    label: 'Fact note shortcut',
    skips: ['multi_extraction'],
    executes: ['note_extraction'],
    force_category: 'fact'
  },
  '%%': {
    label: 'Activity + note shortcut',
    skips: ['multi_extraction'],
    executes: ['activity_extraction', 'note_extraction']
  }
};
```

**Pros:**
- ✅ Fast (no DB lookup)
- ✅ Type-safe
- ✅ Easy to reason about
- ✅ No n8n restart needed (just reload workflow)

**Cons:**
- ❌ Not user-configurable without editing workflow
- ❌ Requires code change to add shortcuts
- ❌ Limited to developers

**Feasibility:** ⭐⭐⭐⭐⭐ (5/5) - Trivial to implement

---

#### Option 2: Database-Backed Shortcuts (Fully Configurable)

**Approach:** Store shortcuts in database, user manages via Discord commands

```sql
CREATE TABLE shortcuts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NULL,  -- NULL = global, otherwise user-specific
  tag TEXT NOT NULL,  -- '$$', '%%', etc.
  label TEXT NOT NULL,
  projection_type TEXT NOT NULL,  -- 'activity', 'note', 'todo'
  force_category TEXT NULL,  -- Optional: 'fact', 'work', etc.
  skip_steps TEXT[] NOT NULL,  -- ['multi_extraction']
  execute_steps TEXT[] NOT NULL,  -- ['activity_extraction']
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, tag)
);

-- Seed with defaults
INSERT INTO shortcuts (user_id, tag, label, projection_type, skip_steps, execute_steps) VALUES
  (NULL, '!!', 'Activity shortcut', 'activity', ARRAY['multi_extraction'], ARRAY['activity_extraction']),
  (NULL, '..', 'Note shortcut', 'note', ARRAY['multi_extraction'], ARRAY['note_extraction']),
  (NULL, '++', 'Thread shortcut', 'thread', ARRAY['multi_extraction'], ARRAY['thread_start']),
  (NULL, '::', 'Command shortcut', 'command', ARRAY['multi_extraction'], ARRAY['command_handler']);
```

**Discord Commands:**
```javascript
// List shortcuts
::shortcuts

// Create custom shortcut
::shortcut add $$ "Fact note" --type note --category fact

// Edit shortcut
::shortcut edit $$ --category reflection

// Delete shortcut
::shortcut delete $$

// Disable/enable shortcut
::shortcut disable $$
::shortcut enable $$
```

**n8n Implementation:**
```javascript
// In Discord_Message_Router workflow
const tag = detectTag(message); // Returns '$$' or null

if (tag) {
  // Lookup shortcut from database
  const shortcut = await db.query(`
    SELECT * FROM shortcuts 
    WHERE tag = $1 
      AND (user_id = $2 OR user_id IS NULL)
      AND active = true
    ORDER BY user_id DESC NULLS LAST  -- User shortcuts override global
    LIMIT 1
  `, [tag, userId]);
  
  if (shortcut) {
    // Execute shortcut
    await executeSteps(shortcut.execute_steps, {
      force_category: shortcut.force_category
    });
  } else {
    // Unknown tag, treat as regular message
    await runMultiExtraction(message);
  }
}
```

**Pros:**
- ✅ Fully user-configurable
- ✅ User-specific shortcuts (power users can customize)
- ✅ Global shortcuts (shared across all users)
- ✅ Can add shortcuts without code changes
- ✅ Enables experimentation (users can try different workflows)

**Cons:**
- ❌ DB lookup on every message (adds latency ~10-50ms)
- ❌ More complex (another table to maintain)
- ❌ Cache invalidation issues (need to reload shortcuts)
- ❌ Potential for user confusion (too many shortcuts)
- ❌ Tag collision risk (user tries to use reserved tag)

**Feasibility:** ⭐⭐⭐☆☆ (3/5) - Moderate complexity, requires careful design

---

#### Option 3: Hybrid Approach (Recommended)

**Approach:** Hardcoded core shortcuts + optional user extensions

```javascript
// Hardcoded (always available, fast)
const CORE_SHORTCUTS = {
  '!!': { executes: ['activity_extraction'] },
  '..': { executes: ['note_extraction'] },
  '++': { executes: ['thread_start'] },
  '::': { executes: ['command_handler'] }
};

// User-defined (optional, slower)
const tag = detectTag(message);

if (CORE_SHORTCUTS[tag]) {
  // Fast path: hardcoded shortcut
  await executeCoreShortcut(tag, message);
} else if (tag && tag.length === 2) {  // Custom tag format
  // Slow path: DB lookup
  const customShortcut = await db.query(`
    SELECT * FROM shortcuts WHERE tag = $1 AND active = true
  `, [tag]);
  
  if (customShortcut) {
    await executeCustomShortcut(customShortcut, message);
  } else {
    // Unknown tag, treat as regular message
    await runMultiExtraction(message);
  }
} else {
  // No tag, run multi-extraction
  await runMultiExtraction(message);
}
```

**Pros:**
- ✅ Core shortcuts remain fast (no DB hit)
- ✅ Users can add custom shortcuts if needed
- ✅ Backwards compatible
- ✅ Best of both worlds

**Cons:**
- ❌ Two code paths to maintain
- ❌ Still need shortcuts table

**Feasibility:** ⭐⭐⭐⭐☆ (4/5) - Good balance, recommended approach

---

## Recommendation: Phased Rollout

### Phase 1: Rebrand to "Shortcuts" (Immediate)
**Effort:** 🔧 Low (documentation update only)

- Update all documentation: "tag shortcuts" instead of "hard override"
- Update Discord help messages
- Update README, AGENTS.md
- No code changes needed

**Benefits:**
- Better user-facing language
- Sets stage for future configurability
- No implementation risk

**Action Items:**
- [ ] Update docs/simplified-extensible-schema.md
- [ ] Update AGENTS.md
- [ ] Update README.md
- [ ] Update Discord help command output
- [ ] Update n8n workflow node names/comments

---

### Phase 2: Add Hardcoded Shortcuts (Short-term)
**Effort:** 🔧🔧 Medium (n8n workflow changes)

Add more built-in shortcuts for common patterns:

```javascript
$$  → Fact note (skip category classification)
%%  → Quick log (activity + note, skip todo extraction)
@@  → Mention/reference (future: cross-reference system)
##  → Goal (todo with is_goal=true)
```

**Implementation:**
- Update TRACE_STEP_REGISTRY in n8n
- Add new handlers for each shortcut
- Update documentation
- No database changes needed

**Benefits:**
- Fast iteration
- No complexity added
- Easy to rollback if not used

---

### Phase 3: User-Configurable Shortcuts (Long-term)
**Effort:** 🔧🔧🔧 High (schema + workflow + UI changes)

Implement hybrid approach (Option 3):
- Add `shortcuts` table
- Create Discord commands (::shortcut add/edit/delete)
- Implement DB lookup for custom tags
- Cache shortcuts in n8n memory
- Document shortcut creation guide

**When to implement:**
- After 100+ messages to validate usage patterns
- When users explicitly request custom shortcuts
- After RAG/embeddings implemented (Phase 7)

**Benefits:**
- Ultimate flexibility
- Power users can optimize workflow
- Learning opportunity (see what shortcuts users create)

---

## Example: User Journey with Shortcuts

### Current (Hard Override)
```
User: "!! working on router"
System: Detects '!!' tag → Skips multi-extraction → Extracts activity
Discord: 🕒 emoji

User: "working on router"
System: No tag → Runs multi-extraction → Extracts activity
Discord: 🕒 emoji
```

### After Phase 1 (Rebrand)
```
User: "!! working on router"
System: Detects '!!' shortcut → Skips classification → Extracts activity
Discord: 🕒 emoji
Help text: "Use !! shortcut to quickly log activities"
```

### After Phase 2 (More Shortcuts)
```
User: "$$ Chris birthday is March 15"
System: Detects '$$' shortcut → Skips classification → Extracts fact note
Discord: 📝 emoji

User: "%% working on router. interesting pattern in logs"
System: Detects '%%' shortcut → Extracts activity + note (skips todo)
Discord: 🕒 📝 emoji
```

### After Phase 3 (Configurable)
```
User: "::shortcut add @@ mention --type reference"
System: Creates custom @@ shortcut

User: "@@ see note about error handling"
System: Detects '@@' shortcut → Creates cross-reference projection
Discord: 🔗 emoji
```

---

## Risk Analysis

### Risk: Shortcut Overload
**Problem:** Too many shortcuts → users forget which is which

**Mitigation:**
- Limit to 8-10 shortcuts max
- Show active shortcuts in `::help`
- Use mnemonic tags (`$$` = dollar = fact/data, `%%` = percent = mixed)

### Risk: Tag Collision
**Problem:** User tries to use reserved tag (`!!`, `..`)

**Mitigation:**
- Reserve first-character tags (`!`, `.`, `+`, `:`) for system
- Allow only two-character tags for custom shortcuts
- Validate on creation: `if (tag[0] in ['!', '.', '+', ':']) { error }`

### Risk: Performance Degradation
**Problem:** DB lookup on every message adds latency

**Mitigation:**
- Cache shortcuts in n8n workflow memory (reload every 5 min)
- Core shortcuts never hit DB (fast path)
- DB lookup only for custom shortcuts (~50ms acceptable)

### Risk: Complexity Creep
**Problem:** Too many features → hard to maintain

**Mitigation:**
- Implement phases only when needed (user-driven)
- Start with Phase 1 (rebrand) immediately
- Phase 2/3 only if users request it
- Keep core shortcuts hardcoded forever (stability)

---

## Conclusion

### Immediate Action: Phase 1 (Rebrand)
**Feasibility:** ⭐⭐⭐⭐⭐ (5/5)
**Effort:** Low (docs only)
**Impact:** High (better UX, sets foundation)

**Decision:** ✅ **Proceed immediately** - Update all documentation to use "shortcuts" language.

### Short-term: Phase 2 (Add Hardcoded Shortcuts)
**Feasibility:** ⭐⭐⭐⭐⭐ (5/5)
**Effort:** Medium (n8n workflow changes)
**Impact:** Medium (more power-user features)

**Decision:** ⏸️ **Wait for user feedback** - Only add if users request specific shortcuts after 1 month of usage.

### Long-term: Phase 3 (User-Configurable)
**Feasibility:** ⭐⭐⭐⭐☆ (4/5)
**Effort:** High (schema + workflow + commands)
**Impact:** High (ultimate flexibility)

**Decision:** ⏸️ **Wait for demand** - Only implement if 3+ users explicitly request custom shortcuts.

---

## Appendix: Shortcut Naming Ideas

### Potential Future Shortcuts
```
$$  → Fact note (external knowledge)
%%  → Quick log (activity + note)
@@  → Mention/reference (cross-reference)
##  → Goal (todo with is_goal=true)
&&  → Context (attach to previous activity)
**  → Highlight (important note/activity)
~~  → Scratch (temporary note, auto-void in 24h)
==  → Checkpoint (milestone activity)
```

### Reserved for System
```
!   → Activity prefix (!! is shortcut)
.   → Note prefix (.. is shortcut)
+   → Thread prefix (++ is shortcut)
:   → Command prefix (:: is shortcut)
```

### Available for Users
```
$, %, @, #, &, *, ~, =, ^, |, <, >, ?
```

All two-character combinations of these are available for custom shortcuts.
