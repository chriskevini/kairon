# Implementation Decision: Store Reactions as Raw Events

## Executive Summary

**Decision: Implement Option B with enhanced lineage tracking**

Store emoji reactions as first-class raw events in the `raw_events` table, maintaining the NOT NULL constraint on `notes.raw_event_id` while establishing clear audit trails for thread extraction saves.

## Core Principle

The fundamental question is not "are reactions messages?" but rather: **"Did a user perform a discrete action that caused system state to change?"**

The answer is unambiguously **yes**. An emoji reaction on a thread summary is:
- A user-initiated action with clear intent ("save this extraction")
- A timestamped event with an identifiable actor
- The **direct causal trigger** for note creation
- Part of Discord's official event model (`MESSAGE_REACTION_ADD`)

Therefore, reactions are raw events and belong in the `raw_events` table.

## Why This Is The Only Valid Choice

### 1. Traceability Follows Causality

The `notes.raw_event_id` field should point to **the event that caused the note to exist**, not the upstream conversational substrate.

**The 5-Year Audit Test:**
In 2029, when examining a note, we need to answer:
- **Who** saved this extraction? 
- **When** did they save it?
- **What exact action** did they take?
- **Which specific extraction** was saved?

| Option | Audit Quality |
|--------|---------------|
| **A (nullable)** | ❌ "It came from a thread... somehow. No actor or timestamp." |
| **C (link to `--`)** | ❌ "Someone requested a summary. But who saved what?" |
| **B (reaction)** | ✅ "User `alice` reacted 1️⃣ on message `123456` at `2025-06-17T14:32:00Z`" |

### 2. The NOT NULL Constraint Is Correct

Making `raw_event_id` nullable weakens the core invariant: **"Every piece of derived data has a traceable origin."**

This constraint encodes business logic. Don't weaken the constraint—fix the event capture.

### 3. Semantic Validity

`raw_events` is an **append-only audit log of external events**, not a "messages table." Reactions are:
- User-generated
- Timestamped
- Attributable
- Meaningful state transitions

This is exactly what belongs in an audit log.

### 4. Legal and Forensic Integrity

In an event-sourced system, falsifying provenance is unacceptable. Options A and C would:
- Create "orphan" data with no traceable source (Option A)
- Misattribute actions (Option C: attributing saves to whoever requested the summary)
- Violate the append-only audit principle

## Implementation Strategy

### Phase 1: Store Reactions as Raw Events

#### Idempotency Key Design

Use a **deterministic, timestamp-free** key to ensure idempotent processing:

```
discord_message_id = "reaction_{summary_msg_id}_{user_id}_{emoji}_{item_index}"
```

**Why this structure:**
- `summary_msg_id`: The message being reacted to
- `user_id`: Who performed the action
- `emoji`: Which reaction (📌, 1️⃣, 2️⃣, etc.)
- `item_index`: Which extraction (1, 2, 3, etc.) - derived from emoji mapping

**Avoid timestamps** in the idempotency key—they can vary across retries and break deduplication.

#### Raw Events Schema Mapping

```sql
INSERT INTO raw_events (
  id,
  source_type,
  discord_message_id,   -- synthetic idempotency key
  author_login,          -- user who clicked the reaction
  thread_id,             -- thread where summary was posted
  raw_text,              -- the emoji: '1️⃣', '2️⃣', etc.
  clean_text,            -- human-readable: "Save extraction 1 as reflection"
  tag,                   -- '📌' or new tag 'REACTION'
  metadata               -- full reaction payload for forensics
) VALUES (
  gen_random_uuid(),
  'discord',
  'reaction_88273_alice_1️⃣_1',
  'alice',
  'thread_555',
  '1️⃣',
  'Save extraction 1 as reflection',
  'REACTION',
  jsonb_build_object(
    'event_type', 'MESSAGE_REACTION_ADD',
    'summary_message_id', '88273',
    'emoji_name', '1️⃣',
    'extraction_index', 1,
    'is_reaction', true
  )
) ON CONFLICT (discord_message_id) DO NOTHING
RETURNING *;
```

### Phase 2: Link Notes to Reaction Events

```sql
INSERT INTO notes (
  id,
  raw_event_id,          -- points to the reaction event
  timestamp,
  category,              -- 'reflection', 'fact', etc.
  text,
  metadata
) VALUES (
  gen_random_uuid(),
  :reaction_raw_event_id,
  NOW(),
  'reflection',
  'I need to improve my sleep schedule',
  jsonb_build_object(
    'conversation_id', :conv_id,
    'thread_extraction_id', :extraction_id,
    'summary_message_id', :summary_msg_id,
    'saved_from', 'thread_extraction',
    'extraction_index', 1
  )
);
```

### Phase 3: Complete Lineage Chain

The full data lineage becomes:

```
Conversation Messages (raw_events with tag='++')
    ↓
Thread Extractions (thread_extractions table - staging)
    ↓
Reaction Event (raw_events with tag='REACTION')
    ↓
Saved Note (notes table)
```

**Querying the lineage:**

```sql
-- Find all notes created from reactions
SELECT n.*, re.*
FROM notes n
JOIN raw_events re ON n.raw_event_id = re.id
WHERE re.tag = 'REACTION'
  AND re.metadata->>'is_reaction' = 'true';

-- Find the original conversation for a note
SELECT n.text, 
       n.metadata->>'conversation_id' as conv_id,
       re.author_login as saved_by,
       re.timestamp as saved_at
FROM notes n
JOIN raw_events re ON n.raw_event_id = re.id
WHERE n.id = :note_id;
```

## Workflow Changes Required

### 1. Route_Reaction Workflow

**Add "Store Reaction Event" node before "Parse Emoji Save":**

```javascript
// Node: Store Reaction Event
// Type: Postgres

const event = $input.item.json;

// Map emoji to extraction index
const emojiMap = {
  '1️⃣': 1, '2️⃣': 2, '3️⃣': 3,
  '4️⃣': 4, '5️⃣': 5
};

const extractionIndex = emojiMap[event.emoji] || null;

// Create synthetic idempotency key
const messageId = event.message_id;
const userId = event.user_id;
const emoji = event.emoji;
const syntheticId = `reaction_${messageId}_${userId}_${emoji}_${extractionIndex}`;

const query = `
INSERT INTO raw_events (
  id,
  source_type,
  discord_message_id,
  author_login,
  thread_id,
  raw_text,
  clean_text,
  tag,
  metadata
) VALUES (
  gen_random_uuid(),
  'discord',
  $1,
  $2,
  $3,
  $4,
  $5,
  'REACTION',
  $6
)
ON CONFLICT (discord_message_id) DO NOTHING
RETURNING *;
`;

return {
  query,
  params: [
    syntheticId,
    event.author_login || event.user_id,
    event.thread_id,
    event.emoji,
    `Save extraction ${extractionIndex}`,
    JSON.stringify({
      event_type: 'MESSAGE_REACTION_ADD',
      summary_message_id: messageId,
      emoji_name: emoji,
      extraction_index: extractionIndex,
      is_reaction: true
    })
  ]
};
```

### 2. Save_Extraction Workflow

**Update "Save as Note" query to use reaction event:**

```sql
INSERT INTO notes (
  id,
  raw_event_id,
  timestamp,
  category,
  text,
  metadata
)
SELECT
  gen_random_uuid(),
  $1::uuid,  -- raw_event_id from upstream reaction event
  NOW(),
  $2::note_category,
  $3,
  jsonb_build_object(
    'conversation_id', $4,
    'thread_extraction_id', $5,
    'summary_message_id', $6,
    'saved_from', 'thread_extraction',
    'extraction_index', $7
  )
RETURNING *;
```

**Key change:** Pass the `raw_event_id` from the "Store Reaction Event" node output.

## Benefits of This Approach

### 1. Complete Audit Trail
Every note has verifiable provenance: actor, timestamp, exact action.

### 2. User Behavior Analysis
Can track which extractions get saved most often, by whom, when.

### 3. Idempotent Processing
Same reaction processed twice = same note once (via synthetic discord_message_id).

### 4. Future Extensibility
Pattern can be reused for other reaction-based features (delete via ❌, edit via ✏️, etc.).

### 5. Multi-User Support
Different users can save the same extraction → different raw_events → different notes.

### 6. System Integrity
Maintains all NOT NULL constraints and append-only principles.

## Addressing Concerns

### "Reactions aren't messages"

**Refutation:** `raw_events` captures **external events**, not just messages. The table already handles:
- User messages (tagged and untagged)
- Cron events (`source_type='cron'`)
- Now: reaction events

The semantic mismatch is resolved by recognizing reactions as first-class user commands.

### "Adds complexity"

**Refutation:** The complexity is ~20 lines of code in Route_Reaction. The alternative is:
- Broken lineage (Option A)
- Data corruption (Option C)
- Technical debt that compounds over time

The added complexity is necessary and minimal.

### "What about reaction removals?"

**Handled:** Reaction removals generate separate events (`MESSAGE_REACTION_REMOVE`). These can be:
- Stored as separate raw_events (tag='REACTION_REMOVE')
- Used to trigger note deletion or archival
- Ignored if the note should persist after un-reacting

The append-only log preserves both addition and removal.

## Future Enhancements (Optional)

### Option 1: Add event_type Field

```sql
ALTER TABLE raw_events 
ADD COLUMN event_type TEXT;

-- Values: 'message', 'reaction_add', 'reaction_remove', 'cron_tick'
```

This makes event types explicit without breaking existing queries.

### Option 2: Explicit Lineage Tables

For more complex lineage queries, add join tables:

```sql
-- Links extractions to source conversation messages
CREATE TABLE thread_extraction_sources (
  thread_extraction_id UUID REFERENCES thread_extractions(id),
  raw_event_id UUID REFERENCES raw_events(id),
  PRIMARY KEY (thread_extraction_id, raw_event_id)
);

-- Links notes to their source extractions
CREATE TABLE note_sources (
  note_id UUID REFERENCES notes(id),
  thread_extraction_id UUID REFERENCES thread_extractions(id),
  PRIMARY KEY (note_id, thread_extraction_id)
);
```

This enables queries like: "Show all conversation messages that contributed to this note."

## Implementation Checklist

- [ ] Add "Store Reaction Event" node to Route_Reaction workflow
- [ ] Update Save_Extraction to accept `raw_event_id` parameter
- [ ] Test idempotency: same reaction twice → one note
- [ ] Test multi-user: two users save same extraction → two notes
- [ ] Verify lineage queries work
- [ ] Update documentation
- [ ] Deploy workflows to n8n
- [ ] End-to-end test with real Discord reactions

## Conclusion

**Option B is the only architecturally sound choice.** It:
- Maintains data integrity (NOT NULL constraint)
- Provides complete audit trails
- Handles edge cases correctly
- Scales to future features
- Respects the event-sourced design

The "added complexity" is negligible compared to the permanent integrity and traceability gained.

---

**Implementation begins now.**
