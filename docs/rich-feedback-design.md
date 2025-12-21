# Rich Feedback Design

## Overview

Allow users to provide feedback on any bot message by simply replying with a thumbs up/down and optional reason text.

**Example:**
```
[Bot] You've been focused for 3 hours. Take a break?
[User] 👎 too robotic, I was in flow state
```

## User Experience

### Input Format
- Reply to any bot message
- Include 👍 or 👎 (anywhere in message)
- Optional: include reason text

### Examples
```
👍                          → score: 1.0, reason: null
👎 too robotic              → score: 0.0, reason: "too robotic"
👍 this was helpful         → score: 1.0, reason: "this was helpful"
good one 👍                 → score: 1.0, reason: "good one"
```

### Bot Response
- Acknowledge with reaction (✅) on user's feedback message
- No reply message (low noise)

## Implementation

### Routing (Route_Message.json)

Detect feedback in existing message routing:

```javascript
// In Route_Message, after tag parsing
const isReply = !!ctx.event.reference_message_id;
const hasFeedbackEmoji = /👍|👎/.test(ctx.event.clean_text);

if (isReply && hasFeedbackEmoji) {
  // Check if replying to bot message
  // Route to Handle_Feedback workflow
}
```

**Detection criteria:**
1. Message is a reply (`reference_message_id` present)
2. Contains 👍 or 👎
3. Replying to a bot message (author is Kairon)

### Parsing (Handle_Feedback.json)

```javascript
// Parse feedback from message
const text = ctx.event.clean_text;

// Extract score
let score = null;
if (text.includes('👍')) score = 1.0;
if (text.includes('👎')) score = 0.0;

// Extract reason (remove emoji, trim)
const reason = text
  .replace(/👍|👎/g, '')
  .trim() || null;

return { score, reason };
```

### Storage

#### Primary: Events Table

Store as `event_type: 'user_feedback'` (follows `user_correction` pattern):

```javascript
// Event payload
{
  // Standard event fields
  discord_message_id: '...',
  channel_id: '...',
  author_login: 'chr15',
  clean_text: '👎 too robotic',
  
  // Reference to rated message
  target_message_id: '1452322304683020460',
  
  // Parsed feedback
  score: 0.0,
  reason: 'too robotic',
  
  // Denormalized projection data (for query efficiency)
  target_projection_id: '8283487d-7356-4431-a36c-f7dcab354ade',  // null if no projection
  target_projection_type: 'nudge',  // null if no projection
  target_projection_data: { ... }   // snapshot of projection at feedback time
}
```

#### Secondary: Update Projection

Also update the projection for quick access to latest rating:

```sql
UPDATE projections SET
  quality_score = $score,
  metadata = metadata || jsonb_build_object(
    'last_feedback_reason', $reason,
    'last_feedback_event_id', $event_id,
    'last_feedback_at', NOW()
  )
WHERE id = $target_projection_id;
```

### Lookup Target Projection

The rated message could be:
1. **User message** → projections linked via `events.payload->>'discord_message_id'`
2. **Bot reply** → projections with `data->>'discord_message_id'` or `metadata->>'message_id'`

```sql
-- Find projection(s) for a discord message
WITH target AS (
  -- Option 1: User message that created projections
  SELECT p.id, p.projection_type, p.data
  FROM projections p
  JOIN events e ON p.event_id = e.id
  WHERE e.payload->>'discord_message_id' = $target_message_id
    AND p.status IN ('auto_confirmed', 'confirmed')
  
  UNION
  
  -- Option 2: Bot reply message
  SELECT p.id, p.projection_type, p.data
  FROM projections p
  WHERE p.data->>'discord_message_id' = $target_message_id
     OR p.metadata->>'message_id' = $target_message_id
    AND p.status IN ('auto_confirmed', 'confirmed')
)
SELECT * FROM target LIMIT 1;
```

### Query Patterns

```sql
-- All feedback for a projection type
SELECT 
  payload->>'reason' as reason,
  payload->>'score' as score,
  payload->>'target_projection_data' as projection,
  received_at
FROM events
WHERE event_type = 'user_feedback'
  AND payload->>'target_projection_type' = 'nudge'
ORDER BY received_at DESC;

-- Feedback aggregates by type
SELECT 
  payload->>'target_projection_type' as type,
  COUNT(*) as total,
  AVG((payload->>'score')::numeric) as avg_score,
  COUNT(*) FILTER (WHERE payload->>'reason' IS NOT NULL) as with_reason
FROM events
WHERE event_type = 'user_feedback'
GROUP BY payload->>'target_projection_type';

-- Recent negative feedback with reasons
SELECT 
  payload->>'target_projection_type' as type,
  payload->>'reason' as reason,
  payload->>'target_projection_data' as what_was_rated,
  received_at
FROM events
WHERE event_type = 'user_feedback'
  AND (payload->>'score')::numeric = 0
  AND payload->>'reason' IS NOT NULL
ORDER BY received_at DESC
LIMIT 20;
```

## Workflow: Handle_Feedback

```
[Execute Workflow Trigger] "Receive Event"
         │
         ▼
[Code] "Parse Feedback"
  - Extract score (👍=1.0, 👎=0.0)
  - Extract reason (text minus emoji)
         │
         ▼
[Postgres] "Lookup Target Projection"
  - Find projection by target_message_id
  - Returns: id, type, data (or null)
         │
         ▼
[Code] "Build Event Payload"
  - Combine ctx.event + parsed feedback + projection data
         │
         ▼
[Postgres] "Store Feedback Event"
  - INSERT INTO events (event_type='user_feedback', payload=...)
         │
         ▼
[IF] "Has Projection?"
  ├─ Yes ─► [Postgres] "Update Projection Quality"
  │              │
  │              ▼
  └─ No ──► [Merge]
         │
         ▼
[Discord] "Add Reaction"
  - Add ✅ to feedback message
  - Fire-and-forget acknowledgment
```

## Migration from Simple Rating

The existing 👍/👎 reaction workflow (Handle_Quality_Rating) can remain for:
- Quick rating without opening keyboard
- Rating when you don't have a reason

Rich feedback is complementary:
- Use reaction for quick binary signal
- Use reply for feedback with context

No migration needed - both patterns coexist.

## Edge Cases

### No projection found
- Still store the feedback event (target_projection_id = null)
- Useful for feedback on error messages, help text, etc.

### Multiple projections for message
- Take the first one (most recent)
- Or: update all projections for that message

### User edits feedback
- Treat as new feedback event (immutable log)
- Latest feedback overwrites projection.quality_score

### Duplicate feedback
- Each reply creates new event (history preserved)
- Projection always has latest score

## Future Enhancements

1. **Feedback categories** - Parse keywords like "timing", "tone", "relevance"
2. **Feedback summary command** - `::feedback nudge` shows recent feedback
3. **Auto-improve prompts** - Use negative feedback to tune prompts
4. **Feedback acknowledgment** - Optional reply thanking for feedback

## Files to Create/Modify

1. **n8n-workflows/Handle_Feedback.json** - New workflow
2. **n8n-workflows/Route_Message.json** - Add feedback detection and routing
3. **discord_relay.py** - Ensure `reference_message_id` is captured (if not already)
