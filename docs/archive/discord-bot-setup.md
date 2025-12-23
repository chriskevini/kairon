# Discord Bot Setup

## Prerequisites

- Python 3.9+
- Discord account with server admin permissions
- n8n instance with webhook configured

## 1. Create Discord Bot

### Go to Discord Developer Portal

1. Visit https://discord.com/developers/applications
2. Click "New Application"
3. Name it "Kairon" (or whatever you prefer)
4. Go to "Bot" tab
5. Click "Add Bot"

### Configure Bot Permissions

Required permissions:
- ✅ Read Messages/View Channels
- ✅ Send Messages
- ✅ Create Public Threads
- ✅ Send Messages in Threads
- ✅ Manage Threads
- ✅ Add Reactions
- ✅ Read Message History

### Enable Privileged Gateway Intents

In Bot settings, enable:
- ✅ MESSAGE CONTENT INTENT (required!)
- ✅ SERVER MEMBERS INTENT
- ✅ PRESENCE INTENT

### Get Bot Token

1. In Bot settings, click "Reset Token"
2. Copy the token (you'll need this for `.env`)
3. **Keep this secret!**

### Generate Invite Link

1. Go to "OAuth2" > "URL Generator"
2. Select scopes:
   - ✅ `bot`
3. Select permissions (same as above)
4. Copy generated URL
5. Open in browser and invite to your server

## 2. Set Up Discord Server

### Create Required Channels

1. **#arcane-shell** (text channel)
   - This is where you'll send commands and log activities
   - Bot must have access

2. **#obsidian-board** (text channel) - Optional for Phase 1
   - This is where Kairon posts summaries and plans
   - Bot must have access

3. **#kairon-log** (text channel) - Optional
   - System audit log
   - Bot must have access

### Channel Permissions

For each channel:
1. Right-click channel → Edit Channel
2. Permissions tab
3. Add Kairon bot role
4. Grant permissions:
   - View Channel
   - Send Messages
   - Create Threads
   - Send Messages in Threads
   - Add Reactions
   - Read Message History
   - Manage Threads

## 3. Install Python Dependencies

```bash
cd /home/chris/Work/kairon
pip install -r requirements.txt
```

## 4. Configure Environment Variables

Create `.env` file:

```bash
cat > .env << 'EOF'
# Discord Bot Token (from Developer Portal)
DISCORD_BOT_TOKEN=your_bot_token_here

# n8n Webhook URL (from n8n workflow)
N8N_WEBHOOK_URL=http://localhost:5678/webhook/discord-webhook
EOF
```

**Important:** Add `.env` to `.gitignore`:

```bash
echo ".env" >> .gitignore
```

## 5. Run the Bot

```bash
python discord_relay.py
```

Expected output:
```
Starting Kairon Discord Relay...
✓ Bot logged in as Kairon#1234
✓ Connected to 1 guild(s)
✓ Listening for messages in #arcane-shell
✓ Webhook URL: http://localhost:5678/webhook/discord-webhook
```

## 6. Test the Integration

### Test Message Relay

In #arcane-shell:
```
!! testing the system
```

Check console output:
```
✓ Sent message 1234567890 to n8n
```

Check n8n:
- Webhook should receive the payload
- Check n8n execution log

### Test Thread Detection

In #arcane-shell:
```
++ test thread
```

Should:
- Create thread
- Bot should detect thread messages
- Relay thread messages to n8n

## Running as a Service (Production)

### Using systemd (Linux)

Create service file:

```bash
sudo nano /etc/systemd/system/kairon-relay.service
```

Content:
```ini
[Unit]
Description=Kairon Discord Relay
After=network.target

[Service]
Type=simple
User=your_username
WorkingDirectory=/home/chris/Work/kairon
Environment="PATH=/home/chris/.local/bin:/usr/bin"
ExecStart=/usr/bin/python3 /home/chris/Work/kairon/discord_relay.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl enable kairon-relay
sudo systemctl start kairon-relay
sudo systemctl status kairon-relay
```

View logs:
```bash
sudo journalctl -u kairon-relay -f
```

### Using PM2 (Node.js)

```bash
npm install -g pm2
pm2 start discord_relay.py --name kairon-relay --interpreter python3
pm2 save
pm2 startup
```

## Troubleshooting

### Bot doesn't see messages

**Check:**
- MESSAGE CONTENT INTENT enabled in Discord Developer Portal
- Bot has "Read Messages" permission in #arcane-shell
- Channel name is exactly "arcane-shell" (case-sensitive)

### Webhook fails

**Check:**
- n8n is running
- Webhook URL is correct
- n8n webhook node is active
- Check n8n logs for errors

### Bot offline

**Check:**
- DISCORD_BOT_TOKEN is correct
- Bot not being rate-limited
- Python dependencies installed
- Check console for error messages

### Thread messages not relaying

**Check:**
- Threads created from #arcane-shell (not other channels)
- Bot has "Send Messages in Threads" permission
- Thread is not archived

## Security Notes

- **Never commit .env or bot tokens to git**
- Regenerate token if exposed
- Use environment variables in production
- Consider using a secrets manager (AWS Secrets, Vault, etc.)
- Limit bot permissions to minimum required

## Next Steps

Once relay is working:
1. Test message flow: Discord → Bot → n8n → Postgres
2. Test emoji reactions (n8n → Discord API)
3. Test thread creation (n8n → Discord API)
4. Verify idempotency (send duplicate message)
