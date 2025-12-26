# Agent Guidelines

Instructions for AI agents working on Kairon - a life-tracking system using n8n workflows + Discord.

## What Agents Do

AI agents in Kairon are responsible for:
- **Understanding user messages** and classifying intent
- **Extracting structured data** from natural language
- **Making decisions** about how to process and store information
- **Following established patterns** for workflow execution

## Core Concepts

### The ctx Pattern (CRITICAL)

All workflow communication uses a standardized `ctx` object. This ensures data flows correctly between nodes and prevents information loss.

**Key Points:**
- Every workflow initializes `ctx.event` with core message data
- Use `ctx` namespaces for different data types (llm, db, validation, etc.)
- Never use node references - always read from `$json.ctx.*`
- First node after trigger must set up complete ctx structure

**📖 Details:** See `docs/BEST_PRACTICES.md` for complete ctx pattern guide

### Best Practices & Patterns

For detailed n8n workflow patterns, conventions, and implementation guidelines:

**📖 Details:** See `docs/BEST_PRACTICES.md` for workflow development best practices

### System Data Flow

```
Discord → Route_Event → Route_Message → Multi_Capture/Execute_Command/etc.
                        ↓
                   Store in PostgreSQL
```

**Key Components:**
- **Route_Event**: Entry point with webhooks and cron triggers
- **Route_Message**: Classifies messages by tag or AI analysis
- **Multi_Capture**: Extracts activities/notes/todos from untagged messages
- **Execute_Command**: Handles system commands (`::help`, `::recent`, etc.)

**📖 Details:** See `docs/BEST_PRACTICES.md` for workflow development patterns

### Database Schema

**Core Tables:**
- `events` - Immutable message log (one per Discord message)
- `traces` - LLM reasoning (one per AI call)
- `projections` - Structured outputs (activities, notes, todos)

**Key Principle:** Everything traces back to an event through a trace.

**📖 Details:** See `docs/DATABASE.md` for complete schema reference

## Development Workflow

### Local Development
```bash
# Start containers
docker-compose -f docker-compose.dev.yml up -d

# Transform and deploy workflows
# ... see docs for complete setup
```

**📖 Complete Guide:** `docs/DEVELOPMENT.md`

### Production Operations
```bash
# Deploy changes
./scripts/deploy.sh

# Monitor system
./tools/kairon-ops.sh status
```

**📖 Complete Guide:** `docs/PRODUCTION.md`

### Debugging Issues
```bash
# Check system health
./tools/kairon-ops.sh status

# Inspect workflow execution
# ... see docs for debug tools
```

**📖 Complete Guide:** `docs/DEBUG.md`

## Agent Responsibilities

### Message Processing
1. **Parse incoming messages** for tags (`!!`, `..`, `$$`, etc.)
2. **Route to appropriate handlers** based on tag or AI classification
3. **Extract structured data** from natural language
4. **Store results** in database with proper relationships

### Error Handling
- Never fail silently - always provide user feedback
- Use appropriate error responses for different scenarios
- Log errors for debugging while maintaining user experience

### Testing
- Write unit tests for all logic components
- Test edge cases and error conditions
- Validate database operations and data integrity

## Key Resources

| Resource | Purpose | Location |
|----------|---------|----------|
| **Best Practices** | Core patterns and conventions | `docs/BEST_PRACTICES.md` |
| **Local Development** | Docker setup and testing | `docs/DEVELOPMENT.md` |
| **Production Operations** | Deployment and monitoring | `docs/PRODUCTION.md` |
| **Debugging** | Tools and troubleshooting | `docs/DEBUG.md` |
| **Testing** | Validation and test frameworks | `docs/TESTING.md` |
| **Deployment** | Pipeline and workflow management | `docs/DEPLOYMENT.md` |

## Quick Reference

### Message Tags
| Tag | Purpose | Example |
|-----|---------|---------|
| `!!` | Activity tracking | `!! debugging auth issues` |
| `..` | Note capture | `.. coffee improves focus` |
| `$$` | Todo creation | `$$ fix the bug` |
| `++` | Thread start | `++ what should I focus on?` |
| `::` | System commands | `::help`, `::recent` |

### Common Commands
- `::help` - Show available commands
- `::recent` - Show recent projections
- `::stats` - Activity statistics
- `::set timezone vancouver` - User preferences

### Database Queries
- Events: Recent messages and processing status
- Traces: LLM call history and performance
- Projections: Structured outputs (activities, notes, todos)
