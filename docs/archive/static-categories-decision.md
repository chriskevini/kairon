# Static Categories Design Decision

> **Status:** Recommended  
> **Date:** 2024-12-17  
> **Context:** Preparation for RAG implementation

---

## Decision

**Move from user-editable categories to static categories** for both activities and notes.

---

## Current State

### Activity Categories (User-Editable)

```sql
CREATE TABLE activity_categories (
  id UUID PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,
  active BOOLEAN DEFAULT true,
  is_sleep_category BOOLEAN DEFAULT false,
  sort_order INT,
  ...
);

CREATE TABLE activity_log (
  id UUID PRIMARY KEY,
  category_id UUID REFERENCES activity_categories(id),
  ...
);
```

**Problems:**
- LLM prompts need category list → requires DB lookup or stale cache
- User renames "work" → "job" → breaks all prompts expecting "work"
- `is_sleep_category` flag needed because can't hardcode name matching
- Special cases require flags or metadata workarounds
- Category FKs make data immutable but UI shows editable names → confusing

### Note Categories (User-Editable)

```sql
CREATE TABLE note_categories (
  id UUID PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,
  ...
);

CREATE TABLE notes (
  id UUID PRIMARY KEY,
  category_id UUID REFERENCES note_categories(id),
  ...
);
```

**Same problems as activities.**

---

## Proposed State

### Static Activity Categories

```sql
-- Remove dynamic table
DROP TABLE activity_categories;

-- Define static enum
CREATE TYPE activity_category AS ENUM (
  'work',
  'leisure', 
  'study',
  'health',
  'sleep',
  'relationships',
  'admin'
);

-- Update activity_log
ALTER TABLE activity_log DROP COLUMN category_id;
ALTER TABLE activity_log ADD COLUMN category activity_category NOT NULL;

-- No more JOINs needed
SELECT * FROM activity_log WHERE category = 'work';
```

### Static Note Categories (2-Category System)

```sql
-- Remove dynamic table
DROP TABLE note_categories;

-- Define minimal binary enum
CREATE TYPE note_category AS ENUM (
  'fact',
  'reflection'
);

-- Update notes
ALTER TABLE notes DROP COLUMN category_id;
ALTER TABLE notes ADD COLUMN category note_category NOT NULL;
```

**Why 2 Categories?**

The clearest semantic boundary in notes is: **external vs internal knowledge**

- **fact** → External, objective knowledge (birthdays, preferences, facts about people/things)
- **reflection** → Internal, subjective knowledge (insights, decisions, observations, realizations)

**Benefits of 2 categories:**
1. **Clear semantic boundary** - Easy for LLM to classify, easy to audit when wrong
2. **No collision with other systems:**
   - `question` → Handled by thread system (`++` chat tag)
   - `idea` → Handled by todo system (`$$` todo tag)
3. **Optimal for hybrid RAG** - Pre-filter by category, then semantic search
4. **Enables cross-type queries:**
   - Facts × Todos: "What should I get John?" → John's preferences + gift ideas
   - Reflections × Activities: "Why am I unproductive on Tuesdays?" → Tuesday activities + productivity reflections
5. **Simple mental model** - Binary choice reduces classification errors

---

## Benefits

### 1. Simpler LLM Prompts

**Before:**
```javascript
// Need to fetch categories from DB first
const categories = await db.query('SELECT name FROM activity_categories WHERE active = true');
const prompt = `Categories: ${categories.map(c => c.name).join(', ')}`;
```

**After:**
```javascript
// Static list, no DB lookup
const prompt = `Categories: work, leisure, study, health, sleep, relationships, admin`;
```

### 2. No Special Flags Needed

**Before:**
```sql
-- Need flag because can't rely on name
SELECT * FROM activity_log a
JOIN activity_categories c ON a.category_id = c.id
WHERE c.is_sleep_category = true;
```

**After:**
```sql
-- Direct enum comparison
SELECT * FROM activity_log WHERE category = 'sleep';
```

### 3. Faster Queries

**Before:**
```sql
-- Requires JOIN
SELECT a.*, c.name AS category_name
FROM activity_log a
JOIN activity_categories c ON a.category_id = c.id
WHERE c.name = 'work';
```

**After:**
```sql
-- No JOIN needed
SELECT * FROM activity_log 
WHERE category = 'work';
```

### 4. Data Integrity

**Before:**
- User renames category → prompts break
- User deletes category → orphaned data (prevented by FK, but confusing)
- User creates duplicate with different casing

**After:**
- Categories are immutable at DB level
- No orphaned data possible
- No naming conflicts

### 5. RAG Readiness

**With RAG:**
- Semantic search handles retrieval: "show me job-related stuff" → finds "work" category
- Categories become **UI labels for filtering**, not retrieval keys
- Embedding similarity > category matching

**Example:**
```sql
-- Semantic search doesn't care about category
SELECT re.raw_text, a.category
FROM embeddings e
JOIN raw_events re ON e.source_id = re.id
JOIN activity_log a ON a.raw_event_id = re.id
WHERE e.embedding <=> $query_embedding < 0.7
ORDER BY e.embedding <=> $query_embedding;

-- User query: "show me my job tasks"
-- Result: Retrieves category='work' activities via semantic match
```

### 6. Simpler Schema

**Before:** 4 tables (activity_categories, note_categories, activity_log, notes)  
**After:** 2 tables (activity_log, notes) + 2 enums

---

## Migration Strategy

### Phase 1: Prepare Migration

```sql
-- Check for custom category names
SELECT DISTINCT name FROM activity_categories 
WHERE name NOT IN ('work', 'leisure', 'study', 'health', 'sleep', 'relationships', 'admin');

SELECT DISTINCT name FROM note_categories
WHERE name NOT IN ('fact', 'reflection');
```

**Migration 002c handles this:**
- Maps old 5-category system → 2-category system
- `question`, `idea`, `decision`, `meta` → all become `reflection`
- `fact` → stays `fact`

**If custom categories exist:**
- Map to closest standard category
- Or add to enum if truly needed

### Phase 2: Create Enums

```sql
CREATE TYPE activity_category AS ENUM (
  'work', 'leisure', 'study', 'health', 'sleep', 'relationships', 'admin'
);

CREATE TYPE note_category AS ENUM (
  'fact', 'reflection'
);
```

### Phase 3: Migrate Data

```sql
-- Add temporary column
ALTER TABLE activity_log ADD COLUMN category_new activity_category;

-- Migrate data (map ID to name, then to enum)
UPDATE activity_log a
SET category_new = (
  SELECT c.name::activity_category 
  FROM activity_categories c 
  WHERE c.id = a.category_id
);

-- Verify no nulls
SELECT COUNT(*) FROM activity_log WHERE category_new IS NULL;
-- Should return 0

-- Drop old column, rename new
ALTER TABLE activity_log DROP COLUMN category_id;
ALTER TABLE activity_log RENAME COLUMN category_new TO category;
ALTER TABLE activity_log ALTER COLUMN category SET NOT NULL;

-- Same for notes
ALTER TABLE notes ADD COLUMN category_new note_category;
UPDATE notes n
SET category_new = (
  SELECT c.name::note_category 
  FROM note_categories c 
  WHERE c.id = n.category_id
);
ALTER TABLE notes DROP COLUMN category_id;
ALTER TABLE notes RENAME COLUMN category_new TO category;
ALTER TABLE notes ALTER COLUMN category SET NOT NULL;
```

### Phase 4: Drop Old Tables

```sql
-- Drop category tables (no longer needed)
DROP TABLE activity_categories;
DROP TABLE note_categories;
```

### Phase 5: Update Views

```sql
-- Update recent_activities view (no JOIN needed now)
CREATE OR REPLACE VIEW recent_activities AS
SELECT 
  a.id,
  a.timestamp,
  a.category,  -- Direct column, not JOIN
  a.description,
  a.thread_id,
  a.confidence,
  re.author_login,
  re.message_url
FROM activity_log a
JOIN raw_events re ON a.raw_event_id = re.id
ORDER BY a.timestamp DESC;

-- Update recent_notes view
CREATE OR REPLACE VIEW recent_notes AS
SELECT 
  n.id,
  n.timestamp,
  n.category,  -- Direct column, not JOIN
  n.title,
  n.text,
  n.thread_id,
  re.author_login,
  re.message_url
FROM notes n
JOIN raw_events re ON n.raw_event_id = re.id
ORDER BY n.timestamp DESC;
```

### Phase 6: Update n8n Workflows

**Activity_Handler.json:**
```javascript
// Before: Query category_id
const categoryResult = await db.query(
  'SELECT id FROM activity_categories WHERE name = $1',
  [$categoryName]
);
const categoryId = categoryResult.rows[0].id;

// After: Use enum directly
const category = $categoryName;  // e.g., 'work'
```

**Intent Classifier prompt:**
```
// Before: Categories fetched from DB
{{ $('Get Categories').item.json.categories }}

// After: Static list in prompt
Categories: work, leisure, study, health, sleep, relationships, admin
```

---

## Risks & Mitigations

### Risk 1: User Loses Customization

**Mitigation:** 
- Categories are for classification, not organization
- RAG enables "show me [custom concept]" via semantic search
- If truly needed, add user-defined tags separately (optional metadata)

### Risk 2: Categories Don't Fit User's Life

**Mitigation:**
- Current 7 activity categories are broad and universal
- Can add more enums if needed (but keep small, ~10 max)
- Edge cases go into closest category + semantic search handles retrieval

### Risk 3: Breaking Existing Workflows

**Mitigation:**
- Test migration on copy first
- Update workflows before migration
- Run parallel for 1 week (both systems work)

---

## Timeline

### Week 1: Preparation
- [ ] Audit existing custom categories
- [ ] Map custom → standard categories
- [ ] Write migration script
- [ ] Test on copy of production DB

### Week 2: Migration
- [ ] Backup production DB
- [ ] Run migration
- [ ] Verify all data migrated correctly
- [ ] Update n8n workflows
- [ ] Test end-to-end

### Week 3: Cleanup
- [ ] Monitor for issues
- [ ] Update all documentation
- [ ] Remove category management UI (if any)

---

## Future: Adding Categories

If a new category is truly needed:

```sql
-- Can't just add to enum (PostgreSQL limitation)
-- Must recreate with new value

-- 1. Create new enum with additional value
CREATE TYPE activity_category_new AS ENUM (
  'work', 'leisure', 'study', 'health', 'sleep', 'relationships', 'admin',
  'creative'  -- new category
);

-- 2. Alter table to use new enum
ALTER TABLE activity_log 
  ALTER COLUMN category TYPE activity_category_new 
  USING category::text::activity_category_new;

-- 3. Drop old enum
DROP TYPE activity_category;

-- 4. Rename new enum
ALTER TYPE activity_category_new RENAME TO activity_category;
```

**Note:** This is complex, so keep categories stable. Only add when absolutely necessary.

---

## Alternative: Hybrid Approach

If you want to keep some flexibility:

```sql
-- Static categories as before
ALTER TABLE activity_log ADD COLUMN category activity_category NOT NULL;

-- Optional user-defined tags
ALTER TABLE activity_log ADD COLUMN tags TEXT[];

-- Query with both
SELECT * FROM activity_log 
WHERE category = 'work' 
  OR 'work' = ANY(tags);
```

This allows:
- Standard classification via `category` (for prompts, logic)
- User organization via `tags` (for filtering, UI)
- RAG handles semantic search across both

**Recommendation:** Start with pure static categories. Add tags later if truly needed.

---

## Decision

**Proceed with static categories** as part of Phase 1 (pre-RAG).

**Rationale:**
1. Simpler architecture now
2. Better RAG integration later
3. Faster queries
4. No loss of functionality (semantic search replaces custom categories)
5. Can always add tags/metadata if needed

---

## References

- `db/migrations/001_initial_schema.sql` - Current dynamic categories
- `docs/rag-implementation-design.md` - RAG architecture
- `docs/todo-intent-design.md` - Similar pattern for static intents
