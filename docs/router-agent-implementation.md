# Router Agent Implementation Guide

## Overview

The Router Agent classifies untagged messages by having an LLM output the appropriate tag (`!!`, `++`, `::`, `..`), then routing back to the existing "Check Tag" node. This is simpler than tool calling and reuses existing routing logic.

## Current Status

❌ **Not Implemented** - The workflow currently has a placeholder node called "Router Agent Placeholder" that needs to be replaced with LLM classification logic.

## Architecture

```
Untagged Message: "thinking about async communication"
    ↓
1. [SKIP Context - Not Needed]
    ↓
2. Build Minimal Prompt (Code) - just tag definitions
    ↓
3. LLM Classification (OpenAI/Anthropic)
   Returns: "..|high"
    ↓
4. Parse & Reconstruct (Code)
   - tag = ".."
   - confidence = "high"
   - content = ".. thinking about async communication"
    ↓
5. [Optional] Log if confidence=low
    ↓
6. Route to EXISTING "Check Tag" node
    ↓
7. "Handle .. Note" → 📝 emoji
```

**Key Optimizations:**
- ❌ No Postgres context query (saves ~50ms + tokens)
- ❌ No user/time/categories in prompt (~70% fewer tokens)
- ✅ LLM outputs just `TAG|CONFIDENCE` (minimal tokens)
- ✅ Reconstruct message in n8n (preserve user's exact wording)

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

### Step 1: Skip Context Fetching (Not Needed!)

**Decision:** For MVP, we don't need to fetch user context. The classification task is simple enough without it.

**Why this works:**
- Most messages are clear: "working on X" vs "I think Y" vs "how do I Z?"
- Ambiguous messages can default to `++` (conversation)
- Saves Postgres query on every untagged message
- Faster response time

**If you need context later:** Add Step 1 back with just `recent_activities` (not categories, not user state).

---

### Step 2: Build Minimal Classification Prompt

**Node Type:** Code (JavaScript)

**Position:** After "Router Agent Placeholder" node

**Code:**
```javascript
// Build minimal classification prompt - just the essentials
const cleanText = $json.clean_text || '';

const systemPrompt = `You are a message classifier for a life tracking system.

Classify the message into ONE of these tags and provide confidence.

## Tags

**!!** = Activity (what user is doing/did)
- Present/past tense actions
- Examples: "working on router", "took a break", "fixed the bug"

**..** = Note (thoughts, insights, decisions)
- Declarative observations (NOT questions)
- Ideas, reflections, decisions
- Examples: "interesting pattern", "should prioritize X", "decided to do Y"

**++** = Question/Exploration (start conversation)
- Questions (who/what/when/where/why/how)
- Requests for help
- Examples: "what did I do yesterday?", "help me plan", "why is X happening?"

**::** = Command (rare system commands)
- Examples: "stats", "help", "pause"

## Output Format

Output ONLY this (nothing else):
\`\`\`
TAG|CONFIDENCE
\`\`\`

Where:
- TAG is one of: !! or .. or ++ or ::
- CONFIDENCE is one of: high or medium or low

## Confidence Guide

- **high**: Very clear classification (90%+ confident)
- **medium**: Reasonable but some ambiguity (60-90% confident)  
- **low**: Unclear or could be multiple (<60% confident)

**If low confidence:** Choose ++ (safer to start conversation than misclassify)

## Examples

Input: "working on the router agent"
Output: \`!!|high\`

Input: "async communication reduces context switching"
Output: \`..|high\`

Input: "what did I do yesterday?"
Output: \`++|high\`

Input: "hmm not sure"
Output: \`++|low\`

Input: "still working on it"
Output: \`!!|medium\`

Remember: Output ONLY the tag and confidence. Nothing else.`;

return {
  ...$json,
  classification_prompt: systemPrompt
};
```

**Key Changes:**
- ❌ Removed: user name, timestamp, sleeping state, recent activities, categories
- ✅ Kept: Clear tag definitions, examples, confidence guide
- ✅ New format: `TAG|CONFIDENCE` (not `TAG MESSAGE\nCONFIDENCE: X`)
- 📉 Token reduction: ~70% fewer tokens in prompt

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

### Step 4: Parse LLM Output & Reconstruct Message

**Node Type:** Code (JavaScript)

**Purpose:** Parse the simple `TAG|CONFIDENCE` format and reconstruct the full message

**Code:**
```javascript
// Parse LLM output: "!!|high" or "++|low" etc
const llmOutput = ($json.llm_classification || '').trim();

// Split by pipe
const parts = llmOutput.split('|');
const tag = parts[0]?.trim() || '';
const confidence = parts[1]?.trim().toLowerCase() || 'unknown';

// Validate tag
let validTag = tag;
if (!['!!', '++', '::', '..'].includes(tag)) {
  // Invalid format - default to ++ (conversation)
  validTag = '++';
  console.log(`Warning: LLM returned invalid tag "${tag}". Defaulting to ++. Full output: ${llmOutput}`);
}

// For :: commands, extract command name from original message
let command = null;
if (validTag === '::') {
  const commandMatch = $json.clean_text.match(/^(\w+)/);
  command = commandMatch ? commandMatch[1] : null;
}

// Reconstruct full message with tag prefix
// Use original clean_text (don't let LLM rewrite it)
const taggedContent = `${validTag} ${$json.clean_text}`.trim();

return {
  ...$json,
  tag: validTag,
  command: command,
  content: taggedContent,  // Reconstructed: "!! working on router"
  confidence: confidence,
  llm_raw_output: llmOutput,
  classification_method: 'llm'
};
```

**Key Points:**
- ✅ Parses simple `TAG|CONFIDENCE` format
- ✅ Uses **original `clean_text`** (doesn't let LLM reword)
- ✅ Validates tag, defaults to `++` if invalid
- ✅ Reconstructs `content` field for downstream handlers

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
   - Expected LLM: `!!|high`
   - Parsed: tag="!!", confidence="high"
   - Reconstructed: `"!! working on the router agent implementation"`
   - Routes to: "Handle !! Activity"
   - Expected emoji: 🕒

2. **Note/Insight:** `"I think async communication reduces context switching"`
   - Expected LLM: `..|high`
   - Parsed: tag="..", confidence="high"
   - Reconstructed: `".. I think async communication reduces context switching"`
   - Routes to: "Handle .. Note"
   - Expected emoji: 📝

3. **Question:** `"what did I work on yesterday?"`
   - Expected LLM: `++|high`
   - Parsed: tag="++", confidence="high"
   - Reconstructed: `"++ what did I work on yesterday?"`
   - Routes to: "Handle ++ Thread Start"
   - Expected emoji: 💭

4. **Ambiguous:** `"still working on it"`
   - Expected LLM: `!!|low` (best guess, but uncertain)
   - Parsed: tag="!!", confidence="low"
   - Reconstructed: `"!! still working on it"`
   - Routes to: "Handle !! Activity" (confidence logged)
   - Expected emoji: 🕒

5. **Very unclear:** `"hmm"`
   - Expected LLM: `++|low` (defaults to conversation when unsure)
   - Parsed: tag="++", confidence="low"
   - Reconstructed: `"++ hmm"`
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
