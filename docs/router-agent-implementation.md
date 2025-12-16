# Router Agent Implementation Guide

## Overview

The Router Agent classifies untagged messages by having an LLM output the appropriate tag (`!!`, `++`, `::`, `..`), then routing back to the existing "Check Tag" node. This is simpler than tool calling and reuses existing routing logic.

## Current Status

❌ **Not Implemented** - The workflow currently has a placeholder node called "Router Agent Placeholder" that needs to be replaced with LLM classification logic.

## Architecture

```
Untagged Message
    ↓
1. Fetch User Context (Postgres)
    ↓
2. Build Classification Prompt (Code)
    ↓
3. LLM Classification (returns "!! working" or ".. interesting idea")
    ↓
4. Parse LLM Output + Confidence Check (Code)
    ↓
5. Route back to "Check Tag" node (EXISTING)
    ↓
6. Handlers (!! Activity, ++ Thread, :: Command, .. Note)
```

**Key Insight:** We reuse the existing tag routing infrastructure. The LLM just decides which tag to apply!

---

## Why This Approach?

✅ **Simpler:** No tool schemas, just text output  
✅ **Debuggable:** See exactly what LLM decided in logs  
✅ **Reuses existing code:** All handler nodes already exist  
✅ **Works with any LLM:** OpenAI, Anthropic, local models  
✅ **Faster & Cheaper:** No function calling overhead  
✅ **Confidence tracking:** LLM outputs confidence for auditing  

---

## Implementation Steps

### Step 1: Add "Fetch User Context" Node

**Node Type:** Postgres (Execute Query)

**Position:** After "Router Agent Placeholder" node (or where untagged messages route)

**Query:**
```sql
-- Fetch all context in one query using CTEs
-- Uses expressions to pull author_login from the incoming message
WITH recent_acts AS (
  SELECT category_name, description, timestamp
  FROM recent_activities
  WHERE author_login = '{{ $json.author.login }}'
  ORDER BY timestamp DESC
  LIMIT 3
),
activity_cats AS (
  SELECT array_agg(DISTINCT name ORDER BY name) as categories
  FROM activity_categories
  WHERE active = true
),
note_cats AS (
  SELECT array_agg(DISTINCT name ORDER BY name) as categories
  FROM note_categories
  WHERE active = true
),
user_info AS (
  SELECT sleeping, last_observation_at
  FROM user_state
  WHERE user_login = '{{ $json.author.login }}'
)
SELECT 
  -- Include original message fields
  '{{ $json.author.login }}' as author_login,
  '{{ $json.clean_text }}' as clean_text,
  '{{ $json.content }}' as content,
  '{{ $json.timestamp }}' as timestamp,
  '{{ $json.message_id }}' as message_id,
  '{{ $json.channel_id }}' as channel_id,
  '{{ $json.guild_id }}' as guild_id,
  '{{ $json.message_url }}' as message_url,
  -- Context data
  (SELECT json_agg(row_to_json(recent_acts)) FROM recent_acts) as recent_activities,
  (SELECT categories FROM activity_cats) as activity_categories,
  (SELECT categories FROM note_cats) as note_categories,
  (SELECT sleeping FROM user_info) as user_sleeping,
  (SELECT last_observation_at FROM user_info) as last_observation
;
```

**Output:** Single row with both original message data and context data

---

### Step 2: Build Classification Prompt

**Node Type:** Code (JavaScript)

**Code:**
```javascript
// Build the router agent classification prompt with context
const user = $json.author_login || 'unknown';
const timestamp = $json.timestamp || new Date().toISOString();
const sleeping = $json.user_sleeping ? "Sleeping" : "Awake";
const cleanText = $json.clean_text || '';

// Format recent activities
let recentActivitiesText = 'None';
if ($json.recent_activities && $json.recent_activities.length > 0) {
  recentActivitiesText = $json.recent_activities.map(a => 
    `- [${a.timestamp}] ${a.category_name}: ${a.description}`
  ).join('\n');
}

// Format categories
const activityCats = $json.activity_categories?.join(', ') || 'work, personal, health, sleep, leisure';
const noteCats = $json.note_categories?.join(', ') || 'idea, decision, reflection, goal';

const systemPrompt = `You are a classification agent for a life tracking system.

## User Context

- **User:** ${user}
- **Time:** ${timestamp}
- **Current State:** ${sleeping}

## Recent Activities (Last 3)

${recentActivitiesText}

## Available Categories

**Activity Categories:** ${activityCats}
**Note Categories:** ${noteCats}

---

## Your Task

Classify the user's message and output the appropriate tag + message in this EXACT format:

\`\`\`
TAG MESSAGE
CONFIDENCE: high|medium|low
\`\`\`

## Available Tags

### !! (Activity)
**Use when:** User is stating what they're currently doing or have done
- Present or past tense action statements
- Clear activity observations
- Examples: "working on the router", "took a break", "going to bed"

**Output format:** \`!! ACTIVITY_DESCRIPTION\`
**Example:** \`!! working on router agent implementation\`

### .. (Note)
**Use when:** Declarative thoughts, insights, observations, or decisions (NOT questions)
- Ideas or reflections to remember
- Decisions made
- Meta observations
- Examples: "interesting pattern", "I should prioritize X", "decided to do Y"

**Output format:** \`.  . NOTE_TEXT\`
**Example:** \`.. async communication reduces context switching\`

### ++ (Thread Start / Question)
**Use when:** User asks a question or requests exploration
- Questions (who, what, when, where, why, how)
- Requests for help or brainstorming
- "Let's think about..." statements
- Examples: "what did I work on yesterday?", "help me plan my week"

**Output format:** \`++ QUESTION_OR_TOPIC\`
**Example:** \`++ what did I work on yesterday?\`

### :: (Command)
**Use when:** User is issuing a system command
- Explicit commands like "stats", "help", "pause", etc.
- Should be rare - most user input won't be commands

**Output format:** \`::COMMAND_NAME ARGS\`
**Example:** \`::stats weekly\`

---

## Confidence Levels

After your classification, add a confidence line:

- **high:** Very clear what the user means (90%+ confident)
- **medium:** Reasonable interpretation but some ambiguity (60-90% confident)
- **low:** Unclear or could be multiple things (<60% confident)

**If confidence is low:** Bias toward \`++\` (thread start) - it's safer to start a conversation than to misclassify.

---

## Examples

Input: "working on the router agent"
Output:
\`\`\`
!! working on the router agent
CONFIDENCE: high
\`\`\`

Input: "I think async communication is better"
Output:
\`\`\`
.. I think async communication is better
CONFIDENCE: high
\`\`\`

Input: "what did I do yesterday?"
Output:
\`\`\`
++ what did I do yesterday?
CONFIDENCE: high
\`\`\`

Input: "still working on it"
Output:
\`\`\`
!! still working on it
CONFIDENCE: low
\`\`\`
(Note: Ambiguous reference, but likely continuing previous activity)

Input: "hmm not sure about this approach"
Output:
\`\`\`
++ hmm not sure about this approach
CONFIDENCE: medium
\`\`\`
(Note: Unclear - could be note or question, so safer to start conversation)

---

## Important Rules

1. Output ONLY the tag + message and confidence line - no other text
2. Don't explain your reasoning
3. Don't add quotes or extra formatting
4. Preserve the user's original wording after the tag
5. When in doubt, use \`++\` (conversation is safer than misclassification)`;

return {
  ...$json,
  classification_prompt: systemPrompt
};
```

---

### Step 3: Add LLM Classification Node

**Node Type:** OpenAI / Anthropic (Basic Chat Model - NOT AI Agent)

**Configuration:**

- **Model:** `claude-3-5-sonnet-20241022` (recommended) or `gpt-4o`
- **System Message:** `={{ $json.classification_prompt }}`
- **User Message:** `={{ $json.clean_text }}`
- **Temperature:** `0.1` (low for consistent classification)

**Output Field:** Store the LLM response in `llm_classification`

---

### Step 4: Parse LLM Output & Check Confidence

**Node Type:** Code (JavaScript)

**Purpose:** Extract tag, clean text, and confidence from LLM output. Store low-confidence classifications for review.

**Code:**
```javascript
// Parse LLM output
const llmOutput = ($json.llm_classification || '').trim();

// Extract confidence line
const confidenceMatch = llmOutput.match(/CONFIDENCE:\s*(high|medium|low)/i);
const confidence = confidenceMatch ? confidenceMatch[1].toLowerCase() : 'unknown';

// Extract the tag line (first line)
const firstLine = llmOutput.split('\n')[0].trim();
const firstToken = firstLine.split(/\s+/)[0];

// Validate tag
let tag = null;
let taggedMessage = llmOutput;

if (['!!', '++', '::', '..'].includes(firstToken)) {
  tag = firstToken;
  // Remove tag from beginning of first line
  taggedMessage = firstLine.slice(firstToken.length).trim();
} else {
  // Invalid format - default to ++ (conversation)
  tag = '++';
  taggedMessage = $json.clean_text;
  console.log(`Warning: LLM returned invalid format. Defaulting to ++ thread start. LLM output: ${llmOutput}`);
}

// For :: commands, extract command name
let command = null;
if (tag === '::') {
  const commandMatch = taggedMessage.match(/^(\w+)/);
  command = commandMatch ? commandMatch[1] : null;
}

return {
  ...$json,
  tag: tag,
  command: command,
  content: taggedMessage,  // The message with tag removed
  clean_text: taggedMessage,
  confidence: confidence,
  llm_raw_output: llmOutput,
  classification_method: 'llm'
};
```

**Note:** This node prepares the data in the same format as the "Parse Tag & Clean Text" node, so it can route to the existing "Check Tag" node!

---

### Step 5: Store Low-Confidence Classifications (Optional)

**Node Type:** IF node

**Condition:** `{{ $json.confidence === 'low' }}`

**If TRUE:**
- Add Postgres INSERT to store in a `classification_audit` table (or log to Discord channel)
- Continue to routing anyway

**Query (if using audit table):**
```sql
INSERT INTO routing_decisions (
  raw_event_id,
  intent,
  forced_by,
  confidence,
  payload
)
SELECT
  (SELECT id FROM raw_events WHERE discord_message_id = '{{ $json.message_id }}'),
  CASE 
    WHEN '{{ $json.tag }}' = '!!' THEN 'Activity'
    WHEN '{{ $json.tag }}' = '..' THEN 'Note'
    WHEN '{{ $json.tag }}' = '++' THEN 'ThreadStart'
    WHEN '{{ $json.tag }}' = '::' THEN 'Command'
  END,
  'agent',
  0.4,  -- Low confidence ~40%
  jsonb_build_object(
    'llm_output', '{{ $json.llm_raw_output }}',
    'confidence', '{{ $json.confidence }}',
    'original_message', '{{ $json.content }}'
  )
RETURNING *;
```

**If FALSE:**
- Skip audit, continue to routing

---

### Step 6: Route to Existing "Check Tag" Node

**Node Type:** Connector (just connect to existing node)

**Action:** Connect the output of Step 4 (or Step 5) to the **existing "Check Tag" node** in your workflow.

The "Check Tag" node will route based on the `tag` field:
- `!!` → "Handle !! Activity" 
- `++` → "Handle ++ Thread Start"
- `::` → "Handle :: Command"
- `..` → "Handle .. Note" (**NEW - need to add this**)
- No tag → "Router Agent Placeholder" (you just came from here, so this won't happen)

---

### Step 7: Add "Handle .. Note" Node

**Node Type:** Set (Edit assignments)

**Position:** Add as a new output from "Check Tag" switch node

**First, update the "Check Tag" switch node:**

Add a new condition:
- **Condition ID:** `tag-note`
- **Left Value:** `={{ $json.tag }}`
- **Operator:** `equals`
- **Right Value:** `..`

**Then create the handler node:**

**Parameters:**
```json
{
  "assignments": {
    "assignments": [
      {
        "id": "emoji",
        "name": "emoji",
        "value": "📝",
        "type": "string"
      },
      {
        "id": "intent",
        "name": "intent",
        "value": "Note",
        "type": "string"
      }
    ]
  }
}
```

**Notes:** `"TODO: Extract category + title via LLM\nTODO: Write to notes table"`

**Connect to:** "Send Emoji Reaction" node

---

## Updated "Check Tag" Switch Node

Your "Check Tag" node should now have **4 outputs**:

1. **Output 0:** `tag` equals `!!` → "Handle !! Activity"
2. **Output 1:** `tag` equals `++` → "Handle ++ Thread Start"
3. **Output 2:** `tag` equals `::` → "Handle :: Command"
4. **Output 3:** `tag` equals `..` → "Handle .. Note" ⭐ NEW
5. **Fallback (no match):** → "Router Agent" flow (won't happen since LLM always returns valid tag)

---

## Testing

### Test Cases

1. **Activity statement:** `"working on the router agent implementation"`
   - Expected: LLM outputs `!! working on the router agent implementation\nCONFIDENCE: high`
   - Routes to: "Handle !! Activity"
   - Expected emoji: 🕒

2. **Note/Insight:** `"I think async communication reduces context switching"`
   - Expected: LLM outputs `.. I think async communication reduces context switching\nCONFIDENCE: high`
   - Routes to: "Handle .. Note"
   - Expected emoji: 📝

3. **Question:** `"what did I work on yesterday?"`
   - Expected: LLM outputs `++ what did I work on yesterday?\nCONFIDENCE: high`
   - Routes to: "Handle ++ Thread Start"
   - Expected emoji: 💭

4. **Ambiguous:** `"still working on it"`
   - Expected: LLM outputs `!! still working on it\nCONFIDENCE: low`
   - Routes to: "Handle !! Activity" (but confidence is logged)
   - Expected emoji: 🕒

5. **Very unclear:** `"hmm"`
   - Expected: LLM outputs `++ hmm\nCONFIDENCE: low`
   - Routes to: "Handle ++ Thread Start" (safe fallback)
   - Expected emoji: 💭

---

## Confidence Tracking & Review

### Why Track Confidence?

- **Improve prompts:** Review low-confidence classifications to refine system prompt
- **Catch errors:** Find misclassifications and add examples
- **User feedback:** If user reacts with ❌, check if it was low confidence
- **Analytics:** Track accuracy over time

### How to Review

**Option 1: Database Query**
```sql
SELECT 
  re.message_url,
  re.clean_text,
  rd.intent,
  rd.confidence,
  rd.payload->>'llm_output' as llm_reasoning,
  rd.routed_at
FROM routing_decisions rd
JOIN raw_events re ON rd.raw_event_id = re.id
WHERE rd.forced_by = 'agent'
  AND rd.confidence < 0.6
ORDER BY rd.routed_at DESC
LIMIT 50;
```

**Option 2: Discord Logging Channel**
Create a `#kairon-log` channel and post low-confidence classifications:
```javascript
// In Step 5 IF node, add HTTP Request to Discord:
{
  "content": `⚠️ Low confidence classification\n\n**Message:** ${$json.clean_text}\n**Classified as:** ${$json.tag}\n**Confidence:** ${$json.confidence}\n**Link:** ${$json.message_url}`
}
```

---

## Integration Points

The Router Agent integrates with:
- **Existing "Check Tag" node:** Reuses routing logic
- **"Handle !! Activity" node:** For activities
- **"Handle ++ Thread Start" node:** For questions/threads
- **"Handle :: Command" node:** For commands
- **"Handle .. Note" node:** For notes (NEW)
- **routing_decisions table:** Stores classification audit trail
- **Discord #kairon-log:** Optional logging for low-confidence

---

## Advantages Over Tool Calling

| Aspect | Tag Classification (This) | Tool Calling (Old) |
|--------|---------------------------|-------------------|
| Complexity | ✅ Simple text output | ❌ Complex tool schemas |
| Debugging | ✅ See exact LLM output | ❌ Nested JSON, tool errors |
| Portability | ✅ Any LLM provider | ❌ Requires function calling support |
| Cost | ✅ Fewer tokens | ❌ Tool definitions sent every request |
| Latency | ✅ Faster (text completion) | ❌ Slower (function calling) |
| Maintenance | ✅ Reuses existing handlers | ❌ Duplicate routing logic |
| Flexibility | ✅ Easy to add new tags | ❌ Update tool schemas |

---

## Future Enhancements

1. **Add few-shot examples:** Include user-specific examples in prompt based on their history
2. **Fine-tune LLM:** Train on your classification data for better accuracy
3. **Add feedback loop:** Let user correct misclassifications (thumbs up/down reactions)
4. **Confidence thresholds:** Auto-escalate very low confidence to thread (always ask if unsure)
5. **A/B testing:** Test different prompts and track accuracy

---

## References

- System Prompt: `/prompts/router-agent.md` (now simplified)
- Design Doc: `/README.md` (Section 5.4)
- Database Schema: `/db/migrations/001_initial_schema.sql`
- Main Workflow: `/n8n-workflows/Discord_Message_Ingestion.json`
