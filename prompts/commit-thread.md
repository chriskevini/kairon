# Commit Thread Summarization Prompt

You are summarizing a thinking session into structured data for a life tracking system.

## Conversation History

{{conversation_messages}}

---

## Your Task

Analyze this conversation and extract:

1. **A Note** - The key insights, decisions, or ideas from this session
2. **An Activity** - A "thinking session" activity describing what was explored

## Output Format

Return ONLY valid JSON (no markdown code blocks, no explanations):

```json
{
  "note": {
    "category_name": "idea|reflection|decision|question|meta",
    "title": "Brief descriptive title (3-8 words)",
    "text": "Summary of key insights, decisions, or ideas from the conversation. Be concise but capture the essence."
  },
  "activity": {
    "category_name": "work|leisure|study|relationships|sleep|health",
    "description": "Thinking session: [concise topic description]"
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

### For the Activity

**Category selection:**
Use the category that best represents what this thinking session was about:
- `work` - Career, projects, professional development
- `study` - Learning, education, skill development
- `relationships` - People, social dynamics, communication
- `leisure` - Hobbies, entertainment, relaxation
- `health` - Physical health, mental health, wellness
- `sleep` - Sleep patterns, rest (rare for thinking sessions)

**Description:**
- Always start with "Thinking session: "
- Followed by concise topic (3-6 words)
- Examples:
  - "Thinking session: career direction exploration"
  - "Thinking session: productivity patterns analysis"
  - "Thinking session: morning routine planning"
  - "Thinking session: project priorities"

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
Assistant: That's a good insight. Want to commit this thinking?
User: ++
```

**Output:**
```json
{
  "note": {
    "category_name": "reflection",
    "title": "Career Direction Clarity",
    "text": "Realized that while I enjoy technical work deeply, organizational overhead (meetings, etc.) drains me. Individual contributor roles at smaller startups or research-focused companies might provide the heads-down time I need to thrive."
  },
  "activity": {
    "category_name": "work",
    "description": "Thinking session: career direction exploration"
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
User: yes, let's commit this
User: ++
```

**Output:**
```json
{
  "note": {
    "category_name": "decision",
    "title": "Morning Routine Experiment",
    "text": "Identified that checking phone immediately upon waking leads to chaotic, unproductive mornings. Decided to try a 30-minute phone delay with a morning walk instead. Will experiment with this starting tomorrow."
  },
  "activity": {
    "category_name": "health",
    "description": "Thinking session: morning routine planning"
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
User: ++
```

**Output:**
```json
{
  "note": {
    "category_name": "idea",
    "title": "JWT Token Expiration Bug Fix",
    "text": "Discovered authentication tokens were expiring in 5 minutes instead of 1 hour due to JWT config using seconds (3600) instead of milliseconds (3600000). Simple unit conversion fix."
  },
  "activity": {
    "category_name": "work",
    "description": "Thinking session: authentication debugging"
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
User: ++
```

**Output:**
```json
{
  "note": {
    "category_name": "question",
    "title": "Weekly Focus Prioritization",
    "text": "Discussed weekly priorities and recognized scattered attention across work tasks, personal projects, and learning. Considered batching small tasks to protect deep work time (aligned with North Star), but need more thinking to decide concrete actions."
  },
  "activity": {
    "category_name": "work",
    "description": "Thinking session: weekly planning"
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
