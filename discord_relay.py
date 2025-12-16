"""
Discord Webhook Relay for Kairon Life OS

Listens to messages in #arcane-shell and forwards them to n8n webhook.
"""

import os
import discord
from discord.ext import commands
import aiohttp
import asyncio
from datetime import datetime
from typing import Optional
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Configuration
DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")
N8N_WEBHOOK_URL = os.getenv("N8N_WEBHOOK_URL")
ARCANE_SHELL_CHANNEL_NAME = "arcane-shell"

# Bot setup
intents = discord.Intents.default()
intents.message_content = True
intents.guilds = True

bot = commands.Bot(command_prefix="!", intents=intents)


def format_message_payload(message: discord.Message) -> dict:
    """
    Format Discord message into n8n webhook payload.
    """
    return {
        "guild_id": str(message.guild.id) if message.guild else None,
        "channel_id": str(message.channel.id),
        "message_id": str(message.id),
        "thread_id": str(message.channel.id) if isinstance(message.channel, discord.Thread) else None,
        "author": {
            "login": message.author.name,
            "id": str(message.author.id),
            "display_name": message.author.display_name,
        },
        "content": message.content,
        "timestamp": message.created_at.isoformat(),
    }


async def send_to_n8n(payload: dict) -> bool:
    """
    Send payload to n8n webhook.
    Returns True if successful, False otherwise.
    """
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                N8N_WEBHOOK_URL,
                json=payload,
                timeout=aiohttp.ClientTimeout(total=10),
            ) as response:
                if response.status == 200:
                    print(f"✓ Sent message {payload['message_id']} to n8n")
                    return True
                else:
                    print(f"✗ n8n webhook returned {response.status}")
                    return False
    except asyncio.TimeoutError:
        print(f"✗ Timeout sending to n8n")
        return False
    except Exception as e:
        print(f"✗ Error sending to n8n: {e}")
        return False


@bot.event
async def on_ready():
    """
    Bot startup event.
    """
    print(f"✓ Bot logged in as {bot.user}")
    print(f"✓ Connected to {len(bot.guilds)} guild(s)")
    print(f"✓ Listening for messages in #{ARCANE_SHELL_CHANNEL_NAME}")
    print(f"✓ Webhook URL: {N8N_WEBHOOK_URL}")


@bot.event
async def on_message(message: discord.Message):
    """
    Message event handler.
    Forwards messages from #arcane-shell or threads started from #arcane-shell.
    """
    # Ignore bot messages
    if message.author.bot:
        return

    # Check if message is in #arcane-shell or a thread from it
    should_process = False

    if isinstance(message.channel, discord.Thread):
        # Message in thread - check if thread parent is #arcane-shell
        parent_channel = message.channel.parent
        if parent_channel and parent_channel.name == ARCANE_SHELL_CHANNEL_NAME:
            should_process = True
    elif isinstance(message.channel, discord.TextChannel):
        # Message in channel - check if it's #arcane-shell
        if message.channel.name == ARCANE_SHELL_CHANNEL_NAME:
            should_process = True

    if not should_process:
        return

    # Format and send to n8n
    payload = format_message_payload(message)
    success = await send_to_n8n(payload)

    if not success:
        # Optionally: add warning reaction if webhook fails
        await message.add_reaction("⚠️")


@bot.event
async def on_error(event: str, *args, **kwargs):
    """
    Global error handler.
    """
    print(f"✗ Error in {event}: {args} {kwargs}")


def main():
    """
    Main entry point.
    """
    # Validate environment variables
    if not DISCORD_BOT_TOKEN:
        print("✗ DISCORD_BOT_TOKEN environment variable not set")
        return

    if not N8N_WEBHOOK_URL:
        print("✗ N8N_WEBHOOK_URL environment variable not set")
        return

    # Run bot
    print("Starting Kairon Discord Relay...")
    bot.run(DISCORD_BOT_TOKEN)


if __name__ == "__main__":
    main()
