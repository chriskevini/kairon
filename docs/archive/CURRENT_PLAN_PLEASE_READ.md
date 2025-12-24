# 🚨 Master Action Plan: n8n Production Recovery

**Status:** P0 Critical Incident | **Objective:** Restore Database Persistence

The goal is to fix the "silent failure" where n8n workflows report success but fail to write `traces` and `projections` to PostgreSQL due to deprecated node parameters and Code node strictness.

---

## Phase 1: Establish Command & Control (15 min)

To bypass DigitalOcean’s SSH rate limiting, we will use **SSH Multiplexing**. This allows multiple sessions over a single TCP connection.

### 1.1 Configure SSH ControlMaster

Update your **local** `~/.ssh/config`:

```ssh
Host DigitalOcean
    HostName 164.92.84.170
    User ubuntu
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 600
    ServerAliveInterval 60

```

**Action:** Establish the master connection in a dedicated terminal:

```bash
mkdir -p ~/.ssh/sockets
ssh -N DigitalOcean  # Keep this window open

```

### 1.2 The "Ops" Helper Script

Create a local script `remote.sh` to standardize commands:

```bash
#!/bin/bash
# Usage: ./remote.sh db "SELECT count(*) FROM traces"
API_KEY="YOUR_REDACTED_KEY"
case $1 in
  db) ssh DigitalOcean "source ~/kairon/.env && docker exec postgres-db psql -U \$DB_USER -d \$DB_NAME -c '$2'" ;;
  api) ssh DigitalOcean "curl -s -H 'X-N8N-API-KEY: $API_KEY' 'http://localhost:5678/api/v1/$2'" ;;
esac

```

---

## Phase 2: Deployment of the Fix (30 min)

The primary blocker is the `Execute_Queries` workflow (`ID: CgUAxK0i4YhrZ2Wp`) using the deprecated `queryReplacement` field.

### 2.1 Sanitize and Patch JSON

We must strip metadata that causes n8n API 400 errors and swap the deprecated parameter.

**Action:** Run these commands locally:

```bash
# 1. Apply the fix to the local file
sed -i 's/"queryReplacement"/"values"/g' n8n-workflows/Execute_Queries.json

# 2. Prepare the minimal API payload
jq '{name, nodes, connections, settings}' n8n-workflows/Execute_Queries.json > /tmp/deploy_payload.json

# 3. Upload to server
scp /tmp/deploy_payload.json DigitalOcean:/tmp/execute_queries_fix.json

```

### 2.2 Trigger Production Update

Execute the update via the server-side API:

```bash
ssh DigitalOcean "curl -s -X PUT \
  -H 'Content-Type: application/json' \
  -H 'X-N8N-API-KEY: $API_KEY' \
  -d @/tmp/execute_queries_fix.json \
  'http://localhost:5678/api/v1/workflows/CgUAxK0i4YhrZ2Wp'"

# Reactivate the workflow
ssh DigitalOcean "curl -s -X POST -H 'X-N8N-API-KEY: $API_KEY' 'http://localhost:5678/api/v1/workflows/CgUAxK0i4YhrZ2Wp/activate'"

```

---

## Phase 3: Verification & Smoke Testing (20 min)

We need to prove that rows are actually landing in the database.

### 3.1 Send Test Stimulus

Trigger the webhook manually:

```bash
curl -X POST "https://n8n.chrisirineo.com/webhook/asoiaf92746087" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "message",
    "message_id": "recovery-test-'$(date +%s)'",
    "content": "System recovery test sequence.",
    "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'"
  }'

```

### 3.2 Audit Database Deltas

Check if the `traces` table is populating:

```bash
./remote.sh db "SELECT count(*) as count, max(created_at) FROM traces WHERE created_at > NOW() - INTERVAL '5 minutes';"

```

**Expected Result:** `count` > 0.

---

## Phase 4: Long-Term Hardening

To prevent future "silent" failures, implement these observability improvements.

### 4.1 "Green but Wrong" Detection

Add a **Code Node** in n8n immediately after your Postgres node to validate the result:

```javascript
// If the DB says 0 rows affected, force an error so the workflow turns RED
if (Object.keys($input.all()).length === 0) {
    throw new Error("Database Write Failed: No rows returned/affected.");
}
return $input.all();

```

### 4.2 Automated Health Canary

Add a simple cron job on the server to alert you if events arrive but traces don't:

```bash
# Sample logic for a check script
EVENTS=$(psql -t -c "SELECT count(*) FROM events WHERE received_at > NOW() - INTERVAL '1 hour'")
TRACES=$(psql -t -c "SELECT count(*) FROM traces WHERE created_at > NOW() - INTERVAL '1 hour'")

if [ "$EVENTS" -gt 0 ] && [ "$TRACES" -eq 0 ]; then
    echo "ALERT: Database Pipeline is broken!"
fi

```

---

## Summary Checklist

| Phase | Task | Status |
| --- | --- | --- |
| **Setup** | Configure SSH ControlMaster & Sockets | ⬜ |
| **Fix** | Replace `queryReplacement` with `values` | ⬜ |
| **Deploy** | API PUT to `CgUAxK0i4YhrZ2Wp` | ⬜ |
| **Verify** | Webhook trigger + DB count check | ⬜ |
| **Harden** | Commit changes to Git & Rotate API Key | ⬜ |
