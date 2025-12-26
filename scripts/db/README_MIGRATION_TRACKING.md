# Database Migration Version Tracking

This directory contains tools for managing database migrations with automatic version tracking.

## Overview

The migration system tracks which migrations have been applied to prevent:
- **Double-applying** migrations (running same migration twice)
- **Missing migrations** (forgetting to run a migration)
- **Incorrect order** (running migrations out of sequence)
- **Modified migrations** (changing migration after it's been applied)

## Architecture

### schema_migrations Table

```sql
CREATE TABLE schema_migrations (
    version TEXT PRIMARY KEY,           -- Migration file name (e.g., "025_schema_migrations")
    applied_at TIMESTAMPTZ NOT NULL,   -- When migration was run
    checksum TEXT,                      -- SHA256 of migration file
    description TEXT,                    -- Migration purpose
    migrated_by TEXT                     -- Who ran the migration
);
```

### Migration Files

Migrations are SQL files in `db/migrations/` with numeric prefixes:
```
db/migrations/
  001_initial_data.sql
  002_add_todos.sql
  ...
  024_backfill_meta_event_types.sql
  025_schema_migrations.sql
```

**Naming Convention:**
- Format: `{number}_{description}.sql`
- Number: 3-digit zero-padded (001, 002, ..., 025)
- Description: Snake_case, describes what migration does

**Migration File Header:**
```sql
-- Migration: 025_schema_migrations.sql
-- Add migration version tracking table

BEGIN;

-- Your migration SQL here
CREATE TABLE schema_migrations (...);

COMMIT;
```

## migrate.sh

The main migration runner with version tracking.

### Requirements

- PostgreSQL client: `psql`
- Access to database server
- Environment variables configured (see `.env`)

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | `localhost` | Database server host |
| `DB_PORT` | `5432` | Database server port |
| `DB_USER` | `n8n_user` | Database user |
| `DB_NAME` | `kairon` | Database name |

### Commands

#### Run Pending Migrations
```bash
./scripts/db/migrate.sh
```

Runs all migrations that haven't been applied yet, in order.

**Output:**
```
==========================================
Running Pending Migrations
==========================================

[MIGRATION] Running migration: 025_schema_migrations
[INFO] Description: Add migration version tracking table
[INFO] Checksum: a1b2c3d4e5f6...
[SUCCESS] Migration 025_schema_migrations applied successfully

==========================================
Completed: 1 migration(s) applied
==========================================
```

#### Show Migration Status
```bash
./scripts/db/migrate.sh status
```

Shows which migrations have been applied and which are pending.

**Output:**
```
==========================================
Migration Status
==========================================

Applied Migrations:
-------------------
  ✓ 001_initial_data
  ✓ 002_add_todos
  ...
  ✓ 024_backfill_meta_event_types

Pending Migrations:
-------------------
  ○ 025_schema_migrations - Add migration version tracking table

==========================================
```

#### Dry Run
```bash
./scripts/db/migrate.sh --dry-run
```

Shows what would be run without executing.

**Use case:** Preview migrations before applying in production.

#### Run Specific Migration
```bash
./scripts/db/migrate.sh --version 025
```

Runs a specific migration (skips status check).

**Use case:** Re-run a failed migration or run a specific migration in isolation.

#### Verify Checksums
```bash
./scripts/db/migrate.sh --verify
```

Verifies all applied migrations match their stored checksums.

**Output:**
```
==========================================
Verifying Migration Checksums
==========================================

[SUCCESS] ✓ 001_initial_data - Checksum verified
[SUCCESS] ✓ 002_add_todos - Checksum verified
[ERROR] ✗ 024_backfill_meta_event_types - Checksum mismatch!
[INFO]   Stored:   abc123...
[INFO]   Current:  def456...
[WARNING]   Migration file has been modified since application

[ERROR] Checksum verification failed
```

**Use case:** Detect if migration files have been modified after being applied.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Migration failed or checksum verification failed |
| 2 | Invalid arguments |
| 3 | Database connection error |

### Log Files

Each migration creates a log file in `logs/`:
```
logs/migration_025_schema_migrations_20241226_120000.log
```

Logs contain full SQL output for debugging failed migrations.

## Workflow

### Initial Setup

1. **Apply version tracking migration** (one-time):
```bash
./scripts/db/test-migration.sh db/migrations/025_schema_migrations.sql
psql -d kairon -f db/migrations/025_schema_migrations.sql
```

2. **Verify setup**:
```bash
./scripts/db/migrate.sh status
```

Should show `schema_migrations` table exists.

### Applying New Migrations

1. **Create migration file**:
```bash
# db/migrations/026_add_feature.sql
-- Migration: 026_add_feature.sql
-- Add new feature table

BEGIN;

CREATE TABLE new_feature (...);

COMMIT;
```

2. **Test migration**:
```bash
./scripts/db/test-migration.sh db/migrations/026_add_feature.sql
```

3. **Run migration**:
```bash
./scripts/db/migrate.sh
```

4. **Verify**:
```bash
./scripts/db/migrate.sh status
```

### Production Deployment

1. **Check status** (dev):
```bash
./scripts/db/migrate.sh status
```

2. **Verify checksums** (dev):
```bash
./scripts/db/migrate.sh --verify
```

3. **Dry run** (staging):
```bash
./scripts/db/migrate.sh --dry-run
```

4. **Apply migrations** (production):
```bash
./scripts/db/migrate.sh
```

5. **Verify** (production):
```bash
./scripts/db/migrate.sh status
```

## Best Practices

### 1. Always Test Migrations
```bash
# Never skip testing
./scripts/db/test-migration.sh db/migrations/026_new_migration.sql
```

### 2. Use Transaction Blocks
```sql
BEGIN;

-- All migration SQL here

COMMIT;
```

**Why:** Ensures migration is atomic (all or nothing).

### 3. Make Migrations Idempotent
```sql
-- Good: Safe to run multiple times
CREATE TABLE IF NOT EXISTS my_table (...);

-- Bad: Will fail on second run
CREATE TABLE my_table (...);
```

**Why:** Allows safe re-running if migration fails mid-way.

### 4. Include Rollback Comments
```sql
-- Migration: 026_add_feature.sql
-- Add new feature table

-- ROLLBACK:
-- DROP TABLE IF EXISTS new_feature CASCADE;

BEGIN;

CREATE TABLE new_feature (...);

COMMIT;
```

**Why:** Documents how to undo migration if needed.

### 5. Write Descriptive Headers
```sql
-- Migration: 026_add_feature.sql
-- Add new feature table to track user preferences
-- Changes: Creates new_table, adds index, updates view
```

**Why:** Shows migration purpose at a glance.

### 6. Verify Before Deploying
```bash
# Check status before pushing
./scripts/db/migrate.sh status

# Verify no tampering
./scripts/db/migrate.sh --verify
```

### 7. Keep Migrations Small
- Each migration should do one thing
- Break large migrations into multiple steps
- Easier to debug and rollback

### 8. Use Numbered Files
```
✅ Good: 001_initial.sql, 002_add_todos.sql
❌ Bad: initial.sql, add_todos.sql
```

**Why:** Guarantees execution order.

## Troubleshooting

### Migration Fails

**Symptom:**
```
[ERROR] Migration 026_add_feature failed
```

**Solution:**
1. Check log file: `logs/migration_026_*.log`
2. Fix migration SQL
3. Rollback manually (if needed):
   ```bash
   psql -d kairon -f db/migrations/026_add_feature_rollback.sql
   ```
4. Test again: `./scripts/db/test-migration.sh db/migrations/026_add_feature.sql`
5. Re-apply: `./scripts/db/migrate.sh --version 026`

### Checksum Mismatch

**Symptom:**
```
[ERROR] ✗ 024_backfill_meta_event_types - Checksum mismatch!
```

**Cause:** Migration file modified after being applied.

**Solution:**
1. Check git diff: `git diff db/migrations/024_backfill_meta_event_types.sql`
2. If intentional change: Create new migration
3. If accidental: Restore from git
4. Re-verify: `./scripts/db/migrate.sh --verify`

### Pending Migrations Don't Apply

**Symptom:** Migration shows as pending but doesn't run.

**Cause:** Migration fails silently (e.g., missing BEGIN/COMMIT).

**Solution:**
1. Check migration has transaction block
2. Run manually: `psql -d kairon -f db/migrations/026.sql`
3. Check logs in `logs/` directory

### Database Connection Error

**Symptom:**
```
[ERROR] Cannot connect to database at localhost:5432
```

**Solution:**
1. Check PostgreSQL running: `docker ps | grep postgres`
2. Test connection: `psql -h localhost -U n8n_user -d kairon`
3. Verify `.env` has correct values
4. Update `.env` if database moved

## Migration Lifecycle

```
┌─────────────────┐
│ Create SQL File │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Test Migration │
│ (test-migrate) │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Add to Git     │
│ & Push         │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Run in Dev     │
│ (migrate.sh)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Deploy to Prod │
│ (migrate.sh)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Verify Status  │
│ (migrate status)│
└─────────────────┘
```

## Integration with Git Hooks

The pre-push hook automatically detects migration file changes but doesn't run `migrate.sh`.

**Why:** Migration runner should only be run explicitly by developer.

**Workflow:**
1. Developer creates migration
2. Pre-push hook tests migration (via `test-migration.sh`)
3. Developer pushes to repo
4. On production: `./scripts/db/migrate.sh`

## Related Documentation

- `scripts/db/README_MIGRATION_TESTING.md` - Migration testing
- `docs/archive/database-migration-safety.md` - Manual migration procedures
- `DEPLOYMENT_PIPELINE_AUDIT.md` - System audit and recommendations

## Migration Template

```sql
-- Migration: XXX_migration_name.sql
-- Brief description of what migration does
-- Detailed explanation if needed

-- ROLLBACK:
-- SQL commands to undo this migration

BEGIN;

-- Add new tables
CREATE TABLE IF NOT EXISTS table_name (...);

-- Add new columns
ALTER TABLE existing_table ADD COLUMN IF NOT EXISTS new_col TEXT;

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_table_col ON table_name(col);

-- Create views
CREATE OR REPLACE VIEW view_name AS ...;

COMMIT;
```

Copy this template for new migrations and replace `XXX` with next number.
