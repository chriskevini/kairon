"""
Unit tests for discord_relay.py

Tests the core payload formatting and channel filtering logic.
Run with: pytest tests/test_discord_relay.py -v
"""

import pytest
from unittest.mock import Mock, MagicMock
from datetime import datetime


# Import the functions to test (after mocking discord imports)
@pytest.fixture(autouse=True)
def mock_discord_imports(monkeypatch):
    """Mock discord imports before importing discord_relay."""
    import sys
    
    # Create mock discord module
    mock_discord = MagicMock()
    mock_discord.Intents.default.return_value = MagicMock()
    mock_discord.Thread = type('Thread', (), {})
    mock_discord.TextChannel = type('TextChannel', (), {})
    mock_discord.Message = type('Message', (), {})
    mock_discord.Reaction = type('Reaction', (), {})
    mock_discord.User = type('User', (), {})
    mock_discord.Member = type('Member', (), {})
    
    mock_commands = MagicMock()
    mock_aiohttp = MagicMock()
    mock_dotenv = MagicMock()
    
    monkeypatch.setitem(sys.modules, 'discord', mock_discord)
    monkeypatch.setitem(sys.modules, 'discord.ext', MagicMock())
    monkeypatch.setitem(sys.modules, 'discord.ext.commands', mock_commands)
    monkeypatch.setitem(sys.modules, 'aiohttp', mock_aiohttp)
    monkeypatch.setitem(sys.modules, 'dotenv', mock_dotenv)
    
    # Now we can import the module
    import importlib
    if 'discord_relay' in sys.modules:
        importlib.reload(sys.modules['discord_relay'])


class TestIsArcaneShellChannel:
    """Tests for is_arcane_shell_channel function."""
    
    def test_text_channel_arcane_shell(self):
        """Text channel named arcane-shell should return True."""
        import discord_relay
        import discord
        
        channel = Mock(spec=discord.TextChannel)
        channel.name = "arcane-shell"
        
        assert discord_relay.is_arcane_shell_channel(channel) is True
    
    def test_text_channel_other_name(self):
        """Text channel with different name should return False."""
        import discord_relay
        import discord
        
        channel = Mock(spec=discord.TextChannel)
        channel.name = "general"
        
        assert discord_relay.is_arcane_shell_channel(channel) is False
    
    def test_thread_from_arcane_shell(self):
        """Thread from arcane-shell should return True."""
        import discord_relay
        import discord
        
        parent = Mock()
        parent.name = "arcane-shell"
        
        thread = Mock(spec=discord.Thread)
        thread.parent = parent
        
        assert discord_relay.is_arcane_shell_channel(thread) is True
    
    def test_thread_from_other_channel(self):
        """Thread from other channel should return False."""
        import discord_relay
        import discord
        
        parent = Mock()
        parent.name = "general"
        
        thread = Mock(spec=discord.Thread)
        thread.parent = parent
        
        assert discord_relay.is_arcane_shell_channel(thread) is False
    
    def test_thread_no_parent(self):
        """Thread with no parent should return False."""
        import discord_relay
        import discord
        
        thread = Mock(spec=discord.Thread)
        thread.parent = None
        
        assert discord_relay.is_arcane_shell_channel(thread) is False
    
    def test_unknown_channel_type(self):
        """Unknown channel type should return False."""
        import discord_relay
        
        channel = Mock()  # Not a Thread or TextChannel
        channel.name = "arcane-shell"
        
        # Remove spec attributes to make isinstance checks fail
        assert discord_relay.is_arcane_shell_channel(channel) is False


class TestFormatMessagePayload:
    """Tests for format_message_payload function."""
    
    def create_mock_message(self, **kwargs):
        """Helper to create a mock Discord message."""
        import discord
        
        message = Mock(spec=discord.Message)
        message.guild = Mock()
        message.guild.id = kwargs.get('guild_id', 123456789)
        message.channel = Mock(spec=discord.TextChannel)
        message.channel.id = kwargs.get('channel_id', 987654321)
        message.channel.name = kwargs.get('channel_name', 'arcane-shell')
        message.id = kwargs.get('message_id', 111222333)
        message.author = Mock()
        message.author.name = kwargs.get('author_name', 'testuser')
        message.author.id = kwargs.get('author_id', 444555666)
        message.author.display_name = kwargs.get('display_name', 'Test User')
        message.content = kwargs.get('content', 'Hello world')
        message.created_at = kwargs.get('created_at', datetime(2025, 12, 21, 10, 30, 0))
        
        return message
    
    def test_basic_message_payload(self):
        """Test basic message formatting."""
        import discord_relay
        
        message = self.create_mock_message(
            guild_id=123,
            channel_id=456,
            message_id=789,
            author_name='alice',
            author_id=111,
            display_name='Alice',
            content='!! working on tests',
            created_at=datetime(2025, 12, 21, 14, 30, 0)
        )
        
        payload = discord_relay.format_message_payload(message)
        
        assert payload['event_type'] == 'message'
        assert payload['guild_id'] == '123'
        assert payload['channel_id'] == '456'
        assert payload['message_id'] == '789'
        assert payload['author']['login'] == 'alice'
        assert payload['author']['id'] == '111'
        assert payload['author']['display_name'] == 'Alice'
        assert payload['content'] == '!! working on tests'
        assert payload['thread_id'] is None
        assert payload['parent_id'] is None
    
    def test_thread_message_payload(self):
        """Test message in thread includes thread_id and parent_id."""
        import discord_relay
        import discord
        
        message = self.create_mock_message()
        
        # Make channel a thread
        message.channel = Mock(spec=discord.Thread)
        message.channel.id = 999888777
        message.channel.parent_id = 123456789
        
        payload = discord_relay.format_message_payload(message)
        
        assert payload['thread_id'] == '999888777'
        assert payload['parent_id'] == '123456789'
    
    def test_no_guild_message(self):
        """Test DM message (no guild) has null guild_id."""
        import discord_relay
        
        message = self.create_mock_message()
        message.guild = None
        
        payload = discord_relay.format_message_payload(message)
        
        assert payload['guild_id'] is None


class TestFormatReactionPayload:
    """Tests for format_reaction_payload function."""
    
    def create_mock_reaction(self, **kwargs):
        """Helper to create a mock Discord reaction."""
        import discord
        
        reaction = Mock(spec=discord.Reaction)
        reaction.emoji = kwargs.get('emoji', '✅')
        
        message = Mock(spec=discord.Message)
        message.guild = Mock()
        message.guild.id = kwargs.get('guild_id', 123456789)
        message.channel = Mock(spec=discord.TextChannel)
        message.channel.id = kwargs.get('channel_id', 987654321)
        message.id = kwargs.get('message_id', 111222333)
        message.author = Mock()
        message.author.id = kwargs.get('author_id', 444555666)
        message.author.name = kwargs.get('author_name', 'originaluser')
        message.content = kwargs.get('message_content', 'Original message')
        
        reaction.message = message
        
        return reaction
    
    def create_mock_user(self, **kwargs):
        """Helper to create a mock Discord user."""
        import discord
        
        user = Mock(spec=discord.User)
        user.id = kwargs.get('id', 777888999)
        user.name = kwargs.get('name', 'reactor')
        user.display_name = kwargs.get('display_name', 'Reactor User')
        
        return user
    
    def test_reaction_add_payload(self):
        """Test reaction add payload formatting."""
        import discord_relay
        
        reaction = self.create_mock_reaction(
            emoji='👍',
            guild_id=123,
            channel_id=456,
            message_id=789
        )
        user = self.create_mock_user(id=111, name='alice', display_name='Alice')
        
        payload = discord_relay.format_reaction_payload(reaction, user, 'add')
        
        assert payload['event_type'] == 'reaction'
        assert payload['action'] == 'add'
        assert payload['emoji'] == '👍'
        assert payload['guild_id'] == '123'
        assert payload['channel_id'] == '456'
        assert payload['message_id'] == '789'
        assert payload['user']['id'] == '111'
        assert payload['user']['login'] == 'alice'
    
    def test_reaction_remove_payload(self):
        """Test reaction remove action."""
        import discord_relay
        
        reaction = self.create_mock_reaction()
        user = self.create_mock_user()
        
        payload = discord_relay.format_reaction_payload(reaction, user, 'remove')
        
        assert payload['action'] == 'remove'
    
    def test_custom_emoji(self):
        """Test custom emoji (non-string) handling."""
        import discord_relay
        
        custom_emoji = Mock()
        custom_emoji.name = 'custom_emoji'
        
        reaction = self.create_mock_reaction()
        reaction.emoji = custom_emoji
        
        user = self.create_mock_user()
        
        payload = discord_relay.format_reaction_payload(reaction, user, 'add')
        
        assert payload['emoji_name'] == 'custom_emoji'
