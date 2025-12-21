# Problem: What raw_event_id Should Thread Extraction Notes Use?

## ⚠️ STATUS: RESOLVED

**Decision: Option B - Store reactions as raw_events**

See full implementation: `docs/synthesis-raw-event-id-implementation.md`

---

## Original Problem Statement

## Context

We're building a life OS that captures Discord messages as `raw_events` (append-only audit log) and derives structured data (notes, activities, todos) from them. The `notes` table has a `NOT NULL` constraint on `raw_event_id` for traceability.

## The Issue

When users save thread extractions as notes, we don't have an obvious raw_event_id to use:

1. **Thread extractions are synthesized knowledge**: An LLM analyzes an entire conversation (multiple messages) and extracts insights like "reflection: I'm focusing on improving my sleep schedule" 
2. **The save action is an emoji reaction**: User reacts with 📌 on a summary message to save an extraction
3. **Current system has a traceability gap**: Reaction events are NOT stored in raw_events

## Database Schema

```sql
-- Append-only audit log
CREATE TABLE raw_events (
  id UUID PRIMARY KEY,
  source_type TEXT NOT NULL CHECK (source_type IN ('discord', 'cron')),
  discord_message_id TEXT UNIQUE, -- idempotency key
  author_login TEXT,
  thread_id TEXT,
  raw_text TEXT NOT NULL,
  clean_text TEXT NOT NULL,
  tag TEXT  -- '!!', '++', '::', etc.
);

-- Derived structured data
CREATE TABLE notes (
  id UUID PRIMARY KEY,
  raw_event_id UUID NOT NULL REFERENCES raw_events(id),  -- ⚠️ NOT NULL!
  timestamp TIMESTAMPTZ NOT NULL,
  category note_category NOT NULL,  -- 'reflection' or 'fact'
  text TEXT NOT NULL,
  metadata JSONB  -- can store conversation_id, from_thread flag
);

-- Thread extraction staging (before user saves)
CREATE TABLE thread_extractions (
  id UUID PRIMARY KEY,
  conversation_id UUID NOT NULL REFERENCES conversations(id),
  item_type TEXT NOT NULL CHECK (item_type IN ('reflection', 'fact', 'todo')),
  text TEXT NOT NULL,  -- LLM-extracted insight
  display_order INTEGER NOT NULL,
  saved_as TEXT,  -- 'note' or 'todo' after user saves
  saved_id UUID,  -- references notes.id or todos.id
  summary_message_id TEXT  -- Discord message showing extractions
);
```

## Current Flow

1. User starts thread: `++ what should I focus on today?`
2. Conversation happens (multiple messages, all stored as raw_events)
3. User sends `--` (save thread) - triggers LLM analysis
4. LLM extracts insights from entire conversation → stores in `thread_extractions`
5. Bot posts summary message to Discord with numbered items
6. User reacts with 1️⃣ emoji to save first extraction
7. **Reaction triggers note creation** → ⚠️ What raw_event_id should we use?

## Three Options

### Option A: Make raw_event_id nullable
**Rationale**: Thread extractions aren't derived from a single event, but from entire conversations.
- ✅ Accurately models that extractions have no single source event
- ✅ Can use metadata.conversation_id to link back to source thread
- ❌ **Breaks traceability**: No direct link to WHO saved WHAT and WHEN
- ❌ Undermines the entire point of append-only raw_events
- ❌ Future queries lose audit trail for note creation

### Option B: Store reaction as raw_event
**Rationale**: The emoji reaction IS a Discord event that triggers the save action.
- Create synthetic discord_message_id: `{msg_id}_reaction_{emoji}_{user_id}_{timestamp}`
- Store with: `source_type='discord'`, `raw_text=emoji`, `clean_text='Save extraction'`
- ✅ **Perfect traceability**: WHO saved, WHAT emoji, WHEN it happened
- ✅ Maintains NOT NULL constraint and audit principles
- ✅ reaction + metadata.conversation_id = complete lineage
- ❌ Reactions aren't traditional "messages" (semantic mismatch?)
- ❌ Adds complexity to Route_Reaction workflow

### Option C: Link to the `--` tag message
**Rationale**: The `--` message initiated the save process.
- ✅ Links to actual user message event
- ❌ **Breaks traceability**: The `--` tag doesn't tell us which extraction was saved
- ❌ Multiple extractions would reference same raw_event_id
- ❌ Doesn't capture WHO performed the save action (could be different user)

## Design Principles

1. **Append-only audit log**: raw_events should capture ALL significant user actions
2. **Traceability**: Every derived data point should link to its source event
3. **Idempotency**: Reprocessing same event should produce same result
4. **Data integrity**: Constraints should reflect business logic

## Question

**Which option should we implement, and why?** 

Provide a firm conclusion with strong arguments. Consider:
- Does the emoji reaction count as a "raw event" semantically?
- Is perfect traceability worth the added complexity?
- Are there better alternatives not listed here?
- What would a 5-year audit of this system need?
