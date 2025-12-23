# Tag Parsing Reference

## Supported Tags

### Symbol Tags (2 characters)

| Symbol | Intent | Semantic Alternative | Example |
|--------|--------|---------------------|---------|
| `!!`   | Activity | `act` | `!! working on auth` |
| `..`   | Note | `note` | `.. interesting insight` |
| `++`   | Thread Start | `chat` | `++ what did I work on?` |
| `--`   | Thread Save | `save` | `-- (saves & closes thread)` |
| `::`   | Command | `cmd` | `::todos` |
| `$$`   | Todo | `todo` | `$$ buy milk` |

### Word Tags (semantic alternatives)

- `act` → Activity (`!!`)
- `note` → Note (`..`)
- `chat` → Thread Start (`++`)
- `save` → Thread Save (`--`)
- `cmd` → Command (`::`)
- `todo` → Todo (`$$`)

---

## Parsing Rules

### 1. Position: Start of Message Only

Tags are **only recognized at position 0** (very start of message).

```javascript
// ✅ Valid
"!! working on auth"         → tag='!!', clean_text='working on auth'
"act working on auth"        → tag='!!', clean_text='working on auth'
"$$ buy milk"                → tag='$$', clean_text='buy milk'
"todo buy milk"              → tag='$$', clean_text='buy milk'

// ❌ Invalid (tag not at start)
"I am !! working"            → tag=null, clean_text='I am !! working'
"need to todo buy milk"      → tag=null, clean_text='need to todo buy milk'
"should I ask about this"    → tag=null, clean_text='should I ask about this'
```

### 2. Whitespace: Required After Tag

Symbol tags require whitespace immediately after. Word tags require whitespace or end-of-string.

```javascript
// ✅ Valid
"!! working"                 → tag='!!', clean_text='working'
"act working"                → tag='!!', clean_text='working'
"todo"                       → tag='$$', clean_text='' (empty is ok)

// ❌ Invalid (no whitespace)
"!!working"                  → tag=null, clean_text='!!working'
"todolist"                   → tag=null, clean_text='todolist'
"activity working"           → tag=null, clean_text='activity working'
```

### 3. Case: Insensitive for Words

Word tags are case-insensitive. Symbol tags are case-sensitive (but all symbols).

```javascript
// ✅ Valid (case insensitive words)
"ACT working"                → tag='!!', clean_text='working'
"Note interesting"           → tag='..', clean_text='interesting'
"TODO buy milk"              → tag='$$', clean_text='buy milk'
"AcT working"                → tag='!!', clean_text='working'

// ✅ Valid (symbols always same)
"!! working"                 → tag='!!', clean_text='working'
"$$ buy milk"                → tag='$$', clean_text='buy milk'
```

### 4. Normalization

All word tags normalize to their symbol equivalent:

```javascript
"act working"    → normalized to → "!! working"
"note insight"   → normalized to → ".. insight"
"ask question"   → normalized to → "++ question"
"save"           → normalized to → "--"
"cmd help"       → normalized to → ":: help"
"todo buy milk"  → normalized to → "$$ buy milk"
```

---

## Implementation Regex

### JavaScript/n8n Implementation

```javascript
// Tag extraction regex
const tagRegex = /^(!!|\.\.|\+\+|--|::|$$|act|note|chat|commit|cmd|todo)(\s+|$)/i;

const match = message.match(tagRegex);

if (match) {
  const rawTag = match[1].toLowerCase(); // Normalize to lowercase for comparison
  const symbolTag = {
    '!!': '!!',
    '..': '..',
    '++': '++',
    '--': '--',
    '::': '::',
    '$$': '$$',
    'act': '!!',
    'note': '..',
    'chat': '++',
    'commit': '--',
    'cmd': '::',
    'todo': '$$'
  }[rawTag];
  
  const cleanText = message.slice(match[0].length); // Remove tag + whitespace
  
  return {
    tag: symbolTag,
    clean_text: cleanText,
    raw_text: message
  };
} else {
  return {
    tag: null,
    clean_text: message,
    raw_text: message
  };
}
```

### Python Implementation (for discord_relay.py)

```python
import re

TAG_PATTERN = re.compile(r'^(!!|\.\.|\+\+|--|::|$$|act|note|chat|save|cmd|todo)(\s+|$)', re.IGNORECASE)

TAG_MAP = {
    '!!': '!!',
    '..': '..',
    '++': '++',
    '--': '--',
    '::': '::',
    '$$': '$$',
    'act': '!!',
    'note': '..',
    'chat': '++',
    'commit': '--',
    'cmd': '::',
    'todo': '$$'
}

def parse_tag(message: str) -> dict:
    match = TAG_PATTERN.match(message)
    
    if match:
        raw_tag = match.group(1).lower()
        symbol_tag = TAG_MAP.get(raw_tag)
        clean_text = message[len(match.group(0)):]  # Remove tag + whitespace
        
        return {
            'tag': symbol_tag,
            'clean_text': clean_text,
            'raw_text': message
        }
    else:
        return {
            'tag': None,
            'clean_text': message,
            'raw_text': message
        }
```

---

## Edge Cases

### Empty Message After Tag

Valid - tag with no content:

```javascript
"todo"           → tag='$$', clean_text=''
"save"           → tag='--', clean_text=''
"::"             → tag='::', clean_text=''
```

**Handling:** Downstream handlers should validate that clean_text is not empty when required.

### Multiple Tags in Message

Only first tag (at position 0) is recognized:

```javascript
"!! working on .. something"  → tag='!!', clean_text='working on .. something'
"todo buy !! milk"            → tag='$$', clean_text='buy !! milk'
```

### Tag-Like Words in Content

Not recognized unless at start:

```javascript
"I need to ask you something"     → tag=null
"let me note this down"           → tag=null
"should I save this change"       → tag=null
```

### Special Characters in Tags

Only the exact symbols are recognized:

```javascript
"!!! working"    → tag=null (three !)
"... thinking"   → tag=null (three .)
"$ buy milk"     → tag=null (only one $)
"$$$$ rich"      → tag=null (four $)
```

---

## LLM Classifier Considerations

### Why Consistent Character Count Matters

The LLM intent classifier receives messages **without tags** (uses `clean_text`).

**Problem with inconsistent tags:**
```
User types: "!! working"   → LLM sees: "working"    (2 chars removed)
User types: "$ working"    → LLM sees: "working"    (1 char removed)
```

LLM training examples would need to account for both, causing confusion.

**Solution: All tags are 2 characters (symbols) or full words**

```
Symbol tags: Always 2 chars
Word tags:   Always full word (3-6 chars)
```

This makes LLM training consistent:
- Symbol messages: 2 chars + space removed
- Word messages: Full word + space removed
- Untagged: Nothing removed

### Escaping Tags in Content

If user wants literal tag at start of message:

```javascript
// Escape with space or other char
" !! not a tag"              → tag=null, clean_text=' !! not a tag'
"\!! not a tag"              → tag=null, clean_text='\!! not a tag'
```

Or use LLM classifier (no tag = classified by LLM).

---

## Testing Checklist

- [ ] Symbol tags at start: `!! working` → tag='!!'
- [ ] Word tags at start: `act working` → tag='!!'
- [ ] Case insensitive: `ACT working` → tag='!!'
- [ ] Tags not at start: `I am !! working` → tag=null
- [ ] No whitespace: `!!working` → tag=null
- [ ] Empty after tag: `todo` → tag='$$', clean_text=''
- [ ] Multiple tags: `!! working on .. something` → tag='!!', clean_text='working on .. something'
- [ ] Special chars: `!!! working` → tag=null
- [ ] All word tags: `act`, `note`, `chat`, `save`, `cmd`, `todo`
- [ ] All symbol tags: `!!`, `..`, `++`, `--`, `::`, `$$`

---

## Router Implementation Update Needed

### Current State (n8n-workflows/Discord_Message_Router.json)

Needs update in "Parse Tag" node:

```javascript
// OLD: Only checks symbols
const match = $json.content.match(/^(!!|\.\.|::|\\+\\+)/);

// NEW: Check symbols + words
const tagRegex = /^(!!|\.\.|\+\+|--|::|$$|act|note|chat|commit|cmd|todo)(\s+|$)/i;
const match = $json.content.match(tagRegex);

if (match) {
  const rawTag = match[1].toLowerCase();
  const tagMap = {
    '!!': '!!', '..': '..', '++': '++', '--': '--', '::': '::', '$$': '$$',
    'act': '!!', 'note': '..', 'chat': '++', 'save': '--', 'cmd': '::', 'todo': '$$'
  };
  const tag = tagMap[rawTag];
  const cleanText = $json.content.slice(match[0].length);
  
  return {
    tag: tag,
    clean_text: cleanText,
    raw_text: $json.content
  };
} else {
  return {
    tag: null,
    clean_text: $json.content,
    raw_text: $json.content
  };
}
```

### Switch Node Update

Add `--` (commit) case to switch node:

```javascript
// Current cases: !!, .., ++, ::
// Add: --, $$

rules: [
  { condition: tag === '!!' },
  { condition: tag === '..' },
  { condition: tag === '++' },
  { condition: tag === '--' },  // NEW
  { condition: tag === '::' },
  { condition: tag === '$$' }   // NEW
]
```

---

## Documentation for Users

### Quick Reference Card

```
📌 Quick Tags:

🏃 Activity: !! or act
  "!! working on project"

📝 Note: .. or note
  ".. interesting insight"

💬 Chat: ++ or ask
  "++ what did I work on?"

✅ Save: -- or save
  "-- (in thread to save conversation)"

⚙️  Command: :: or cmd
  "::todos" or "cmd help"

☑️  Todo: $$ or todo
  "$$ buy milk"
```

### Tips

- Use **symbols** (!!, .., $$) for speed
- Use **words** (act, note, todo) for clarity
- No tag? System will auto-classify with AI
- Tags only work at the start of your message
