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

#### 1.1 ~~Missing Merge Wrappers for Native Nodes~~ RESOLVED
~~**Impact:** Data loss when Postgres/HTTP nodes overwrite `$json`~~

**Status:** RESOLVED (Dec 2025) - Merge wrappers added in commits 6ac2fbf, 2babfd9.

#### 1.2 ~~ctx Pattern Violations (Node References)~~ RESOLVED
~~**Impact:** Tight coupling, breaks if nodes are moved/renamed~~

**Status:** RESOLVED (Dec 2025) - Refactored to read from `$json.ctx.*` in commits 6ac2fbf, 2babfd9.

### High

#### 1.3 Hardcoded Workflow IDs
Workflows use hardcoded IDs instead of names or environment variables:

- `Route_Event.json` - Hardcoded IDs for `Route_Message`, `Route_Reaction`, `Execute_Command`
- `Route_Reaction.json` - Hardcoded IDs for `Save_Extraction`, `Handle_Correction`
- `Handle_Correction.json` - Hardcoded ID for `Capture_Projection`

**Fix:** Use workflow names or move IDs to environment variables.

#### 1.4 Switch Nodes Without Defaults
Some Switch nodes lack fallback cases, causing silent failures when no match occurs.

#### 1.5 ~~Set Nodes with "Keep Only Set"~~ RESOLVED
~~Older nodes in `Execute_Command.json` use "Keep Only Set" behavior, dropping the `ctx` object.~~

**Status:** RESOLVED (Dec 2025) - `includeOtherFields: true` added in commit 5aa298c.

### Medium

#### 1.6 Inconsistent Error Handling
Not all workflows return user-friendly error messages on failure.

#### 1.7 Missing ctx Initialization
Some workflows don't initialize `ctx.event` in the first node, especially system-triggered ones like `Generate_Daily_Summary`.

---

## 2. Database Schema

### Critical

#### 2.1 ~~Missing GIN Indexes~~ RESOLVED
~~Migration 006 originally included GIN indexes on `events.payload` and `projections.data`, but these are **missing** from `db/schema.sql`.~~

**Status:** RESOLVED (Dec 2025) - GIN indexes were present but **unused** (0 scans in pg_stat_user_indexes). All queries use `->>` (text extraction), not `@>` (containment). GIN only optimizes containment queries. Migration 020 dropped these indexes to reduce write overhead. Future RAG will use pgvector, not GIN.

#### 2.2 ~~Broken Seed File~~ RESOLVED
~~`db/seeds/001_initial_data.sql` references `activity_categories` and `note_categories` tables that were dropped in Migration 013.~~

**Status:** RESOLVED - Seed file was already updated to only seed the `config` table.

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

#### 3.1 ~~Inefficient HTTP Connection Handling~~ RESOLVED
~~**File:** `discord_relay.py:106`~~

~~Creates a new `aiohttp.ClientSession()` for every request. This causes socket exhaustion under load.~~

**Status:** RESOLVED - `discord_relay.py` now uses a persistent `http_session` global initialized in `on_ready()`.

### High

#### 3.2 ~~Logic Duplication~~ RESOLVED
~~**File:** `discord_relay.py:150, 187, 220`~~

~~Channel filtering logic for `#arcane-shell` is duplicated 3 times.~~

**Status:** RESOLVED - Extracted to `is_arcane_shell_channel()` helper function.

#### 3.3 Hardcoded Absolute Paths
**Files:**
- `test_json_files.py:98` - Hardcoded `/home/chris/Work/kairon/n8n-workflows`
- `fix_json_files.py:73` - Same hardcoded path

**Fix:** Use `Path(__file__).parent` for relative paths.

#### 3.4 ~~Zero Test Coverage~~ RESOLVED
~~No unit tests exist. Critical gaps in:~~
~~- Payload formatting logic (`format_message_payload`)~~
~~- ctx-pattern linter regex rules~~

**Status:** RESOLVED (Dec 2025) - Added 12 unit tests for `discord_relay.py` covering channel filtering and payload formatting.

### Medium

#### 3.5 ~~Unpinned Dependencies~~ RESOLVED
~~`requirements.txt` uses `>=` instead of exact versions, risking build breaks.~~

**Status:** RESOLVED (Dec 2025) - Dependencies pinned to exact versions.

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

#### 4.1 ~~SQL Injection in setup_db.sh~~ RESOLVED
~~**File:** `scripts/db/setup_db.sh:66-70`~~

~~User input is interpolated directly into SQL~~

**Status:** RESOLVED - The referenced code no longer exists in `setup_db.sh`.

### High

#### 4.2 ~~Missing `set -u`~~ RESOLVED
~~All scripts lack `set -u` (nounset), allowing undefined variable usage.~~

**Status:** RESOLVED (Dec 2025) - All scripts now use `set -euo pipefail`. Fixed unbound variable issues with `${1:-}` and `${ARRAY[$key]:-}` syntax.

#### 4.3 Fragile .env Loading
**Files:** `n8n-pull.sh`, `n8n-push.sh`, `run-migration.sh`, `db-query.sh`

Pattern `export $(grep -v '^#' "$ENV_FILE" | xargs)` fails with spaces/special chars.

### Medium

#### 4.4 ~~Code Duplication~~ RESOLVED
~~`.env` loading, path resolution, and SSH setup are copy-pasted across 4+ scripts.~~

**Status:** RESOLVED (Dec 2025) - Extracted to `scripts/common.sh` with `kairon_init`, `kairon_require_vars`, `kairon_setup_ssh` functions.

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

#### 5.2 ~~Inconsistent Tag Definitions~~ RESOLVED
~~Tags defined differently across documents~~

**Status:** RESOLVED (Dec 2025) - `AGENTS.md` updated with complete tag definitions. Outdated `docs/SUMMARY.md` removed.

### High

#### 5.3 Deprecated Prompt References
**File:** `prompts/router-agent.md`

- Still uses "Tool Calling" format (deprecated)
- References "Note Titles" (removed in migration 002b)

**Fix:** Update to `TAG|CONFIDENCE` format.

#### 5.4 ~~Category Implementation Confusion~~ RESOLVED
~~`AGENTS.md` says "Categories are strings in JSONB (not enums)" but `docs/SUMMARY.md` discusses "fixed enums".~~

**Status:** RESOLVED (Dec 2025) - Removed outdated `docs/SUMMARY.md`. `AGENTS.md` is the source of truth.

#### 5.5 ~~Missing Workflow Documentation~~ RESOLVED
~~No docs for `Handle_Todo_Status.json` or `Handle_Correction.json`.~~

**Status:** RESOLVED (Dec 2025) - Added to workflow table in README.md.

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

### Phase 1: Critical Fixes ~~(Week 1)~~ COMPLETED
1. ~~Add GIN indexes to schema.sql~~ - RESOLVED: Dropped unused indexes instead (migration 020)
2. ~~Fix broken seed file~~ - RESOLVED: Already fixed
3. ~~Refactor `discord_relay.py` to use persistent session~~ - RESOLVED: Already implemented
4. ~~Add SQL injection protection to `setup_db.sh`~~ - RESOLVED: Code no longer exists

### Phase 2: High Priority ~~(Week 2-3)~~ COMPLETED
1. ~~Add Merge wrappers to all native nodes in workflows~~ - RESOLVED (commits 6ac2fbf, 2babfd9)
2. ~~Refactor ctx pattern violations~~ - RESOLVED (commits 6ac2fbf, 2babfd9)
3. ~~Add `set -euo pipefail` to all scripts~~ - RESOLVED (Dec 2025)
4. ~~Update outdated documentation (AGENTS.md tags, prompts)~~ - RESOLVED (commit e0a2469)

### Phase 3: Medium Priority ~~(Month 1)~~ COMPLETED
1. ~~Extract common shell functions~~ - RESOLVED (Dec 2025) - `scripts/common.sh`
2. ~~Add basic test coverage for Python~~ - RESOLVED (Dec 2025) - 12 tests for discord_relay.py
3. ~~Pin dependencies~~ - RESOLVED (Dec 2025) - Exact versions in requirements.txt
4. ~~Consolidate documentation inconsistencies~~ - RESOLVED (Dec 2025) - Removed outdated SUMMARY.md

### Phase 4: Ongoing
1. Add workflow documentation as features ship
2. Improve type hints
3. Consider materialized views for performance
