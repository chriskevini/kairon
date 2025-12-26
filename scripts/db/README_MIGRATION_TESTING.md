# Database Migration Testing

This directory contains tools for safely testing database migrations before production deployment.

## test-migration.sh

Automated migration testing script that validates migrations on a temporary database.

### Requirements

- PostgreSQL client tools: `psql`, `pg_dump`, `pg_restore`, `createdb`, `dropdb`
- Access to PostgreSQL server (local or remote)
- Environment variables configured (see `.env.example`)

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | `localhost` | Database server host |
| `DB_PORT` | `5432` | Database server port |
| `DB_USER` | `n8n_user` | Database user |
| `DB_NAME` | `kairon` | Source database name |

### Usage

```bash
# Test a single migration
./scripts/db/test-migration.sh db/migrations/024_backfill_meta_event_types.sql

# The script will:
# 1. Create a temporary test database
# 2. Initialize it with basic schema
# 3. Run the migration
# 4. Check for errors
# 5. Test rollback if a rollback file exists
# 6. Test idempotency (runs migration twice)
# 7. Clean up automatically
```

### What the script does

1. **Validation**: Checks migration file exists and is readable
2. **Connectivity**: Verifies database connection
3. **Setup**: Creates temporary database with minimal schema
4. **Execution**: Runs the migration and logs output
5. **Error Check**: Searches for ERROR strings in migration output
6. **Rollback**: Tests rollback if `{migration}_rollback.sql` exists
7. **Idempotency**: Runs migration twice to ensure it's safe to run multiple times
8. **Cleanup**: Removes temporary database

### Exit Codes

- `0` - Success
- `1` - Migration test failed
- `2` - Invalid arguments
- `3` - Environment error (cannot connect to database)

### Output

The script creates log files in `logs/`:
- `migration_test_{name}_{timestamp}.log` - Migration execution log
- `migration_test_{name}_{timestamp}_rollback.log` - Rollback execution log (if applicable)

### Integration with Git Hooks

The pre-push hook automatically runs migration tests when migration files are changed:

```bash
# When you push changes to db/migrations/*.sql files
git push

# The hook will:
# 1. Detect changed migration files
# 2. Run test-migration.sh for each changed file
# 3. Block push if any test fails
```

To bypass migration testing (not recommended):
```bash
git push --no-verify
```

### Best Practices

1. **Always test migrations** - Never skip migration testing for production changes
2. **Write idempotent migrations** - Use `IF NOT EXISTS`, `ON CONFLICT`, etc.
3. **Include rollback files** - Create `{migration}_rollback.sql` for complex migrations
4. **Check logs** - Review log files after testing
5. **Use BEGIN/COMMIT** - Wrap migrations in transactions when possible

### Example Migration

**File**: `db/migrations/025_add_feature.sql`
```sql
BEGIN;

-- Add new column with default (safe for existing data)
ALTER TABLE events ADD COLUMN IF NOT EXISTS feature_flag TEXT DEFAULT 'disabled';

-- Create new index (safe)
CREATE INDEX IF NOT EXISTS idx_events_feature_flag ON events(feature_flag);

COMMIT;
```

**Rollback**: `db/migrations/025_add_feature_rollback.sql`
```sql
BEGIN;

-- Drop index
DROP INDEX IF EXISTS idx_events_feature_flag;

-- Drop column
ALTER TABLE events DROP COLUMN IF EXISTS feature_flag;

COMMIT;
```

### Testing Locally

If you don't have a local PostgreSQL server:

1. **Start PostgreSQL with Docker**:
```bash
docker run --name postgres-test -e POSTGRES_PASSWORD=test -p 5432:5432 -d postgres:15
export DB_HOST=localhost DB_USER=postgres
```

2. **Or use remote server**:
```bash
# Update .env with remote server details
DB_HOST=your-server.com DB_USER=your_user ./scripts/db/test-migration.sh migration.sql
```

### Troubleshooting

**Cannot connect to database**:
```bash
# Check if PostgreSQL is running
docker ps | grep postgres

# Test connection manually
psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d postgres -c "SELECT 1"
```

**Migration test fails**:
- Check log file in `logs/` directory
- Look for SQL syntax errors
- Verify migration uses transaction blocks (BEGIN/COMMIT)
- Ensure migration is idempotent

**Permission denied**:
- Ensure `.env` file has correct database credentials
- Check database user has necessary privileges

## Related Documentation

- `docs/archive/database-migration-safety.md` - Manual migration procedures
- `DEPLOYMENT_PIPELINE_AUDIT.md` - System audit and recommendations
- `docs/archive/postmortem-2025-12-22-postgres-migration.md` - Migration incident analysis
