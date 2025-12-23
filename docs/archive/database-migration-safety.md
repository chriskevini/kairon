# Database Migration Safety Guide

> **Golden Rule:** ALWAYS backup before ANY schema changes.

---

## Pre-Migration Checklist

Before running ANY migration:

- [ ] **Backup database** (see commands below)
- [ ] **Test on copy first** (see procedure below)
- [ ] **Read migration file completely** (understand what it does)
- [ ] **Check migration is idempotent** (safe to run multiple times)
- [ ] **Verify rollback steps exist** (in migration comments)
- [ ] **Schedule during low-usage time** (if production)
- [ ] **Have rollback plan ready** (tested on copy)

### Additional Steps for Postgres Container Changes

If changing the postgres container (image upgrade, recreation, etc.):

- [ ] **Document current n8n credential IDs:**
  ```bash
  docker exec -i postgres-db psql -U n8n_user -d n8n_chat_memory -c \
    "SELECT id, name FROM credentials_entity WHERE type='postgres';"
  ```
- [ ] **Test n8n credential connectivity** (run `scripts/verify_n8n_credentials.sh`)
- [ ] **Note all workflows using each credential**
- [ ] **Plan for credential recreation if needed** (n8n credentials may become invalid after container recreation)
- [ ] **Run post-migration smoke test:**
  ```bash
  curl -s -X POST "http://localhost:5678/webhook/asoiaf92746087" \
    -H "Content-Type: application/json" \
    -d '{"event_type":"message","guild_id":"test","channel_id":"test","message_id":"smoke_test","content":"::ping","author":{"login":"test"},"timestamp":"'$(date -Iseconds)'"}'
  ```

> **Lesson from 2025-12-22 incident:** Container recreation can invalidate n8n credentials even if data volume is preserved. See `postmortem-2025-12-22-postgres-migration.md` for details.

---

## Backup Commands

### Full Database Backup

```bash
# Custom format (recommended - allows selective restore)
pg_dump -U n8n_user -d kairon -F c -f backups/kairon_$(date +%Y%m%d_%H%M%S).dump

# Plain SQL format (human-readable)
pg_dump -U n8n_user -d kairon -f backups/kairon_$(date +%Y%m%d_%H%M%S).sql
```

### Schema-Only Backup

```bash
# Backup just schema (useful for comparison)
pg_dump -U n8n_user -d kairon -s -f backups/kairon_schema_$(date +%Y%m%d_%H%M%S).sql
```

### Verify Backup

```bash
# Check file size (should be > 0)
ls -lh backups/

# Verify backup is valid
pg_restore -U n8n_user -d postgres -l backups/kairon_20241217_*.dump | head
```

---

## Test Migration Procedure

### 1. Create Test Database

```bash
# Create test database
createdb -U n8n_user kairon_test

# Restore backup to test database
pg_restore -U n8n_user -d kairon_test backups/kairon_20241217_*.dump
```

### 2. Run Migration on Test

```bash
# Run migration
psql -U n8n_user -d kairon_test -f db/migrations/002_add_todos.sql

# Check for errors (should say "CREATE TABLE", "CREATE INDEX", etc.)
# If any errors, DO NOT proceed to production
```

### 3. Verify Test Results

```bash
# Check new tables exist
psql -U n8n_user -d kairon_test -c "\dt todos"

# Check schema looks correct
psql -U n8n_user -d kairon_test -c "\d todos"

# Check views exist
psql -U n8n_user -d kairon_test -c "\dv *todo*"

# Try inserting test data
psql -U n8n_user -d kairon_test -c "
  INSERT INTO todos (description, status, priority) 
  VALUES ('test todo', 'pending', 'medium') 
  RETURNING *;
"

# Check constraints work
psql -U n8n_user -d kairon_test -c "
  INSERT INTO todos (description, status, priority) 
  VALUES ('bad status', 'invalid', 'medium');
"
# Should FAIL with constraint violation (this is good!)
```

### 4. Test Rollback (on test DB)

```bash
# Try rollback steps from migration comments
psql -U n8n_user -d kairon_test -c "DROP TABLE IF EXISTS todos CASCADE;"

# Verify clean state
psql -U n8n_user -d kairon_test -c "\dt todos"
# Should say "Did not find any relation named 'todos'"
```

### 5. Clean Up Test Database

```bash
# If all tests pass, drop test database
dropdb -U n8n_user kairon_test
```

---

## Production Migration Procedure

### 1. Final Backup

```bash
# Create pre-migration backup (keep for 30 days minimum)
pg_dump -U n8n_user -d kairon -F c -f backups/kairon_pre_migration_002_$(date +%Y%m%d_%H%M%S).dump

# Verify backup
ls -lh backups/kairon_pre_migration_*
```

### 2. Stop Workflows (Optional but Recommended)

If migration modifies existing tables:

```bash
# Note: 002_add_todos.sql is SAFE (only adds new tables)
# But for future migrations that modify existing tables:

# In n8n UI: Deactivate all workflows
# Or via CLI if available
```

### 3. Run Migration

```bash
# Run migration with output logging
psql -U n8n_user -d kairon -f db/migrations/002_add_todos.sql 2>&1 | tee logs/migration_002_$(date +%Y%m%d_%H%M%S).log

# Check log for errors
grep -i error logs/migration_002_*.log
# Should return nothing (no errors)
```

### 4. Verify Production

```bash
# Check tables exist
psql -U n8n_user -d kairon -c "
  SELECT table_name 
  FROM information_schema.tables 
  WHERE table_name = 'todos';
"
# Should return: todos

# Check constraints
psql -U n8n_user -d kairon -c "
  SELECT constraint_name, constraint_type
  FROM information_schema.table_constraints
  WHERE table_name = 'todos';
"
# Should list CHECK constraints, PRIMARY KEY, etc.

# Check views
psql -U n8n_user -d kairon -c "SELECT * FROM open_todos LIMIT 1;"
# Should return empty result (no error)
```

### 5. Restart Workflows

```bash
# Reactivate workflows in n8n UI
# Test with actual Discord message
```

### 6. Monitor

```bash
# Watch logs for issues
journalctl -u n8n -f

# Check database connections
psql -U n8n_user -d kairon -c "SELECT count(*) FROM todos;"
# Should return: 0 (empty table, but no error)
```

---

## Rollback Procedure

If something goes wrong:

### Option 1: Drop New Tables (for additive migrations like 002)

```bash
# Drop everything added by migration
psql -U n8n_user -d kairon -f - <<'EOF'
DROP VIEW IF EXISTS stale_todos;
DROP VIEW IF EXISTS recent_todo_completions;
DROP VIEW IF EXISTS open_todos;
DROP TABLE IF EXISTS todos CASCADE;
ALTER TABLE routing_decisions DROP CONSTRAINT IF EXISTS routing_decisions_intent_check;
ALTER TABLE routing_decisions ADD CONSTRAINT routing_decisions_intent_check 
  CHECK (intent IN ('Activity', 'Note', 'ThreadStart', 'Chat', 'Commit', 'Command'));
EOF

# Verify clean state
psql -U n8n_user -d kairon -c "\dt todos"
# Should say not found
```

### Option 2: Full Restore (nuclear option)

```bash
# Stop n8n
sudo systemctl stop n8n

# Drop and recreate database
dropdb -U n8n_user kairon
createdb -U n8n_user kairon

# Restore from backup
pg_restore -U n8n_user -d kairon backups/kairon_pre_migration_002_*.dump

# Restart n8n
sudo systemctl start n8n
```

**⚠️ WARNING:** Full restore loses all data created AFTER the backup was made!

---

## Migration Types by Risk Level

### Low Risk (Additive Only)
- Adding new tables
- Adding new columns with defaults
- Adding new indexes
- Adding new views
- **Example:** 002_add_todos.sql

**Safe because:** Doesn't touch existing data, easy to rollback

### Medium Risk (Schema Changes)
- Modifying column types
- Adding NOT NULL constraints to existing columns
- Renaming columns
- **Example:** Static categories migration (future)

**Requires:** Careful testing, possibly downtime, data migration

### High Risk (Data Transformation)
- Deleting columns with data
- Complex data migrations
- Changing primary/foreign keys
- **Example:** Merging tables

**Requires:** Extended downtime, extensive testing, staged rollout

---

## Common Mistakes to Avoid

### ❌ Don't Do This

```bash
# Running migration without backup
psql -U n8n_user -d kairon -f db/migrations/002_add_todos.sql

# Running untested migration in production
psql -U n8n_user -d kairon -f db/migrations/new_untested.sql

# Ignoring errors
psql -d kairon -f migration.sql
# ERROR: ... (ignored, kept typing commands)

# No verification after migration
# (just assuming it worked)
```

### ✅ Do This

```bash
# 1. Backup
pg_dump -U n8n_user -d kairon -F c -f backups/pre_002.dump

# 2. Test on copy
createdb kairon_test
pg_restore -d kairon_test backups/pre_002.dump
psql -d kairon_test -f db/migrations/002_add_todos.sql
# Verify success, test queries

# 3. Run on production with logging
psql -U n8n_user -d kairon -f db/migrations/002_add_todos.sql 2>&1 | tee logs/migration_002.log

# 4. Verify
psql -U n8n_user -d kairon -c "\d todos"
psql -U n8n_user -d kairon -c "SELECT * FROM open_todos LIMIT 1;"

# 5. Monitor
journalctl -u n8n -f
```

---

## Quick Reference

### Essential Commands

```bash
# Backup
pg_dump -U n8n_user -d kairon -F c -f backups/backup_$(date +%Y%m%d_%H%M%S).dump

# Test database
createdb kairon_test
pg_restore -d kairon_test backups/backup_*.dump
psql -d kairon_test -f db/migrations/XXX.sql

# Run migration
psql -U n8n_user -d kairon -f db/migrations/XXX.sql

# Verify
psql -U n8n_user -d kairon -c "\d table_name"

# Rollback (if migration includes rollback steps)
psql -U n8n_user -d kairon -f db/rollbacks/XXX.sql
```

---

## For Migration 002 (Add Todos)

### Risk Level: **LOW** ✅

**Why safe:**
- Only adds new tables (doesn't modify existing)
- Includes explicit rollback steps
- No data migration needed
- Can be rolled back by dropping tables

### Minimal Procedure

```bash
# 1. Backup (always!)
pg_dump -U n8n_user -d kairon -F c -f backups/pre_todos_$(date +%Y%m%d_%H%M%S).dump

# 2. Run migration
psql -U n8n_user -d kairon -f db/migrations/002_add_todos.sql

# 3. Verify
psql -U n8n_user -d kairon -c "SELECT * FROM open_todos;"
# Should return empty result (no error)

# Done! ✅
```

### If Needed: Rollback

```bash
psql -U n8n_user -d kairon -c "DROP TABLE IF EXISTS todos CASCADE;"
# Removes table and all dependent views
```

---

## Best Practices

1. **Always backup** - Even for "simple" migrations
2. **Test on copy first** - Every migration, no exceptions
3. **Read before running** - Understand what the migration does
4. **Log everything** - Use `tee` to capture output
5. **Verify after** - Don't assume success
6. **Keep backups** - 7 days minimum, 30 days recommended
7. **Document changes** - Update AGENTS.md with migration date
8. **One migration at a time** - Don't batch multiple migrations

---

## Emergency Contact

If migration fails catastrophically:

1. **Stay calm**
2. **Stop making changes** (don't try to "fix" it)
3. **Restore from backup** (see Full Restore above)
4. **Review logs** (understand what went wrong)
5. **Fix migration file** (on test database)
6. **Try again** (after successful test)

**Remember:** With a good backup, everything is recoverable. Without a backup, you're gambling.
