# Summary: Terminology & Architecture Updates

**Date:** 2024-12-17  
**Changes:** Tag system finalized, commit → save terminology, clean architecture plan

---

## Tag System - Finalized ✅

### All Supported Tags

| Symbol | Word    | Intent       | Example |
|--------|---------|--------------|---------|
| `!!`   | `act`   | Activity     | `!! working on auth` |
| `..`   | `note`  | Note         | `.. interesting insight` |
| `++`   | `ask`   | Thread Start | `++ what did I work on?` |
| `--`   | `save`  | Thread Save  | `-- (saves & closes thread)` |
| `::`   | `cmd`   | Command      | `::todos` |
| `$$`   | `todo`  | Todo         | `$$ buy milk` |

### Design Principles

1. **Ease of typing** (top priority)
   - Symbols: 2 chars, easy on mobile
   - Words: Short, common words

2. **LLM robustness** (second priority)
   - Consistent character count (all symbols = 2 chars)
   - Clear word boundaries

3. **Symmetry & memorability**
   - `++` start thread / `--` save thread (symmetric!)
   - Words are intuitive: `act`, `note`, `ask`, `save`, `todo`

4. **Position-aware parsing**
   - Tags only at **start of message** (position 0)
   - Prevents accidental invocation mid-sentence

### Why `--` / `save` (not `++` / `commit`)

- **Symmetry:** `++` increase / `--` decrease (start / end)
- **Shorter word:** `save` (4 chars) vs `commit` (6 chars)
- **Clearer meaning:** "Save conversation" more intuitive than "commit thread"
- **Matches other tags:** All words are 3-4 chars (act, note, ask, save, todo, cmd)

---

## Commit → Save Terminology Change ✅

### Renamed Files

- `prompts/commit-thread.md` → `prompts/save-thread.md`

### Updated References

- All documentation: "commit thread" → "save thread"
- Migration 002: Comments updated
- Tag parsing guide: `commit` → `save`
- Prompt examples: User types `--` or `save`

### Save Thread Behavior

**Simplified from original design:**

**OLD (complex):**
```
Thread → Commit (++) → LLM → note + activity
```

**NEW (simple):**
```
Thread → Save (--) → LLM → note only
```

**Rationale:**
- Threads are long-living conversations (not point-in-time)
- Activities are point-in-time observations
- Thread = exploration/thinking = note-like
- Simpler to implement and reason about

**Schema change:**
- `conversations.activity_id` removed (migration 002)
- Only `conversations.note_id` remains

---

## Architecture: Clean First ✅

### Decision: Option B (Clean Architecture Priority)

**Order of implementation:**

1. **Static categories** (Week 1)
2. **Save thread** (Week 2)
3. **Todos** (Week 2-3)

### Why This Order?

**Static categories affect everything:**
- Save thread needs to know category structure
- Todo handler needs category list in prompts
- All current handlers use categories
- Better to migrate once than change twice

**Benefits:**
- Clean architecture from day 1
- All new features built on solid foundation
- No need to refactor after launch

---

## Implementation Status

### ✅ Ready to Execute

**Created files:**
- `db/migrations/002_static_categories.sql` - Production ready
- `db/migrations/003_add_todos.sql` - Production ready
- `docs/tag-parsing-reference.md` - Complete tag spec
- `docs/clean-architecture-implementation-plan.md` - 3-week plan
- `docs/static-categories-decision.md` - Rationale & migration
- `docs/database-migration-safety.md` - Safety procedures
- `prompts/save-thread.md` - Updated prompt

**Updated files:**
- `docs/todo-intent-design.md` - All design decisions resolved
- `docs/rag-implementation-design.md` - RAG architecture

### 🔄 Pending (Implementation Phase)

**Week 1:**
- [ ] Test migration 002 on copy
- [ ] Run migration 002 in production
- [ ] Update Activity_Handler.json (use enums)
- [ ] Update Note_Handler.json (use enums)
- [ ] Update all prompts (static lists)
- [ ] Update tag parsing in router

**Week 2:**
- [ ] Create Save_Thread_Handler.json
- [ ] Wire `--` tag to handler
- [ ] Test save thread flow
- [ ] Run migration 003 (todos)
- [ ] Create Todo_Handler.json
- [ ] Update Intent Classifier prompt

**Week 3:**
- [ ] Implement auto-completion
- [ ] Add todo commands
- [ ] Integrate with daily summary
- [ ] Create proactive reminders
- [ ] Update documentation

---

## Key Design Decisions - Resolved

### 1. Tags ✅

**Symbols:** `!!`, `..`, `++`, `--`, `::`, `$$`  
**Words:** `act`, `note`, `ask`, `save`, `cmd`, `todo`  
**Parsing:** Position 0 only, case-insensitive words

### 2. Static Categories ✅

**Activity:** `work`, `leisure`, `study`, `health`, `sleep`, `relationships`, `admin`  
**Note:** `idea`, `reflection`, `decision`, `question`, `meta`  
**Rationale:** Simpler prompts, faster queries, RAG-ready

### 3. Save Thread Behavior ✅

**Creates:** Note only (not activity)  
**Why:** Threads are conversations, not point-in-time events  
**Schema:** Removed `conversations.activity_id`

### 4. Todos ✅

**Structure:** Hierarchical (parent_todo_id, is_goal)  
**Auto-completion:** pg_trgm similarity matching  
**Reminders:** Context, time, and activity-based  
**Sub-tasks:** Supported via parent relationship

---

## Migration Safety

### Backup Before Everything

```bash
# Before any migration
pg_dump -U n8n_user -d kairon -F c -f backups/backup_$(date +%Y%m%d_%H%M%S).dump
```

### Test on Copy First

```bash
createdb kairon_test
pg_restore -d kairon_test backups/backup_*.dump
psql -d kairon_test -f db/migrations/002_static_categories.sql
# Test, verify, then run on production
```

### Risk Levels

- **Migration 002 (static categories):** MEDIUM - Transforms existing data
- **Migration 003 (add todos):** LOW - Additive only

See: `docs/database-migration-safety.md` for detailed procedures.

---

## Next Actions

**Ready to start Week 1:**

1. **Review migration 002** (`db/migrations/002_static_categories.sql`)
2. **Test on copy database** (follow safety guide)
3. **Run in production** (during low-usage time)
4. **Update workflows** (Activity_Handler, Note_Handler)
5. **Update prompts** (static category lists)
6. **Update router tag parsing**

**Questions before proceeding?**

---

## References

**Design docs:**
- `docs/todo-intent-design.md` - Full todo system design
- `docs/static-categories-decision.md` - Why static categories
- `docs/rag-implementation-design.md` - Future RAG architecture
- `docs/tag-parsing-reference.md` - Complete tag specification
- `docs/clean-architecture-implementation-plan.md` - 3-week roadmap

**Migrations:**
- `db/migrations/002_static_categories.sql` - Convert to enums
- `db/migrations/003_add_todos.sql` - Add todos table

**Prompts:**
- `prompts/save-thread.md` - Thread summarization (note only)
- `prompts/router-agent.md` - Intent classification (needs $$ update)
- `prompts/thread-agent.md` - Thread agent (static categories)

**Safety:**
- `docs/database-migration-safety.md` - Backup/test/verify procedures
