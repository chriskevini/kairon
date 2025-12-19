# Route_Message Architecture Refactor

## Problem Statement

Current Route_Message.json has architectural issues:
1. ❌ **Writes events** (should only classify intent - separation of concerns)
2. ❌ **Routes by `tag`** (should route by `intent` after classification)
3. ❌ **No multi-extraction** (planned for root channel messages)
4. ❌ **Mixes concerns** (event ingestion + intent classification + routing)

## Correct Architecture

### Separation of Concerns

**1. Route_Discord_Event.json** (Webhook entry point)
- Receives Discord webhook
- Parses message payload
- Detects tag shortcuts (deterministic)
- **Writes to events table** with idempotency
- Calls Route_Message subworkflow

**2. Route_Message.json** (Intent classification - TRACE STEP)
- Receives event object
- If tag exists → Set intent = tag (fast path)
- If no tag → LLM classification (create trace)
- Returns `{ ...event, intent: '!!' | '..' | '++' | '::' | '$$' }`
- **Does NOT write to events** (that's Route_Discord_Event's job)

**3. Route by Intent** (In Route_Discord_Event)
- After Route_Message returns intent
- Switch on `intent` field (not `tag`)
- Route to appropriate handler subworkflow

### Multi-Extraction Flow

**For root channel messages (no tag):**

```
Route_Discord_Event
  ↓ Write event
  ↓ Detect: no tag, not in thread
  ↓
Multi_Extract (NEW workflow)
  ↓ Single LLM call returns:
  {
    "activity": { category, description, confidence },
    "note": { category, text },
    "todo": { description, priority }
  }
  ↓ Create 3 traces (activity_extraction, note_extraction, todo_extraction)
  ↓ Write 3 projections in parallel
  ↓ React with combined emoji (🔘📝✅)
```

**For tagged messages (shortcuts):**

```
Route_Discord_Event
  ↓ Write event
  ↓ Detect: tag = '!!'
  ↓
Route_Message → Returns intent='!!'
  ↓
Execute: Save_Activity
  ↓ Extract ONLY activity
  ↓ Create 1 trace (activity_extraction)
  ↓ Write 1 projection
  ↓ React with 🔘
```

## New Workflow Structure

### Route_Discord_Event.json (Entry point)
```
1. Webhook Trigger
2. Parse Discord Payload
3. Build Event Object
4. Detect Tag (deterministic: !!, .., ++, ::, $$, or null)
5. Store Event (INSERT INTO events)
6. Add event_id to context
7. IF tag exists:
     Set intent = tag (fast path)
   ELSE IF in_thread:
     Set intent = '++' (thread message)
   ELSE:
     Call Multi_Extract workflow (multi-extraction)
8. Switch on intent:
     '!!' → Execute: Save_Activity
     '..' → Execute: Save_Note
     '++' → Execute: Start_Chat
     '::' → Execute: Execute_Command
     '$$' → Execute: Save_Todo (future)
     null → Execute: Multi_Extract
```

### Multi_Extract.json (NEW - Multi-extraction)
```
1. Execute Workflow Trigger (receives event)
2. Call LLM: Multi-Extraction Prompt
3. Parse JSON Response:
   {
     "activity": {...} or null,
     "note": {...} or null,
     "todo": {...} or null
   }
4. Create Traces (in parallel):
   - IF activity: Create activity_extraction trace
   - IF note: Create note_extraction trace
   - IF todo: Create todo_extraction trace
5. Write Projections (in parallel):
   - IF activity: Write to projections (type=activity)
   - IF note: Write to projections (type=note)
   - IF todo: Write to projections (type=todo)
6. React with Combined Emoji:
   - activity → 🔘
   - note → 📝
   - todo → ✅
   - Combine: 🔘📝✅ (or subset)
```

### Route_Message.json (DEPRECATED - Remove)
- Current version mixes concerns
- Replace with intent detection in Route_Discord_Event
- Or simplify to ONLY LLM classification (return intent, no routing)

## Intent Field vs Tag Field

**After refactor:**

- **`tag`** (in events.payload) - User-provided shortcut (deterministic)
  - Values: '!!', '..', '++', '::', '$$', or null
  - Never changes, reflects what user typed

- **`intent`** (derived during routing) - Classified intent (LLM or tag)
  - Values: '!!', '..', '++', '::', '$$', 'multi' (multi-extraction)
  - Used for routing decisions
  - Can differ from tag if LLM classified

**Example:**
```javascript
// User message: "working on the router"
{
  tag: null,           // No tag provided
  intent: '!!'         // LLM classified as activity
}

// User message: "!! working on the router"
{
  tag: '!!',           // User provided tag
  intent: '!!'         // Fast path, no LLM needed
}
```

## Migration Path

### Phase 1: Create Multi_Extract workflow (NEW)
- Implement multi-extraction LLM prompt
- Create traces for each extraction type
- Write projections in parallel
- Test with untagged root channel messages

### Phase 2: Refactor Route_Discord_Event (MODIFY)
- Move event writing from Route_Message to Route_Discord_Event
- Add intent detection logic (tag fast path vs multi-extraction)
- Update switch to route by `intent` (not `tag`)
- Call Multi_Extract for untagged root channel messages

### Phase 3: Simplify Route_Message (OPTIONAL)
- Option A: Delete entirely (intent detection in Route_Discord_Event)
- Option B: Keep as LLM-only classifier (for future use)

### Phase 4: Fix Route_Reaction (URGENT)
- Update to write to `events` table (not raw_events)
- Use same event structure as Route_Discord_Event

## Benefits

✅ **Separation of concerns** - Event writing separate from intent classification  
✅ **Single LLM call** - Multi-extraction reduces cost/latency  
✅ **Trace accuracy** - Each extraction creates proper trace  
✅ **Tag shortcuts work** - Fast path bypasses multi-extraction  
✅ **Extensible** - Easy to add new extraction types (todos, goals, etc.)  
✅ **Correct schema usage** - Events written by entry point, traces by handlers  

## Open Questions

1. **Multi-extraction prompt design** - What JSON schema?
2. **Emoji combination** - How to show multiple extractions? (🔘📝✅ vs separate reactions?)
3. **Confidence thresholds** - Skip extraction if confidence < X?
4. **Partial failures** - What if LLM returns activity but not note?
5. **Thread messages** - Never multi-extract in threads? (Correct - only on save)

## Timeline

- [ ] Phase 1: Create Multi_Extract workflow (2-3 hours)
- [ ] Phase 2: Refactor Route_Discord_Event (1-2 hours)
- [ ] Phase 3: Clean up Route_Message (30 min)
- [ ] Phase 4: Fix Route_Reaction (30 min)
- [ ] Testing: End-to-end validation (1 hour)

**Total: ~6 hours of focused work**

---

**Next Steps:** Implement Phase 1 (Multi_Extract workflow) to validate architecture before refactoring existing workflows.
