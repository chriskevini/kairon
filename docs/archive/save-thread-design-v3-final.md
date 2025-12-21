# Save Thread Design v3 - Final

## Simplified: Native Data Types Only

**Key insight:** Don't store intermediate types (insight/decision/action).
Map directly to our native types: `reflection`, `fact`, `todo`.

---

## Workflow Architecture

```
Discord Webhooks:
├─ MESSAGE_CREATE → Discord_Message_Router
│   ├─→ !! → Save_Activity
│   ├─→ .. → Save_Note
│   ├─→ ++ → Start_Thread / Continue_Thread
│   ├─→ -- → Save_Thread
│   └─→ :: → Execute_Command
│
└─ MESSAGE_REACTION_ADD → Emoji_Reaction_Router (NEW)
    ├─→ On summary message → Handle_Extraction_Save
    ├─→ On other messages → [future handlers]
    └─→ Else → Ignore
```

---

## Database Schema

### Thread Extractions Table
```sql
CREATE TABLE thread_extractions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid REFERENCES conversations(id),
  item_type text NOT NULL,  -- 'reflection', 'fact', 'todo'
  text text NOT NULL,
  display_order int NOT NULL,  -- 1, 2, 3, 4...
  saved_as text,  -- 'note', 'todo', NULL
  saved_id uuid,  -- FK to notes or todos table
  summary_message_id text,  -- Discord message ID
  created_at timestamptz DEFAULT NOW()
);
```

**Simplified!** 
- `item_type` maps directly to our data model
- `reflection` and `fact` → save as notes
- `todo` → save as todos

---

## Workflow: Save_Thread

### LLM Extraction Prompt

```markdown
You are analyzing a conversation thread to extract actionable items.

## Thread History
{full conversation - no limit}

## Task
Classify each item into ONE of these types:

**reflection** - Internal knowledge about the user
- Personal insights, patterns, self-observations
- Decisions, commitments, resolutions made
- Examples:
  • I work better in mornings after coffee
  • I've decided to switch to async communication
  • I feel more focused after 20-minute walks
  • Deep work requires 2+ hour blocks

**fact** - External knowledge about the world or others
- Information about other people (preferences, birthdays, allergies)
- Factual statements about things/places
- Examples:
  • Mom's birthday is June 12th
  • John prefers dark roast coffee
  • Sarah is allergic to nuts
  • Dad prefers evening phone calls

**todo** - Concrete action items
- Next steps, tasks to complete
- Must be actionable and specific
- Examples:
  • Block calendar for morning deep work
  • Draft async communication guidelines
  • Buy birthday gift for Mom
  • Schedule coffee with John

## Output Format
One item per line, format: type|text

reflection|I work better in mornings after coffee
fact|Mom's birthday is June 12th
reflection|Will switch to async communication
todo|Block calendar for morning deep work
todo|Draft async guidelines

## Rules
- Be specific and concrete
- Use user's own words when possible
- Only extract items explicitly discussed
- Max 10 items total
- Order by importance (most important first)
- If unsure between reflection and fact, choose reflection
```

### Parse LLM Output
```javascript
const lines = llmOutput.split('\n').filter(line => line.includes('|'));
const extractions = [];
let displayOrder = 1;

lines.forEach(line => {
  const [itemType, text] = line.split('|').map(s => s.trim());
  
  // Validate item_type
  if (!['reflection', 'fact', 'todo'].includes(itemType)) {
    console.error(`Invalid item_type: ${itemType}`);
    return;
  }
  
  extractions.push({
    conversation_id: conversationId,
    item_type: itemType,
    text: text,
    display_order: displayOrder++,
    saved_as: null,
    saved_id: null
  });
});
```

### Build Summary Message
```javascript
const notes = extractions.filter(e => 
  e.item_type === 'reflection' || e.item_type === 'fact'
);
const todos = extractions.filter(e => e.item_type === 'todo');

let content = '📊 **Thread Summary**\n\n';

if (notes.length > 0) {
  content += '💡 **Insights & Facts**\n';
  notes.forEach(item => {
    const emoji = getNumberEmoji(item.display_order);
    content += `${emoji} ${item.text}\n`;
  });
  content += '\n';
}

if (todos.length > 0) {
  content += '📋 **Action Items**\n';
  todos.forEach(item => {
    const emoji = getNumberEmoji(item.display_order);
    content += `${emoji} ${item.text}\n`;
  });
  content += '\n';
}

content += '---\n';
content += 'Tap number emoji to save\n';
content += '❌ Dismiss • 🗑️ Delete thread';
```

---

## Workflow: Emoji_Reaction_Router (NEW)

**Top-level router for all emoji reactions.**

### Trigger
- Discord webhook: `MESSAGE_REACTION_ADD`

### Node Flow

#### 1. Parse Webhook
```javascript
const event = {
  guild_id: $json.guild_id,
  channel_id: $json.channel_id,
  message_id: $json.message_id,
  user_id: $json.user_id,
  emoji: $json.emoji.name  // '1️⃣', '❌', '🗑️', etc.
};
```

#### 2. Check if Bot's Own Reaction
```javascript
if (event.user_id === BOT_USER_ID) {
  return;  // Ignore bot's own reactions
}
```

#### 3. Check Message Type

**Branch A: On Summary Message**
```sql
SELECT COUNT(*) as is_summary 
FROM thread_extractions 
WHERE summary_message_id = $1 
LIMIT 1;
```
- If `is_summary > 0` → Route to **Handle_Extraction_Save**

**Branch B: Other Message Types (future)**
```javascript
// Check for other reaction handlers
// Example: reaction on poll, reaction on question, etc.
// For now: ignore
```

**Branch C: Unknown Message**
```javascript
return;  // Ignore
```

---

## Workflow: Handle_Extraction_Save

**Handles reactions on summary messages.**

### Input
- `event` object from Emoji_Reaction_Router

### Node Flow

#### 1. Parse Emoji Type

**Case A: Number Emoji (1️⃣-🔟)**
```javascript
const emojiMap = {
  '1️⃣': 1, '2️⃣': 2, '3️⃣': 3, '4️⃣': 4, '5️⃣': 5,
  '6️⃣': 6, '7️⃣': 7, '8️⃣': 8, '9️⃣': 9, '🔟': 10
};

const displayOrder = emojiMap[event.emoji];
if (!displayOrder) {
  return;  // Not a number emoji, ignore
}

// Continue to save item...
```

#### 2. Get Extraction Item
```sql
SELECT * FROM thread_extractions 
WHERE summary_message_id = $1 
  AND display_order = $2 
  AND saved_as IS NULL
LIMIT 1;
```

- If not found: Already saved or invalid, ignore

#### 3. Save Based on item_type

**If item_type = 'reflection' or 'fact' → Save as Note**
```sql
INSERT INTO notes (timestamp, category, text, metadata)
VALUES (
  NOW(),
  $1,  -- item_type ('reflection' or 'fact')
  $2,  -- text
  jsonb_build_object('from_thread', true, 'conversation_id', $3)
)
RETURNING id;

UPDATE thread_extractions 
SET saved_as = 'note', saved_id = $1 
WHERE id = $2;
```

**If item_type = 'todo' → Save as Todo**
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

#### 4. Remove Emoji from Summary
```javascript
DELETE /channels/{channel_id}/messages/{message_id}/reactions/{emoji}/@me
```

#### 5. Check if All Items Saved
```sql
SELECT COUNT(*) as unsaved 
FROM thread_extractions 
WHERE summary_message_id = $1 
  AND saved_as IS NULL;
```

**If unsaved = 0:**
```javascript
PATCH /channels/{channel_id}/messages/{message_id}
{
  "content": "✅ All items saved!\n\n🗑️ Delete thread • ❌ Dismiss"
}
```

---

**Case B: ❌ Dismiss**
```javascript
DELETE /channels/{channel_id}/messages/{message_id}
// Thread continues, extractions not saved
```

---

**Case C: 🗑️ Delete Thread**

#### 1. Get Conversation ID
```sql
SELECT conversation_id FROM thread_extractions 
WHERE summary_message_id = $1 
LIMIT 1;
```

#### 2. Get Thread ID
```sql
SELECT thread_id FROM conversations WHERE id = $1;
```

#### 3. Delete Discord Thread
```javascript
DELETE /channels/{thread_id}
```

#### 4. Update Database
```sql
UPDATE conversations 
SET status = 'completed', deleted_at = NOW() 
WHERE id = $1;
```

#### 5. Delete Summary Message
```javascript
DELETE /channels/{channel_id}/messages/{message_id}
```

---

## Workflow Naming - Final

```
Old Name                    → New Name
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Activity_Handler            → Save_Activity
Note_Handler                → Save_Note
Command_Handler             → Execute_Command
Thread_Handler              → Start_Thread
Thread_Continuation_Agent   → Continue_Thread
(new)                       → Save_Thread
(new)                       → Emoji_Reaction_Router
(new)                       → Handle_Extraction_Save
```

---

## Migration: Add thread_extractions Table

```sql
-- Migration 004: Thread extractions
CREATE TABLE thread_extractions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid REFERENCES conversations(id) ON DELETE CASCADE,
  item_type text NOT NULL CHECK (item_type IN ('reflection', 'fact', 'todo')),
  text text NOT NULL,
  display_order int NOT NULL,
  saved_as text CHECK (saved_as IN ('note', 'todo', NULL)),
  saved_id uuid,
  summary_message_id text,
  created_at timestamptz DEFAULT NOW()
);

CREATE INDEX idx_thread_extractions_conversation 
  ON thread_extractions(conversation_id);

CREATE INDEX idx_thread_extractions_summary_message 
  ON thread_extractions(summary_message_id);
```

---

## Discord Bot Setup

### Add Reaction Intent

```python
# discord_relay.py
intents = discord.Intents.default()
intents.guilds = True
intents.messages = True
intents.message_content = True
intents.guild_reactions = True  # NEW
```

### Webhook Routes

```python
# Route MESSAGE_CREATE to main webhook
@bot.event
async def on_message(message):
    # Existing logic
    ...

# Route MESSAGE_REACTION_ADD to reaction webhook
@bot.event
async def on_reaction_add(reaction, user):
    payload = {
        "type": "MESSAGE_REACTION_ADD",
        "guild_id": str(reaction.message.guild.id),
        "channel_id": str(reaction.message.channel.id),
        "message_id": str(reaction.message.id),
        "user_id": str(user.id),
        "emoji": {
            "name": reaction.emoji if isinstance(reaction.emoji, str) else reaction.emoji.name
        }
    }
    
    # Send to n8n
    requests.post(REACTION_WEBHOOK_URL, json=payload)
```

---

## Implementation Checklist

### Phase 1: Foundation
- [ ] Create migration 004 (thread_extractions table)
- [ ] Run migration on production
- [ ] Update discord_relay.py (add reaction intent + webhook)
- [ ] Deploy discord_relay.py

### Phase 2: Workflows
- [ ] Create Emoji_Reaction_Router workflow
  - [ ] Webhook trigger (MESSAGE_REACTION_ADD)
  - [ ] Check if bot's own reaction (ignore)
  - [ ] Check if on summary message
  - [ ] Route to Handle_Extraction_Save
- [ ] Create Save_Thread workflow
  - [ ] Get thread history
  - [ ] LLM extraction (reflection/fact/todo)
  - [ ] Store in thread_extractions
  - [ ] Post summary to channel root
  - [ ] Add emoji reactions
- [ ] Create Handle_Extraction_Save workflow
  - [ ] Parse emoji (number/dismiss/delete)
  - [ ] Save to notes or todos
  - [ ] Remove emoji
  - [ ] Check if all saved

### Phase 3: Integration
- [ ] Update Discord_Message_Router
  - [ ] Route `--` tag to Save_Thread
- [ ] Test end-to-end:
  - [ ] Start thread with `++`
  - [ ] Have conversation
  - [ ] Send `--` in thread
  - [ ] React with number emoji
  - [ ] Verify note/todo saved
  - [ ] React with 🗑️
  - [ ] Verify thread deleted

### Phase 4: Workflow Renaming (Optional)
- [ ] Rename Activity_Handler → Save_Activity
- [ ] Rename Note_Handler → Save_Note
- [ ] Rename Command_Handler → Execute_Command
- [ ] Rename Thread_Handler → Start_Thread
- [ ] Rename Thread_Continuation_Agent → Continue_Thread
- [ ] Update all references in workflows
- [ ] Update AGENTS.md documentation

---

## Example Flow

```
1. User: "++ what should I focus on today?"
   Bot: [creates conversation, starts thread]

2. Bot: "Let me check your recent activities..."
   User: "I want to balance deep work with relationships"
   Bot: "Based on your week, I see you've been..."
   
3. User: "--"
   Bot: 💭 (in thread)
   Bot: Posts to channel root:
   
   📊 Thread Summary
   
   💡 Insights & Facts
   1️⃣ User values balancing deep work with relationships
   2️⃣ User works best in morning blocks
   
   📋 Action Items
   3️⃣ Schedule friend coffee this week
   4️⃣ Block 2-hour morning focus time
   
   ---
   Tap number emoji to save
   ❌ Dismiss • 🗑️ Delete thread

4. User: *clicks 1️⃣ 2️⃣ 4️⃣*
   Bot: *removes those emojis*
   
5. User: *clicks 🗑️*
   Bot: *deletes thread*
   Bot: *deletes summary*
   
   ✅ Clean workspace!
```

---

## Summary of Changes from v2

| Aspect | v2 | v3 |
|--------|----|----|
| **Data model** | insight/decision/action | reflection/fact/todo |
| **Schema** | extraction_type + note_category | item_type only |
| **Routing** | Handle_Extraction_Reaction only | Emoji_Reaction_Router + branches |
| **LLM prompt** | TYPE\|CATEGORY\|TEXT | TYPE\|TEXT |
| **Complexity** | Higher (intermediate types) | Lower (native types) |

Much cleaner! Ready to implement. 🚀
