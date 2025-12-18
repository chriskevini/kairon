# Save Thread Summarization Prompt

You are summarizing a thinking session into a structured note for a life tracking system.

## Conversation History

{{conversation_messages}}

---

## Your Task

Analyze this conversation and extract **a single note** capturing the key insights, decisions, or ideas from this session.

## Output Format

Return ONLY valid JSON (no markdown code blocks, no explanations):

```json
{
  "note": {
    "category": "idea|reflection|decision|question|meta",
    "title": "Brief descriptive title (3-8 words)",
    "text": "Summary of key insights, decisions, or ideas from the conversation. Be concise but capture the essence."
  }
}
```

## Guidelines

### For the Note

**Category selection:**
- `idea` - New concepts, brainstorms, creative thoughts
- `reflection` - Observations about themselves, patterns noticed
- `decision` - Decisions made, commitments, resolutions
- `question` - Unresolved questions, things to explore further
- `meta` - Thoughts about the system, process, or how they work

**Title:**
- 3-8 words maximum
- Descriptive and specific
- No question marks (even for question category)
- Title case

**Text:**
- 2-4 sentences
- Capture key insights, not the full conversation
- Focus on outcomes, not process
- Be specific and actionable when possible



## Examples

### Example 1: Career Exploration

**Conversation:** 
```
User: let's think about my career direction
Assistant: I'd love to help. What aspects feel aligned with where you want to go?
User: I love the technical work but hate the meetings
Assistant: So the craft is fulfilling but the organizational overhead isn't?
User: exactly, maybe I should look for IC roles
Assistant: Individual contributor roles could give you more heads-down time. What companies value deep technical work?
User: probably smaller startups or research-focused places
Assistant: That's a good insight. Want to save this conversation?
User: --
```

**Output:**
```json
{
  "note": {
    "category": "reflection",
    "title": "Career Direction Clarity",
    "text": "Realized that while I enjoy technical work deeply, organizational overhead (meetings, etc.) drains me. Individual contributor roles at smaller startups or research-focused companies might provide the heads-down time I need to thrive."
  }
}
```

### Example 2: Productivity Patterns

**Conversation:**
```
User: why am I so unproductive lately?
Assistant: Let me look at your recent patterns... [retrieves data]
User: yeah I've been starting late and getting distracted
Assistant: I notice you have no morning routine logged. What happens when you wake up?
User: I check phone immediately, then it's chaos
Assistant: That's a common pattern. What if you delayed phone for 30 mins?
User: could do morning walk instead
Assistant: Good idea. Want to try that tomorrow?
User: yes, let's save this
User: --
```

**Output:**
```json
{
  "note": {
    "category": "decision",
    "title": "Morning Routine Experiment",
    "text": "Identified that checking phone immediately upon waking leads to chaotic, unproductive mornings. Decided to try a 30-minute phone delay with a morning walk instead. Will experiment with this starting tomorrow."
  }
}
```

### Example 3: Technical Problem

**Conversation:**
```
User: help me figure out this authentication bug
Assistant: What's the symptom?
User: tokens expire too fast
Assistant: How fast?
User: like 5 minutes instead of 1 hour
Assistant: Check your JWT config - probably using seconds instead of milliseconds
User: oh wow yes that's it, 3600 vs 3600000
Assistant: Classic bug. Easy fix!
User: --
```

**Output:**
```json
{
  "note": {
    "category": "idea",
    "title": "JWT Token Expiration Bug Fix",
    "text": "Discovered authentication tokens were expiring in 5 minutes instead of 1 hour due to JWT config using seconds (3600) instead of milliseconds (3600000). Simple unit conversion fix."
  }
}
```

### Example 4: Open Question

**Conversation:**
```
User: what should I focus on this week?
Assistant: Let me see what you've been working on... [retrieves]
User: yeah lots of scattered tasks
Assistant: I see work tasks, personal projects, and some learning. What feels most important?
User: honestly not sure, that's why I'm asking
Assistant: Fair. What's your North Star again?
User: focus on deep work
Assistant: Then maybe batching the scattered tasks and protecting blocks for deep work?
User: makes sense but need to think more about this
User: --
```

**Output:**
```json
{
  "note": {
    "category": "question",
    "title": "Weekly Focus Prioritization",
    "text": "Discussed weekly priorities and recognized scattered attention across work tasks, personal projects, and learning. Considered batching small tasks to protect deep work time (aligned with North Star), but need more thinking to decide concrete actions."
  }
}
```

---

## Important

- Return ONLY the JSON object
- No markdown code blocks (no ```json)
- No explanations before or after
- Valid JSON syntax
- Use double quotes for strings
- Ensure all fields are present
