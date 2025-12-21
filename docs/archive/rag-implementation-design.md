# RAG Implementation Design

> **Status:** Planning phase  
> **Last Updated:** 2024-12-17  
> **Dependencies:** PostgreSQL with pgvector extension

---

## Overview

This document outlines the plan for implementing **Retrieval-Augmented Generation (RAG)** in Kairon Life OS, enabling **hybrid search** (metadata filtering + semantic search) across all user data.

**Goals:**
- Hybrid search: Category/metadata filtering + semantic embeddings
- Cross-type queries: Combine facts × todos, reflections × activities
- Context-aware thread responses
- Pattern recognition and insights
- Reduce hallucination via pre-filtering

**Key Insight: The 2-Category System**

Notes use a **binary category system** (`fact` vs `reflection`) optimized for RAG:
- **fact** → External, objective knowledge (birthdays, preferences, facts about people/things)
- **reflection** → Internal, subjective knowledge (insights, decisions, observations)

This enables powerful cross-type queries while maintaining simplicity.

---

## Why RAG?

### Current System

**Strengths:**
- Fast category-based filtering (exact matches)
- Static categories prevent schema drift
- Clear organizational structure

**Limitations:**
- Can't find "that conversation about productivity" without keywords
- No conceptual/semantic search
- Can't combine data types (e.g., "facts about John" + "todos for John")

### With Hybrid RAG

**The Gold Standard: Metadata Filtering + Semantic Search**

1. **Pre-filter by metadata** (fast, exact)
   - Category: `note_category = 'fact'`
   - Time: `timestamp > NOW() - INTERVAL '30 days'`
   - Type: `entity_type = 'activity'`

2. **Then semantic search** (focused, accurate)
   - Smaller corpus = better results
   - Reduces hallucination
   - Cheaper computation

**Example queries:**
- "Show me facts about John's preferences" → Filter `fact` category, then semantic search "John preferences"
- "Why am I unproductive on Tuesdays?" → Filter Tuesday activities + reflections, then semantic search "productivity patterns"
- "What did I decide about sleep?" → Filter `reflection` category + sleep-related activities, semantic search "decision sleep"

---

## Architecture

### Vector Storage Strategy

**Option A: Single Embeddings Table (Recommended)**

Store all embeddings centrally, reference source tables:

```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE embeddings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Source reference (polymorphic)
  source_table TEXT NOT NULL CHECK (source_table IN ('raw_events', 'notes', 'conversations')),
  source_id UUID NOT NULL,
  
  -- Vector
  embedding VECTOR(1536) NOT NULL, -- OpenAI text-embedding-3-small
  
  -- Metadata for filtering
  author_login TEXT,
  created_at TIMESTAMPTZ NOT NULL,
  entity_type TEXT, -- 'message', 'note', 'activity', 'todo', 'conversation'
  
  -- Additional searchable metadata
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Timestamps
  embedded_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_embeddings_vector ON embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX idx_embeddings_source ON embeddings(source_table, source_id);
CREATE INDEX idx_embeddings_entity_type ON embeddings(entity_type);
CREATE INDEX idx_embeddings_created_at ON embeddings(created_at DESC);
CREATE INDEX idx_embeddings_author ON embeddings(author_login);

COMMENT ON TABLE embeddings IS 'Centralized vector embeddings for semantic search across all entities';
COMMENT ON COLUMN embeddings.source_table IS 'Which table this embedding references';
COMMENT ON COLUMN embeddings.source_id IS 'ID in the source table';
COMMENT ON COLUMN embeddings.entity_type IS 'Logical entity type for filtering (may differ from source_table)';
```

**Rationale:**
- Single index to maintain (faster queries)
- Unified search across all entities
- Easy to add new source tables
- Metadata filtering for scoped queries

**Option B: Embeddings Per Table**

Add `embedding` column to each table (raw_events, notes, activity_log, todos):

```sql
ALTER TABLE raw_events ADD COLUMN embedding VECTOR(1536);
ALTER TABLE notes ADD COLUMN embedding VECTOR(1536);
-- etc.
```

**Why not this:**
- Multiple indexes to maintain (slower writes)
- Can't do unified search without UNION ALL
- Harder to manage embedding pipeline
- Duplicates embeddings (raw_events + notes both have same text)

### What to Embed

**Priority 1: Raw Events**
- Embed `raw_events.raw_text` (original user message)
- Captures user's exact words
- Most important for retrieval

**Priority 2: Notes**
- Embed `notes.text` (may include synthesized text from threads)
- Notes are longer-form, benefit from semantic search

**Priority 3: Conversation Summaries**
- Embed final thread topic/summary when committed
- Enables "find that conversation about X"

**Skip:**
- Individual `conversation_messages` (too granular, use summary)
- `activity_log.description` (covered by raw_events)
- `todos.description` (covered by raw_events)

---

## Embedding Pipeline

### On Message Receipt

**Workflow: Discord_Message_Router.json**

After storing in `raw_events`:

1. Check if message length > 10 chars (skip very short messages)
2. Call OpenAI embedding API:
   ```
   POST https://api.openai.com/v1/embeddings
   {
     "model": "text-embedding-3-small",
     "input": "{{ $json.raw_text }}"
   }
   ```
3. Insert into `embeddings`:
   ```sql
   INSERT INTO embeddings (
     source_table,
     source_id,
     embedding,
     author_login,
     created_at,
     entity_type,
     metadata
   ) VALUES (
     'raw_events',
     $raw_event_id,
     $embedding_vector,
     $author_login,
     $received_at,
     $intent, -- 'activity', 'note', 'todo', 'discussion'
     jsonb_build_object(
       'tag', $tag,
       'thread_id', $thread_id,
       'confidence', $confidence
     )
   );
   ```

### On Note Creation

**Workflow: Note_Handler.json**

After storing note:

1. Check if note text differs significantly from raw_text (e.g., thread commit with synthesized summary)
2. If different, create separate embedding
3. If same, skip (already embedded from raw_event)

### On Thread Commit

**Workflow: Thread_Continuation_Agent.json**

When thread is committed:

1. Generate summary of entire conversation
2. Embed the summary
3. Link to `conversations.id`

### Backfill Existing Data

**One-time migration script:**

```sql
-- Backfill raw_events
INSERT INTO embeddings (source_table, source_id, embedding, author_login, created_at, entity_type)
SELECT 
  'raw_events',
  id,
  NULL, -- will be populated by batch job
  author_login,
  received_at,
  CASE 
    WHEN tag = '!!' THEN 'activity'
    WHEN tag = '..' THEN 'note'
    WHEN tag = '++' THEN 'discussion'
    WHEN tag = '::' THEN 'command'
    ELSE 'message'
  END
FROM raw_events
WHERE LENGTH(raw_text) > 10
ON CONFLICT DO NOTHING;
```

Then run batch embedding job (n8n workflow triggered manually).

---

## Query Patterns

### Basic Semantic Search

```sql
-- Find messages similar to query
SELECT 
  e.source_table,
  e.source_id,
  re.raw_text,
  re.received_at,
  1 - (e.embedding <=> $query_embedding) AS similarity
FROM embeddings e
JOIN raw_events re ON e.source_table = 'raw_events' AND e.source_id = re.id
WHERE e.entity_type = 'activity'
  AND e.created_at > NOW() - INTERVAL '30 days'
ORDER BY e.embedding <=> $query_embedding
LIMIT 10;
```

### Filtered Semantic Search

```sql
-- Find work-related messages about "productivity" from last week
WITH query_vector AS (
  SELECT embedding FROM get_embedding('productivity tips') -- helper function
)
SELECT 
  re.raw_text,
  re.received_at,
  a.description AS activity,
  ac.name AS category,
  1 - (e.embedding <=> q.embedding) AS similarity
FROM embeddings e
CROSS JOIN query_vector q
JOIN raw_events re ON e.source_id = re.id
LEFT JOIN activity_log a ON a.raw_event_id = re.id
LEFT JOIN activity_categories ac ON a.category_id = ac.id
WHERE e.source_table = 'raw_events'
  AND e.created_at > NOW() - INTERVAL '7 days'
  AND (ac.name = 'work' OR e.metadata->>'tag' = '!!')
  AND (e.embedding <=> q.embedding) < 0.7
ORDER BY e.embedding <=> q.embedding
LIMIT 20;
```

### Hybrid Search (Keyword + Semantic)

```sql
-- Combine full-text search with vector similarity
WITH query_vector AS (
  SELECT embedding FROM get_embedding($user_query)
)
SELECT 
  re.id,
  re.raw_text,
  re.received_at,
  ts_rank(to_tsvector('english', re.raw_text), plainto_tsquery('english', $user_query)) AS keyword_score,
  1 - (e.embedding <=> q.embedding) AS semantic_score,
  (ts_rank(to_tsvector('english', re.raw_text), plainto_tsquery('english', $user_query)) * 0.3 +
   (1 - (e.embedding <=> q.embedding)) * 0.7) AS combined_score
FROM embeddings e
CROSS JOIN query_vector q
JOIN raw_events re ON e.source_id = re.id
WHERE e.source_table = 'raw_events'
  AND (
    to_tsvector('english', re.raw_text) @@ plainto_tsquery('english', $user_query)
    OR (e.embedding <=> q.embedding) < 0.7
  )
ORDER BY combined_score DESC
LIMIT 20;
```

---

## Cross-Type Query Patterns

**The Power of Hybrid RAG: Combining Data Types**

The 2-category note system (`fact` vs `reflection`) enables powerful cross-type queries that combine different tables for richer context.

### Pattern 1: Facts × Todos

**Query:** "What should I get John for his birthday?"

**Strategy:**
```sql
-- Step 1: Get facts about John
WITH john_facts AS (
  SELECT n.text, 1 - (e.embedding <=> $query_embedding) AS similarity
  FROM embeddings e
  JOIN notes n ON e.source_id = n.id
  WHERE e.source_table = 'notes'
    AND n.category = 'fact'
    AND e.embedding <=> $query_embedding < 0.7
  ORDER BY e.embedding <=> $query_embedding
  LIMIT 5
),
-- Step 2: Get todos mentioning John
john_todos AS (
  SELECT t.description, t.status
  FROM embeddings e
  JOIN todos t ON e.source_id = t.id
  WHERE e.source_table = 'todos'
    AND e.embedding <=> $query_embedding < 0.7
  ORDER BY e.embedding <=> $query_embedding
  LIMIT 3
)
-- Step 3: Combine for LLM context
SELECT * FROM john_facts
UNION ALL
SELECT text AS description, 'fact' AS status FROM john_todos;
```

**Result:**
- Facts: "John loves dark roast coffee", "John wants noise-canceling headphones"
- Todos: "should buy noise-canceling headphones for John"
- LLM synthesis: "You already noted John wants noise-canceling headphones, and he loves dark roast coffee"

### Pattern 2: Reflections × Activities

**Query:** "Why do I feel unproductive on Tuesdays?"

**Strategy:**
```sql
-- Step 1: Get Tuesday activities
WITH tuesday_activities AS (
  SELECT a.description, a.category, a.timestamp
  FROM activity_log a
  WHERE EXTRACT(dow FROM a.timestamp) = 2  -- Tuesday
    AND a.timestamp > NOW() - INTERVAL '90 days'
  ORDER BY a.timestamp DESC
  LIMIT 20
),
-- Step 2: Get reflections about productivity from Tuesdays
tuesday_reflections AS (
  SELECT n.text, n.timestamp, 1 - (e.embedding <=> $query_embedding) AS similarity
  FROM embeddings e
  JOIN notes n ON e.source_id = n.id
  WHERE e.source_table = 'notes'
    AND n.category = 'reflection'
    AND EXTRACT(dow FROM n.timestamp) = 2
    AND n.timestamp > NOW() - INTERVAL '90 days'
    AND e.embedding <=> $query_embedding < 0.7
  ORDER BY e.embedding <=> $query_embedding
  LIMIT 10
)
SELECT * FROM tuesday_activities
UNION ALL
SELECT text, timestamp, category FROM tuesday_reflections;
```

**Result:**
- Activities: Heavy admin tasks, meetings, context switching
- Reflections: "meetings fragment my day", "context switching kills flow"
- LLM synthesis: "Tuesdays have more meetings and admin work. Your reflections show context switching disrupts your productivity."

### Pattern 3: Facts × Activities × Reflections (Triple Join!)

**Query:** "How can I better support Sarah at work?"

**Strategy:**
```sql
-- Step 1: Facts about Sarah
WITH sarah_facts AS (
  SELECT n.text, 'fact' AS type
  FROM embeddings e
  JOIN notes n ON e.source_id = n.id
  WHERE e.source_table = 'notes'
    AND n.category = 'fact'
    AND e.embedding <=> embed('Sarah preferences communication') < 0.7
  LIMIT 5
),
-- Step 2: Activities with Sarah (relationship category)
sarah_activities AS (
  SELECT a.description, a.timestamp, 'activity' AS type
  FROM activity_log a
  JOIN embeddings e ON e.source_id = a.id
  WHERE a.category = 'relationships'
    AND e.embedding <=> embed('Sarah work collaboration') < 0.7
  ORDER BY a.timestamp DESC
  LIMIT 10
),
-- Step 3: Reflections about collaboration
collab_reflections AS (
  SELECT n.text, n.timestamp, 'reflection' AS type
  FROM embeddings e
  JOIN notes n ON e.source_id = n.id
  WHERE n.category = 'reflection'
    AND e.embedding <=> embed('async communication collaboration') < 0.7
  LIMIT 5
)
SELECT * FROM sarah_facts
UNION ALL SELECT * FROM sarah_activities
UNION ALL SELECT * FROM collab_reflections;
```

**Result:**
- Facts: "Sarah prefers async communication", "Sarah has kids"
- Activities: Past work sessions, meeting patterns
- Reflections: "async communication reduces stress", "scheduling flexibility helps"
- LLM synthesis: "Sarah prefers async due to kid schedule. Your reflections show async works better for you too. Send updates end-of-day instead of real-time."

### Pattern 4: Time-Based Pattern Discovery

**Query:** "What patterns emerge when I sleep poorly?"

**Strategy:**
```sql
-- Step 1: Find poor sleep activities
WITH poor_sleep_dates AS (
  SELECT DATE(timestamp) AS sleep_date
  FROM activity_log
  WHERE category = 'sleep'
    AND (
      description ILIKE '%poor%' 
      OR description ILIKE '%restless%'
      OR confidence < 0.5  -- uncertain classification = disrupted routine
    )
),
-- Step 2: Get activities on those dates
sleep_day_activities AS (
  SELECT a.*, DATE(a.timestamp) AS activity_date
  FROM activity_log a
  JOIN poor_sleep_dates ps ON DATE(a.timestamp) = ps.sleep_date
  WHERE a.category != 'sleep'
),
-- Step 3: Get reflections from those days
sleep_day_reflections AS (
  SELECT n.text, DATE(n.timestamp) AS note_date
  FROM notes n
  JOIN poor_sleep_dates ps ON DATE(n.timestamp) = ps.sleep_date
  WHERE n.category = 'reflection'
)
SELECT 
  COUNT(*) AS frequency,
  category,
  description
FROM sleep_day_activities
GROUP BY category, description
ORDER BY frequency DESC
LIMIT 10;
```

**Result:**
- Pattern: Late work sessions (after 10pm) correlate with poor sleep
- Reflections: "feeling wired", "can't shut brain off"
- LLM synthesis: "When you work late, you note feeling wired and have poor sleep. Consider setting an evening cutoff time."

### Pattern 5: Gift Ideas (Practical Example)

**Query:** "What should I get Mom for her birthday?"

**Strategy:**
```sql
-- Hard filter: facts about Mom
WITH mom_facts AS (
  SELECT n.text, 1 - (e.embedding <=> $query) AS similarity
  FROM embeddings e
  JOIN notes n ON e.source_id = n.id
  WHERE e.source_table = 'notes'
    AND n.category = 'fact'
    AND (
      e.metadata->>'text' ILIKE '%mom%'
      OR e.metadata->>'text' ILIKE '%mother%'
    )
  ORDER BY e.embedding <=> embed('Mom preferences likes hobbies') 
  LIMIT 10
)
SELECT * FROM mom_facts;
```

**Result:**
- "Mom loves gardening books"
- "Mom's favorite flowers are peonies"
- "Mom enjoys historical fiction"
- LLM synthesis: "Based on your notes, your mom loves gardening books and historical fiction. Her favorite flowers are peonies."

---

## Cross-Type Query Implementation

### n8n Workflow Pattern

**Workflow: Hybrid_RAG_Query.json**

```
Input: { query, query_type }
  ↓
[Classify Query Type] (e.g., "gift_idea", "pattern_discovery", "support_person")
  ↓
[Generate Query Embedding]
  ↓
[Branch by Query Type]
  ↓
  ├─→ [Facts × Todos Query] → [Merge Results]
  ├─→ [Reflections × Activities Query] → [Merge Results]
  └─→ [Triple Join Query] → [Merge Results]
  ↓
[Format Context for LLM]
  ↓
[Generate Response]
```

### Query Type Classification

**Auto-detect which tables to search:**

```javascript
// Code node: Classify Query Type
const query = $json.query.toLowerCase();

let queryType;
let tables;

if (query.match(/gift|buy|get.*for|birthday.*present/)) {
  queryType = 'gift_idea';
  tables = ['notes:fact', 'todos'];
} else if (query.match(/why.*feel|pattern|tend to|always/)) {
  queryType = 'pattern_discovery';
  tables = ['activities', 'notes:reflection'];
} else if (query.match(/support|help.*with|better.*for/)) {
  queryType = 'relationship_support';
  tables = ['notes:fact', 'activities:relationships', 'notes:reflection'];
} else if (query.match(/when|what time|date|birthday/)) {
  queryType = 'factual_recall';
  tables = ['notes:fact'];
} else {
  queryType = 'general_search';
  tables = ['notes', 'activities', 'todos'];
}

return { json: { queryType, tables, originalQuery: query } };
```

---

## Integration Points

### Thread Agent Context Retrieval

**Current:** Thread agent explicitly calls `retrieve_recent_activities()`, `retrieve_recent_notes()`

**With RAG:** Thread agent can do semantic retrieval

**New tool for thread-agent.md:**

```markdown
### semantic_search(query, timeframe, entity_types, limit)

Semantic search across all user data.

**Parameters:**
- `query`: Natural language search query (e.g., "morning routine", "productivity issues")
- `timeframe`: "today" | "this_week" | "30d" | "all" (default: "30d")
- `entity_types`: Array of types to search (e.g., ["activity", "note"]) or null for all
- `limit`: Number of results (default: 10, max: 50)

**Returns:** Relevant messages, activities, notes, todos with similarity scores

**Examples:**
- "Show me everything about sleep patterns" → semantic_search("sleep patterns", "30d", null, 20)
- "What productivity insights did I note?" → semantic_search("productivity", "all", ["note"], 10)
```

### Daily Summary Enhancement

**Current:** Daily summary uses time-based queries

**With RAG:** Can identify themes and patterns

**Enhanced Daily_Summary_Generator.json:**

1. Get all activities/notes from today
2. Embed summary of today: "Summary of user's day: [activity list]"
3. Semantic search for similar past days
4. Include in summary: "Today was similar to [date] when you [pattern]"

### Pattern Recognition

**New workflow: Weekly_Insights_Generator.json**

1. Get all activities from past week
2. Embed weekly summary
3. Semantic search for similar patterns in history
4. Generate insights:
   - "You tend to have low energy after late work nights"
   - "Your most productive days include morning exercise"
   - "Sleep quality correlates with reduced screen time"

---

## Performance Considerations

### Index Strategy

- **IVFFlat index:** Good for datasets < 1M vectors
  - `lists = 100` for ~10k vectors
  - `lists = 1000` for ~1M vectors
- **Query time:** ~10-50ms for 10k vectors
- **Build time:** A few seconds for 10k vectors

### Embedding Costs

**OpenAI text-embedding-3-small:**
- Cost: $0.02 / 1M tokens
- Typical message: ~50 tokens
- 10k messages: ~500k tokens = $0.01
- Very affordable for personal use

**Volume estimates:**
- 50 messages/day = 1,500/month = 18k/year
- 3 years of usage = ~50k embeddings
- Total cost: ~$0.50/year for embeddings

### Query Optimization

**Best Practices:**
1. Always filter by `created_at` when possible (indexed)
2. Use `entity_type` filter to reduce search space
3. Set reasonable distance threshold (< 0.7)
4. Limit results (default 10-20, max 50)
5. Use `EXPLAIN ANALYZE` to tune queries

**Example optimized query:**

```sql
SELECT re.raw_text, 1 - (e.embedding <=> $query) AS similarity
FROM embeddings e
JOIN raw_events re ON e.source_id = re.id
WHERE e.source_table = 'raw_events'
  AND e.entity_type IN ('activity', 'note')  -- filter
  AND e.created_at > NOW() - INTERVAL '30 days'  -- narrow time window
  AND e.embedding <=> $query < 0.7  -- distance threshold
ORDER BY e.embedding <=> $query
LIMIT 10;
```

---

## Migration from Categories

### Transition Strategy

**Phase 1: Parallel Operation**
- Keep existing category-based queries
- Add RAG-powered semantic search
- A/B test retrieval quality

**Phase 2: Gradual Shift**
- Thread agent uses semantic search by default
- Keep categories for UI filtering/visualization
- Deprecate category-based prompts for LLM

**Phase 3: Static Categories**
- Remove user-editable categories (keep as fixed enums)
- Categories become UI labels only
- All retrieval via RAG

**Why static categories are better with RAG:**
- LLM prompts don't need DB lookups
- Data integrity guaranteed
- Categories used for quick filtering in UI
- Semantic search handles retrieval needs
- Simpler schema, fewer moving parts

### Category Schema Simplification

**Current (After Migration 002c):**
```sql
-- Static enums (no editable tables)
CREATE TYPE activity_category AS ENUM ('work', 'leisure', 'study', 'health', 'sleep', 'relationships', 'admin');
CREATE TYPE note_category AS ENUM ('fact', 'reflection');

-- Direct enum columns (no FK joins)
activity_log.category activity_category NOT NULL;
notes.category note_category NOT NULL;
```

**Benefits:**
- No JOINs needed for category lookups
- No orphaned FKs or data integrity issues
- Simpler LLM prompts (fixed list, no DB lookup)
- Faster queries (no join overhead)
- Easier to reason about
- 2-category system for notes optimizes RAG filtering

**Why 2 Categories for Notes?**
- Clear semantic boundary: external knowledge (fact) vs internal knowledge (reflection)
- Enables hybrid RAG: filter by category, then semantic search
- Reduces classification errors (easier for LLM to distinguish)
- Supports cross-type queries (facts × todos, reflections × activities)
- No collision with threads (questions → chat tag) or todos (ideas → todo tag)

---

## Implementation Roadmap

### Phase 1: Core Infrastructure (Week 1)

- [ ] Install pgvector extension: `CREATE EXTENSION vector;`
- [ ] Create `embeddings` table with indexes
- [ ] Test embedding API calls in n8n
- [ ] Create helper workflow: `Generate_Embedding.json` (reusable)

### Phase 2: Real-Time Embedding (Week 2)

- [ ] Update `Discord_Message_Router.json` to embed new messages
- [ ] Update `Note_Handler.json` to embed note text
- [ ] Test end-to-end: message → embed → store → query
- [ ] Monitor embedding costs and latency

### Phase 3: Backfill (Week 3)

- [ ] Write backfill migration
- [ ] Create batch embedding workflow
- [ ] Run backfill on historical data (may take hours for large datasets)
- [ ] Verify index performance

### Phase 4: Query Tools (Week 4)

- [ ] Add `semantic_search()` tool to thread agent
- [ ] Create test queries in n8n
- [ ] Compare semantic vs category-based retrieval
- [ ] Gather user feedback

### Phase 5: Advanced Features (Month 2)

- [ ] Hybrid search (keyword + semantic)
- [ ] Pattern recognition insights
- [ ] Enhanced daily/weekly summaries
- [ ] Thread commit summaries
- [ ] Multi-intent extraction from historical data

### Phase 6: Category Migration (Month 3)

- [ ] Decide based on RAG performance
- [ ] If good: migrate to static categories
- [ ] Update all prompts
- [ ] Simplify schema
- [ ] Remove category management UI

---

## Open Questions

1. **Should we embed in real-time or batch?**
   - Real-time: Better UX, higher API costs
   - Batch: Lower costs, delayed search availability
   - **Recommendation:** Real-time for new messages, batch for backfill

2. **Should we use hybrid search by default?**
   - Keyword search is fast and precise for exact matches
   - Semantic search is better for fuzzy/conceptual queries
   - **Recommendation:** Hybrid with adjustable weights

3. **How to handle embedding model updates?**
   - OpenAI may release new models (e.g., text-embedding-3-large)
   - Requires re-embedding entire dataset
   - **Recommendation:** Store model version in metadata, plan for migrations

4. **Should we support multi-lingual embeddings?**
   - text-embedding-3 supports 100+ languages
   - May need language detection for better results
   - **Recommendation:** Start English-only, expand if needed

5. **How to protect privacy in embeddings?**
   - Embeddings can leak information about original text
   - Store embeddings with same security as raw data
   - **Recommendation:** Same security model as raw_events table

---

## References

- **pgvector:** https://github.com/pgvector/pgvector
- **OpenAI Embeddings:** https://platform.openai.com/docs/guides/embeddings
- **Vector Search Best Practices:** https://www.timescale.com/blog/nearest-neighbor-indexes-what-are-ivfflat-indexes-in-pgvector-and-how-do-they-work/

---

## Appendix: Sample n8n Workflow Nodes

### Generate Embedding Node

```json
{
  "parameters": {
    "authentication": "headerAuth",
    "url": "https://api.openai.com/v1/embeddings",
    "method": "POST",
    "bodyParameters": {
      "parameters": [
        {
          "name": "model",
          "value": "text-embedding-3-small"
        },
        {
          "name": "input",
          "value": "={{ $json.raw_text }}"
        }
      ]
    }
  },
  "name": "Generate Embedding",
  "type": "n8n-nodes-base.httpRequest"
}
```

### Store Embedding Node

```json
{
  "parameters": {
    "operation": "executeQuery",
    "query": "INSERT INTO embeddings (source_table, source_id, embedding, author_login, created_at, entity_type, metadata) VALUES ('raw_events', $1, $2::vector, $3, $4, $5, $6) RETURNING id",
    "options": {
      "queryReplacement": "={{ $json.raw_event_id }},{{ JSON.stringify($('Generate Embedding').item.json.data[0].embedding) }},={{ $json.author_login }},={{ $json.received_at }},={{ $json.intent }},={{ JSON.stringify($json.metadata) }}"
    }
  },
  "name": "Store Embedding",
  "type": "n8n-nodes-base.postgres"
}
```

### Semantic Search Node

```json
{
  "parameters": {
    "operation": "executeQuery",
    "query": "SELECT re.raw_text, re.received_at, 1 - (e.embedding <=> $1::vector) AS similarity FROM embeddings e JOIN raw_events re ON e.source_id = re.id WHERE e.source_table = 'raw_events' AND e.created_at > NOW() - INTERVAL $2 ORDER BY e.embedding <=> $1::vector LIMIT $3",
    "options": {
      "queryReplacement": "={{ JSON.stringify($('Generate Query Embedding').item.json.data[0].embedding) }},={{ $json.timeframe || '30 days' }},={{ $json.limit || 10 }}"
    }
  },
  "name": "Semantic Search",
  "type": "n8n-nodes-base.postgres"
}
```
