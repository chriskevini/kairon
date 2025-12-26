# Kairon

A Discord-first life tracking system using n8n workflows and PostgreSQL.

## What It Does

Send messages to Discord, Kairon captures and organizes them:

- **Activities** - Track what you're doing (`!! working on router`)
- **Notes** - Capture thoughts and observations (`.. coffee helps focus`)
- **Todos** - Track tasks (`$$ fix the bug`)
- **Threads** - Multi-turn conversations (`++ what should I focus on?`)
- **Commands** - System control (`::help`, `::recent`, `::set timezone vancouver`)

No tag? Kairon uses AI to classify your message automatically.

## Architecture

```
Discord → discord_relay.py → n8n webhook → Route_Event workflow
                                                    ↓
                                    ┌───────────────┼───────────────┐
                                    ↓               ↓               ↓
                              Route_Message   Route_Reaction   Cron triggers
                                    ↓               ↓               ↓
                              Multi_Capture   (reactions)    Generate_Nudge
                              Start_Thread                   Generate_Daily_Summary
                              Execute_Command
                                    ↓
                              Capture_Projection → PostgreSQL
```

## Database Schema

**5 tables, that's it:**

```
events        Immutable log of all incoming events
traces        One trace per LLM call, links to event
projections   Structured outputs (activities, notes, todos, nudges, etc.)
config        User settings (north_star, timezone)
embeddings    Vector storage for RAG (future)
```

**Core principle:** Every projection traces back to an event through a trace.

```
Event (discord message or system trigger)
  └── Trace (LLM reasoning)
        └── Projection (activity, note, todo, etc.)
```

See `db/schema.sql` for the complete schema. Historical migrations are in `db/migrations/archive/`.

## Quick Start

### 1. Database Setup

```bash
createdb kairon
psql kairon < db/schema.sql
```

### 2. Discord Bot

```bash
pip install -r requirements.txt
cp .env.example .env
# Edit .env with your Discord token and n8n webhook URL
python discord_relay.py
```

### 3. n8n Workflows

Push workflows to your n8n instance:

```bash
./scripts/workflows/n8n-push.sh
```

Activate `Route_Event` workflow (the main entry point with webhook + crons).

## Usage

### Message Tags

| Tag | Purpose | Example |
|-----|---------|---------|
| `!!` | Log activity | `!! debugging auth` |
| `..` | Capture note | `.. John likes dark roast` |
| `++` | Start thread | `++ what should I focus on?` |
| `::` | Run command | `::help` |
| (none) | AI classifies | `just finished lunch` |

### Commands

```
::help                    Show all commands
::ping                    Test system
::stats                   Activity statistics
::recent [N]              Last N projections
::recent activities [N]   Last N activities
::recent notes [N]        Last N notes
::recent todos [N]        Last N todos
::delete activity 1 3     Delete by index
::get <key>               Get config value
::set <key> <value>       Set config value
::generate nudge          Trigger nudge now
::generate summary        Trigger daily summary
```

### Config Keys

```
north_star    Your guiding principle (used by nudge AI)
timezone      Your timezone (e.g., "vancouver", "pacific", "America/Vancouver")
```

## Workflows

| Workflow | Purpose |
|----------|---------|
| Route_Event | Main entry point (webhook + crons) |
| Route_Message | Classify and route messages by tag |
| Route_Reaction | Handle emoji reactions |
| Multi_Capture | Extract activities/notes/todos from untagged text |
| Start_Thread | Create Discord threads for `++` |
| Continue_Thread | Handle thread replies |
| Capture_Thread | Save thread extractions on `--` |
| Capture_Projection | Store projections in DB |
| Save_Extraction | Save individual thread items via reaction |
| Execute_Command | Handle `::` commands |
| Handle_Correction | Re-process messages after user correction emoji |
| Handle_Todo_Status | Update todo status via reactions (WIP) |
| Generate_Nudge | Periodic check-ins (every 15 min) |
| Generate_Daily_Summary | End-of-day summary (11 PM) |
| Handle_Error | Error handling and logging |

## Development

### Workflow Development

```bash
# Pull latest from server
./scripts/workflows/n8n-pull.sh

# Push changes to server
./scripts/workflows/n8n-push.sh

# Validate JSON syntax
./scripts/workflows/validate_workflows.sh

# Lint for ctx pattern compliance
python3 scripts/workflows/lint_workflows.py
```

### Database Queries

```bash
# Run SQL on remote DB
./scripts/db/db-query.sh "SELECT * FROM projections LIMIT 5;"

# Run a migration
./scripts/db/run-migration.sh db/migrations/archive/017_fix_trace_chains.sql
```

### Git Hooks

```bash
# Set up pre-commit hooks (validates workflows before commit)
git config core.hooksPath .githooks
```

## Project Structure

```
n8n-workflows/           Workflow JSON files (synced with server)
scripts/
  workflows/             n8n-push.sh, n8n-pull.sh, validate, lint
  db/                    run-migration.sh, db-query.sh
db/
  schema.sql             Current database schema
  migrations/archive/    Historical migrations
prompts/                 LLM prompts
discord_relay.py         Discord bot → n8n webhook
```

## Environment Variables

See `.env.example` for required variables. Key ones:

```
DISCORD_TOKEN            Bot token
N8N_WEBHOOK_URL          Webhook endpoint
DISCORD_CHANNEL_ARCANE   Main input channel ID
DISCORD_CHANNEL_LOGS     Logs channel ID
```

n8n environment variables (set in n8n):

```
DISCORD_GUILD_ID
DISCORD_CHANNEL_ARCANE_SHELL
DISCORD_CHANNEL_KAIRON_LOGS
OPENROUTER_API_KEY
POSTGRES_*
```

## The ctx Pattern

All workflows pass data through a `ctx` object to prevent data loss:

```javascript
{
  ctx: {
    event: { event_id, channel_id, message_id, clean_text, tag, ... },
    routing: { intent, confidence },
    db: { projection_id, trace_id },
    response: { content, channel_id }
  }
}
```

See `AGENTS.md` for detailed workflow development guidelines.

## Documentation

### 📚 Documentation Overview

The `docs/` directory contains comprehensive documentation for development, operations, and maintenance.

### 📋 Documentation Guide

| Document | Purpose | Audience | Quick Access |
|----------|---------|----------|--------------|
| **[AGENTS.md](AGENTS.md)** | Agent guidelines, ctx pattern, n8n best practices | All developers | Root directory |
| **[docs/TOOLING-LOCAL.md](docs/TOOLING-LOCAL.md)** | Local development with Docker containers | Developers | Local setup |
| **[docs/TOOLING-PROD.md](docs/TOOLING-PROD.md)** | Production operations and remote management | DevOps, Operations | Production ops |
| **[docs/DEBUG.md](docs/DEBUG.md)** | Debugging tools, techniques, and troubleshooting | All users | Debug guide |
| **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)** | Deployment pipeline and workflow management | DevOps, CI/CD | Deployment |
| **[docs/testing/n8n-ui-compatibility-testing.md](docs/testing/n8n-ui-compatibility-testing.md)** | Workflow validation and testing system | Developers | Testing |

### 🗂️ Archived Documentation

Historical documentation is stored in `docs/archive/` for reference:
- Implementation plans and design decisions
- Postmortems and recovery plans
- Deprecated features and approaches
- Historical migrations and changes

### 🚀 Quick Start by Role

1. **New to Kairon?** Start here for project overview and architecture
2. **Setting up local development?** → `docs/TOOLING-LOCAL.md`
3. **Managing production systems?** → `docs/TOOLING-PROD.md`
4. **Debugging issues?** → `docs/DEBUG.md`
5. **Deploying changes?** → `docs/DEPLOYMENT.md`
6. **Understanding the codebase?** → `AGENTS.md`

### 🔑 Key Concepts

- **ctx Pattern**: Standardized data flow between n8n workflow nodes
- **Local Development**: Docker-based isolated testing environment
- **Deployment Pipeline**: Automated testing and rollback for production
- **Workflow Transformation**: Converting workflows for different environments
