# Agent Guidelines

This document contains instructions for AI coding agents working on the Kairon project.

---

## ⚠️ Local Configuration

**Check `.env.local` for local development setup** (SSH access, docker containers, etc.)  
This file is `.gitignored` and contains environment-specific info not suitable for public repos.

---

## Table of Contents

1. [Workflow Export & Sanitization](#workflow-export--sanitization)
2. [Environment Variables](#environment-variables)
3. [Database Schema](#database-schema)
4. [Code Style & Conventions](#code-style--conventions)
5. [Git Commit Guidelines](#git-commit-guidelines)
6. [Testing Workflows](#testing-workflows)
7. [Documentation Updates](#documentation-updates)

---

## Workflow Export & Sanitization

### ⚠️ CRITICAL: Always Sanitize Before Committing

**Before committing any changes to n8n workflow files:**

```bash
# Run sanitization script
./sanitize_workflows.sh

# Verify changes
git diff n8n-workflows/*.json

# Only then commit
git add n8n-workflows/*.json
git commit -m "your message"
```

### Why Sanitize?

n8n workflow exports contain a `pinData` section with test execution data that includes:
- Real Discord IDs (guild, channel, message IDs)
- Real webhook paths
- User information
- Actual message content from testing

**The sanitization script removes this sensitive data.**

### Workflow Export Process

1. **Make changes in n8n UI**
2. **Test the workflow** with real data
3. **Export the workflow** (Download as JSON)
4. **Save to** `n8n-workflows/` directory
5. **Run sanitization script:** `./sanitize_workflows.sh`
6. **Review the diff:** `git diff n8n-workflows/*.json`
7. **Commit the sanitized file**

### Manual Verification Checklist

Before committing workflow files, verify:

- [ ] No `pinData` section exists
- [ ] No hardcoded Discord IDs (should use `{{ $env.DISCORD_* }}`)
- [ ] No hardcoded webhook paths (should use `{{ $env.WEBHOOK_PATH }}`)
- [ ] No real API keys or tokens
- [ ] No personal/test data in node configurations

---

## Environment Variables

### Required Variables

All sensitive configuration must use environment variables:

| Variable | Usage | Example |
|----------|-------|---------|
| `WEBHOOK_PATH` | Webhook security path | `abc123xyz789` |
| `DISCORD_GUILD_ID` | Discord server ID | Used in conditionals |
| `DISCORD_CHANNEL_ARCANE_SHELL` | Main input channel | For posting responses |
| `DISCORD_CHANNEL_KAIRON_LOGS` | Logging channel | For debug/classification logs |
| `OPENROUTER_API_KEY` | LLM API access | For Message Classifier |
| `POSTGRES_*` | Database credentials | For all DB operations |

### Using Environment Variables in n8n

**Syntax:**
```javascript
{{ $env.VARIABLE_NAME }}
```

**Example node configurations:**
```javascript
// Webhook node - Path field
{{ $env.WEBHOOK_PATH }}

// Discord node - Channel ID field
{{ $env.DISCORD_CHANNEL_KAIRON_LOGS }}

// Code node - Accessing in JavaScript
const guildId = $env.DISCORD_GUILD_ID;
const webhookPath = $env.WEBHOOK_PATH;
```

### Never Hardcode

❌ **Don't do this:**
```javascript
"path": "asoiaf92746087"
"channelId": "1450655614421303367"
```

✅ **Do this instead:**
```javascript
"path": "={{ $env.WEBHOOK_PATH }}"
"channelId": "={{ $env.DISCORD_CHANNEL_KAIRON_LOGS }}"
```

---

## Database Schema

### ⚠️ IMPORTANT: Migration in Progress

**Current state:** Transitioning from legacy schema to Event-Trace-Projection architecture (see `docs/simplified-extensible-schema.md`)

**Target schema (Migration 006):**
- **`events`** - Immutable event log (replaces raw_events)
- **`traces`** - LLM reasoning chains (replaces routing_decisions, adds multi-step support)
- **`projections`** - Structured outputs (replaces activity_log, notes, todos, thread_extractions)
- **`embeddings`** - Vector embeddings for RAG (new table, unpopulated initially)

**Legacy schema (still active):**
- `raw_events`, `routing_decisions`, `activity_log`, `notes`, `todos`, `conversations`, `thread_messages`, `user_state`, `config`

### Schema Locations

- **Current schema:** `db/migrations/001-005_*.sql`
- **New architecture design:** `docs/simplified-extensible-schema.md`
- **Migration 006 (pending):** `db/migrations/006_events_traces_projections.sql`

### New Architecture: Event-Trace-Projection Pattern

**Core Principle:** Separate "The Truth" (events) from "The Interpretation" (traces + projections)

**4-Table Structure:**

1. **`events`** - Immutable facts (Discord messages, reactions, corrections, cron)
   - All events MUST have idempotency_key (never null)
   - Event types: discord_message, user_correction, thread_save, cron_trigger, etc.
   - Payload stored as JSONB (flexible schema)

2. **`traces`** - LLM reasoning chains (multi-step, cancellable)
   - Links: event_id (source) + parent_trace_id (chain structure)
   - All LLM data in JSONB: result, prompt, confidence, duration_ms
   - Supports voiding/correction via voided_at + superseded_by_trace_id

3. **`projections`** - Structured outputs (activities, notes, todos, thread_extractions)
   - References: trace_id + event_id + trace_chain (full audit trail)
   - Categories stored as strings in JSONB (no enums = no migrations)
   - Status lifecycle: pending → auto_confirmed/confirmed → voided
   - Correction tracking: superseded_by_projection_id, voided_reason

4. **`embeddings`** - Vector embeddings for RAG (unpopulated initially)
   - One-to-many with projections (multi-model support)
   - Easy model upgrades without touching projections

**Key Design Decisions:**

- **JSONB-first:** All LLM output in JSONB, minimal fixed columns
- **No category enums:** Categories hardcoded in n8n prompts (easy iteration)
- **Tag detection ≠ trace:** Tags (!!, .., ++, ::) are deterministic, happen before traces
- **Multi-extraction:** Single LLM call extracts all types (activity + note + todo)
- **Progressive feedback:** Single message with emoji updates (🛑 → 🕒 → ✅ → 🔄)
- **Correction without deletion:** Void old projection, create new one, keep audit trail

### Category System (Hardcoded in Prompts, Not DB)

**Activity categories:** work, leisure, study, health, sleep, relationships, admin
**Note categories:** fact (external knowledge), reflection (internal knowledge)

**Why hardcoded in prompts instead of enums?**
- ✅ No migrations when adding categories
- ✅ Fast iteration on category definitions
- ✅ Categories stored as strings in JSONB
- ✅ Can migrate to DB table later if iteration speed becomes bottleneck

### Important Patterns

**Root Channel vs Threads (Critical Distinction):**
```javascript
// Root channel (#arcane-shell): Immediate multi-extraction
// - Atomic messages (no context needed)
// - Extract ALL types: activity + note + todo
// - Time-sensitive (accurate timestamps)
// - Single LLM call per message

// Threads: Extract once on save
// - Long conversations (full context needed)
// - NO continuous extraction (spammy, inaccurate)
// - NO activities extracted (not time-sensitive)
// - Extract on thread save only
```

**Tag as Hard Override:**
```javascript
// Tags skip multi-extraction, go straight to handler
!! → Extract ONLY activity (no notes/todos)
.. → Extract ONLY note (no activities/todos)
++ → Thread start ONLY (no extraction)
:: → Command ONLY (no extraction)
(no tag) → Multi-extraction (all types)
```

**Idempotency (events table):**
```sql
-- ✅ Always use ON CONFLICT for events
INSERT INTO events (event_type, source, payload, idempotency_key)
VALUES ('discord_message', 'discord', $1, $2)
ON CONFLICT (event_type, idempotency_key) DO NOTHING
RETURNING *;
```

**Query projections (exclude voided):**
```sql
-- ✅ Show only valid activities
SELECT * FROM projections
WHERE projection_type = 'activity'
  AND status IN ('auto_confirmed', 'confirmed')
  AND data->>'category' = 'work'
ORDER BY (data->>'timestamp')::timestamptz DESC;

-- ✅ Show recent notes
SELECT * FROM projections
WHERE projection_type = 'note'
  AND status IN ('auto_confirmed', 'confirmed')
ORDER BY created_at DESC;
```

**Trace chains (audit trail):**
```sql
-- ✅ Get full reasoning chain for a projection
SELECT t.* FROM traces t
WHERE t.id = ANY((SELECT trace_chain FROM projections WHERE id = $1));

-- ✅ Find corrections
SELECT 
  p_old.data->>'category' as old_category,
  p_new.data->>'category' as new_category
FROM projections p_old
JOIN projections p_new ON p_old.superseded_by_projection_id = p_new.id
WHERE p_old.voided_reason = 'user_correction';
```

---

## Code Style & Conventions

### Object Key Naming

**IMPORTANT:** Always use `snake_case` for object keys in all workflows.

```javascript
// ✅ Correct
{
  raw_event_id: "uuid",
  clean_text: "message",
  guild_id: "123",
  all_scores: { work: 0.9, leisure: 0.1 }
}

// ❌ Wrong
{
  rawEventId: "uuid",      // camelCase
  CleanText: "message",    // PascalCase
  "guild-id": "123",       // kebab-case
  AllScores: { work: 0.9 } // PascalCase
}
```

**Why snake_case?**
- Consistent with database column names
- Easier to map between DB and JSON
- Standard in Python ecosystem (discord_relay.py)
- More readable in n8n expressions

### n8n Workflow Naming

- **Workflows:** PascalCase with underscores: `Discord_Message_Router`, `Command_Handler`
- **Nodes:** Descriptive names: "Parse Tag", "Store Raw Event", "Handle !! Activity"
- **Sticky notes:** Use for documentation sections

### n8n Merge Nodes

**CRITICAL:** Always configure Merge nodes properly!

```json
// ✅ Correct
{
  "parameters": {
    "mode": "append",
    "numberInputs": 2  // or 3, 4, etc. - must match actual connections!
  },
  "type": "n8n-nodes-base.merge"
}

// ❌ Wrong
{
  "parameters": {},  // Missing mode and numberInputs!
  "type": "n8n-nodes-base.merge"
}
```

**Why this matters:**
- `mode: "append"` - Combines all inputs into one array (what we almost always want)
- `mode: "combine"` - Tries to merge by position (rarely useful, causes issues)
- `numberInputs` - Must match the number of incoming connections or nodes won't connect

**Common mistake:** Creating merge node with empty parameters, then wondering why connections fail or data is duplicated.

### Node Organization

**Visual Layout:**
- Left to right flow: Webhook → Processing → Response
- Group related nodes with sticky note backgrounds
- Use consistent spacing (align nodes to grid)

**Node Colors (via sticky notes):**
- 🟦 Blue: Main routing path
- 🟨 Yellow: LLM/AI operations
- 🟩 Green: Database operations
- 🟧 Orange: External API calls
- 🟪 Purple: Thread/conversation handling

---

## Error Handling & Resilience

### ⚠️ CRITICAL: Workflows Must Be Antifragile

**Principle:** Workflows should NEVER die silently. Always inform the user when something goes wrong.

### Error Handling Patterns

#### 1. **Database Queries - Always Handle Failures**

```javascript
// ✅ Good: Set alwaysOutputData and handle empty results
{
  "parameters": {
    "operation": "executeQuery",
    "query": "SELECT * FROM activities WHERE id = $1",
    "options": { "queryReplacement": "={{ $json.short_id || '' }}" }
  },
  "alwaysOutputData": true  // Continue even if query fails
}

// In downstream Code node:
const result = $input.item.json;
if (!result || !result.id) {
  return {
    response: "❌ Activity not found with that ID",
    ...event
  };
}
```

#### 2. **SQL Queries - Handle Missing Parameters**

```sql
-- ❌ Bad: Breaks when $1 is empty or null
WHERE item_type = $1

-- ✅ Good: Provide fallback values
WHERE COALESCE($1, 'activities') IN ('activities', 'activity', '')

-- ✅ Good: Handle optional parameters
WHERE $1::text = '' OR category_name = $1::text
```

#### 3. **LLM Calls - Always Have Fallbacks**

```javascript
// ✅ Good: Use needsFallback in LLM chain
{
  "parameters": {
    "promptType": "define",
    "text": "...",
    "needsFallback": true  // Use fallback model if primary fails
  },
  "type": "@n8n/n8n-nodes-langchain.chainLlm"
}
```

#### 4. **Code Nodes - Validate Inputs**

```javascript
// ✅ Good: Check for required data before processing
const args = $('Parse Command and Args').item?.json?.args;
if (!args || args.length === 0) {
  return {
    response: "❌ Missing required argument. Use `::help` for syntax.",
    ...event
  };
}

// ✅ Good: Handle array access safely
const shortId = args[0] || '';
if (shortId.length < 8) {
  return {
    response: "❌ Invalid short ID format. Use `::recent` to see valid IDs.",
    ...event
  };
}

// ✅ Good: Provide helpful error messages
try {
  // risky operation
} catch (error) {
  return {
    response: `❌ Operation failed: ${error.message}\\n\\nUse \`::help\` for correct syntax.`,
    ...event
  };
}
```

#### 5. **User-Facing Error Messages**

**Always include:**
- ❌ Error icon to signal failure
- Clear description of what went wrong
- Hint about how to fix it or where to get help
- Reference to `::help` when appropriate

**Examples:**

```javascript
// ✅ Excellent error messages
"❌ No activities found with ID: a1b2c3d4. Use `::recent activities` to see valid IDs."

"❌ Missing required argument. Syntax: `::delete activity <short-id>`"

"❌ Database query failed. Please try again or use `::help` for assistance."

"❌ Config key 'north_star' not found. Use `::set north_star <value>` to set it first."

// ❌ Bad error messages (never do this)
"Error"
"Failed"
"undefined"
"Query error" (no context or fix)
```

### Testing for Antifragility

**Before committing any workflow, test these edge cases:**

1. **No arguments:** `::recent` (should default to activities, limit 10)
2. **Invalid arguments:** `::delete activity` (missing short_id)
3. **Non-existent IDs:** `::delete activity zzzzzzz`
4. **Empty database:** Test when no activities/notes exist
5. **SQL injection attempts:** `::delete activity '; DROP TABLE--`
6. **Very long inputs:** 500+ character messages
7. **Special characters:** Emojis, unicode, quotes in text
8. **Concurrent requests:** Multiple users at once

### Workflow Configuration for Error Handling

**Postgres nodes:**
```json
{
  "parameters": { "..." },
  "alwaysOutputData": true,  // IMPORTANT: Always set this
  "continueOnFail": false     // Fail loudly, don't hide errors
}
```

**Code nodes:**
```json
{
  "parameters": { "jsCode": "..." },
  "continueOnFail": false,  // Let errors bubble up
  "onError": "stopWorkflow"  // Don't continue with bad data
}
```

### Common Pitfalls

**❌ Don't do this:**
```javascript
// No validation
const result = $input.item.json.data;
return result.value; // What if data is undefined?
```

**✅ Do this instead:**
```javascript
// Defensive programming
const data = $input.item?.json?.data;
if (!data || !data.value) {
  return {
    response: "❌ No data returned from query",
    ...event
  };
}
return { response: data.value, ...event };
```

### Error Handling Checklist

Before committing, verify:

- [ ] All Postgres nodes have `alwaysOutputData: true`
- [ ] All SQL queries handle NULL/$1='' cases
- [ ] All Code nodes validate inputs before processing
- [ ] All error paths return user-friendly messages
- [ ] All error messages include hints or next steps
- [ ] Tested with missing/invalid arguments
- [ ] Tested with empty database state
- [ ] No workflow dies silently (user always gets feedback)

---

### Python (discord_relay.py)

```python
# Follow PEP 8
# Use type hints where helpful
# Use environment variables for config
# Log important events

import os
from typing import Optional

WEBHOOK_URL = os.getenv('N8N_WEBHOOK_URL')
```

### SQL Queries in n8n

```sql
-- Use parameterized queries (prevent SQL injection)
SELECT * FROM activity_log 
WHERE timestamp > $1 
  AND category_id = $2
LIMIT $3;

-- Format for readability
-- Use CTEs for complex queries
WITH recent_acts AS (
  SELECT * FROM activity_log 
  WHERE timestamp > NOW() - INTERVAL '24 hours'
)
SELECT * FROM recent_acts;
```

---

## Git Commit Guidelines

### Commit Message Format

```
<type>: <short summary>

<detailed description>

<bullet points of changes>
- Change 1
- Change 2

<manual steps if needed>
```

### Types

- `feat:` New feature
- `fix:` Bug fix
- `refactor:` Code restructuring (no behavior change)
- `docs:` Documentation only
- `chore:` Maintenance (deps, config, etc.)
- `security:` Security improvements

### Examples

**Good commit:**
```
refactor: Rename Discord_Message_Ingestion to Discord_Message_Router

- Rename workflow for consistency with naming convention
- Update all documentation references
- Create external Command_Handler workflow
- Add ++ fallback when LLM classification fails

Manual steps:
- Update webhook path in n8n UI to use {{ $env.WEBHOOK_PATH }}
```

**Bad commit:**
```
update stuff
```

### Pre-Commit Checklist

Before every commit:

- [ ] Run `./sanitize_workflows.sh` if workflows changed
- [ ] Update relevant documentation (README, docs/)
- [ ] Test changes if possible
- [ ] Check for sensitive data: `git diff | grep -E "(password|token|secret|api_key)"`
- [ ] Review diff: `git diff --staged`

---

## Testing Workflows

### Testing in n8n UI

**Use pinned test data:**
1. Create test execution data
2. Pin it to the webhook node
3. Test workflow with "Test Workflow" button
4. **IMPORTANT:** Delete pinned data before exporting

**Test message examples:**
```javascript
// Activity (tagged)
{ "content": "!! working on the router agent" }

// Activity (untagged - triggers LLM)
{ "content": "debugging authentication bug" }

// Note (untagged)
{ "content": "interesting insight about async communication" }

// Thread start
{ "content": "what did I work on yesterday?" }

// Command
{ "content": ":: ping" }
```

### End-to-End Testing

**Test flow:**
1. Send actual Discord message in #arcane-shell
2. Check Discord for emoji reaction
3. Check #kairon-logs for classification output
4. Verify database: `SELECT * FROM raw_events ORDER BY received_at DESC LIMIT 5;`
5. Check n8n execution logs

**Key test scenarios:**
- Tagged message (`!!`, `..`, `++`, `::`)
- Untagged message (triggers LLM classifier)
- Message in thread
- Malformed message
- Very long message
- Empty message
- Command with args

---

## Documentation Updates

### When to Update Documentation

**Always update documentation when:**
- Adding/changing workflows
- Modifying database schema
- Adding environment variables
- Changing architecture
- Adding new commands
- Modifying prompts

### Documentation Files

| File | Purpose | Update When |
|------|---------|-------------|
| `README.md` | High-level architecture | Major changes |
| `docs/router-agent-implementation.md` | Router implementation | Router changes |
| `docs/n8n-environment-variables.md` | Environment variables | New env vars |
| `docs/n8n-workflow-implementation.md` | Workflow details | Workflow changes |
| `docs/database-setup.md` | Database setup | Schema changes |
| `docs/discord-bot-setup.md` | Discord relay setup | Bot changes |
| `.env.example` | Environment template | New env vars |
| `AGENTS.md` | This file | Agent guidelines change |

### Documentation Style

**Use clear sections:**
```markdown
## Section Title

Brief description of what this section covers.

### Subsection

Specific details.

**Example:**
```code example```
```

**Use status markers:**
- ✅ Completed/implemented
- ⏳ TODO/pending
- ❌ Deprecated/don't use
- ⚠️ Important warning

**Code examples:**
- Always include working examples
- Show both wrong (❌) and correct (✅) approaches
- Include expected output where helpful

---

## Architecture Decisions

### Current Design Patterns

**1. External Handler Workflows**
- Router only does classification + dispatch
- All handlers are separate workflows
- Cleaner, more maintainable
- Easier to test individually

**2. LLM Classification (Not Tool Calling)**
- Simple TAG|CONFIDENCE output format
- Faster, cheaper than function calling (~70% fewer tokens)
- Reuses existing tag routing logic
- Fallback to `++` (conversation) on failure

**3. Hybrid Routing**
- Tags (`!!`, `..`, `++`, `::`) = fast deterministic path
- No tag = LLM classification path
- Best of both worlds: speed + intelligence

**4. Append-Only Event Log**
- `raw_events` table is append-only
- Never delete from raw_events
- Enables replay, debugging, audit trail

**5. Category IDs (Not Names)**
- All FKs use category IDs
- Users can rename categories without breaking history
- Special flags (e.g., `is_sleep_category`) avoid name-based logic

### Design Principles

1. **Security First** - Never commit secrets
2. **Idempotency** - All operations should be safe to retry
3. **Explicit Over Implicit** - Use clear names, avoid magic
4. **Minimize LLM Context** - Only include what's necessary
5. **Fail Safe** - Default to conversation mode (`++`) when uncertain
6. **User Editable** - Categories, config should be user-changeable
7. **Audit Trail** - Keep raw_events forever

---

## Common Pitfalls

### ❌ Don't Do This

**1. Committing unsanitized workflows**
```bash
# ❌ Don't
git add n8n-workflows/*.json
git commit -m "update workflow"
```

**2. Hardcoding IDs**
```javascript
// ❌ Don't
const channelId = "1450655614421303367";
```

**3. Deleting from raw_events**
```sql
-- ❌ Don't
DELETE FROM raw_events WHERE ...;
```

**4. Using category names in queries**
```sql
-- ❌ Don't
WHERE category_name = 'work'
```

**5. Assuming message order**
```javascript
// ❌ Don't assume first() always works
const tag = $json.content.match(/!!|\\+\\+/)[0];
```

### ✅ Do This Instead

**1. Always sanitize before committing**
```bash
# ✅ Do
./sanitize_workflows.sh
git add n8n-workflows/*.json
git commit -m "update workflow"
```

**2. Use environment variables**
```javascript
// ✅ Do
const channelId = $env.DISCORD_CHANNEL_KAIRON_LOGS;
```

**3. Keep raw_events immutable**
```sql
-- ✅ Do (if you need to mark as processed)
UPDATE raw_events SET metadata = jsonb_set(metadata, '{processed}', 'true')
WHERE id = $1;
```

**4. Use category IDs with subqueries**
```sql
-- ✅ Do
WHERE category_id = (SELECT id FROM activity_categories WHERE name = 'work')
```

**5. Use safe extraction with fallbacks**
```javascript
// ✅ Do
const match = $json.content.match(/!!|\\+\\+|::|\\.\\./)
const tag = match ? match[0] : null;
```

---

## Troubleshooting

### Workflow Not Executing

**Check:**
1. Is workflow activated?
2. Are environment variables set? Test with: `return [{ json: { test: $env.WEBHOOK_PATH } }]`
3. Is webhook URL correct in discord_relay.py?
4. Check n8n logs: `docker logs n8n` or `journalctl -u n8n -f`
5. Check Discord bot logs: `journalctl -u kairon-relay -f`

### LLM Classification Failing

**Check:**
1. OpenRouter API key set? `echo $OPENROUTER_API_KEY`
2. Check #kairon-logs for error messages
3. Check raw_events table: `SELECT * FROM raw_events ORDER BY received_at DESC LIMIT 5;`
4. Is fallback to `++` working? (Should always route somewhere)
5. Try reducing prompt length if hitting token limits

### Database Errors

**Check:**
1. Schema up to date? `psql kairon < db/migrations/001_initial_schema.sql`
2. Seed data loaded? `psql kairon < db/seeds/001_initial_data.sql`
3. Connection string correct in n8n credentials?
4. Postgres running? `docker ps` or `systemctl status postgresql`
5. Check n8n execution logs for actual SQL error

### Changes Not Appearing

**Check:**
1. Did you save the workflow in n8n UI?
2. Did you activate the workflow after changes?
3. Did you restart n8n after environment variable changes?
4. Clear browser cache (n8n UI can cache aggressively)
5. Try deactivating and reactivating the workflow

---

## Quick Reference

### Essential Commands

```bash
# Sanitize workflows before commit
./sanitize_workflows.sh

# Check for sensitive data
git diff | grep -E "(password|token|secret|key|[0-9]{18})"

# View recent database events
docker exec -it postgres-db psql -U n8n_user -d kairon -c "SELECT * FROM raw_events ORDER BY received_at DESC LIMIT 10;"

# Check n8n logs
docker logs -f n8n
# or
journalctl -u n8n -f

# Check Discord bot logs
journalctl -u kairon-relay -f

# Restart n8n (Docker)
docker-compose restart n8n

# Restart n8n (systemd)
sudo systemctl restart n8n

# Generate new webhook path
openssl rand -hex 16

# Test Discord bot connection
curl -X POST $N8N_WEBHOOK_URL -H "Content-Type: application/json" -d '{"content": "test"}'
```

### File Locations

```
kairon/
├── n8n-workflows/           # n8n workflow exports (sanitized)
│   ├── Discord_Message_Router.json
│   └── Command_Handler.json
├── db/
│   ├── migrations/          # Database schema
│   └── seeds/               # Initial data
├── docs/                    # Detailed documentation
├── prompts/                 # LLM prompts
├── discord_relay.py         # Discord bot
├── sanitize_workflows.sh    # Workflow sanitization script
├── .env.example             # Environment variable template
├── README.md                # Main documentation
└── AGENTS.md                # This file
```

### n8n Expression Cheatsheet

```javascript
// Environment variables
{{ $env.VARIABLE_NAME }}

// Previous node output
{{ $('Node Name').item.json.field }}
{{ $('Node Name').first().json.field }}
{{ $('Node Name').all()[0].json.field }}

// Current item
{{ $json.field }}

// Regular expressions
{{ $json.content.match(/pattern/).first() }}
{{ $json.content.replace(/pattern/, 'replacement') }}

// Fallback values
{{ $json.field || 'default' }}
{{ $json.field ?? 'default' }}

// Conditionals in Set node
{{ $json.value > 5 ? 'high' : 'low' }}

// Arrays
{{ $json.items.length }}
{{ $json.items.map(i => i.name) }}
{{ $json.items.filter(i => i.active) }}
```

---

## Getting Help

### Resources

1. **Project Documentation:** Start with `README.md` and `docs/` folder
2. **n8n Documentation:** https://docs.n8n.io/
3. **Discord API:** https://discord.com/developers/docs
4. **PostgreSQL Docs:** https://www.postgresql.org/docs/

### When Asking Questions

**Provide:**
- What you're trying to do
- What you expected to happen
- What actually happened
- Relevant logs/errors
- Steps to reproduce

**Example:**
```
Issue: LLM classifier not outputting valid tags

Expected: Should output "!!|high" format
Actual: Getting "Activity: work" format
Logs: [paste n8n execution log]

Steps to reproduce:
1. Send message "working on router" to #arcane-shell
2. Check #kairon-logs output
3. See incorrect format
```

---

## Contributing

### Workflow for Changes

1. **Understand the change** - Read relevant docs
2. **Make changes in n8n UI** - Test thoroughly
3. **Export workflows** - Download as JSON
4. **Sanitize exports** - Run `./sanitize_workflows.sh`
5. **Update documentation** - Keep docs in sync
6. **Test end-to-end** - Real Discord messages
7. **Commit with good message** - Follow guidelines above
8. **Push to main** - Or create PR if major change

### Code Review Checklist

When reviewing changes:

- [ ] Workflows sanitized (no pinData)
- [ ] No hardcoded secrets/IDs
- [ ] Environment variables used correctly
- [ ] Documentation updated
- [ ] Commit message follows guidelines
- [ ] Changes tested end-to-end
- [ ] No breaking changes to database schema (or migration provided)
- [ ] Backwards compatible with existing data

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2024-12-17 | Initial version with sanitization guidelines |

---

**Remember:** When in doubt, sanitize! It's better to run `./sanitize_workflows.sh` too often than to accidentally commit sensitive data.
