# Discord Event Router Implementation

## Architecture Overview

The Discord bot sends events to n8n through a unified webhook entry point that immediately responds to Discord, then routes internally based on event type:

```
discord_relay.py
   ↓ (sends event_type: "message" or "reaction")
Discord_Event_Router
   ├─ Responds "OK" immediately (relay's job is done)
   └─ Routes via HTTP to sub-workflows
      ├─→ Discord_Message_Router (handles messages)
      └─→ Emoji_Reaction_Router (handles reactions)
```

**Why HTTP requests instead of Execute Workflow?**
- Sub-workflows already have webhook triggers on different paths
- HTTP requests work reliably and are easy to debug
- No need to refactor existing workflows
- Each workflow can still be tested independently via its webhook

## Webhook Paths

- **Main entry:** `WEBHOOK_PATH` (e.g., `/abc123xyz`)
- **Message handler:** `WEBHOOK_PATH/message` (e.g., `/abc123xyz/message`)
- **Reaction handler:** `WEBHOOK_PATH/reaction` (e.g., `/abc123xyz/reaction`)

## Environment Variables

### Required in n8n:
- `WEBHOOK_PATH` - Base webhook path (no trailing slash)
- `N8N_WEBHOOK_BASE_URL` - n8n webhook base URL (e.g., `https://n8n.yourdomain.com`)

### Required in discord_relay.py:
- `DISCORD_BOT_TOKEN` - Discord bot token
- `N8N_WEBHOOK_URL` - Full URL to main entry point (e.g., `https://n8n.yourdomain.com/webhook/abc123xyz`)

## Discord Bot Setup

### Required Intents

In Discord Developer Portal → Bot → Privileged Gateway Intents:
- ✅ **MESSAGE CONTENT INTENT** (required for reaction events on message content)
- ✅ **PRESENCE INTENT** (optional)
- ✅ **SERVER MEMBERS INTENT** (optional)

In `discord_relay.py`:
```python
intents = discord.Intents.default()
intents.message_content = True  # Required
intents.guilds = True
intents.guild_reactions = True  # Required for reactions
intents.members = True  # If you enabled SERVER MEMBERS INTENT
```

### Required Permissions

Bot needs these permissions:
- Read Messages/View Channels
- Send Messages
- Read Message History (required for reaction events)
- Add Reactions
- Use External Emojis (optional)

## Event Payloads

### Message Event
```json
{
  "event_type": "message",
  "guild_id": "123...",
  "channel_id": "456...",
  "parent_id": "789..." (if in thread),
  "message_id": "012...",
  "thread_id": "456..." (if in thread),
  "author": {
    "login": "username",
    "id": "345...",
    "display_name": "Display Name"
  },
  "content": "message text",
  "timestamp": "2025-12-18T11:00:00.000Z"
}
```

### Reaction Event
```json
{
  "event_type": "reaction",
  "action": "add" or "remove",
  "emoji": "📌",
  "emoji_name": "📌",
  "guild_id": "123...",
  "channel_id": "456...",
  "parent_id": "789..." (if in thread),
  "message_id": "012...",
  "thread_id": "456..." (if in thread),
  "user": {
    "id": "345...",
    "login": "username",
    "display_name": "Display Name"
  },
  "message_author": {
    "id": "678...",
    "login": "author_username"
  },
  "message_content": "the message that was reacted to",
  "timestamp": "2025-12-18T11:00:00.000Z"
}
```

## Troubleshooting

### No Reaction Events Received

**Check Discord Bot Intents:**
1. Go to Discord Developer Portal
2. Select your application
3. Go to "Bot" section
4. Scroll to "Privileged Gateway Intents"
5. Enable "MESSAGE CONTENT INTENT"
6. Save changes
7. Restart discord_relay.py

**Check Bot Permissions:**
- Bot must have "Read Message History" permission
- Bot must be able to see the channel

**Check Bot Logs:**
```bash
ssh DigitalOcean "sudo journalctl -u kairon-relay -f"
```

Look for lines like:
- `✓ Sent reaction to n8n (status 200)` - Reaction sent successfully
- `✗ n8n webhook returned 404` - Workflow not activated or wrong path

**Test Reaction Locally:**
Add debug logging to `discord_relay.py`:
```python
@bot.event
async def on_reaction_add(reaction, user):
    print(f"DEBUG: Reaction detected: {reaction.emoji} by {user.name}")
    # ... rest of handler
```

### Webhook 404 Errors

**Cause:** n8n workflow not activated or webhook path mismatch

**Fix:**
1. Activate Discord_Event_Router workflow in n8n
2. Verify webhook path matches: `{{ $env.WEBHOOK_PATH }}`
3. Check `N8N_WEBHOOK_URL` in discord_relay.py matches

### Multiple Workflows on Same Path

**Problem:** Only one workflow can listen on a given webhook path

**Solution:** Use the thin router pattern:
- Discord_Event_Router listens on `WEBHOOK_PATH`
- Routes to sub-paths: `/message` and `/reaction`
- Each handler workflow uses unique sub-path

## Deployment Checklist

- [ ] Discord bot intents enabled (MESSAGE CONTENT required)
- [ ] Discord bot permissions granted (Read Message History required)
- [ ] Environment variables set in n8n
- [ ] Environment variables set in discord_relay.py
- [ ] Import Discord_Event_Router workflow
- [ ] Import Discord_Message_Router workflow
- [ ] Import Emoji_Reaction_Router workflow
- [ ] Activate all workflows
- [ ] Restart discord_relay.py
- [ ] Test message event (send message in #arcane-shell)
- [ ] Test reaction event (add emoji to message)
- [ ] Check n8n execution logs
- [ ] Check bot logs: `journalctl -u kairon-relay -f`
