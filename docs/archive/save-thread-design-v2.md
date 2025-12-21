# Save Thread (--) Feature Design v2

## Updated Based on Feedback

**Key Changes:**
- ✅ Emoji reaction UI instead of text commands
- ✅ Summary posts to channel root (not in thread)
- ✅ 🗑️ emoji deletes Discord thread (clean closure)
- ✅ LLM determines fact vs reflection per item
- ✅ No `-- done` command (use 🗑️ instead)
- ✅ Simplified summary format

---

## Workflow Naming Convention

```
Activity_Handler → Save_Activity
Note_Handler → Save_Note
Command_Handler → Execute_Command
Thread_Handler → Start_Thread
Thread_Continuation_Agent → Continue_Thread
(new) Save_Thread_Handler → Save_Thread
```

---

## User Flow

### 1. User Sends `--` in Thread

```
User: "--"
Bot: 💭 (thinking emoji in thread)
Bot: (posts summary to channel root)
```

### 2. Summary Message (in channel root)

```markdown
📊 Thread Summary from #morning-routines

💡 Insights & Decisions
1️⃣ User works better in mornings after coffee
2️⃣ Mom's birthday is June 12th  
3️⃣ Will switch to async communication

📋 Action Items
4️⃣ Block calendar for morning deep work
5️⃣ Draft async guidelines

---
Tap number emoji to save as note or todo
❌ Dismiss • 🗑️ Delete thread
```

**Bot adds reactions:** 1️⃣ 2️⃣ 3️⃣ 4️⃣ 5️⃣ ❌ 🗑️

### 3. User Reacts with Emoji

**Scenario A: Save specific items**
```
User: *clicks 1️⃣ 2️⃣ 4️⃣*
Bot: *removes those emojis from message*
Bot: *DMs user or edits message:*
     ✅ Saved:
     • Note: User works better in mornings after coffee
     • Note: Mom's birthday is June 12th
     • Todo: Block calendar for morning deep work
```

**Scenario B: Delete thread**
```
User: *clicks 🗑️*
Bot: *deletes Discord thread via API*
Bot: *updates DB: status='completed', deleted_at=NOW()*
Bot: *removes summary message from channel*
```

**Scenario C: Dismiss without saving**
```
User: *clicks ❌*
Bot: *removes summary message from channel*
Bot: *thread continues as normal*
```

---

## Database Schema

### Conversations Table (existing)
```sql
CREATE TABLE conversations (
  id uuid PRIMARY KEY,
  thread_id text NOT NULL UNIQUE,
  status text DEFAULT 'active',  -- active, completed, deleted
  topic text,
  deleted_at timestamptz,  -- NULL if not deleted
  created_at timestamptz DEFAULT NOW(),
  updated_at timestamptz DEFAULT NOW()
);
```

**Status values:**
- `active` - Thread is ongoing (default)
- `completed` - User extracted and deleted thread
- `deleted` - Thread deleted without extraction (rare)

### Thread Extractions Table (new)
```sql
CREATE TABLE thread_extractions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid REFERENCES conversations(id),
  extraction_type text NOT NULL,  -- 'insight', 'decision', 'action'
  note_category text,  -- 'fact', 'reflection', NULL for actions
  text text NOT NULL,
  display_order int NOT NULL,  -- 1, 2, 3, 4, 5...
  saved_as text,  -- 'note', 'todo', NULL
  saved_id uuid,  -- FK to notes or todos
  summary_message_id text,  -- Discord message ID of summary
  created_at timestamptz DEFAULT NOW()
);
```

**Why note_category column?**
- LLM determines fact vs reflection during extraction
- Stored so we know which category to use when saving

---

## Workflow: Save_Thread

### Trigger
- Router detects `--` tag in thread
- Executes Save_Thread workflow

### Node Flow

#### 1. Add Thinking Emoji (in thread)
```javascript
// React with 💭 on user's message
```

#### 2. Get Conversation
```sql
SELECT id, thread_id FROM conversations 
WHERE thread_id = $1 AND status = 'active';
```

#### 3. Get Thread History
```sql
SELECT role, text, timestamp 
FROM conversation_messages 
WHERE conversation_id = $1 
ORDER BY timestamp ASC;
```

**No limit - full conversation for best accuracy.**

#### 4. LLM Extraction Prompt

```markdown
You are analyzing a conversation thread to extract actionable items.

## Thread History
{paste full conversation - all messages}

## Task
Extract and categorize into 3 types:

1. **INSIGHT** - Key realizations, patterns, observations (about user OR others)
2. **DECISION** - Commitments, choices, resolutions
3. **ACTION** - Concrete todos, next steps

For each INSIGHT or DECISION, determine if it's:
- **fact** - External knowledge about the world/others (birthdays, preferences, facts about people)
- **reflection** - Internal knowledge about the user (insights, patterns, self-observations)

## Output Format
One item per line:

INSIGHT|reflection|User works better in mornings after coffee
INSIGHT|fact|Mom's birthday is June 12th
DECISION|reflection|Will switch to async communication
ACTION|Block calendar for morning deep work
ACTION|Draft async communication guidelines

## Rules
- Be specific and concrete
- Use user's own words when possible
- Only extract items explicitly discussed
- Max 10 items total
- ACTIONs don't need category (they become todos)
- Order by importance (most important first)
```

#### 5. Parse LLM Output
```javascript
const lines = llmOutput.split('\n').filter(line => line.trim());
const extractions = [];
let displayOrder = 1;

lines.forEach(line => {
  const parts = line.split('|').map(s => s.trim());
  
  if (parts[0] === 'ACTION') {
    // ACTION|text
    extractions.push({
      extraction_type: 'action',
      note_category: null,
      text: parts[1],
      display_order: displayOrder++
    });
  } else {
    // INSIGHT|category|text or DECISION|category|text
    extractions.push({
      extraction_type: parts[0].toLowerCase(),
      note_category: parts[1],  // 'fact' or 'reflection'
      text: parts[2],
      display_order: displayOrder++
    });
  }
});
```

#### 6. Store Extractions in DB
```sql
INSERT INTO thread_extractions (
  conversation_id,
  extraction_type,
  note_category,
  text,
  display_order,
  summary_message_id
) VALUES ($1, $2, $3, $4, $5, NULL)
RETURNING *;
```

#### 7. Build Summary Message
```javascript
const insights = extractions.filter(e => 
  e.extraction_type === 'insight' || e.extraction_type === 'decision'
);
const actions = extractions.filter(e => e.extraction_type === 'action');

let content = '📊 **Thread Summary**\n\n';

if (insights.length > 0) {
  content += '💡 **Insights & Decisions**\n';
  insights.forEach(item => {
    const emoji = getNumberEmoji(item.display_order);  // 1️⃣ 2️⃣ etc
    content += `${emoji} ${item.text}\n`;
  });
  content += '\n';
}

if (actions.length > 0) {
  content += '📋 **Action Items**\n';
  actions.forEach(item => {
    const emoji = getNumberEmoji(item.display_order);
    content += `${emoji} ${item.text}\n`;
  });
  content += '\n';
}

content += '---\n';
content += 'Tap number emoji to save as note or todo\n';
content += '❌ Dismiss • 🗑️ Delete thread';
```

#### 8. Post Summary to Channel Root
```javascript
// Discord API: Post to channel_id (NOT thread_id)
POST /channels/{channel_id}/messages
{
  "content": summaryMessage,
  "message_reference": {
    "message_id": threadStartMessageId  // References original thread
  }
}
```

#### 9. Add Emoji Reactions
```javascript
// Add number emojis for each extraction
extractions.forEach(item => {
  addReaction(summaryMessageId, getNumberEmoji(item.display_order));
});

// Add control emojis
addReaction(summaryMessageId, '❌');
addReaction(summaryMessageId, '🗑️');
```

#### 10. Update Extractions with Message ID
```sql
UPDATE thread_extractions 
SET summary_message_id = $1 
WHERE conversation_id = $2;
```

#### 11. Remove Thinking Emoji
```javascript
// Remove 💭 from user's message
DELETE /channels/{thread_id}/messages/{message_id}/reactions/💭/@me
```

---

## Workflow: Handle_Extraction_Reaction

### Trigger
- Discord webhook: `MESSAGE_REACTION_ADD` event
- Filter: Only reactions on messages with thread_extractions

### Node Flow

#### 1. Check if Reaction is on Summary Message
```sql
SELECT * FROM thread_extractions 
WHERE summary_message_id = $1 
LIMIT 1;
```
- If not found: Ignore event

#### 2. Parse Reaction Type

**Case A: Number Emoji (1️⃣-🔟)**
```javascript
const emojiToNumber = {
  '1️⃣': 1, '2️⃣': 2, '3️⃣': 3, '4️⃣': 4, '5️⃣': 5,
  '6️⃣': 6, '7️⃣': 7, '8️⃣': 8, '9️⃣': 9, '🔟': 10
};

const displayOrder = emojiToNumber[reaction.emoji.name];
if (!displayOrder) return; // Not a number emoji
```

#### 3. Get Extraction Item
```sql
SELECT * FROM thread_extractions 
WHERE summary_message_id = $1 
  AND display_order = $2 
  AND saved_as IS NULL;  -- Only unsaved items
```

#### 4. Save Based on Type

**If extraction_type = 'action' → Save as Todo (when ready)**
```sql
INSERT INTO todos (text, status, metadata)
VALUES (
  $1, 
  'pending',
  jsonb_build_object('from_thread', true, 'conversation_id', $2)
)
RETURNING id;

UPDATE thread_extractions 
SET saved_as = 'todo', saved_id = $1 
WHERE id = $2;
```

**If extraction_type = 'insight' or 'decision' → Save as Note**
```sql
INSERT INTO notes (timestamp, category, text, metadata)
VALUES (
  NOW(),
  $1,  -- Use note_category from extraction ('fact' or 'reflection')
  $2,
  jsonb_build_object('from_thread', true, 'conversation_id', $3)
)
RETURNING id;

UPDATE thread_extractions 
SET saved_as = 'note', saved_id = $1 
WHERE id = $2;
```

#### 5. Remove Emoji from Summary
```javascript
// Remove the number emoji from summary message
DELETE /channels/{channel_id}/messages/{message_id}/reactions/{emoji}/@me
```

#### 6. Check if All Items Saved
```sql
SELECT COUNT(*) as unsaved 
FROM thread_extractions 
WHERE summary_message_id = $1 
  AND saved_as IS NULL;
```

**If all saved:**
```javascript
// Edit summary message to show completion
PATCH /channels/{channel_id}/messages/{message_id}
{
  "content": "✅ All items saved!\n\n🗑️ Delete thread • ❌ Dismiss"
}
```

---

**Case B: ❌ Dismiss**
```javascript
// Delete summary message
DELETE /channels/{channel_id}/messages/{message_id}

// Thread continues as normal, extractions not saved
```

---

**Case C: 🗑️ Delete Thread**

#### 1. Delete Discord Thread
```javascript
DELETE /channels/{thread_id}
```

#### 2. Update Database
```sql
UPDATE conversations 
SET status = 'completed', deleted_at = NOW() 
WHERE thread_id = $1;
```

#### 3. Delete Summary Message
```javascript
DELETE /channels/{channel_id}/messages/{summary_message_id}
```

---

## Discord Webhook Setup

### New Webhook: Reaction Events

Need to subscribe to `MESSAGE_REACTION_ADD`:

```javascript
// Discord bot intents
intents: [
  'GUILDS',
  'GUILD_MESSAGES',
  'MESSAGE_CONTENT',
  'GUILD_MESSAGE_REACTIONS'  // NEW
]
```

### Webhook Payload
```json
{
  "type": "MESSAGE_REACTION_ADD",
  "guild_id": "...",
  "channel_id": "...",
  "message_id": "...",
  "user_id": "...",
  "emoji": {
    "name": "1️⃣",
    "id": null  // null for unicode emojis
  }
}
```

---

## Edge Cases

### What if user reacts with wrong emoji?
- Ignore non-number emojis (except ❌ and 🗑️)
- No error message needed

### What if user reacts multiple times on same emoji?
- Discord sends multiple events
- Database check: `saved_as IS NULL` prevents double-save
- Idempotent

### What if Discord thread already deleted manually?
- API call fails gracefully
- Update DB anyway: `status='deleted'`

### What if extraction yields no items?
- LLM returns empty or "No items found"
- Bot responds: "No actionable items found in this thread. Continue the conversation or use `--` again later."

### What if user wants to re-extract?
- Check: If extractions exist for this conversation with unsaved items
- Show previous extraction
- To force re-extract: Delete old extractions first (not in MVP)

---

## Number Emoji Helper

```javascript
function getNumberEmoji(n) {
  const emojis = ['1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣', '🔟'];
  return emojis[n - 1] || '➕';  // Fallback for 11+
}

function emojiToNumber(emoji) {
  const map = {
    '1️⃣': 1, '2️⃣': 2, '3️⃣': 3, '4️⃣': 4, '5️⃣': 5,
    '6️⃣': 6, '7️⃣': 7, '8️⃣': 8, '9️⃣': 9, '🔟': 10
  };
  return map[emoji] || null;
}
```

---

## Implementation Phases

### Phase 1: Emoji Reaction UI (MVP)
- [ ] Rename workflows (Activity_Handler → Save_Activity, etc.)
- [ ] Save_Thread workflow
  - [ ] Extract thread history
  - [ ] LLM extraction (type + category per item)
  - [ ] Post summary to channel root
  - [ ] Add number emojis + control emojis
- [ ] Handle_Extraction_Reaction workflow
  - [ ] Listen for MESSAGE_REACTION_ADD
  - [ ] Parse emoji → display_order
  - [ ] Save to notes (with dynamic category)
  - [ ] Remove emoji from summary
- [ ] 🗑️ Delete thread functionality
  - [ ] Discord API: DELETE thread
  - [ ] Update DB: status='completed'
- [ ] ❌ Dismiss functionality
  - [ ] Delete summary message

### Phase 2: Todo Integration
- [ ] Migration 003 (todos table)
- [ ] Save ACTION items as todos
- [ ] Todo status tracking in separate workflow

### Phase 3: Polish
- [ ] ✅ Show "All items saved!" when complete
- [ ] Handle 11+ items (pagination or limit to 10)
- [ ] Re-extraction support (clear old extractions)
- [ ] Thread stats in ::stats command

---

## Open Questions - ANSWERED

1. **Category for thread-derived notes:** ~~Always reflection?~~
   - **ANSWER:** LLM decides per item (fact vs reflection)
   - Thread can contain both external and internal knowledge

2. **Should `-- done` be required?**
   - **ANSWER:** No, use 🗑️ emoji instead (better UX)

3. **Should we show thread stats in `::stats`?**
   - **ANSWER:** No, Discord UI already shows active threads prominently

4. **Extraction context:**
   - **ANSWER:** Full conversation, no limit (best accuracy)

5. **Summary location:**
   - **ANSWER:** Channel root (not in thread) - cleaner, more visible

6. **Already-saved tracking:**
   - **ANSWER:** Remove from MVP (can't rely on string equality)

---

## Summary of Changes from v1

| Feature | v1 | v2 |
|---------|----|----|
| **Save UI** | Text commands (`-- note 1 3`) | Emoji reactions (click 1️⃣) |
| **Summary location** | Inside thread | Channel root |
| **Thread closure** | `-- done` command | 🗑️ emoji deletes thread |
| **Note category** | Always reflection | LLM decides per item |
| **Already-saved** | Show ✅ marks | Removed (can't detect) |
| **Stats** | Show active threads | Removed (Discord UI sufficient) |
| **Extraction limit** | 10-20 messages | Full conversation |

Much cleaner UX! 🎉
