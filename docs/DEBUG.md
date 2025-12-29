# Kairon Debugging Guide

Comprehensive guide to debugging Kairon workflows, database issues, and system problems.

## Table of Contents

- [Quick Debug Checklists](#quick-debug-checklists)
- [Debug Tools Reference](#debug-tools-reference)
- [Debugging by Scenario](#debugging-by-scenario)
- [Common Issues & Solutions](#common-issues--solutions)
- [Advanced Debugging](#advanced-debugging)

## Quick Debug Checklists

### 🔍 General System Health Check

```bash
# 1. Check system status
./tools/kairon-ops.sh status  # Production
# OR for local dev:
docker-compose ps

# 2. Check recent activity
./tools/kairon-ops.sh db-query "
  SELECT event_type, COUNT(*) as count,
         MAX(received_at) as latest
  FROM events
  WHERE received_at > NOW() - INTERVAL '1 hour'
  GROUP BY event_type
"

# 3. Check for errors in logs
docker-compose logs -f n8n-dev  # Local dev
# OR for production:
ssh production-server "docker logs n8n --tail 50"
```

### 🔄 Workflow Processing Check

```bash
# 1. Verify workflow is active
curl -s http://localhost:5679/api/v1/workflows | jq '.data[] | select(.name | contains("Route_Event")) | {name, active}'

# 2. Check for stuck executions
curl -s http://localhost:5679/api/v1/executions?status=running | jq '.data | length'

# 3. Test webhook manually
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! debug test", "guild_id": "test", "channel_id": "test", "message_id": "debug-123", "author": {"login": "test"}, "timestamp": "'$(date -Iseconds)'"}'
```

### 🗄️ Database Integrity Check

```bash
# 1. Check table counts
./tools/kairon-ops.sh db-query "
  SELECT 'events' as table_name, COUNT(*) as count FROM events
  UNION ALL
  SELECT 'traces', COUNT(*) FROM traces
  UNION ALL
  SELECT 'projections', COUNT(*) FROM projections
"

# 2. Check for orphaned records
./tools/kairon-ops.sh db-query "
  SELECT 'events_without_traces' as issue,
         COUNT(*) as count
  FROM events e
  WHERE NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id)
    AND e.created_at > NOW() - INTERVAL '24 hours'
"

# 3. Check recent errors
./tools/kairon-ops.sh db-query "
  SELECT error_message, COUNT(*) as occurrences
  FROM traces
  WHERE error_message IS NOT NULL
    AND created_at > NOW() - INTERVAL '1 hour'
  GROUP BY error_message
  ORDER BY occurrences DESC
"
```

---

## Debug Tools Reference

### Workflow Inspection Tools

#### inspect_workflow.py - Analyze Workflow Structure
```bash
# Show workflow overview
./scripts/workflows/inspect_workflow.py n8n-workflows/Route_Event.json

# List all nodes by type
./scripts/workflows/inspect_workflow.py n8n-workflows/Route_Event.json --nodes

# Show specific node details
./scripts/workflows/inspect_workflow.py n8n-workflows/Route_Event.json --node "Parse Message"

# Extract all SQL queries
./scripts/workflows/inspect_workflow.py n8n-workflows/Route_Event.json --sql

# Show connection graph
./scripts/workflows/inspect_workflow.py n8n-workflows/Route_Event.json --connections

# Validate structure (orphans, connections, ctx usage)
./scripts/workflows/inspect_workflow.py n8n-workflows/*.json --validate
```

#### lint_workflows.py - Validate Best Practices
```bash
# Lint all workflows
python scripts/workflows/lint_workflows.py

# Check specific workflow
python scripts/workflows/lint_workflows.py n8n-workflows/Route_Event.json

# Lint with detailed output
python scripts/workflows/lint_workflows.py --verbose
```

#### inspect_execution.py - Debug Failed Executions
```bash
# Analyze execution results (requires execution ID)
./scripts/workflows/inspect_execution.py <execution-id>

# Show execution summary
./scripts/workflows/inspect_execution.py <execution-id> --summary

# Extract error details
./scripts/workflows/inspect_execution.py <execution-id> --errors
```

### Database Health Tools

#### Migration Status Check
```bash
# Check migration status
./scripts/db/check_migration_status.sql

# Check for duplicate events
./scripts/db/check_duplicates.sql

# Analyze processing by tag type
./scripts/db/check_orphans_by_tag.sql
```

#### Database Query Templates
```bash
# Recent events by type
./tools/kairon-ops.sh db-query "
  SELECT event_type, COUNT(*) as count,
         MIN(created_at) as earliest, MAX(created_at) as latest
  FROM events
  WHERE created_at > NOW() - INTERVAL '1 hour'
  GROUP BY event_type
  ORDER BY count DESC
"

# Failed traces in last hour
./tools/kairon-ops.sh db-query "
  SELECT e.event_type, e.clean_text, t.error_message, t.created_at
  FROM events e
  JOIN traces t ON t.event_id = e.id
  WHERE t.error_message IS NOT NULL
    AND t.created_at > NOW() - INTERVAL '1 hour'
  ORDER BY t.created_at DESC
  LIMIT 10
"

# Projection status summary
./tools/kairon-ops.sh db-query "
  SELECT projection_type, status, COUNT(*) as count
  FROM projections
  WHERE created_at > NOW() - INTERVAL '24 hours'
  GROUP BY projection_type, status
  ORDER BY projection_type, status
"
```

### Testing Tools

#### n8n Workflow Validator
```bash
# Validate workflow structure
python scripts/validation/n8n_workflow_validator.py n8n-workflows/Route_Event.json

# Check ctx pattern compliance
python scripts/validation/n8n_workflow_validator.py n8n-workflows/Route_Event.json --ctx-only
```

#### UI Compatibility Testing
```bash
# Run UI compatibility tests
python scripts/testing/n8n-ui-tester.py

# Test specific workflow
python scripts/testing/n8n-ui-tester.py --workflow Route_Event
```

---

## Debugging by Scenario

### 🔄 Workflow Not Processing Messages

**Symptoms:** Messages sent but no database updates, no errors in logs

```bash
# 1. Check webhook registration
curl -s http://localhost:5679/api/v1/workflows | jq '.data[] | select(.active == true) | {name, id}'

# 2. Verify webhook path
curl -s http://localhost:5679/api/v1/workflows/<workflow-id> | jq '.nodes[] | select(.type == "n8n-nodes-base.webhook") | .parameters.path'

# 3. Test webhook directly
curl -X POST http://localhost:5679/webhook/kairon-dev-test \
  -H "Content-Type: application/json" \
  -d '{"event_type": "message", "content": "!! test", "guild_id": "test", "channel_id": "test", "message_id": "test-123", "author": {"login": "test"}, "timestamp": "'$(date -Iseconds)'"}'

# 4. Check execution status
curl -s http://localhost:5679/api/v1/executions?limit=5 | jq '.data[] | {id, status, workflowId, createdAt}'
```

### 📝 Messages Processing But No Projections Created

**Symptoms:** Events in database, traces created, but no activities/notes/todos

```bash
# 1. Check message parsing
./tools/kairon-ops.sh db-query "
  SELECT id, clean_text, tag, received_at
  FROM events
  WHERE event_type = 'discord_message'
  ORDER BY received_at DESC
  LIMIT 5
"

# 2. Check trace creation
./tools/kairon-ops.sh db-query "
  SELECT e.clean_text, t.id as trace_id, t.llm_model, t.error_message
  FROM events e
  LEFT JOIN traces t ON t.event_id = e.id
  WHERE e.event_type = 'discord_message'
  ORDER BY e.received_at DESC
  LIMIT 5
"

# 3. Check LLM responses (if using real API)
./tools/kairon-ops.sh db-query "
  SELECT t.llm_input_tokens, t.llm_output_tokens, t.confidence, t.error_message
  FROM traces t
  WHERE t.created_at > NOW() - INTERVAL '1 hour'
  ORDER BY t.created_at DESC
  LIMIT 5
"
```

### 🚨 Workflow Failing with Errors

**Symptoms:** Executions failing, error messages in logs

```bash
# 1. Get recent failed executions
curl -s http://localhost:5679/api/v1/executions?status=error&limit=5 | jq '.data[] | {id, workflowId, createdAt}'

# 2. Inspect specific execution
curl -s http://localhost:5679/api/v1/executions/<execution-id> | jq '.data[] | select(.nodeName and .error) | {nodeName, error}'

# 3. Check workflow structure
./scripts/workflows/inspect_workflow.py n8n-workflows/Route_Event.json --validate

# 4. Test individual nodes (if possible)
# Use n8n UI to test individual nodes manually
```

### 🗄️ Database Connection Issues

**Symptoms:** Workflows failing at database nodes, connection errors

```bash
# 1. Test database connectivity
./tools/kairon-ops.sh db-query "SELECT version()"

# 2. Check active connections
./tools/kairon-ops.sh db-query "
  SELECT count(*) as active_connections
  FROM pg_stat_activity
  WHERE state = 'active'
"

# 3. Check for locks
./tools/kairon-ops.sh db-query "
  SELECT pid, usename, pg_blocking_pids(pid) as blocked_by, query
  FROM pg_stat_activity
  WHERE cardinality(pg_blocking_pids(pid)) > 0
"

# 4. Verify credentials (in n8n UI)
# Check Postgres node credentials are correct
```

### ⚡ Performance Issues

**Symptoms:** Workflows slow, high resource usage, timeouts

```bash
# 1. Check execution times
./tools/kairon-ops.sh db-query "
  SELECT AVG(EXTRACT(epoch FROM (updated_at - created_at))) as avg_execution_time_seconds
  FROM projections
  WHERE created_at > NOW() - INTERVAL '1 hour'
"

# 2. Check slow queries
./tools/kairon-ops.sh db-query "
  SELECT query, total_time/1000 as seconds, calls
  FROM pg_stat_statements
  ORDER BY total_time DESC
  LIMIT 10
"

# 3. Monitor resource usage
docker stats  # For local dev
# OR for production:
ssh production-server "docker stats"
```

---

## Common Issues & Solutions

### Issue: "Webhook not registered"
```
Error: The requested webhook "POST kairon-dev-test" is not registered
```

**Solutions:**
1. **Check workflow is active:**
   ```bash
   curl -s http://localhost:5679/api/v1/workflows | jq '.data[] | select(.active == true) | {name, id}'
   ```

2. **Verify webhook path:**
   ```bash
   curl -s http://localhost:5679/api/v1/workflows/<id> | jq '.nodes[] | select(.type == "n8n-nodes-base.webhook") | .parameters.path'
   ```

3. **Activate workflow:**
   ```bash
   curl -X POST http://localhost:5679/api/v1/workflows/<id>/activate
   ```

### Issue: "ctx.event is undefined"
```
Error: Cannot read property 'event_id' of undefined
```

**Solutions:**
1. **Check ctx initialization:**
   ```bash
   ./scripts/workflows/inspect_workflow.py n8n-workflows/Route_Event.json --ctx
   ```

2. **Verify data flow:**
   - Check that nodes read from `$json.ctx.*` not node references
   - Ensure ctx is preserved through Merge nodes

3. **Add debug logging:**
   ```javascript
   console.log('ctx at this point:', $json.ctx);
   return [{ json: { ctx: $json.ctx } }];
   ```

### Issue: "Database connection failed"
```
Error: Connection to database failed
```

**Solutions:**
1. **Check credentials:** Verify Postgres node has correct credentials
2. **Test connection:** Use `./tools/kairon-ops.sh db-query "SELECT 1"`
3. **Check network:** For local dev, ensure postgres container is running
4. **Verify SSL settings:** Some deployments require SSL configuration

### Issue: "LLM API rate limited"
```
Error: Rate limit exceeded
```

**Solutions:**
1. **Check API usage:** Monitor OpenRouter dashboard
2. **Add retry logic:** Configure HTTP Request node with retries
3. **Use caching:** Implement response caching for common queries
4. **Switch to mock mode:** Use `NO_MOCKS=1` in local dev

### Issue: "Workflow stuck in 'running' state"
```
Status: running (but never completes)
```

**Solutions:**
1. **Check for infinite loops:** Review workflow connections
2. **Look for hanging HTTP calls:** Check external API timeouts
3. **Inspect execution:** Use execution inspector to see where it stopped
4. **Kill stuck executions:** `curl -X POST http://localhost:5679/api/v1/executions/<id>/stop`

---

## Advanced Debugging

### Custom Debug Workflows

Create temporary workflows for testing specific components:

```bash
# Test database connection
curl -X POST http://localhost:5679/webhook/test-db \
  -H "Content-Type: application/json" \
  -d '{"test": "connection"}'
```

### Performance Profiling

```bash
# Profile workflow execution times
./tools/kairon-ops.sh db-query "
  WITH execution_times AS (
    SELECT
      EXTRACT(epoch FROM (p.updated_at - e.received_at)) as total_time,
      EXTRACT(epoch FROM (t.created_at - e.received_at)) as llm_time,
      p.projection_type
    FROM events e
    JOIN traces t ON t.event_id = e.id
    JOIN projections p ON p.trace_id = t.id
    WHERE e.received_at > NOW() - INTERVAL '1 hour'
  )
  SELECT
    projection_type,
    COUNT(*) as count,
    AVG(total_time) as avg_total_time,
    AVG(llm_time) as avg_llm_time
  FROM execution_times
  GROUP BY projection_type
  ORDER BY avg_total_time DESC
"
```

### Memory and Resource Debugging

```bash
# Check n8n memory usage
docker stats n8n-local

# Monitor database connections
./tools/kairon-ops.sh db-query "
  SELECT
    state,
    COUNT(*) as count,
    AVG(EXTRACT(epoch FROM (now() - state_change))) as avg_state_time_seconds
  FROM pg_stat_activity
  GROUP BY state
  ORDER BY count DESC
"
```

### Network Debugging

```bash
# Test external API connectivity
curl -I https://api.openai.com/v1/models

# Check webhook payload format
curl -X POST http://localhost:5679/webhook/test \
  -H "Content-Type: application/json" \
  -d @test-payload.json
```

### Log Analysis Patterns

```bash
# Extract error patterns from logs
docker logs n8n-local 2>&1 | grep -i error | tail -20

# Find timeout issues
docker logs n8n-local 2>&1 | grep -i timeout

# Analyze execution patterns
docker logs n8n-local 2>&1 | grep "execution.*completed" | wc -l
```

---

## Debug Tool Quick Reference

| Tool | Purpose | Usage |
|------|---------|-------|
| `inspect_workflow.py` | Analyze workflow structure | `./scripts/workflows/inspect_workflow.py workflow.json --validate` |
| `lint_workflows.py` | Check best practices | `python scripts/workflows/lint_workflows.py` |
| `inspect_execution.py` | Debug failed executions | `./scripts/workflows/inspect_execution.py <execution-id>` |
| `check_migration_status.sql` | Database health check | `./tools/kairon-ops.sh db -f scripts/db/check_migration_status.sql` |
| `kairon-ops.sh status` | System overview | `./tools/kairon-ops.sh status` |
| `docker logs` | Container logs | `docker logs n8n-local` |

**Remember:** Start with the checklists, use the tools systematically, and work from symptoms to root cause!

---

**Last Updated:** 2025-12-26