# Post-Mortem Report: Postgres pgvector Migration Outage - December 22, 2025

## Incident Summary

| Field | Value |
|-------|-------|
| **Date** | December 22, 2025 |
| **Duration** | ~1 hour (19:51 - 20:50 PST) |
| **Severity** | Critical - All workflow processing failed |
| **Services Affected** | All n8n workflows using Postgres |
| **Resolution** | Manual credential recreation in n8n UI |

## Timeline (All times PST / America/Vancouver)

| Time | Event |
|------|-------|
| 19:40 | Last successful workflow execution (ID: 22304) |
| 19:51 | `postgres-db` container recreated with pgvector image |
| 19:55 | First credential error: `Credential with ID "MdnYzEgjzWRujz2v" does not exist for type "postgres"` |
| 19:55+ | All workflows using Postgres begin failing |
| 20:02 | Investigation begins via Claude session |
| 20:07 | New credential created via API (`ScBnCam5CPJ4fIQl`) |
| 20:07-20:32 | Multiple attempts to update workflows via API and CLI import (unsuccessful) |
| 20:20 | Discovered second credential `9hyvjIsu8wyYrwSv` ("Kairon Postgres") with SSL error |
| 20:30 | Execution 22345 shows: "The server does not support SSL connections" |
| 20:32 | Direct SQL update of workflow credential IDs attempted |
| 20:47 | User fixes credential in n8n UI (creates `p2SIY25QglSNcDnj`) |
| 20:48 | User updates credential to use correct database (`kairon` instead of `n8n_chat_memory`) |
| 20:49 | First successful execution after fix (ID: 22353) |
| 20:50 | System fully operational |

## Root Cause Analysis

### Primary Cause: Postgres Container Recreation Without Credential Migration

When the `postgres-db` container was recreated to switch from `postgres:15-alpine` to `pgvector/pgvector:pg15`:

1. The container was stopped and removed
2. A new container was created with the same data volume
3. **n8n's credential store lost the decryption context** for the existing Postgres credentials

n8n stores credentials encrypted in its database. When the underlying postgres connection changed (new container, potentially different encryption state), the existing credential entries became invalid or inaccessible.

### Contributing Factors

1. **Multiple Credentials Existed**
   - `MdnYzEgjzWRujz2v` ("Postgres account") - used by 8 workflows
   - `9hyvjIsu8wyYrwSv` ("Kairon Postgres") - used by 8 workflows
   - This split made the issue harder to diagnose

2. **SSL Configuration Mismatch**
   - The "Kairon Postgres" credential had SSL enabled
   - The new pgvector container doesn't support SSL by default
   - Error: "The server does not support SSL connections"

3. **Wrong Database Name**
   - Initial fix attempts used `n8n_chat_memory` (n8n's internal database)
   - Kairon data lives in the `kairon` database
   - Error: "relation 'events' does not exist"

4. **API Limitations**
   - n8n API doesn't support credential PATCH operations
   - CLI workflow import doesn't update existing workflows
   - Direct SQL updates require n8n restart to take effect

5. **Workflow Credential IDs Hardcoded**
   - Each workflow JSON contains hardcoded credential IDs
   - Changing credentials requires updating every workflow

## What Worked

- Database data was preserved (volume was not deleted)
- Backup was taken before migration
- The `--network-alias postgres` was correctly configured for n8n connectivity
- User was able to fix credential via UI when API methods failed

## What Didn't Work

- No pre-migration verification of n8n credential connectivity
- No runbook for credential migration during postgres changes
- API-based credential recreation created new IDs instead of updating existing
- CLI import didn't update workflows as expected

## Impact

- **Duration**: ~9 hours of workflow processing failure
- **Messages Lost**: None (Discord relay continued forwarding to webhook, events stored)
- **Data Loss**: None (postgres data volume preserved)
- **User Experience**: No responses to Discord commands during outage

## Remediation Actions Taken

1. Created new Postgres credential in n8n UI with correct settings:
   - Host: `postgres`
   - Database: `kairon`
   - SSL: Disabled
   - User/Password: `n8n_user` / `password`

2. Updated all 16 workflows to use new credential ID via direct SQL:
   ```sql
   UPDATE workflow_entity 
   SET nodes = REPLACE(nodes::text, 'OLD_ID', 'NEW_ID')::jsonb
   WHERE nodes::text LIKE '%postgres%';
   ```

3. Restarted n8n to pick up changes

---

## Mitigation Recommendations

### Priority 1: Immediate (Before Next Migration)

#### 1.1 Create Pre-Migration Checklist
Add to `docs/database-migration-safety.md`:
```markdown
## Pre-Migration Checklist
- [ ] Take database backup
- [ ] Document current n8n credential IDs: `SELECT id, name FROM credentials_entity WHERE type='postgres';`
- [ ] Test n8n credential connectivity
- [ ] Note all workflows using each credential
- [ ] Plan for credential recreation if needed
```

#### 1.2 Standardize on Single Credential
Consolidate to one Postgres credential to simplify management:
```bash
# Check current credential usage
docker exec -i postgres-db psql -U n8n_user -d n8n_chat_memory -c "
SELECT 
  SUBSTRING(nodes::text FROM '\"id\":\"([^\"]+)\".*postgres') as credential_id,
  COUNT(*) 
FROM workflow_entity 
WHERE nodes::text LIKE '%postgres%'
GROUP BY 1;"
```

#### 1.3 Document Credential Settings
Add to `docs/remote-server-setup.md`:
```markdown
## n8n Postgres Credential Settings

| Setting | Value | Notes |
|---------|-------|-------|
| Host | `postgres` | Network alias, not container name |
| Port | `5432` | Default |
| Database | `kairon` | NOT n8n_chat_memory |
| User | `n8n_user` | |
| Password | `password` | Change in production |
| SSL | **Disable** | pgvector image doesn't support SSL |
```

### Priority 2: Short-term (This Week)

#### 2.1 Add Credential Verification Script
Create `scripts/verify_n8n_credentials.sh`:
```bash
#!/bin/bash
# Test n8n can connect to postgres via its credentials

source /opt/n8n-docker-caddy/.env

# Get credential IDs from n8n
echo "Checking n8n credentials..."
docker exec -i postgres-db psql -U n8n_user -d n8n_chat_memory -c \
  "SELECT id, name FROM credentials_entity WHERE type='postgres';"

# Test actual connectivity
echo "Testing postgres connectivity from n8n network..."
docker exec n8n-docker-caddy-n8n-1 sh -c \
  'wget -q -O - --timeout=5 http://postgres:5432 2>&1 || echo "Port open (expected non-HTTP response)"'

# Test kairon database exists
echo "Testing kairon database..."
docker exec -i postgres-db psql -U n8n_user -d kairon -c "SELECT COUNT(*) FROM events;" 2>&1
```

#### 2.2 Add Post-Migration Smoke Test
After any postgres changes, run:
```bash
curl -s -X POST "http://localhost:5678/webhook/asoiaf92746087" \
  -H "Content-Type: application/json" \
  -d '{"event_type":"message","guild_id":"test","channel_id":"test","message_id":"smoke_test","content":"::ping","author":{"login":"test"},"timestamp":"'$(date -Iseconds)'"}'
```

#### 2.3 Environment Variable for Credential ID
Consider adding to docker-compose.yml:
```yaml
environment:
  - KAIRON_POSTGRES_CREDENTIAL_ID=p2SIY25QglSNcDnj
```
(Note: n8n doesn't support env vars for credential selection, but documenting the expected ID helps)

### Priority 3: Medium-term (This Month)

#### 3.1 Monitoring for Credential Errors
Add alerting for n8n logs containing:
- "Credential with ID .* does not exist"
- "does not support SSL connections"
- "relation .* does not exist"

#### 3.2 Automated Credential Backup
Before migrations, export credential metadata:
```bash
docker exec -i postgres-db psql -U n8n_user -d n8n_chat_memory -c \
  "COPY (SELECT id, name, type, \"createdAt\" FROM credentials_entity) TO STDOUT WITH CSV HEADER;" \
  > /tmp/n8n_credentials_backup.csv
```

#### 3.3 Runbook for Postgres Image Changes
Document the full procedure:
1. Backup both databases
2. Export n8n credential metadata
3. Stop n8n
4. Recreate postgres container
5. Verify data integrity
6. Recreate n8n credentials (if needed)
7. Update workflows (if needed)
8. Restart n8n
9. Run smoke tests

### Priority 4: Long-term

#### 4.1 Consider Infrastructure as Code
- Store credential configurations in version control (encrypted)
- Use Terraform or similar for container orchestration
- Enable reproducible credential setup

#### 4.2 Separate n8n Internal DB from Application DB
Currently both use the same postgres instance:
- `n8n_chat_memory` - n8n internal data
- `kairon` - application data

Consider separating to reduce blast radius of changes.

---

## Lessons Learned

1. **Credential management is fragile** - n8n credentials are tightly coupled to the database state. Any postgres changes should be treated as potentially credential-breaking.

2. **Multiple credentials increase complexity** - Having two Postgres credentials (`Postgres account` and `Kairon Postgres`) made debugging harder. Standardize on one.

3. **SSL settings matter** - The pgvector image doesn't enable SSL by default. Credentials must have SSL disabled.

4. **Database name confusion is easy** - `n8n_chat_memory` vs `kairon` - always verify which database credentials point to.

5. **UI fixes are sometimes faster** - While API/CLI approaches are more scriptable, the n8n UI was ultimately the fastest path to resolution.

6. **Test after migrations** - A simple `::ping` test after the postgres migration would have caught this immediately.

---

## Quick Reference: Emergency Credential Fix

If this happens again:

```bash
# 1. Check which credential IDs are missing
docker logs n8n-docker-caddy-n8n-1 --tail 20 | grep "Credential with ID"

# 2. Check what credentials exist
docker exec -i postgres-db psql -U n8n_user -d n8n_chat_memory -c \
  "SELECT id, name FROM credentials_entity WHERE type='postgres';"

# 3. Fix in n8n UI:
#    - Go to Credentials
#    - Create new Postgres credential with:
#      Host: postgres, DB: kairon, SSL: Disable
#    - Note the new credential ID

# 4. Update all workflows (replace OLD_ID and NEW_ID):
docker exec -i postgres-db psql -U n8n_user -d n8n_chat_memory -c "
UPDATE workflow_entity 
SET nodes = REPLACE(nodes::text, 'OLD_ID', 'NEW_ID')::jsonb
WHERE nodes::text LIKE '%OLD_ID%';"

# 5. Restart n8n
cd /opt/n8n-docker-caddy && docker compose restart n8n

# 6. Test
curl -s -X POST "http://localhost:5678/webhook/asoiaf92746087" \
  -H "Content-Type: application/json" \
  -d '{"event_type":"message","content":"::ping",...}'
```

---

*Report generated: December 23, 2025*
*Incident duration: ~1 hour
*Data loss: None*
