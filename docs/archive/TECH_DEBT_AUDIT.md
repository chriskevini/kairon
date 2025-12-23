# Technical Debt Audit - December 2025

This audit identifies technical debt across the Kairon codebase, organized by priority and area.

## Executive Summary

**Status: Nearly all critical and high-priority items resolved.**

| Area | Resolved | Remaining (Low Priority) |
|------|----------|-------------------------|
| n8n Workflows | 7 | 0 |
| Database | 5 | 2 (views, embeddings) |
| Python Code | 7 | 1 (type hints) |
| Shell Scripts | 4 | 2 (quoting, pre-commit speed) |
| Documentation | 8 | 0 |

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

#### 1.3 ~~Hardcoded Workflow IDs~~ NOT AN ISSUE
~~Workflows use hardcoded IDs instead of names or environment variables~~

**Status:** NOT AN ISSUE (Dec 2025) - n8n workflow IDs are stable and don't change. The IDs are generated once when workflows are created and persist across deployments. n8n doesn't support name-based workflow references, so using IDs is the standard approach. Moving to env vars would add complexity without benefit.

#### 1.4 ~~Switch Nodes Without Defaults~~ NOT AN ISSUE
~~Some Switch nodes lack fallback cases, causing silent failures when no match occurs.~~

**Status:** NOT AN ISSUE (Dec 2025) - Audited all Switch nodes. Most have `fallbackOutput: extra` or explicit fallback outputs. The one exception (`Save_Extraction: What Action` with `fallbackOutput: none`) is intentional - unknown emojis are filtered upstream in Route_Reaction before reaching this workflow.

#### 1.5 ~~Set Nodes with "Keep Only Set"~~ RESOLVED
~~Older nodes in `Execute_Command.json` use "Keep Only Set" behavior, dropping the `ctx` object.~~

**Status:** RESOLVED (Dec 2025) - `includeOtherFields: true` added in commit 5aa298c.

### Medium

#### 1.6 ~~Inconsistent Error Handling~~ RESOLVED
~~Not all workflows return user-friendly error messages on failure.~~

**Status:** RESOLVED (Dec 2025) - All 15 workflows now have error handling. 14 of 15 workflows have `errorWorkflow` configured pointing to `Handle_Error` workflow (the exception is `Handle_Error` itself). The global error handler adds ❌ reactions, removes 🔵 processing indicators, and posts error details to the logs channel.

#### 1.7 ~~Missing ctx Initialization~~ RESOLVED
~~Some workflows don't initialize `ctx.event` in the first node, especially system-triggered ones like `Generate_Daily_Summary`.~~

**Status:** RESOLVED (Dec 2025) - Workflow linter confirms all workflows pass ctx pattern validation. System-triggered workflows (`Generate_Daily_Summary`, `Generate_Nudge`) have dedicated "initialize_ctx" Code nodes. Sub-workflows (`Handle_Todo_Status`, `Route_Message`, etc.) receive ctx from parent workflows via `executeWorkflowTrigger`.

#### 1.8 Timezone in Projections
Migration 019 added `timezone` columns to projections. All workflows should populate this field.

**Status:** RESOLVED (Dec 2025) - Added timezone to projection INSERTs in 5 workflows: Capture_Thread, Continue_Thread, Generate_Daily_Summary, Multi_Capture, Start_Thread.

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

#### 2.3 ~~Nullable Foreign Keys~~ RESOLVED
~~`projections.trace_id` and `projections.event_id` are nullable despite the architecture requiring them.~~

**Status:** RESOLVED (Dec 2025) - Migration 021 added NOT NULL constraints. Data audit confirmed no null values existed.

#### 2.4 ~~Nullable Idempotency Key~~ RESOLVED
~~`events.idempotency_key` should be `NOT NULL` per Migration 006 documentation.~~

**Status:** RESOLVED (Dec 2025) - Migration 021 added NOT NULL constraint. Data audit confirmed no null values existed.

### Medium

#### 2.5 View Performance
`recent_projections` view performs `LEFT JOIN` and `ORDER BY` on casted JSONB fields. Consider materialized view.

#### 2.6 Embeddings Table Downgrade
`embeddings.embedding_data` uses JSONB instead of `pgvector`, which is inefficient for similarity searches.

#### 2.7 ~~Timezone Column Usage~~ RESOLVED
~~Migration 019 added `timezone` columns. Ensure all workflows populate this field.~~

**Status:** RESOLVED (Dec 2025) - All projection INSERT statements now include timezone. User-triggered workflows use `$json.ctx.event.timezone`, system-triggered workflows use `(SELECT value FROM config WHERE key = 'timezone')`.

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

#### 3.3 ~~Hardcoded Absolute Paths~~ RESOLVED
~~**Files:**~~
~~- `test_json_files.py:98` - Hardcoded `/home/chris/Work/kairon/n8n-workflows`~~
~~- `fix_json_files.py:73` - Same hardcoded path~~

**Status:** RESOLVED (Dec 2025) - Refactored to use `Path(__file__).parent` for relative paths.

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

#### 3.7 ~~SSH Command Injection Risk~~ RESOLVED
~~**File:** `scripts/workflows/inspect_execution.py:57`~~

~~Builds shell commands via string interpolation.~~

**Status:** RESOLVED (Dec 2025) - Added `shlex.quote()` for all interpolated values in SSH curl commands.

#### 3.8 ~~Manual .env Parsing~~ RESOLVED
~~**File:** `scripts/workflows/inspect_execution.py:26`~~

~~Manually parses `.env` instead of using `python-dotenv`.~~

**Status:** RESOLVED (Dec 2025) - Switched to `dotenv_values()` from python-dotenv.

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

#### 4.3 ~~Fragile .env Loading~~ RESOLVED
~~**Files:** `n8n-pull.sh`, `n8n-push.sh`, `run-migration.sh`, `db-query.sh`~~

~~Pattern `export $(grep -v '^#' "$ENV_FILE" | xargs)` fails with spaces/special chars.~~

**Status:** RESOLVED (Dec 2025) - Refactored `scripts/common.sh` to use line-by-line parsing that properly handles spaces and quoted values.

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

#### 5.1 ~~Outdated Architecture Docs~~ RESOLVED
~~**File:** `docs/n8n-workflow-implementation.md`~~

~~References deprecated "original architecture" with old workflow names and patterns.~~

**Status:** RESOLVED (Dec 2025) - Moved to `docs/archive/`.

#### 5.2 ~~Inconsistent Tag Definitions~~ RESOLVED
~~Tags defined differently across documents~~

**Status:** RESOLVED (Dec 2025) - `AGENTS.md` updated with complete tag definitions. Outdated `docs/SUMMARY.md` removed.

### High

#### 5.3 ~~Deprecated Prompt References~~ RESOLVED
~~**File:** `prompts/router-agent.md`~~

~~- Still uses "Tool Calling" format (deprecated)~~
~~- References "Note Titles" (removed in migration 002b)~~

**Status:** RESOLVED (Dec 2025) - Archived `router-agent.md`. The system now uses `Multi_Capture` workflow with embedded prompts for untagged messages.

#### 5.4 ~~Category Implementation Confusion~~ RESOLVED
~~`AGENTS.md` says "Categories are strings in JSONB (not enums)" but `docs/SUMMARY.md` discusses "fixed enums".~~

**Status:** RESOLVED (Dec 2025) - Removed outdated `docs/SUMMARY.md`. `AGENTS.md` is the source of truth.

#### 5.5 ~~Missing Workflow Documentation~~ RESOLVED
~~No docs for `Handle_Todo_Status.json` or `Handle_Correction.json`.~~

**Status:** RESOLVED (Dec 2025) - Added to workflow table in README.md.

### Medium

#### 5.6 ~~Stale TODO Comments~~ RESOLVED
~~- `docs/router-agent-implementation.md:320` - References deprecated title extraction~~
~~- `docs/thread-continuation-agent-implementation.md:384` - Incomplete implementation notes~~

**Status:** RESOLVED (Dec 2025) - Both files moved to `docs/archive/`.

#### 5.7 ~~Implementation Status Inconsistencies~~ RESOLVED
~~- `docs/router-agent-implementation.md` marked "Not Implemented"~~
~~- `docs/todo-intent-design.md` marked "Pending"~~
~~- No tracking of what's actually live~~

**Status:** RESOLVED (Dec 2025) - Archived 24 outdated design docs. Active docs reduced from 34 to 8. `AGENTS.md` and `README.md` are the sources of truth for current implementation.

#### 5.8 ~~Broken Migration References~~ NOT AN ISSUE
~~Documents reference migrations in `db/migrations/` but most are in `archive/`.~~

**Status:** NOT AN ISSUE - Migrations in `archive/` are intentionally preserved for historical reference. The archive structure is documented.

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
5. ~~Add timezone to projection INSERTs~~ - RESOLVED (Dec 2025) - All 5 workflows with projection INSERTs now include timezone
6. ~~Error handling in workflows~~ - RESOLVED (Dec 2025) - All workflows have errorWorkflow configured
7. ~~ctx initialization~~ - RESOLVED (Dec 2025) - All workflows pass ctx pattern linter

### Phase 4: Ongoing
1. Add workflow documentation as features ship
2. Improve type hints
3. Consider materialized views for performance
4. Upgrade embeddings table to pgvector when implementing RAG
