# Save Thread Feature - Deployment Notes

## Changes Made

### 1. Discord Relay Improvements

**File:** `discord_relay.py`

**Changes:**
- **Unified webhook:** Removed `N8N_REACTION_WEBHOOK_URL`, now uses single `N8N_WEBHOOK_URL` for both messages and reactions
- **Added `event_type` field:** `"message"` or `"reaction"` to distinguish event types in n8n
- **Added `parent_id` field:** For threads, includes parent channel ID so summaries can post to channel root
- **Fast fire-and-forget:** 2s timeout, immediate response, n8n handles errors
- **Simplified:** Less configuration, cleaner architecture

**New payload structure:**
```json
{
  "event_type": "message" | "reaction",
  "parent_id": "channel_id_of_parent",  // NEW: For threads
  // ... rest of fields
}
```

### 2. Router Updates Needed

**Discord_Message_Router.json:**
- Add filter: `event_type === "message"` at start
- Pass through `parent_id` to downstream workflows

**Emoji_Reaction_Router.json:**
- Change webhook trigger to use same URL as message router
- Add filter: `event_type === "reaction"` at start
- Or merge into Discord_Message_Router with switch node

### 3. Save_Thread Workflow Updates Needed

**Add before "send_a_message" node:**

```sql
-- Get old summary message ID
SELECT summary_message_id 
FROM thread_extractions 
WHERE conversation_id = $1 
  AND summary_message_id IS NOT NULL 
LIMIT 1;
```

**If found, delete it:**
```javascript
DELETE https://discord.com/api/v10/channels/{parent_id}/messages/{old_summary_message_id}
```

**Update "send_a_message" node:**
- Change `channel_id` from `{{ $json.channel_id }}` to `{{ $json.parent_id }}`
- This posts to channel root instead of inside thread

### 4. Database Backup Created

**Location:** `/root/backups/kairon_backup_20251218_010652.dump` (69KB)

**Restore command:**
```bash
docker exec -i postgres-db pg_restore -U n8n_user -d kairon < /root/backups/kairon_backup_20251218_010652.dump
```

## Deployment Steps

### 1. Update discord_relay.py on DigitalOcean

```bash
# SSH to server
ssh DigitalOcean

# Backup current relay
cp discord-bot/discord_relay.py discord-bot/discord_relay.py.backup

# Pull latest code
cd /root/kairon
git pull origin main

# Copy updated relay to docker volume
cp discord_relay.py ../discord-bot/

# Remove N8N_REACTION_WEBHOOK_URL from .env if present
cd ../discord-bot
nano .env  # Remove N8N_REACTION_WEBHOOK_URL line

# Restart service
systemctl restart kairon-relay

# Check logs
journalctl -u kairon-relay -f
```

### 2. Update n8n Workflows

1. **Export current workflows as backup**
2. **Import updated workflows:**
   - Save_Thread.json (with old summary deletion)
   - Discord_Message_Router.json (with event_type filter)
   - Emoji_Reaction_Router.json (using same webhook)
3. **Update webhook paths** to use `{{ $env.WEBHOOK_PATH }}`
4. **Activate workflows**

### 3. Test End-to-End

```
1. Start thread: ++ what should I focus on?
2. Have conversation with insights/todos
3. Send -- to trigger extraction
4. Verify summary posts to CHANNEL ROOT (not thread)
5. Send -- again to regenerate
6. Verify old summary is DELETED, new one appears
7. Click number emoji to save
8. Verify item saved and emoji removed
9. Click 🗑️ to delete thread
10. Verify thread deleted, summary deleted, DB updated
```

## Architecture Benefits

### Single Webhook
- ✅ Less configuration
- ✅ Simpler relay code
- ✅ n8n queues events naturally
- ✅ No collision risk (extremely unlikely user sends message + emoji simultaneously)

### Fire-and-Forget Relay
- ✅ Lean relay (no error handling)
- ✅ Fast feedback (immediate 200 OK)
- ✅ n8n handles workflow errors
- ✅ Easy to monitor (⚠️ reaction if webhook fails)

### Summary in Channel Root
- ✅ Clean thread UI (no clutter)
- ✅ Summary visible to all (not buried in thread)
- ✅ Easy to find past summaries (scroll channel)
- ✅ Old summaries auto-deleted on regeneration

### Old Summary Deletion
- ✅ No stale UI (old emojis don't work anyway)
- ✅ Clean UX (one summary per thread at a time)
- ✅ Less confusion (clear which is current)

## Troubleshooting

### Reactions not working
```bash
# Check relay logs
journalctl -u kairon-relay -f

# Verify bot has reaction permissions
# Discord Developer Portal > Bot > Privileged Gateway Intents > 
#   ✅ Message Content Intent
#   ✅ Server Members Intent (optional)

# Test manually in Discord
# Add reaction to bot message, check relay logs
```

### Summary posts to thread instead of channel
```bash
# Check parent_id in raw_events table
SELECT parent_id FROM raw_events WHERE message_id = '...';

# If NULL, relay not capturing parent_id
# Check discord_relay.py version
```

### Old summaries not deleted
```bash
# Check thread_extractions for summary_message_id
SELECT summary_message_id FROM thread_extractions 
WHERE conversation_id = '...';

# If NULL, workflow not updating after emoji reactions
# Check Handle_Extraction_Save workflow
```

## Rollback Plan

If issues occur:

```bash
# 1. Rollback relay
ssh DigitalOcean
cd discord-bot
cp discord_relay.py.backup discord_relay.py
systemctl restart kairon-relay

# 2. Restore database
docker exec -i postgres-db pg_restore -U n8n_user -d kairon \
  < /root/backups/kairon_backup_20251218_010652.dump

# 3. Revert workflows in n8n UI
# Import from previous backup

# 4. Re-add N8N_REACTION_WEBHOOK_URL if needed
nano .env
```

## Next Phase

After successful deployment and testing:

1. **Optional: Merge routers** - Combine Discord_Message_Router and Emoji_Reaction_Router into single workflow with switch node
2. **Optional: Workflow renaming** - Rename workflows for consistency (Activity_Handler → Save_Activity, etc.)
3. **Optional: Proactive reminders** - Use unsaved_extractions view for gentle nudges
4. **Optional: Thread archival** - Auto-archive old threads, keep DB clean
