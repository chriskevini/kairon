# Technical Debt Audit - December 2025

This audit identifies technical debt across the Kairon codebase, organized by priority and area.

## Executive Summary

| Area | Critical | High | Medium | Low |
|------|----------|------|--------|-----|
| n8n Workflows | 2 | 4 | 3 | 2 |
| Database | 2 | 2 | 3 | 1 |
| Python Code | 1 | 3 | 4 | 2 |
| Shell Scripts | 1 | 2 | 3 | 2 |
| Documentation | 2 | 3 | 4 | 2 |

---

## 1. n8n Workflows

### Critical

#### 1.1 Missing Merge Wrappers for Native Nodes
**Impact:** Data loss when Postgres/HTTP nodes overwrite `$json`

~80% of Postgres and HTTP nodes lack Merge wrappers to restore `ctx`. This breaks the ctx pattern documented in AGENTS.md.

**Affected Workflows:**
- `Capture_Projection.json` - `Store Projection` node
- `Handle_Correction.json` - `Lookup Original Event` node
- `Multi_Capture.json` - `Store LLM Trace` node
- `Generate_Daily_Summary.json` - `Insert Event` node
- `Generate_Nudge.json` - `Insert Event` node
- `Route_Reaction.json` - `Get Emoji Config` node

**Fix:** Add Merge node (Mode: Append) after each native node to restore ctx.

#### 1.2 ctx Pattern Violations (Node References)
**Impact:** Tight coupling, breaks if nodes are moved/renamed

Nodes reading from `$('Node Name').item.json` instead of `$json.ctx.*`:

| Workflow | Node | Issue |
|----------|------|-------|
| `Capture_Projection.json` | `Prepare Projection` | Reads from `$('Extract Projection Data')` |
| `Save_Extraction.json` | `Prepare Save` | Reads from `$('Get Pending Extractions')` |
| `Handle_Correction.json` | `Prepare Correction` | Reads from `$('Execute Workflow Trigger')` |
| `Multi_Capture.json` | `Parse & Split` | Reads from `$('Prepare Capture')` |
| `Generate_Daily_Summary.json` | `init-ctx` | Reads from `$('Prepare Event Data')` |

**Fix:** Refactor to read from `$json.ctx.*` exclusively.

### High

#### 1.3 Hardcoded Workflow IDs
Workflows use hardcoded IDs instead of names or environment variables:

- `Route_Event.json` - Hardcoded IDs for `Route_Message`, `Route_Reaction`, `Execute_Command`
- `Route_Reaction.json` - Hardcoded IDs for `Save_Extraction`, `Handle_Correction`
- `Handle_Correction.json` - Hardcoded ID for `Capture_Projection`

**Fix:** Use workflow names or move IDs to environment variables.

#### 1.4 Switch Nodes Without Defaults
Some Switch nodes lack fallback cases, causing silent failures when no match occurs.

#### 1.5 Set Nodes with "Keep Only Set"
Older nodes in `Execute_Command.json` use "Keep Only Set" behavior, dropping the `ctx` object.

**Fix:** Enable `includeOtherFields: true` on all Set nodes.

### Medium

#### 1.6 Inconsistent Error Handling
Not all workflows return user-friendly error messages on failure.

#### 1.7 Missing ctx Initialization
Some workflows don't initialize `ctx.event` in the first node, especially system-triggered ones like `Generate_Daily_Summary`.

---

## 2. Database Schema

### Critical

#### 2.1 Missing GIN Indexes
Migration 006 originally included GIN indexes on `events.payload` and `projections.data`, but these are **missing** from `db/schema.sql`.

```sql
-- Add to schema.sql
CREATE INDEX idx_events_payload_gin ON events USING gin(payload);
CREATE INDEX idx_projections_data_gin ON projections USING gin(data);
```

**Impact:** Full table scans when searching JSONB fields.

#### 2.2 Broken Seed File
`db/seeds/001_initial_data.sql` references `activity_categories` and `note_categories` tables that were dropped in Migration 013.

**Impact:** Fresh installs fail.

**Fix:** Remove or update the seed file.

### High

#### 2.3 Nullable Foreign Keys
`projections.trace_id` and `projections.event_id` are nullable despite the architecture requiring them.

**Fix:** Add `NOT NULL` constraints after confirming no orphaned data.

#### 2.4 Nullable Idempotency Key
`events.idempotency_key` should be `NOT NULL` per Migration 006 documentation.

### Medium

#### 2.5 View Performance
`recent_projections` view performs `LEFT JOIN` and `ORDER BY` on casted JSONB fields. Consider materialized view.

#### 2.6 Embeddings Table Downgrade
`embeddings.embedding_data` uses JSONB instead of `pgvector`, which is inefficient for similarity searches.

#### 2.7 Timezone Column Usage
Migration 019 added `timezone` columns. Ensure all workflows populate this field.

---

## 3. Python Code

### Critical

#### 3.1 Inefficient HTTP Connection Handling
**File:** `discord_relay.py:106`

Creates a new `aiohttp.ClientSession()` for every request. This causes socket exhaustion under load.

```python
# Current (bad)
async with aiohttp.ClientSession() as session:
    await session.post(url, json=payload)

# Fix: Use persistent session attached to bot
```

### High

#### 3.2 Logic Duplication
**File:** `discord_relay.py:150, 187, 220`

Channel filtering logic for `#arcane-shell` is duplicated 3 times.

**Fix:** Extract to helper function or decorator.

#### 3.3 Hardcoded Absolute Paths
**Files:**
- `test_json_files.py:98` - Hardcoded `/home/chris/Work/kairon/n8n-workflows`
- `fix_json_files.py:73` - Same hardcoded path

**Fix:** Use `Path(__file__).parent` for relative paths.

#### 3.4 Zero Test Coverage
No unit tests exist. Critical gaps in:
- Payload formatting logic (`format_message_payload`)
- ctx-pattern linter regex rules

### Medium

#### 3.5 Unpinned Dependencies
`requirements.txt` uses `>=` instead of exact versions, risking build breaks.

#### 3.6 Missing Type Hints
Many functions lack return types and parameter types.

#### 3.7 SSH Command Injection Risk
**File:** `scripts/workflows/inspect_execution.py:57`

Builds shell commands via string interpolation.

**Fix:** Use `shlex.quote()` for all interpolated values.

#### 3.8 Manual .env Parsing
**File:** `scripts/workflows/inspect_execution.py:26`

Manually parses `.env` instead of using `python-dotenv`.

---

## 4. Shell Scripts

### Critical

#### 4.1 SQL Injection in setup_db.sh
**File:** `scripts/db/setup_db.sh:66-70`

User input is interpolated directly into SQL:
```bash
VALUES ('$DISCORD_USER', false, NULL)
```

**Fix:** Use `psql` variables (`-v`) or validate input.

### High

#### 4.2 Missing `set -u`
All scripts lack `set -u` (nounset), allowing undefined variable usage.

**Fix:** Use `set -euo pipefail` in all scripts.

#### 4.3 Fragile .env Loading
**Files:** `n8n-pull.sh`, `n8n-push.sh`, `run-migration.sh`, `db-query.sh`

Pattern `export $(grep -v '^#' "$ENV_FILE" | xargs)` fails with spaces/special chars.

### Medium

#### 4.4 Code Duplication
`.env` loading, path resolution, and SSH setup are copy-pasted across 4+ scripts.

**Fix:** Extract to `scripts/common.sh`.

#### 4.5 Inconsistent Quoting
Variable quoting is inconsistent, especially in SQL contexts.

#### 4.6 Slow Pre-commit Hook
`.githooks/pre-commit` calls Python for each file individually.

**Fix:** Batch all files to single Python invocation.

---

## 5. Documentation

### Critical

#### 5.1 Outdated Architecture Docs
**File:** `docs/n8n-workflow-implementation.md`

References deprecated "original architecture" with old workflow names and patterns.

**Fix:** Archive or rewrite.

#### 5.2 Inconsistent Tag Definitions
Tags defined differently across documents:

| Document | `++` Tag Name |
|----------|---------------|
| `AGENTS.md` | "Start chat thread" |
| `docs/tag-parsing-reference.md` | "Thread Start" |
| `docs/SUMMARY.md` | "ask" |

Also, `AGENTS.md` is missing `--`, `::`, and `$$` tags.

**Fix:** Make `docs/tag-parsing-reference.md` the single source of truth.

### High

#### 5.3 Deprecated Prompt References
**File:** `prompts/router-agent.md`

- Still uses "Tool Calling" format (deprecated)
- References "Note Titles" (removed in migration 002b)

**Fix:** Update to `TAG|CONFIDENCE` format.

#### 5.4 Category Implementation Confusion
`AGENTS.md` says "Categories are strings in JSONB (not enums)" but `docs/SUMMARY.md` discusses "fixed enums".

**Fix:** Clarify actual implementation.

#### 5.5 Missing Workflow Documentation
No docs for `Handle_Todo_Status.json` or `Handle_Correction.json`.

### Medium

#### 5.6 Stale TODO Comments
- `docs/router-agent-implementation.md:320` - References deprecated title extraction
- `docs/thread-continuation-agent-implementation.md:384` - Incomplete implementation notes

#### 5.7 Implementation Status Inconsistencies
- `docs/router-agent-implementation.md` marked "Not Implemented"
- `docs/todo-intent-design.md` marked "Pending"
- No tracking of what's actually live

#### 5.8 Broken Migration References
Documents reference migrations in `db/migrations/` but most are in `archive/`.

---

## Recommended Priority Order

### Phase 1: Critical Fixes (Week 1)
1. Add GIN indexes to schema.sql
2. Fix broken seed file
3. Refactor `discord_relay.py` to use persistent session
4. Add SQL injection protection to `setup_db.sh`

### Phase 2: High Priority (Week 2-3)
1. Add Merge wrappers to all native nodes in workflows
2. Refactor ctx pattern violations
3. Add `set -euo pipefail` to all scripts
4. Update outdated documentation (AGENTS.md tags, prompts)

### Phase 3: Medium Priority (Month 1)
1. Extract common shell functions
2. Add basic test coverage for Python
3. Pin dependencies
4. Consolidate documentation inconsistencies

### Phase 4: Ongoing
1. Add workflow documentation as features ship
2. Improve type hints
3. Consider materialized views for performance
