# n8n Environment Variables Setup

This document explains how to configure environment variables for the Kairon workflows.

## Why Environment Variables?

- **Security**: Keeps sensitive data (webhook paths, IDs) out of version control
- **Flexibility**: Easy to change configuration across environments (dev/prod)
- **Best Practice**: Follows 12-factor app methodology

---

## Required Environment Variables

| Variable Name | Description | Example |
|---------------|-------------|---------|
| `WEBHOOK_PATH` | Random string for webhook security | `abc123xyz789` |
| `DISCORD_GUILD_ID` | Your Discord server ID | `123456789012345678` |
| `DISCORD_CHANNEL_ARCANE_SHELL` | #arcane-shell channel ID | `123456789012345678` |
| `DISCORD_CHANNEL_KAIRON_LOGS` | #kairon-logs channel ID | `123456789012345678` |

---

## Setup Instructions

### Option 1: Docker (Recommended)

If running n8n via Docker, add environment variables to your `docker-compose.yml`:

```yaml
version: '3'
services:
  n8n:
    image: n8nio/n8n
    environment:
      - WEBHOOK_PATH=your-random-webhook-path
      - DISCORD_GUILD_ID=your-guild-id
      - DISCORD_CHANNEL_ARCANE_SHELL=your-arcane-shell-id
      - DISCORD_CHANNEL_KAIRON_LOGS=your-kairon-logs-id
      # ... other n8n environment variables
    ports:
      - "5678:5678"
    volumes:
      - n8n_data:/home/node/.n8n
```

Then restart n8n:

```bash
docker-compose down
docker-compose up -d
```

### Option 2: Systemd Service

If running n8n as a systemd service, edit the service file:

```bash
sudo nano /etc/systemd/system/n8n.service
```

Add environment variables:

```ini
[Service]
Environment="WEBHOOK_PATH=your-random-webhook-path"
Environment="DISCORD_GUILD_ID=your-guild-id"
Environment="DISCORD_CHANNEL_ARCANE_SHELL=your-arcane-shell-id"
Environment="DISCORD_CHANNEL_KAIRON_LOGS=your-kairon-logs-id"
# ... rest of your service configuration
```

Reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart n8n
```

### Option 3: .env File (Local Development)

Create a `.env` file in your n8n directory:

```bash
# Copy from .env.example
cp .env.example .env

# Edit with your values
nano .env
```

Then start n8n with:

```bash
# Load .env file
export $(cat .env | xargs)
n8n start
```

---

## Using Environment Variables in n8n Workflows

In n8n, reference environment variables using the expression syntax:

```javascript
{{ $env.VARIABLE_NAME }}
```

### Example 1: Webhook Path

In the **Discord Webhook** node:

```
Path: {{ $env.WEBHOOK_PATH }}
```

### Example 2: Discord Channel ID

In a **Discord** node sending messages:

```javascript
Channel ID: {{ $env.DISCORD_CHANNEL_KAIRON_LOGS }}
```

### Example 3: Conditional Logic

```javascript
// In a Code node or expression
const guildId = $env.DISCORD_GUILD_ID;
const isCorrectGuild = $json.guild_id === guildId;
```

---

## Updating Workflows in n8n UI

After setting up environment variables, update your workflows:

### 1. Discord_Message_Router

**Webhook Node:**
- Path: Change `asoiaf92746087` to `{{ $env.WEBHOOK_PATH }}`

**"Log classification to #kairon-logs" Node:**
- Channel ID: Change to `{{ $env.DISCORD_CHANNEL_KAIRON_LOGS }}`

### 2. Command_Handler

**Webhook Node:**
- Path: Change `asoiaf92746087` to `{{ $env.WEBHOOK_PATH }}`

**Discord Nodes (when implemented):**
- Channel ID: Use `{{ $env.DISCORD_CHANNEL_ARCANE_SHELL }}` or `{{ $env.DISCORD_CHANNEL_KAIRON_LOGS }}`

---

## Verifying Environment Variables

You can verify environment variables are loaded in n8n:

1. Create a temporary **Code** node
2. Add this code:
   ```javascript
   return [{
     json: {
       webhook_path: $env.WEBHOOK_PATH,
       guild_id: $env.DISCORD_GUILD_ID
     }
   }];
   ```
3. Execute the node
4. Check the output
5. Delete the node after verification

---

## Security Best Practices

1. **Never commit** actual values to git
2. **Generate random webhook paths**: Use `openssl rand -hex 16` or similar
3. **Rotate webhook paths** periodically if exposed
4. **Restrict n8n access**: Use authentication and HTTPS
5. **Use .env.example**: Commit this with placeholder values only

---

## Discord Relay Configuration

Update your `discord_relay.py` to use the webhook URL with environment variable:

```python
import os

# Load from environment or .env file
N8N_WEBHOOK_URL = os.getenv('N8N_WEBHOOK_URL')
# Example: "https://your-n8n-domain.com/webhook/your-webhook-path"

# Or construct from parts:
N8N_DOMAIN = os.getenv('N8N_DOMAIN', 'n8n.chrisirineo.com')
WEBHOOK_PATH = os.getenv('WEBHOOK_PATH', 'asoiaf92746087')
N8N_WEBHOOK_URL = f"https://{N8N_DOMAIN}/webhook/{WEBHOOK_PATH}"
```

---

## Troubleshooting

### "Workflow cannot be activated" Error

If you see this after adding environment variables:

1. Check that environment variables are actually set in your n8n environment
2. Restart n8n after setting environment variables
3. Try re-importing the workflow
4. Check n8n logs: `docker logs n8n` or `journalctl -u n8n -f`

### Workflow Executions Fail

If workflows fail after adding environment variables:

1. Verify environment variables are loaded (see "Verifying Environment Variables" above)
2. Check for typos in variable names (case-sensitive!)
3. Ensure no quotes around values in expressions: `{{ $env.VARIABLE }}` not `"{{ $env.VARIABLE }}"`

### Old Webhook Path Still Works

This is expected - webhook paths in the workflow configuration are cached. To fully change:

1. Update the workflow
2. Deactivate the workflow
3. Activate it again
4. Update Discord relay to use new webhook URL

---

## Regenerating Webhook Path

If your webhook path is compromised:

```bash
# Generate new random path
openssl rand -hex 16
# Example output: 8f3d2a1b9c7e4f6d2a8b3e1f9c7d4a2b

# Update environment variable
# Update discord_relay.py with new URL
# Restart both n8n and discord relay
```

---

## Next Steps

After setting up environment variables:

1. ✅ Copy `.env.example` to `.env` and fill in your values
2. ✅ Set environment variables in your n8n deployment
3. ✅ Update workflows in n8n UI to use `{{ $env.VARIABLE }}` syntax
4. ✅ Re-export workflows and commit to git (now sanitized)
5. ✅ Update `discord_relay.py` with environment variable for webhook URL
6. ✅ Test workflows to ensure environment variables work
